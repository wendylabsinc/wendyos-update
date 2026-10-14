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
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
	"golang.org/x/sys/unix"
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
	// t264). 0 = success; 6163 = NVIDIA: boot-chain update canceled;
	// 6164 = NVIDIA: GPT metadata update failed.
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
	mountFn     func(dev string) (string, func(), error)
	rootIDFn    func() (string, error)
	listPartsFn func() ([]partitionInfo, error)
	mountInfoFn func(path string) (mountInfo, bool, error)
	mountESPFn  func(dev string) (string, func(), error)
}

func New() *Controller {
	c := &Controller{
		Nvbootctrl:  "nvbootctrl",
		EfivarsDir:  "/sys/firmware/efi/efivars",
		RootDir:     "",
		mountFn:     defaultMount,
		rootIDFn:    currentRootID,
		listPartsFn: listPartitions,
		mountInfoFn: mountedFilesystem,
	}
	c.mountESPFn = c.mountVfat
	return c
}

// runCmd executes a command and returns combined output as a string.
func runCmd(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return string(out), err
}

var _ connector.Connector = (*Controller)(nil)

func (c *Controller) Name() string { return "tegrauefi" }

// CurrentSlot runs `nvbootctrl [-t rootfs] get-current-slot` — the boot-chain
// slot on Orin (bootChainSlotAB), the rootfs-redundancy slot elsewhere. The two
// are coupled, so the running rootfs slot is the same either way.
// Output validated on r36 and r38: a single digit, 0 or 1.
func (c *Controller) CurrentSlot() (connector.Slot, error) {
	args := append(c.nvbootctrlSlotArgs(), "get-current-slot")
	out, err := exec.Command(c.Nvbootctrl, args...).Output()
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

// PartitionFor resolves the slot on the disk containing the running root.
// Global by-partlabel links are ambiguous when eMMC and NVMe both carry APP.
// Refuse unknown layouts rather than risk writing an unrelated disk.
func (c *Controller) PartitionFor(s connector.Slot) (string, error) {
	if s != connector.SlotA && s != connector.SlotB {
		return "", fmt.Errorf("invalid slot %d", s)
	}
	part, err := c.partitionOnBootDisk([]string{partlabelFor(s)})
	if err != nil {
		return "", fmt.Errorf("partition for slot %s: %w", s, err)
	}
	return part.Path, nil
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

// ConfirmBoot implements connector.BootConfirmer: `nvbootctrl verify` tells
// UEFI this boot succeeded, stopping the rootfs A/B boot-validation watchdog
// and retry countdown for the running slot. With rootfs redundancy enabled UEFI
// arms that watchdog on EVERY boot (not just trials) and reboots the SoC minutes
// into userspace unless something confirms.
//
// `verify` is the command stock L4T's nv_update_verifier.service runs each boot,
// validated on r36/r38/r39.2. The connector runs the same command so the confirm
// does not depend on that service being present. The earlier spelling
// `mark-boot-successful` is the AOSP boot_control name and does NOT exist in
// L4T's nvbootctrl — it failed with exit 64 every boot, which also made MarkGood
// (which calls this) fail. `verify` takes no `-t rootfs` selector.
func (c *Controller) ConfirmBoot() error {
	if out, err := runCmd(c.Nvbootctrl, "verify"); err != nil {
		return fmt.Errorf("confirm boot: nvbootctrl verify: %w (%s)", err, out)
	}
	return nil
}

// redundancyLevelVar is NVIDIA's UEFI variable that enables rootfs A/B
// redundancy. On disk it is 4-byte attrs (0x07 = NV+BS+RT) + a UINT32 level
// (see scripts/system-status.sh --dual, which writes 07 00 00 00 01 00 00 00).
func (c *Controller) redundancyLevelVar() string {
	return filepath.Join(c.EfivarsDir, "RootfsRedundancyLevel-"+VendorGUID)
}

// rootfsRedundancyArmed reports whether rootfs A/B redundancy is enabled in
// firmware. Armed means the RootfsRedundancyLevel variable exists with a
// non-zero level. A missing (or zero) variable means single-slot: firmware
// ignores `nvbootctrl -t rootfs set-active-boot-slot`, so a slot switch is a
// silent no-op. This is the state left by flashing a rootfs directly to disk
// (e.g. straight to NVMe) instead of via tegraflash, which arms it.
func (c *Controller) rootfsRedundancyArmed() (bool, error) {
	raw, err := os.ReadFile(c.redundancyLevelVar())
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	// attrs(4) + UINT32 level; armed iff the level is non-zero.
	if len(raw) < 8 {
		return false, nil
	}
	return raw[4]|raw[5]|raw[6]|raw[7] != 0, nil
}

// PreflightInstall implements connector.InstallPreflighter. The tegra A/B
// scheme depends on rootfs redundancy being armed in firmware: without it,
// `nvbootctrl -t rootfs set-active-boot-slot` is silently ignored — the
// bootchain flips but the running rootfs slot never moves, so every update
// rolls back at commit (running slot != target slot). Refuse up front with an
// actionable message instead of downloading, writing, rebooting, then rolling
// back.
func (c *Controller) PreflightInstall() error {
	if c.capsuleUpdateEffective() {
		if _, err := os.Stat(c.RootDir + MarkerPath); err == nil {
			esp, err := c.espPartition()
			if err != nil {
				return err
			}
			if _, err := c.existingESPMount(esp); err != nil {
				return err
			}
			if err := c.checkCapsuleBootChainIdle(); err != nil {
				return err
			}
		}
	}
	// Advisory: a full ESP does not stop the install, but it does decide it
	// long before anyone finds out, so say so now rather than after 16 GB.
	// `wendyos-update check` reports the same condition as a failure.
	if err := c.espCapsuleHeadroom(); err != nil {
		slog.Warn("preflight: " + err.Error())
	}

	return c.rootfsRedundancyReady()
}

// rootfsRedundancyReady reports whether a rootfs slot switch can take effect.
// Split out of PreflightInstall so `check` can ask the same question without
// the install-time side effects — calling PreflightInstall from there logged a
// "preflight:" warning during a read-only check, and printed the ESP shortfall
// a second time.
func (c *Controller) rootfsRedundancyReady() error {
	// Boot-chain A/B (Orin) does not use RootfsRedundancyLevel at all — the
	// chain switch moves the coupled rootfs slot without it — so there is
	// nothing to arm and nothing to preflight. (The var is unarmable from the
	// OS on Orin anyway; blocking on it is exactly what this replaces.)
	if c.bootChainSlotAB() {
		return nil
	}

	armed, err := c.rootfsRedundancyArmed()
	if err != nil {
		// Probe failed unexpectedly: don't block the update on a read error —
		// the commit-time running-slot vs target-slot check still catches a
		// genuine no-op fallback.
		slog.Warn("preflight: could not read RootfsRedundancyLevel; proceeding", "err", err)
		return nil
	}
	if !armed {
		return fmt.Errorf("rootfs A/B redundancy is not armed on this device "+
			"(UEFI variable %s missing or zero): a rootfs slot switch is ignored by "+
			"firmware, so the update would install and then roll back. Arm redundancy "+
			"(the wendyos-tegra-rootfs-redundancy boot service, or system-status.sh "+
			"--dual) and reboot, then retry the update", "RootfsRedundancyLevel")
	}
	return nil
}

// espHeadroomMargin covers FAT cluster rounding on the capsule plus a cluster
// for the EFI/UpdateCapsule directory. Both are kilobytes at the 4 KiB clusters
// a 512 MiB ESP uses, so this is generous on purpose — the point is to catch a
// full ESP, not to police the last few blocks.
const espHeadroomMargin = 1 << 20

// espCapsuleHeadroom reports whether the ESP has room to stage a bootloader
// capsule. Staging is the very last step of an install, so running out there
// costs the whole transfer and the rootfs slot write — measured at 3.6 GB and
// 12 GiB — before anything says a word.
//
// It cannot read the incoming image: the target rootfs is not written yet, and
// the capsule lives inside that payload rather than in the manifest. So it
// sizes against the RUNNING rootfs, which is a proxy — same-lineage images
// carry the same marker policy and a same-BSP capsule of the same order of
// size. Good enough to report, not certain enough to block on, which is why
// PreflightInstall only warns while `check` treats it as a failure.
//
// The requirement is one whole capsule of free space, not the difference
// against what is already staged: copyFileSync writes a temp file and renames,
// so the old capsule still holds its clusters while the new one is written.
//
// Only inspect an existing, verified ESP mount. `check` must not mount a disk
// read-write just to estimate capacity. An unmounted ESP reports an unknown
// capacity; install treats that as advisory and mounts it during staging.
func (c *Controller) espCapsuleHeadroom() error {
	if !c.capsuleUpdateEffective() {
		return nil
	}
	if _, err := os.Stat(c.RootDir + MarkerPath); err != nil {
		return nil // this image does not request a bootloader update
	}
	fi, err := os.Stat(c.RootDir + CapsuleSrcPath)
	if err != nil {
		return nil
	}
	need := fi.Size() + espHeadroomMargin

	esp, err := c.espPartition()
	if err != nil {
		return err
	}
	espDir, err := c.existingESPMount(esp)
	if err != nil {
		return err
	}
	if espDir == "" {
		return fmt.Errorf("ESP %s is not mounted; capsule free space has not been checked", esp.Path)
	}
	var st unix.Statfs_t
	if err := unix.Statfs(espDir, &st); err != nil {
		return nil
	}
	if free := int64(st.Bavail) * st.Bsize; free < need {
		return fmt.Errorf("the ESP (%s) has %d bytes free but staging the bootloader "+
			"capsule needs %d (capsule %d + margin): the install would run to completion "+
			"and then fail at the last step. Free space on the ESP, or reflash to pick up "+
			"a larger one", espDir, free, need, fi.Size())
	}
	return nil
}

// CheckReadiness implements connector.ReadinessChecker: the tegra conditions
// that decide whether an install can succeed, reported rather than enforced.
func (c *Controller) CheckReadiness() []connector.Check {
	checks := []connector.Check{{Name: "rootfs A/B redundancy", OK: true}}
	if err := c.rootfsRedundancyReady(); err != nil {
		checks[0].OK, checks[0].Detail = false, err.Error()
	} else if c.bootChainSlotAB() {
		checks[0].Detail = "not applicable: boot-chain A/B moves the rootfs slot"
	} else {
		checks[0].Detail = "armed"
	}
	if c.capsuleUpdateEffective() {
		if _, err := os.Stat(c.RootDir + MarkerPath); err == nil {
			chain := connector.Check{Name: "capsule boot-chain state", OK: true}
			if err := c.checkCapsuleBootChainIdle(); err != nil {
				chain.OK, chain.Detail = false, err.Error()
			}
			checks = append(checks, chain)
		}
	}

	esp := connector.Check{Name: "ESP capsule headroom", OK: true}
	if err := c.espCapsuleHeadroom(); err != nil {
		esp.OK, esp.Detail = false, err.Error()
	} else if !c.capsuleUpdateEffective() {
		esp.Detail = "not applicable: this SoC does not stage capsules"
	}

	return append(checks, esp)
}

// BootIsCompromised, VerifyPlatformUpdate, AbortPlatformUpdate live in
// verify.go; SwapSlot in swap-slot.go.
