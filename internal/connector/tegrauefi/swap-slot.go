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
		out, err := runCmd(c.Nvbootctrl, "-t", "rootfs", "set-active-boot-slot", fmt.Sprintf("%d", int(s)))
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
	// processing the capsule at reboot — no nvbootctrl call. It is taken only
	// when the firmware advertises capsule-on-disk support (capsuleUpdateEffective).
	// When it does not, fall back to the reliable nvbootctrl slot switch: the new
	// rootfs boots on the existing bootloader (validated by manual
	// set-active-boot-slot), only the bootloader is left un-updated.
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
		out, err := runCmd(c.Nvbootctrl, "-t", "rootfs", "set-active-boot-slot", fmt.Sprintf("%d", int(s)))
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

	// Clear any pending FW-chain switch first: the firmware CANCELS a capsule
	// (last_attempt_status 6163 = LAS_ERROR_BOOT_CHAIN_UPDATE_CANCELED) while
	// BootChainFwNext or BootChainFwStatus exists. See settleBootChain.
	if err := c.settleBootChain(); err != nil {
		return fmt.Errorf("swap to slot %s: %w", s, err)
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

// capsuleUpdateEffective reports whether staging a UEFI capsule-on-disk update
// (capsule on the ESP + OsIndications bit, no nvbootctrl call) will be honored
// by this platform's firmware. It trusts the firmware's own capability signal:
// OsIndicationsSupported advertising FILE_CAPSULE_DELIVERY (bit 2).
//
// Orin (t234/r39.2) verified on-device 2026-07-05: a staged capsule is
// processed (OsIndications bit cleared, boot chain flipped, capsule consumed).
// Thor (t264/r38) honors capsule-on-disk (Phase 1 validation), which per the
// UEFI spec entails advertising the bit. The earlier tegra264-only allowlist was a
// misdiagnosis: the "Orin ignores the capsule" symptom was actually an unarmed
// rootfs-A/B redundancy no-op (the boot chain flipped but the rootfs slot could
// not follow), since fixed by PreflightInstall refusing an install unless
// RootfsRedundancyLevel is armed. So an Orin reaches this path only when armed —
// exactly the condition under which the capsule works.
//
// We do NOT special-case per-SoC allowlists or manual overrides. A firmware that
// advertises but does not honor the capsule fails SAFE: the boot chain never
// switches, so Commit sees running slot != target and rolls back — no brick, no
// skew. A genuinely lying firmware is a BSP defect, not something the update
// engine should paper over.
func (c *Controller) capsuleUpdateEffective() bool {
	return firmwareSupportsCapsuleOnDisk(filepath.Join(c.EfivarsDir, "OsIndicationsSupported-"+EfiGlobalGUID))
}

// bootChainVars are the pending-FW-chain-switch UEFI variables (NVIDIA vendor
// namespace, VendorGUID). While either exists the firmware CANCELS a capsule
// update with last_attempt_status 6163 (LAS_ERROR_BOOT_CHAIN_UPDATE_CANCELED):
// TegraFmp.c FmpTegraCheckImage → BootChainDxe.c BootChainCheckAndCancelUpdate
// cancels if BootChainFwNext OR BootChainFwStatus is present. The firmware
// deletes BootChainFwNext itself on the cancel but NEVER deletes
// BootChainFwStatus, so a rolled-back rootfs-only OTA leaves BootChainFwStatus
// set and every later capsule 6163s until it is cleared out-of-band. (On Orin's
// linked chains a rootfs-slot switch is what leaves BootChainFwNext behind —
// device-observed, not confirmed from the closed nvbootctrl source.)
var bootChainVars = []string{"BootChainFwNext", "BootChainFwStatus"}

// settleBootChain clears any pending FW-chain switch so the capsule is not
// canceled for an "FMP conflict". Deleting these efivars is the same operation
// the firmware performs on BootChainFwNext, and was proven on-device to clear
// both (Orin Nano t234/r39.2, capture-orin-capsule.sh --settle-probe, 2026-07-06;
// nvbootctrl has no mark-boot-successful there, so efivarfs delete is the only
// mechanism). Safe here because the engine serializes OTAs: at capsule-stage
// time a pending switch is a stale, un-committed prior attempt — not a live
// in-flight update. An out-of-band pending switch (e.g. an operator arming a
// chain change by hand) would also be cleared, which is acceptable: the firmware
// would cancel that switch the moment it processed the capsule anyway (same
// CheckAndCancelUpdate), so no update the capsule wouldn't supersede is lost.
func (c *Controller) settleBootChain() error {
	for _, name := range bootChainVars {
		path := filepath.Join(c.EfivarsDir, name+"-"+VendorGUID)
		_, statErr := os.Stat(path)
		if err := deleteVar(path); err != nil {
			return fmt.Errorf("clear pending FW-chain var %s: %w", name, err)
		}
		if statErr == nil {
			slog.Info("swap: cleared pending FW-chain variable to avoid capsule cancel (6163)", "var", name)
		}
	}
	return nil
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
