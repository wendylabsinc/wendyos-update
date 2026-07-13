// Package grubenv implements connector.Connector for generic x86-64 UEFI
// boards that boot via GRUB-EFI and select their A/B rootfs slot from a GRUB
// environment block (grubenv on the EFI System Partition). It is the third
// connector after tegrauefi (Jetson) and ubootenv (Raspberry Pi), and the
// realization of the x86 OTA plan (meta-edgeos/docs/plans/x86-ota-plan.md).
//
// It mirrors the ubootenv trial-boot model exactly, under the SAME env-var
// names, so the whole fleet behaves identically. The only differences are the
// environment access seam (grub-editenv instead of libubootenv) and that x86 is
// GPT-only (no MBR partition-number fallback):
//
//   - the GRUB config picks the rootfs slot from `wendyos_boot_slot`;
//   - when `wendyos_upgrade_available=1` the boot is a TRIAL: the GRUB config's
//     bootcount logic (bootlimit 1) falls back to the other slot if the trial
//     slot fails to reach a healthy userspace and commit;
//   - committing clears `wendyos_upgrade_available` so the slot becomes the
//     permanent default.
//
// The GRUB A/B config (grubAB.cfg) and the grubenv on the ESP live in
// meta-edgeos; this connector only reads and writes the environment via
// grub-editenv. See docs/connector-architecture.md for the boundary contract.
//
// The env-var contract (the GRUB config must honor the same names):
//
//	wendyos_boot_slot          "0" (A) | "1" (B)  — slot the GRUB config selects
//	wendyos_upgrade_available  "0" | "1"          — a trial boot is armed
//	bootcount                  "0" | "1"          — trial attempt counter
//
// Platform updates (UEFI firmware) are out of scope in v1: x86 firmware is
// updated through a separate channel (fwupd / UEFI capsule), so
// VerifyPlatformUpdate and AbortPlatformUpdate are no-ops and install never
// inspects the payload for a bootloader marker.
package grubenv

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// Environment variable names (our names; the same contract as ubootenv). The
// GRUB config in meta-edgeos selects the slot and arms the trial off exactly
// these.
const (
	envBootSlot         = "wendyos_boot_slot"
	envUpgradeAvailable = "wendyos_upgrade_available"
	envBootCount        = "bootcount"
)

// Slot labels for the two rootfs slots. The x86 A/B wks (meta-edgeos,
// genericx86-ab.wks) labels its rootfs partitions exactly these — both as the
// GPT PARTLABEL and the ext4 filesystem label — so slot→device resolution is a
// stable label lookup with no partition-number arithmetic.
const (
	partlabelA = "rootfsA"
	partlabelB = "rootfsB"
)

// grubenvDefaultPath is where the A/B GRUB config keeps its environment block:
// EFI/BOOT/grubenv on the mounted ESP. grub-editenv defaults to
// /boot/grub/grubenv, which is NOT where we put it, so the path is always
// passed explicitly.
const grubenvDefaultPath = "/boot/EFI/BOOT/grubenv"

// bootMount is the ESP mount point (see the x86 A/B fstab). The env-writable
// guard checks this is a real mountpoint so a write cannot land on a shadow
// copy in the rootfs when the ESP failed to mount.
const bootMount = "/boot"

func init() {
	connector.Register("grubenv", connector.Factory{
		New:    func() connector.Connector { return New() },
		Detect: detect,
	})
}

// detect: grub-editenv present AND our env layout seeded (wendyos_boot_slot is
// defined). fw_printenv (ubootenv) and nvbootctrl (tegrauefi) are absent on an
// x86 image, so this never collides with them. x86 images additionally pin the
// connector explicitly via /etc/wendyos-update/config.json, so detection is
// only a secondary safety net.
func detect() bool {
	if _, err := exec.LookPath("grub-editenv"); err != nil {
		return false
	}
	v, err := New().env.get(envBootSlot)
	return err == nil && v != ""
}

// envStore is the GRUB environment access seam. The real implementation shells
// out to grub-editenv; tests substitute an in-memory store. set is a single
// atomic batch (grub-editenv rewrites the whole 1 KiB block in one write), which
// matters when arming a trial: slot + flag + counter must land together.
type envStore interface {
	get(name string) (string, error)
	set(vars map[string]string) error
}

// Controller implements connector.Connector via grub-editenv. Every platform
// seam (env access, running-root resolution, device listing) is a field so
// tests can fake the board completely.
type Controller struct {
	RootDir string // prefix for filesystem lookups (tests); "" in production

	env          envStore
	rootDeviceFn func() (string, error)     // block device mounted at /
	listPartsFn  func() ([]partInfo, error) // block partitions (lsblk)
}

func New() *Controller {
	return &Controller{
		env:          grubEditenv{bin: "grub-editenv", path: grubenvDefaultPath},
		rootDeviceFn: currentRootDevice,
		listPartsFn:  lsblkParts,
	}
}

var _ connector.Connector = (*Controller)(nil)

func (c *Controller) Name() string { return "grubenv" }

// --- grub-editenv-backed envStore ---

type grubEditenv struct {
	bin  string
	path string
}

// get reads one variable by listing the block and matching "name=value".
// grub-editenv exits non-zero when the file is missing or unreadable; we treat
// that (and an unset variable) as the empty string — the same fail-safe default
// ubootenv uses (a missing trial flag means "no trial", a missing slot means
// "unknown", both handled by the callers here).
func (g grubEditenv) get(name string) (string, error) {
	out, err := exec.Command(g.bin, g.path, "list").Output()
	if err != nil {
		return "", nil
	}
	return grubenvValue(string(out), name), nil
}

// grubenvValue extracts one variable from `grub-editenv list` output (one
// "name=value" per line).
func grubenvValue(list, name string) string {
	prefix := name + "="
	for _, line := range strings.Split(list, "\n") {
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(line, prefix))
		}
	}
	return ""
}

// set writes variables atomically. `grub-editenv <file> set k=v ...` rewrites
// the whole environment block in a single write, so a power cut cannot leave a
// half-armed trial (slot flipped but flag unset, or vice versa).
//
// grub-editenv needs the block to exist first, and `create` makes a FRESH block
// (wiping any existing vars), so create only when the file is absent — never on
// an existing env. A global Sync follows, because callers arm a trial then
// reboot almost immediately and the env is a file on the FAT ESP.
func (g grubEditenv) set(vars map[string]string) error {
	if _, err := os.Stat(g.path); err != nil {
		if out, err := exec.Command(g.bin, g.path, "create").CombinedOutput(); err != nil {
			return fmt.Errorf("grub-editenv create: %w (%s)", err, strings.TrimSpace(string(out)))
		}
	}
	if out, err := exec.Command(g.bin, grubSetArgs(g.path, vars)...).CombinedOutput(); err != nil {
		return fmt.Errorf("grub-editenv set: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	syscall.Sync()
	return nil
}

// grubSetArgs builds the `grub-editenv <path> set key=value ...` argument list.
// grub-editenv requires "key=value" pairs; each pair is one positional arg.
func grubSetArgs(path string, vars map[string]string) []string {
	args := []string{path, "set"}
	for k, v := range vars {
		args = append(args, k+"="+v)
	}
	return args
}

// assertEnvWritable guards against a silently-ineffective env write. The grubenv
// lives on the FAT ESP mounted at /boot. If the ESP fails to mount (the fstab
// mounts it `nofail`), grub-editenv would happily create/write a copy in the
// empty /boot directory on the rootfs and exit 0 — but GRUB reads the real ESP,
// so a trial is never armed and the device just reboots the current slot (a
// silent no-op OTA). So refuse to write unless /boot is a real mountpoint. Fail
// OPEN if we cannot stat it (tests, unusual layouts) — grub-editenv surfaces
// genuine errors itself; this only closes the shadow-file trap.
func (c *Controller) assertEnvWritable() error {
	mp, err := isMountpoint(filepath.Join(c.RootDir, bootMount))
	if err != nil {
		return nil
	}
	if !mp {
		return fmt.Errorf("grubenv boot partition %s is not mounted: refusing — "+
			"grub-editenv would write a copy the bootloader never reads", bootMount)
	}
	return nil
}

// isMountpoint reports whether path is a filesystem mountpoint, by the standard
// test: its st_dev differs from its parent's. Linux-only.
func isMountpoint(path string) (bool, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return false, err
	}
	parent, err := os.Stat(filepath.Dir(path))
	if err != nil {
		return false, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	pst, ok2 := parent.Sys().(*syscall.Stat_t)
	if !ok || !ok2 {
		return false, fmt.Errorf("stat %s: unexpected FileInfo.Sys type", path)
	}
	return st.Dev != pst.Dev, nil
}

// --- slot ↔ partition resolution (GPT only) ---

func rootfsSlotLabel(s connector.Slot) string {
	if s == connector.SlotA {
		return partlabelA
	}
	return partlabelB
}

// partInfo is one block partition as reported by lsblk: device path, GPT
// partlabel, filesystem label, and parent whole-disk kernel name (PKNAME).
type partInfo struct {
	path      string // e.g. /dev/nvme0n1p3
	partlabel string // GPT partition name, e.g. rootfsA
	label     string // filesystem label, e.g. rootfsA (fallback for partlabel)
	pkname    string // parent disk kernel name, e.g. nvme0n1 ("" for a disk)
}

// effectiveLabel is a partition's slot identity: the GPT partlabel when present,
// else the filesystem label. The x86 wks sets both to rootfsA/rootfsB, so the
// partlabel normally wins and the fs label is only a fallback.
func effectiveLabel(p partInfo) string {
	if p.partlabel != "" {
		return p.partlabel
	}
	return p.label
}

// canon canonicalizes a device path via EvalSymlinks, returning the input
// unchanged on failure (e.g. the path is not a real node, as in unit tests).
func canon(dev string) string {
	if c, err := filepath.EvalSymlinks(dev); err == nil {
		return c
	}
	return dev
}

// lsblkParts lists block partitions with their partlabel, fs label and parent
// disk. -P (KEY="value") is robust to empty columns.
func lsblkParts() ([]partInfo, error) {
	out, err := exec.Command("lsblk", "-Pno", "PATH,PARTLABEL,LABEL,PKNAME").Output()
	if err != nil {
		return nil, err
	}
	var parts []partInfo
	for _, line := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		parts = append(parts, partInfo{
			path:      lsblkField(line, "PATH"),
			partlabel: lsblkField(line, "PARTLABEL"),
			label:     lsblkField(line, "LABEL"),
			pkname:    lsblkField(line, "PKNAME"),
		})
	}
	return parts, nil
}

// lsblkField extracts KEY's value from an lsblk -P line (KEY="value" ...).
func lsblkField(line, key string) string {
	pfx := key + `="`
	i := strings.Index(line, pfx)
	if i < 0 {
		return ""
	}
	i += len(pfx)
	j := strings.IndexByte(line[i:], '"')
	if j < 0 {
		return ""
	}
	return line[i : i+j]
}

// bootDisk returns the parent whole-disk kernel name (PKNAME) of the running
// root, e.g. "nvme0n1" for /dev/nvme0n1p3. Rootfs-slot resolution is scoped to
// this disk so a SECOND disk carrying the same rootfsA/rootfsB (e.g. the install
// media beside the internal disk) cannot shadow the disk we actually booted
// from — and so `install` never writes the inactive slot to the wrong disk.
func (c *Controller) bootDisk(parts []partInfo) (string, error) {
	root, err := c.rootDeviceFn()
	if err != nil {
		return "", err
	}
	root = canon(root)
	for _, p := range parts {
		if canon(p.path) == root {
			return p.pkname, nil
		}
	}
	return "", fmt.Errorf("running root %q not found among partitions", root)
}

// PartitionFor resolves a slot's rootfs block device by GPT partlabel
// (rootfsA/rootfsB), scoped to the disk we booted from (see bootDisk). Falls
// back to the /dev/disk/by-partlabel then by-label symlinks only when the
// running root is not listed by lsblk (early boot / unit tests).
func (c *Controller) PartitionFor(s connector.Slot) (string, error) {
	label := rootfsSlotLabel(s)

	if parts, err := c.listPartsFn(); err == nil {
		if disk, err := c.bootDisk(parts); err == nil && disk != "" {
			for _, p := range parts {
				if effectiveLabel(p) == label && p.pkname == disk {
					return p.path, nil
				}
			}
		}
	}

	for _, base := range []string{"/dev/disk/by-partlabel/", "/dev/disk/by-label/"} {
		if dev, err := filepath.EvalSymlinks(c.RootDir + base + label); err == nil {
			return dev, nil
		}
	}

	return "", fmt.Errorf("partition for slot %s: no partition labelled %q on the boot disk", s, label)
}

// CurrentSlot returns the slot actually running, derived from the block device
// mounted at /. This is deliberately ground-truth (what booted) rather than
// reading wendyos_boot_slot (what we asked to boot): after a failed trial GRUB
// falls back to the other slot without rewriting the env, so the running rootfs
// is the only reliable source. The engine's fallback detection (running slot !=
// target slot) depends on this being real.
func (c *Controller) CurrentSlot() (connector.Slot, error) {
	root, err := c.rootDeviceFn()
	if err != nil {
		return 0, fmt.Errorf("current slot: %w", err)
	}
	root = canon(root)

	// Identify the running root by its OWN partlabel (unambiguous even when a
	// second disk carries the same rootfsA/rootfsB).
	if parts, err := c.listPartsFn(); err == nil {
		for _, p := range parts {
			if canon(p.path) != root {
				continue
			}
			switch effectiveLabel(p) {
			case partlabelA:
				return connector.SlotA, nil
			case partlabelB:
				return connector.SlotB, nil
			}
			break // running root found; its label didn't resolve — fall through
		}
	}

	// Fallback (running root not listed by lsblk, e.g. unit tests): compare the
	// running root against each slot's resolved device.
	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		dev, err := c.PartitionFor(s)
		if err != nil {
			continue
		}
		if canon(dev) == root {
			return s, nil
		}
	}
	return 0, fmt.Errorf("current slot: running root %q matches neither rootfs slot (%s/%s)", root, partlabelA, partlabelB)
}

// currentRootDevice returns the block device mounted at / (findmnt is in
// util-linux, present on every WendyOS image).
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

// slotEnvValue maps a slot to the wendyos_boot_slot string the GRUB config
// expects ("0"/"1", same encoding as connector.Slot's int value).
func slotEnvValue(s connector.Slot) string {
	return fmt.Sprintf("%d", int(s))
}
