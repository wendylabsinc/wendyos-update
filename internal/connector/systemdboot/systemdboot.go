// Package systemdboot implements connector.Connector for NVIDIA Jetson Orin
// using systemd-boot's native Automatic Boot Assessment (`+tries` boot
// counting) instead of NVIDIA's firmware rootfs A/B redundancy.
//
// Why not tegrauefi on Orin: NVIDIA's rootfs A/B is driven by the
// RootfsRedundancyLevel UEFI variable, which on Orin (tegra234) cannot be armed
// from the OS (runtime SetVariable returns EINVAL), so `nvbootctrl -t rootfs
// set-active-boot-slot` silently no-ops and every OTA rolls back at commit. This
// connector sidesteps the firmware mechanism entirely: it puts systemd-boot on
// the writable ESP and selects/trials the A/B slot with systemd-boot's own boot
// counting, whose state is a FILE-NAME RENAME on the FAT ESP (see entries.go),
// not a persisted EFI variable — so it does not depend on the edk2 quirk.
//
// Boot model (mirrors ubootenv's trial-boot semantics mapped onto systemd-boot):
//
//   - Each slot has a Type #1 loader entry `loader/entries/slot-{a,b}.conf`
//     whose kernel + initrd live on the ESP under `/{a,b}/` (systemd-boot reads
//     the kernel from the ESP, not from the ext4 rootfs).
//   - install (SwapSlot stagePlatformUpdate=true): stage the freshly written
//     slot's kernel/initrd from its rootfs onto the ESP, ARM a trial by
//     renaming its entry to `slot-<x>+3.conf`, and point LoaderEntryDefault at
//     it (`bootctl set-default`). systemd-boot decrements the counter each
//     attempt and falls back to the other (counter-less, always-good) slot when
//     the budget is exhausted.
//   - rollback (SwapSlot stagePlatformUpdate=false): a pure re-point — drop the
//     target slot's counter (make it permanent) and set it default; never a
//     trial, never a mount.
//   - MarkGood: commit the running slot — drop its counter (the
//     `systemd-bless-boot good` rename) and set it default. WendyOS deliberately
//     does NOT enable systemd-bless-boot.service, so commit stays gated on the
//     engine's health check, exactly as tegrauefi withholds
//     nv_update_verifier.service.
//
// Slot -> rootfs partition reuses the tegrauefi APP/APP_b partlabel mapping (the
// NVIDIA redundant-flash layout: slot 0 = APP, slot 1 = APP_b). CurrentSlot is
// ground truth from the running root device (findmnt), never from the loader's
// intent, so the engine's running-slot vs target-slot fallback check is real.
//
// Platform (bootloader/firmware) updates have no in-payload path here in v1:
// VerifyPlatformUpdate/AbortPlatformUpdate are no-ops (like ubootenv).
package systemdboot

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

const (
	// defaultTries is the trial-boot retry budget armed on the target slot at
	// install (matches tegrauefi's re-seeded retry count of 3 and the
	// `slot-<x>+3.conf` entries the builder stages on first boot).
	defaultTries = 3

	// loaderEntriesRel is the Type #1 entries directory, relative to the ESP.
	loaderEntriesRel = "loader/entries"

	// systemdBootRel is the installed systemd-boot EFI binary on the ESP, used
	// by Detect. aa64 = arm64 (Jetson).
	systemdBootRel = "EFI/systemd/systemd-bootaa64.efi"
)

func init() {
	connector.Register("systemdboot", connector.Factory{
		New:    func() connector.Connector { return New() },
		Detect: detect,
	})
}

// detect: bootctl present AND a systemd-boot install on the ESP (the EFI binary
// or the loader entries dir). Jetson images pin connector=systemdboot in
// config.json on this boot path anyway, so detection is only a secondary net;
// it must never collide with tegrauefi (bootctl is absent on the firmware-A/B
// image, and this connector's ESP markers are absent there).
func detect() bool {
	if _, err := exec.LookPath("bootctl"); err != nil {
		return false
	}
	c := New()
	for _, p := range []string{
		filepath.Join(c.ESPDir, systemdBootRel),
		c.entriesDir(),
	} {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

// Controller implements connector.Connector via systemd-boot on the ESP. Every
// platform seam (the bootctl binary, the ESP mount path, the running-root
// resolver, the ext4 mount used to stage the target kernel, and the in-rootfs
// kernel/initrd source paths) is a field so tests can fake the board.
type Controller struct {
	Bootctl string // bootctl binary name/path (EFI-var writes: set-default/set-oneshot)
	ESPDir  string // ESP mountpoint (systemd-boot layout lives here)
	RootDir string // prefix for /dev lookups (tests); "" in production

	// KernelSrcRel / InitrdSrcRel are the kernel and initrd paths WITHIN a
	// slot's rootfs, staged onto the ESP at install. Jetson kernels live in
	// /boot; the initrd name varies by image, so a missing initrd is tolerated
	// (the entry then carries no `initrd` line).
	KernelSrcRel string
	InitrdSrcRel string

	rootDeviceFn func() (string, error)                   // block device mounted at /
	mountFn      func(dev string) (string, func(), error) // mount a slot rootfs RO
}

func New() *Controller {
	return &Controller{
		Bootctl:      "bootctl",
		ESPDir:       "/boot/efi",
		KernelSrcRel: "boot/Image",
		InitrdSrcRel: "boot/initrd",
		rootDeviceFn: currentRootDevice,
		mountFn:      defaultMount,
	}
}

var _ connector.Connector = (*Controller)(nil)

func (c *Controller) Name() string { return "systemdboot" }

// runCmd executes a command and returns combined output as a string.
func runCmd(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return string(out), err
}

// slotLetter maps a slot to the lowercase letter used in loader entry ids and
// the per-slot ESP kernel directory ("a"/"b").
func slotLetter(s connector.Slot) string { return strings.ToLower(s.String()) }

// entriesDir is the systemd-boot Type #1 entries directory on the ESP.
func (c *Controller) entriesDir() string {
	return filepath.Join(c.ESPDir, loaderEntriesRel)
}

// espGuard fails loud when the systemd-boot loader state is not present on the
// ESP — otherwise a rename/set-default would silently operate on a directory the
// firmware never reads (the systemd-boot analogue of ubootenv's shadow-env
// trap). Cheap existence check of the entries dir.
func (c *Controller) espGuard() error {
	dir := c.entriesDir()
	fi, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("systemd-boot loader entries dir %s not present (is the ESP mounted at %s?): %w", dir, c.ESPDir, err)
	}
	if !fi.IsDir() {
		return fmt.Errorf("systemd-boot loader entries path %s is not a directory", dir)
	}
	return nil
}

// partlabelFor maps slots to the NVIDIA rootfs partition labels (identical to
// tegrauefi: the redundant-flash layout labels slot 0 = APP, slot 1 = APP_b).
func partlabelFor(s connector.Slot) string {
	if s == connector.SlotA {
		return "APP"
	}
	return "APP_b"
}

// PartitionFor resolves a slot's rootfs block device by partition label. Unlike
// tegrauefi this deliberately does NOT fall back to partition-number arithmetic
// off the current slot: CurrentSlot itself is derived from PartitionFor here, so
// an arithmetic fallback would recurse. The Jetson NVMe layout always exposes
// the APP/APP_b GPT partlabels, so the symlink (then lsblk) lookup is sufficient.
func (c *Controller) PartitionFor(s connector.Slot) (string, error) {
	label := partlabelFor(s)

	// 1) by-partlabel symlink (standard on the Jetson GPT layout).
	link := c.RootDir + "/dev/disk/by-partlabel/" + label
	if dev, err := filepath.EvalSymlinks(link); err == nil {
		return dev, nil
	}

	// 2) lsblk PARTLABEL scan (symlink absent, e.g. early boot).
	if out, err := exec.Command("lsblk", "-rno", "PATH,PARTLABEL").Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 2 && fields[1] == label {
				return fields[0], nil
			}
		}
	}

	return "", fmt.Errorf("partition for slot %s: no partition labelled %q", s, label)
}

// CurrentSlot returns the slot actually running, derived from the block device
// mounted at / (ground truth — what booted), matched against each slot's rootfs
// partition. Deliberately not read from LoaderEntryDefault (what we asked to
// boot): after a failed trial systemd-boot falls back to the other slot without
// rewriting the default, so the running rootfs is the only reliable source, and
// the engine's fallback detection depends on it.
func (c *Controller) CurrentSlot() (connector.Slot, error) {
	root, err := c.rootDeviceFn()
	if err != nil {
		return 0, fmt.Errorf("current slot: %w", err)
	}
	root = canon(root)
	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		dev, err := c.PartitionFor(s)
		if err != nil {
			continue
		}
		if canon(dev) == root {
			return s, nil
		}
	}
	return 0, fmt.Errorf("current slot: running root %q matches neither rootfs slot (%s/%s)", root, partlabelFor(connector.SlotA), partlabelFor(connector.SlotB))
}

// PrepareTarget rehabilitates a slot before it is armed: if its entry ran out of
// tries in a past failed trial (`slot-<x>+0-N.conf`, marked bad and skipped by
// systemd-boot), rename the counter away so the slot is bootable again. This is
// the direct analogue of tegrauefi resetting a 0xFF "unbootable" RootfsStatusSlot
// before a swap. A missing entry is an error — a slot with no boot entry cannot
// be prepared. The actual trial arming happens in SwapSlot.
func (c *Controller) PrepareTarget(s connector.Slot) error {
	if err := c.espGuard(); err != nil {
		return fmt.Errorf("prepare slot %s: %w", s, err)
	}
	letter := slotLetter(s)
	e, err := c.findEntry(letter)
	if err != nil {
		return fmt.Errorf("prepare slot %s: %w", s, err)
	}
	if !e.hasCounter() {
		return nil // already permanent/good
	}
	if err := c.renameEntry(e, letter, noCounter, 0); err != nil {
		return fmt.Errorf("prepare slot %s: %w", s, err)
	}
	syncFS()
	return nil
}

// MarkGood commits the running slot: drop its `+tries` counter (the
// `systemd-bless-boot good` rename) so it is permanently bootable, and point
// LoaderEntryDefault at it. WendyOS does not enable systemd-bless-boot.service,
// so this explicit commit — gated by the engine's health verdict — is the only
// thing that blesses a trial (mirrors tegrauefi/ubootenv committing in MarkGood).
func (c *Controller) MarkGood() error {
	if err := c.espGuard(); err != nil {
		return fmt.Errorf("mark-good: %w", err)
	}
	cur, err := c.CurrentSlot()
	if err != nil {
		return fmt.Errorf("mark-good: %w", err)
	}
	letter := slotLetter(cur)
	e, err := c.findEntry(letter)
	if err != nil {
		return fmt.Errorf("mark-good: %w", err)
	}
	if e.hasCounter() {
		if err := c.renameEntry(e, letter, noCounter, 0); err != nil {
			return fmt.Errorf("mark-good: %w", err)
		}
	}
	if err := c.setDefault(cur); err != nil {
		return fmt.Errorf("mark-good: %w", err)
	}
	syncFS()
	return nil
}

// setDefault points LoaderEntryDefault at a slot via `bootctl set-default`. The
// id is counter-less ("slot-a"), which is stable across boot-count renames.
func (c *Controller) setDefault(s connector.Slot) error {
	id := entryID(slotLetter(s))
	if out, err := runCmd(c.Bootctl, "set-default", id); err != nil {
		return fmt.Errorf("bootctl set-default %s: %w (%s)", id, err, strings.TrimSpace(out))
	}
	return nil
}

// canon canonicalizes a device path via EvalSymlinks, returning the input
// unchanged on failure (e.g. a fake node in unit tests).
func canon(dev string) string {
	if r, err := filepath.EvalSymlinks(dev); err == nil {
		return r
	}
	return dev
}

// currentRootDevice returns the block device mounted at / (findmnt, util-linux).
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

// copyFileSync copies src to dst and fsyncs dst — the staged kernel/initrd must
// be durable on the ESP before the trial is armed and the device reboots.
func copyFileSync(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
