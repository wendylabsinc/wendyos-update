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

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// ESRT entry0 last_attempt_status codes (validated: t234 incident analysis
// + t264 Phase 1). 0 = success; 1-6 = standard UEFI capsule errors; the
// NVIDIA-specific codes and vendor range are documented per NVIDIA L4T.
const (
	esrtSuccess   = 0
	esrtUEFIErrLo = 1 // 1..6: standard UEFI capsule errors
	esrtUEFIErrHi = 6
	// 6163: NVIDIA "CheckTheImage failed" — the capsule was rejected. NOT a
	// cert/auth failure (test-cert capsules verify fine on a clean device).
	// Observed to be boot-chain-state dependent: staging onto an un-settled
	// or pending boot-chain transition produces it; a fresh flash or a
	// fully-committed prior apply clears it (t264 investigation 2026-06-14;
	// NVIDIA fwd: forums.developer.nvidia.com thread 368593).
	esrtNvidiaCheckImageFail = 6163
	esrtNvidiaSKUMismatch    = 6164   // device SKU not in the capsule's BUP
	esrtNvidiaVendorLo       = 0x1000 // 0x1000..0x4000: NVIDIA vendor error range
	esrtNvidiaVendorHi       = 0x4000
)

// BootIsCompromised reports whether the firmware flagged either slot
// (RootfsStatusSlot status != 0). The engine calls this only while an
// update is pending — a 0xFF here right after a swap means UEFI burned
// the retry budget and fell back.
func (c *Controller) BootIsCompromised() (bool, error) {
	for _, s := range []connector.Slot{connector.SlotA, connector.SlotB} {
		raw, err := readStatus(c.statusVar(s))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return false, fmt.Errorf("boot health: %w", err)
		}
		if !statusIsNormal(raw) {
			return true, nil
		}
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
// 0 success; 1-6 standard UEFI capsule errors; 6163 NVIDIA "CheckTheImage
// failed" / capsule rejected (boot-chain-state dependent, NOT a cert/auth
// failure — see the const above); 6164 NVIDIA SKU mismatch; 0x1000-0x4000
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
		case status == esrtNvidiaCheckImageFail:
			return fmt.Errorf("platform verify: ESRT status %d (NVIDIA: capsule rejected / CheckTheImage failed — typically a pending/un-settled boot-chain state, not a signature problem)", esrtNvidiaCheckImageFail)
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
