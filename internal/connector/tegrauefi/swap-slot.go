package tegrauefi

// SwapSlot: port of the switch-rootfs state script's main flow (the
// hardware-validated boot chain switching strategy).
//
// NVIDIA couples bootloader chain and rootfs slot (chain A ↔ slot 0,
// chain B ↔ slot 1; validated on t234/r36 and t264/r38). Two paths:
//
//   ROOTFS-ONLY:    nvbootctrl -t rootfs set-active-boot-slot N
//   CAPSULE UPDATE: stage TEGRA_BL.Cap on the ESP + set OsIndications
//                   bit 2 — the firmware switches the chain itself,
//                   atomically, and nvbootctrl must NOT also be called
//                   (BC_NEXT conflict).
//
// The decision between the two is made by the MARKER INSIDE the freshly
// written rootfs (/var/lib/wendyos/update-bootloader + the capsule it
// ships), not by the artifact metadata — the new image owns the decision
// (docs/manifest-schema.md). The blUpdate parameter from the manifest is
// only cross-checked for logging.

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
	"golang.org/x/sys/unix"
)

// espPartlabels are the ESP partition labels seen across generations:
// "esp" on t264/r38 (validated), "UEFI-ESP" on t234/r36 layouts.
var espPartlabels = []string{"esp", "UEFI-ESP"}

// SwapSlot makes slot s the next-boot slot.
//
// stagePlatformUpdate distinguishes the two callers:
//   - install (true): s is the freshly-written INACTIVE slot. Inspect its
//     rootfs marker; if a bootloader update is requested, stage the capsule
//     (the firmware switches the chain) — otherwise nvbootctrl flips it.
//   - rollback (false): pure re-point via nvbootctrl. Never mount, never
//     stage. The target may be the running slot (pre-reboot rollback —
//     unmountable) or an old slot whose marker is irrelevant, so the
//     install inspection must be skipped entirely.
func (c *Controller) SwapSlot(s connector.Slot, stagePlatformUpdate bool) error {
	if !stagePlatformUpdate {
		// Rollback: just re-point the active boot slot.
		if err := c.recordBootAttempt(s); err != nil {
			return err
		}
		args := append(c.nvbootctrlSlotArgs(), "set-active-boot-slot", fmt.Sprintf("%d", int(s)))
		out, err := runCmd(c.Nvbootctrl, args...)
		if err != nil {
			return fmt.Errorf("swap to slot %s: nvbootctrl set-active-boot-slot: %w (%s)", s, err, out)
		}
		return nil
	}

	dev, err := c.PartitionFor(s)
	if err != nil {
		return fmt.Errorf("swap to slot %s: %w", s, err)
	}

	// Mount the freshly written rootfs read-only to inspect the marker
	// (and stage the capsule from it if present).
	mountDir, unmount, err := c.mountFn(dev)
	if err != nil {
		return fmt.Errorf("swap to slot %s: mount %s: %w", s, dev, err)
	}
	defer unmount()

	marker := filepath.Join(mountDir, strings.TrimPrefix(MarkerPath, "/"))
	capsule := filepath.Join(mountDir, strings.TrimPrefix(CapsuleSrcPath, "/"))
	_, markerErr := os.Stat(marker)
	hasMarker := markerErr == nil

	// The capsule path (below) delegates the ENTIRE slot switch to UEFI
	// processing the capsule at reboot — no nvbootctrl call. That only works
	// where capsule-on-disk is actually honored (Thor). On Orin and unknown
	// SoCs the firmware silently ignores a correctly-staged capsule, so the
	// slot never moves and the update no-ops (reboots into the same OS). Fall
	// back to the reliable nvbootctrl slot switch there: the new rootfs boots
	// on the existing bootloader (validated by manual set-active-boot-slot),
	// only the bootloader is left un-updated. See capsuleUpdateEffective.
	if !hasMarker || !c.capsuleUpdateEffective() {
		if hasMarker {
			slog.Warn("swap: image requests a bootloader update but UEFI capsule-on-disk is not effective on this platform; applying rootfs-only slot switch — the bootloader will NOT be updated",
				"slot", s.String())
		} else {
			slog.Info("swap: rootfs-only update, switching boot slot", "slot", s.String())
		}
		if err := c.recordBootAttempt(s); err != nil {
			return err
		}
		args := append(c.nvbootctrlSlotArgs(), "set-active-boot-slot", fmt.Sprintf("%d", int(s)))
		out, err := runCmd(c.Nvbootctrl, args...)
		if err != nil {
			return fmt.Errorf("swap to slot %s: nvbootctrl set-active-boot-slot: %w (%s)", s, err, out)
		}
		return nil
	}

	// CAPSULE UPDATE.
	slog.Info("swap: bootloader marker present, staging capsule update", "slot", s.String())
	if _, err := os.Stat(capsule); err != nil {
		return fmt.Errorf("swap to slot %s: bootloader update requested by rootfs marker but capsule missing at %s", s, CapsuleSrcPath)
	}

	// Save the current bootloader version for post-reboot verification
	// (verify-bootloader-update's primary check).
	if ver, err := c.bootloaderVersion(); err == nil {
		_ = os.MkdirAll(filepath.Dir(c.blVersionBeforePath()), 0o755)
		if werr := os.WriteFile(c.blVersionBeforePath(), []byte(ver+"\n"), 0o644); werr != nil {
			return fmt.Errorf("swap to slot %s: save bootloader version: %w", s, werr)
		}
	} else {
		slog.Warn("could not record pre-update bootloader version", "err", err)
	}

	espDir, err := c.espMountpoint()
	if err != nil {
		return fmt.Errorf("swap to slot %s: %w", s, err)
	}
	dst := filepath.Join(espDir, ESPCapsuleRel)
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return fmt.Errorf("swap to slot %s: %w", s, err)
	}
	if err := copyFileSync(capsule, dst); err != nil {
		return fmt.Errorf("swap to slot %s: stage capsule: %w", s, err)
	}

	if err := c.recordBootAttempt(s); err != nil {
		return err
	}
	if err := setOsIndicationsCapsuleBit(filepath.Join(c.EfivarsDir, "OsIndications-"+EfiGlobalGUID)); err != nil {
		return fmt.Errorf("swap to slot %s: %w", s, err)
	}
	// Deliberately NO nvbootctrl call: UpdateFwChain() switches the
	// chain when the capsule is processed.
	return nil
}

// capsuleEffectiveSoC is the device-tree compatible token for the only
// platform where UEFI capsule-on-disk bootloader updates are validated to be
// processed by the firmware: NVIDIA Jetson AGX Thor (t264).
const capsuleEffectiveSoC = "tegra264"

// capsuleUpdateEffective reports whether staging a UEFI capsule-on-disk update
// (capsule on the ESP + OsIndications bit, no nvbootctrl call) will actually
// be honored by this platform's firmware.
//
// This is an allowlist, not a capability probe, and deliberately so: the UEFI
// OsIndicationsSupported variable advertises FILE_CAPSULE_DELIVERY on Orin
// (tegra234) too, yet the firmware never processes a correctly-staged capsule
// there — observed fleet-wide on AGX Orin and Orin Nano (r39.2): ESRT stays 0,
// the boot chain never switches, and the whole update silently no-ops. Only
// Thor (tegra264) is validated to process the capsule. Everything else — Orin
// and any unknown or unreadable SoC — is treated as ineffective so SwapSlot
// falls back to the reliable nvbootctrl slot switch, trading the bootloader
// update for an update that actually applies.
func (c *Controller) capsuleUpdateEffective() bool {
	return c.socCompatibleContains(capsuleEffectiveSoC)
}

// bootChainSlotABSoC is the device-tree compatible token for Orin (t234), the
// platform that drives A/B by switching the BOOT CHAIN rather than the
// rootfs-redundancy slot. See bootChainSlotAB.
const bootChainSlotABSoC = "tegra234"

// bootChainSlotAB reports whether this SoC does OS-driven rootfs A/B by
// switching the BOOT CHAIN (nvbootctrl WITHOUT `-t rootfs`) instead of the
// rootfs-redundancy slot (nvbootctrl `-t rootfs`).
//
// NVIDIA couples the two layers — boot chain N <-> rootfs slot N — but the
// rootfs-redundancy layer is gated by the RootfsRedundancyLevel UEFI variable,
// which is UNARMABLE from the OS on Orin (t234): it is a flash-time device-tree
// setting, and every efivarfs write returns EINVAL. With it unarmed,
// `nvbootctrl -t rootfs set-active-boot-slot` is a silent no-op and every OTA
// rolls back. The boot-chain layer needs no such variable: a capsule-on-disk
// update on Orin (which switches the chain and makes NO nvbootctrl call) was
// observed to flip the coupled rootfs slot, proving the chain switch moves the
// rootfs. So on Orin we drive the chain directly with nvbootctrl and skip the
// redundancy machinery entirely.
//
// Only Orin (tegra234) opts in. Thor (tegra264) keeps the rootfs-redundancy
// path (redundancy is armed at flash there and its flow is hardware-validated),
// and an unknown/unreadable SoC keeps that conservative default too.
func (c *Controller) bootChainSlotAB() bool {
	return c.socCompatibleContains(bootChainSlotABSoC)
}

// nvbootctrlSlotArgs returns the nvbootctrl target-type selector for slot
// operations (get-current-slot / set-active-boot-slot / mark-boot-successful):
// none for the boot-chain layer (Orin), "-t rootfs" for the rootfs-redundancy
// layer (Thor and the conservative default). Returns a fresh slice each call so
// callers can append safely.
func (c *Controller) nvbootctrlSlotArgs() []string {
	if c.bootChainSlotAB() {
		return nil
	}
	return []string{"-t", "rootfs"}
}

// socCompatibleContains reports whether the device-tree "compatible" property
// contains token (e.g. "tegra234", "tegra264"). compatible is a NUL-separated
// list of "vendor,soc" strings. Returns false (with a warning) when it cannot
// be read, so callers treat an unknown SoC conservatively.
func (c *Controller) socCompatibleContains(token string) bool {
	raw, err := os.ReadFile(c.RootDir + "/proc/device-tree/compatible")
	if err != nil {
		slog.Warn("SoC gate: cannot read device-tree compatible; treating SoC as unknown", "token", token, "err", err)
		return false
	}
	for _, tok := range strings.Split(string(raw), "\x00") {
		if strings.Contains(tok, token) {
			return true
		}
	}
	return false
}

// recordBootAttempt notes which slot the next boot targets — input for
// the double-boot detector (BootIsCompromised).
func (c *Controller) recordBootAttempt(s connector.Slot) error {
	if err := os.MkdirAll(c.stateDir(), 0o755); err != nil {
		return fmt.Errorf("record boot attempt: %w", err)
	}
	if err := os.WriteFile(c.bootAttemptedPath(), []byte(fmt.Sprintf("%d\n", int(s))), 0o644); err != nil {
		return fmt.Errorf("record boot attempt: %w", err)
	}
	return nil
}

// blVersionBeforePath: pre-update bootloader version
// (docs/state-schema.md: transient, capsule updates only).
func (c *Controller) blVersionBeforePath() string {
	return c.RootDir + "/data/wendyos-update/bl-version-before"
}

// bootloaderVersion parses "Current version: X" from the BOOTLOADER
// view of dump-slots-info (no -t rootfs; validated format on r36+r38).
func (c *Controller) bootloaderVersion() (string, error) {
	out, err := runCmd(c.Nvbootctrl, "dump-slots-info")
	if err != nil {
		return "", fmt.Errorf("nvbootctrl dump-slots-info: %w", err)
	}
	for _, line := range strings.Split(out, "\n") {
		if rest, ok := strings.CutPrefix(strings.TrimSpace(line), "Current version:"); ok {
			v := strings.TrimSpace(rest)
			if v != "" {
				return v, nil
			}
		}
	}
	return "", fmt.Errorf("nvbootctrl dump-slots-info: no 'Current version:' line")
}

// espMountpoint returns where the ESP is mounted, mounting it at
// /run/wendyos-update/esp if necessary (switch-rootfs behavior:
// findmnt /boot/efi, else mount by-partlabel).
func (c *Controller) espMountpoint() (string, error) {
	if out, err := runCmd("findmnt", "-no", "TARGET", "/boot/efi"); err == nil {
		if t := strings.TrimSpace(out); t != "" {
			return t, nil
		}
	}
	for _, label := range espPartlabels {
		link := c.RootDir + "/dev/disk/by-partlabel/" + label
		dev, err := filepath.EvalSymlinks(link)
		if err != nil {
			continue
		}
		dir, _, err := c.mountVfat(dev)
		if err != nil {
			return "", fmt.Errorf("mount ESP %s: %w", dev, err)
		}
		// Left mounted on purpose: the staged capsule must be on disk
		// at reboot; the mount dies with the system anyway.
		return dir, nil
	}
	return "", fmt.Errorf("ESP not mounted at /boot/efi and no by-partlabel match (%v)", espPartlabels)
}

// copyFileSync copies src to dst and fsyncs dst (the capsule must be
// durable before OsIndications is armed).
func copyFileSync(src, dst string) error {
	data, err := os.ReadFile(src) // capsules are tens of MB; fine to buffer
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

// --- mount seams (real implementations; tests substitute mountFn) ---

// defaultMount mounts dev read-only (ext4 rootfs) under /run and
// returns the dir plus an unmount func.
func defaultMount(dev string) (string, func(), error) {
	dir, err := os.MkdirTemp("/run", "wendyos-update-slot-*")
	if err != nil {
		return "", nil, err
	}
	if err := unix.Mount(dev, dir, "ext4", unix.MS_RDONLY, ""); err != nil {
		os.Remove(dir)
		return "", nil, err
	}
	unmount := func() {
		_ = unix.Unmount(dir, 0)
		_ = os.Remove(dir)
	}
	return dir, unmount, nil
}

// mountVfat mounts the ESP read-write.
func (c *Controller) mountVfat(dev string) (string, func(), error) {
	dir := "/run/wendyos-update/esp"
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", nil, err
	}
	if err := unix.Mount(dev, dir, "vfat", 0, ""); err != nil {
		return "", nil, err
	}
	return dir, func() { _ = unix.Unmount(dir, 0) }, nil
}
