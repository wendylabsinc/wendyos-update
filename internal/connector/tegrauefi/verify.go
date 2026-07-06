package tegrauefi

// Boot health and platform-update verification: ports of
// verify-bootloader-update (the cascade) and abort-blupdate, plus the
// RootfsStatusSlot health check used by the boot verify unit.

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// ESRT entry0 last_attempt_status codes (validated: t234 incident analysis
// + t264 Phase 1). 0 = success; 1-6 = standard UEFI capsule errors; the
// NVIDIA-specific codes and vendor range are documented per NVIDIA L4T.
const (
	esrtSuccess   = 0
	esrtUEFIErrLo = 1 // 1..6: standard UEFI capsule errors
	esrtUEFIErrHi = 6
	// 6163 = LAS_ERROR_BOOT_CHAIN_UPDATE_CANCELED (NOT "CheckTheImage failed"; that
	// was a mis-read of a different firmware's code range). Proven from the r39.2
	// edk2-nvidia source: EDK2 FmpDevicePkg base LAST_ATTEMPT_STATUS_DEVICE_LIBRARY_MIN
	// = 0x1800 (6144), and the enum entry in TegraFmp.c is #19 → 6163. Set by
	// FmpTegraCheckImage (TegraFmp.c) via BootChainDxe.c BootChainCheckAndCancelUpdate,
	// which CANCELS the capsule while BootChainFwNext OR BootChainFwStatus exists (an
	// "FMP conflict" with a pending nvbootctrl-style FW-chain switch). SwapSlot now
	// clears both before staging (settleBootChain), so a fresh 6163 here means the
	// chain re-entered a pending state after staging — a real defect, not stale cruft.
	esrtBootChainUpdateCanceled = 6163
	esrtNvidiaSKUMismatch       = 6164   // device SKU not in the capsule's BUP
	esrtNvidiaVendorLo          = 0x1000 // 0x1000..0x4000: NVIDIA vendor error range
	esrtNvidiaVendorHi          = 0x4000
)

// BootIsCompromised reports whether the firmware flagged the slot we
// actually booted (RootfsStatusSlot status != 0) — a 0xFF right after a
// swap means UEFI burned the retry budget. The engine calls this only
// while an update is pending.
//
// Only the BOOTED slot is evidence about this boot's health. The previous
// implementation scanned both slots and flagged failure if EITHER was
// non-normal, so a stale 0xFF left on the inactive/old slot false-positived
// a perfectly healthy update (WDY-1742). Firmware fallback — running a
// different slot than the update targeted — is detected separately by the
// engine's running-slot vs target-slot check, not here.
//
// Conservative on uncertainty: if we cannot determine the current slot, or
// the booted slot's status var is absent or not the validated 8-byte layout,
// we return "not compromised" rather than crying wolf. The 8-byte format is
// confirmed on t234 (incl. Orin Nano r39.2, read off the device) and t264;
// an unexpected size (the other WDY-1742 failure mode) is treated as
// inconclusive instead of forcing a rollback.
// The engine's slot check and the ESRT platform-verify cascade remain the
// authoritative guards, so this loses no genuine-fallback detection.
func (c *Controller) BootIsCompromised() (bool, error) {
	cur, err := c.CurrentSlot()
	if err != nil {
		slog.Warn("boot health: cannot determine current slot; skipping efivar check", "err", err)
		return false, nil
	}

	raw, err := readStatus(c.statusVar(cur))
	if os.IsNotExist(err) {
		return false, nil // no status var for the booted slot: nothing to flag
	}
	if err != nil {
		return false, fmt.Errorf("boot health: %w", err)
	}
	if !statusIsWellFormed(raw) {
		slog.Warn("boot health: RootfsStatusSlot has unvalidated format; treating as inconclusive",
			"slot", cur.String(), "bytes", len(raw))
		return false, nil
	}
	if !statusIsNormal(raw) {
		slog.Warn("boot health: firmware flagged the booted slot unhealthy", "slot", cur.String())
		return true, nil
	}
	return false, nil
}

// VerifyPlatformUpdate is the verify-bootloader-update cascade. The
// running rootfs's marker file is the source of truth for whether a
// bootloader update was part of this deployment (same rule as staging);
// blUpdate from the manifest is informational.
//
//  1. PRIMARY:   bootloader version changed vs the value saved at swap
//  2. SECONDARY: ESRT last_attempt_status == 0
//  3. FALLBACK:  we booted, assume success — but say so loudly
//
// Validated ESRT codes (t234 incident analysis + t264 Phase 1):
// 0 success; 1-6 standard UEFI capsule errors; 6163 = LAS_ERROR_BOOT_CHAIN_UPDATE_CANCELED
// (capsule canceled by a pending FW-chain switch — see the const above);
// 6164 NVIDIA SKU mismatch; 0x1000-0x4000
// NVIDIA vendor range. nvbootctrl's own capsule status is NOT consulted —
// NVIDIA documents it as unreliable.
func (c *Controller) VerifyPlatformUpdate(blUpdate bool) error {
	if _, err := os.Stat(c.RootDir + MarkerPath); err != nil {
		if blUpdate {
			slog.Info("platform verify: manifest declared bootloader_update but the running rootfs has no marker; skipping")
		}
		return nil
	}
	slog.Info("platform verify: checking bootloader update (version + ESRT cascade)")

	// 1) version comparison
	if before, err := os.ReadFile(c.blVersionBeforePath()); err == nil {
		after, verr := c.bootloaderVersion()
		if verr == nil {
			if strings.TrimSpace(string(before)) != after {
				_ = os.Remove(c.blVersionBeforePath())
				slog.Info("platform verify: bootloader version changed — capsule applied", "version", after)
				return nil // version changed: capsule applied
			}
			slog.Info("platform verify: bootloader version unchanged; checking ESRT", "version", after)
		} else {
			slog.Warn("platform verify: could not read bootloader version; checking ESRT", "err", verr)
		}
	} else {
		slog.Warn("platform verify: no pre-update bootloader version recorded; checking ESRT")
	}

	// 2) ESRT verdict
	if raw, err := os.ReadFile(c.RootDir + ESRTStatusPath); err == nil {
		status, perr := strconv.Atoi(strings.TrimSpace(string(raw)))
		if perr != nil {
			return fmt.Errorf("platform verify: unparseable ESRT status %q", strings.TrimSpace(string(raw)))
		}
		switch {
		case status == esrtSuccess:
			_ = os.Remove(c.blVersionBeforePath())
			slog.Info("platform verify: ESRT reports success", "status", esrtSuccess)
			return nil
		case status >= esrtUEFIErrLo && status <= esrtUEFIErrHi:
			return fmt.Errorf("platform verify: ESRT status %d (standard UEFI capsule error)", status)
		case status == esrtBootChainUpdateCanceled:
			return fmt.Errorf("platform verify: ESRT status %d (LAS_ERROR_BOOT_CHAIN_UPDATE_CANCELED — capsule canceled by a pending FW-chain switch despite settleBootChain; the chain re-entered a pending state after staging)", esrtBootChainUpdateCanceled)
		case status == esrtNvidiaSKUMismatch:
			return fmt.Errorf("platform verify: ESRT status %d (NVIDIA: device SKU not included in the capsule's BUP)", esrtNvidiaSKUMismatch)
		case status >= esrtNvidiaVendorLo && status <= esrtNvidiaVendorHi:
			return fmt.Errorf("platform verify: ESRT status %d (NVIDIA vendor error)", status)
		default:
			slog.Warn("platform verify: unknown ESRT status; falling back to boot-success", "status", status)
		}
	} else {
		slog.Warn("platform verify: ESRT not readable; falling back to boot-success")
	}

	// 3) fallback: the system booted to this point
	slog.Warn("platform verify: could not confirm the bootloader update via version or ESRT; the system booted, assuming success — manual check recommended")
	_ = os.Remove(c.blVersionBeforePath())
	return nil
}

// AbortPlatformUpdate unstages a capsule that has not been processed:
// removes TEGRA_BL.Cap from the ESP (port of abort-blupdate) and disarms
// the OsIndications capsule bit so the firmware will not look for one.
// No-op when nothing is staged.
func (c *Controller) AbortPlatformUpdate() error {
	staged := false

	if espDir, err := c.espMountpoint(); err == nil {
		cap := filepath.Join(espDir, ESPCapsuleRel)
		if _, err := os.Stat(cap); err == nil {
			staged = true
			if err := os.Remove(cap); err != nil {
				return fmt.Errorf("abort platform update: %w", err)
			}
		}
	}

	osiPath := filepath.Join(c.EfivarsDir, "OsIndications-"+EfiGlobalGUID)
	if err := clearOsIndicationsCapsuleBit(osiPath); err != nil {
		return fmt.Errorf("abort platform update: %w", err)
	}

	if staged {
		_ = os.Remove(c.blVersionBeforePath())
	}
	return nil
}
