// Package tegrauefi implements connector.Connector for NVIDIA Jetson
// (UEFI boot, L4T r36/r38). It is a direct port of the three
// hardware-validated meta-edgeos state scripts (switch-rootfs,
// verify-bootloader-update, reset-inactive-slot-status).
//
// Platform facts were validated on t234/r36 (production Mender stack)
// and t264/r38 (AGX Thor, Phase 1 manual validation 2026-06-07 — see
// meta-edgeos/docs/docs-ext/wendy-ota-phase1-results.md):
//
//   - efivar names + GUID identical on both generations.
//   - Status var: 4-byte attrs (0x07 = NV+BS+RT) + UINT32 status;
//     0x00 = normal, 0xFF = unbootable. Writing attrs+0 resets the slot
//     AND re-seeds the firmware retry budget (observed: back to 3).
//   - RootfsRetryCountMax is VOLATILE (attrs 0x06): runtime writes do
//     not persist; effective value 3 on r38.
//   - A rootfs slot swap switches the whole boot chain; a processed
//     capsule does the same switch atomically, and the firmware deletes
//     the consumed capsule on success.
//   - `nvbootctrl dump-slots-info` without `-t rootfs` reports
//     BOOTLOADER slots; rootfs health needs `-t rootfs`.
package tegrauefi

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

const (
	// VendorGUID is NVIDIA's rootfs A/B efivar namespace.
	VendorGUID = "781e084c-a330-417c-b678-38e696380cb9"
	// EfiGlobalGUID is the standard UEFI namespace (OsIndications).
	EfiGlobalGUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"

	// Capsule staging (platform updates). The capsule ships INSIDE each
	// rootfs; the marker in the freshly written rootfs decides staging.
	MarkerPath     = "/var/lib/wendyos/update-bootloader"
	CapsuleSrcPath = "/opt/nvidia/UpdateCapsule/tegra-bl.cap"
	ESPCapsuleRel  = "EFI/UpdateCapsule/TEGRA_BL.Cap"

	// ESRT verdict of the last capsule attempt (entry0 on both t234 and
	// t264). 0 = success; 6163 = NVIDIA: capsule auth/cert failure;
	// 6164 = NVIDIA: SKU not in BUP; 0x1000-0x4000 = NVIDIA vendor range.
	ESRTStatusPath = "/sys/firmware/efi/esrt/entries/entry0/last_attempt_status"
)

func init() {
	connector.Register("tegrauefi", connector.Factory{
		New:    func() connector.Connector { return New() },
		Detect: detect,
	})
}

// detect: nvbootctrl present AND the NVIDIA rootfs A/B efivars exist.
func detect() bool {
	if _, err := exec.LookPath("nvbootctrl"); err != nil {
		return false
	}
	_, err := os.Stat(New().statusVar(connector.SlotA))
	return err == nil
}

// Controller implements connector.Connector via nvbootctrl + efivarfs.
// The exec/file/mount seams are variables so tests can fake the platform.
type Controller struct {
	Nvbootctrl string // binary name/path
	EfivarsDir string // efivarfs mount
	RootDir    string // prefix for /dev, /etc, /data lookups (tests)

	// mountFn mounts a slot's rootfs read-only and returns the mount
	// dir plus an unmount func. Tests substitute a tempdir binder.
	mountFn func(dev string) (string, func(), error)
}

func New() *Controller {
	return &Controller{
		Nvbootctrl: "nvbootctrl",
		EfivarsDir: "/sys/firmware/efi/efivars",
		RootDir:    "",
		mountFn:    defaultMount,
	}
}

// runCmd executes a command and returns combined output as a string.
func runCmd(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return string(out), err
}

var _ connector.Connector = (*Controller)(nil)

func (c *Controller) Name() string { return "tegrauefi" }

// CurrentSlot runs `nvbootctrl -t rootfs get-current-slot`.
// Output validated on r36 and r38: a single digit, 0 or 1.
func (c *Controller) CurrentSlot() (connector.Slot, error) {
	out, err := exec.Command(c.Nvbootctrl, "-t", "rootfs", "get-current-slot").Output()
	if err != nil {
		return 0, fmt.Errorf("nvbootctrl get-current-slot: %w", err)
	}
	switch s := strings.TrimSpace(string(out)); s {
	case "0":
		return connector.SlotA, nil
	case "1":
		return connector.SlotB, nil
	default:
		return 0, fmt.Errorf("nvbootctrl get-current-slot: unexpected output %q", s)
	}
}

// partlabelFor maps slots to the NVIDIA rootfs partition labels.
func partlabelFor(s connector.Slot) string {
	if s == connector.SlotA {
		return "APP"
	}
	return "APP_b"
}

// PartitionFor resolves the slot's rootfs block device. Port of the
// switch-rootfs fallback chain, generalized from "the inactive slot" to
// any slot:
//
//  1. /dev/disk/by-partlabel/APP | APP_b (standard on r36/r38)
//  2. lsblk -rno PATH,PARTLABEL scan
//  3. ROOTFS_PARTUUID_{A,B} in /etc/nv_boot_control.conf
//  4. arithmetic on the current root device's partition number
//     (slots are consecutive: A=pN, B=pN+1)
func (c *Controller) PartitionFor(s connector.Slot) (string, error) {
	label := partlabelFor(s)

	// 1) by-partlabel symlink
	link := c.RootDir + "/dev/disk/by-partlabel/" + label
	if dev, err := filepath.EvalSymlinks(link); err == nil {
		return dev, nil
	}

	// 2) lsblk PARTLABEL scan
	if out, err := exec.Command("lsblk", "-rno", "PATH,PARTLABEL").Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 2 && fields[1] == label {
				return fields[0], nil
			}
		}
	}

	// 3) PARTUUID from nv_boot_control.conf
	key := "ROOTFS_PARTUUID_A"
	if s == connector.SlotB {
		key = "ROOTFS_PARTUUID_B"
	}
	if data, err := os.ReadFile(c.RootDir + "/etc/nv_boot_control.conf"); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 2 && fields[0] == key {
				link := c.RootDir + "/dev/disk/by-partuuid/" + fields[1]
				if dev, err := filepath.EvalSymlinks(link); err == nil {
					return dev, nil
				}
			}
		}
	}

	// 4) toggle the partition number of the current root device.
	cur, err := c.CurrentSlot()
	if err != nil {
		return "", fmt.Errorf("partition for slot %s: all lookups failed and current slot unknown: %w", s, err)
	}
	rootDev, err := currentRootDevice()
	if err != nil {
		return "", fmt.Errorf("partition for slot %s: all lookups failed: %w", s, err)
	}
	if s == cur {
		return rootDev, nil
	}
	base, num, err := splitPartDev(rootDev)
	if err != nil {
		return "", fmt.Errorf("partition for slot %s: %w", s, err)
	}
	target := num + int(s) - int(cur)
	cand := fmt.Sprintf("%sp%d", base, target)
	if _, err := os.Stat(c.RootDir + cand); err != nil {
		return "", fmt.Errorf("partition for slot %s: candidate %s does not exist", s, cand)
	}
	return cand, nil
}

// currentRootDevice returns the block device mounted at /.
func currentRootDevice() (string, error) {
	out, err := exec.Command("findmnt", "-no", "SOURCE", "/").Output()
	if err != nil {
		return "", fmt.Errorf("findmnt /: %w", err)
	}
	dev := strings.TrimSpace(string(out))
	if dev == "" {
		return "", fmt.Errorf("findmnt /: empty source")
	}
	return dev, nil
}

// splitPartDev splits /dev/nvme0n1p2 -> (/dev/nvme0n1, 2) and
// /dev/mmcblk0p1 -> (/dev/mmcblk0, 1).
func splitPartDev(dev string) (string, int, error) {
	i := strings.LastIndex(dev, "p")
	if i < 0 || i == len(dev)-1 {
		return "", 0, fmt.Errorf("unrecognized partition device %q", dev)
	}
	num, err := strconv.Atoi(dev[i+1:])
	if err != nil {
		return "", 0, fmt.Errorf("unrecognized partition device %q", dev)
	}
	return dev[:i], num, nil
}

// statusVar is the efivarfs file for a slot's RootfsStatusSlot variable.
func (c *Controller) statusVar(s connector.Slot) string {
	return filepath.Join(c.EfivarsDir, "RootfsStatusSlot"+s.String()+"-"+VendorGUID)
}

// stateDir is this connector's private bookkeeping location
// (docs/connector-architecture.md rule 2: engine state is off-limits).
func (c *Controller) stateDir() string {
	return c.RootDir + "/data/wendyos-update/connector/tegrauefi"
}

// bootAttemptedPath records which slot the last (uncommitted) boot
// attempt targeted — the double-boot detector input.
func (c *Controller) bootAttemptedPath() string {
	return filepath.Join(c.stateDir(), "boot_attempted")
}

// PrepareTarget resets the slot's RootfsStatusSlot efivar to "normal".
//
// Port of switch-rootfs reset_target_slot_status(): a previous rollback
// leaves the slot 0xFF (unbootable); UEFI refuses to boot it regardless
// of content, so a freshly written slot must be reset before swapping.
// The single 8-byte write also re-seeds the firmware retry budget
// (validated on Thor, Phase 1).
//
// Deviation from the script (which warned and continued on every
// failure): a missing variable is tolerated (nothing to reset), but a
// failed write or read-back mismatch is an error — swapping to a slot
// UEFI will refuse is exactly what the engine must not do silently.
func (c *Controller) PrepareTarget(s connector.Slot) error {
	path := c.statusVar(s)

	raw, err := readStatus(path)
	if os.IsNotExist(err) {
		return nil // variable absent: nothing to reset
	}
	if err != nil {
		return fmt.Errorf("prepare slot %s: %w", s, err)
	}
	if statusIsNormal(raw) {
		return nil
	}
	if err := writeStatusNormal(path); err != nil {
		return fmt.Errorf("prepare slot %s: %w", s, err)
	}
	return nil
}

// MarkGood finalizes a healthy, committed boot:
//   - resets the now-INACTIVE slot's status var so it is a valid
//     rollback target for the next cycle (port of
//     reset-inactive-slot-status; replaces the removed
//     `nvbootctrl mark-boot-successful`),
//   - clears this connector's double-boot bookkeeping.
//
// Note: upstream verify-slot additionally ran `nvbootctrl verify`. That
// call is unvalidated on r38 and NVIDIA's own nv_update_verifier.service
// (present in the image) already runs it each settled boot — the
// connector does not duplicate it.
func (c *Controller) MarkGood() error {
	cur, err := c.CurrentSlot()
	if err != nil {
		return fmt.Errorf("mark-good: %w", err)
	}
	// Confirm the running slot to the bootloader so it stops the trial-boot
	// retry countdown (armed by PrepareTarget's retry-budget re-seed +
	// set-active-boot-slot at install). WendyOS does NOT ship NVIDIA's
	// nv_update_verifier.service, so this confirm is the tool's job — without
	// it the firmware A/B fallback never completes: a committed slot is never
	// confirmed, and a slot that dies before userspace is never distinguished
	// from one that never confirmed. Leaving an un-booted slot unconfirmed is
	// exactly what lets the firmware fall back to the previous slot. Mirrors
	// the ubootenv connector disarming its U-Boot trial in MarkGood.
	if err := c.ConfirmBoot(); err != nil {
		return fmt.Errorf("mark-good: %w", err)
	}
	if err := c.PrepareTarget(cur.Other()); err != nil {
		return fmt.Errorf("mark-good: reset inactive slot: %w", err)
	}
	if err := os.Remove(c.bootAttemptedPath()); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("mark-good: clear boot_attempted: %w", err)
	}
	return nil
}

// ConfirmBoot implements connector.BootConfirmer: `nvbootctrl -t rootfs
// mark-boot-successful` tells UEFI this boot succeeded, stopping the rootfs
// A/B boot-validation watchdog and retry countdown for the running slot.
// With rootfs redundancy enabled UEFI arms that watchdog on EVERY boot (not
// just trials) and reboots the SoC minutes into userspace unless something
// confirms; stock L4T's nv_update_verifier.service did this, and WendyOS
// does not ship it — so the boot verifier calls this each healthy boot.
func (c *Controller) ConfirmBoot() error {
	if out, err := runCmd(c.Nvbootctrl, "-t", "rootfs", "mark-boot-successful"); err != nil {
		return fmt.Errorf("confirm boot: nvbootctrl mark-boot-successful: %w (%s)", err, out)
	}
	return nil
}

// BootIsCompromised, VerifyPlatformUpdate, AbortPlatformUpdate live in
// verify.go; SwapSlot in swap-slot.go.
