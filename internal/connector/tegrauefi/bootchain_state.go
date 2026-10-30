package tegrauefi

import (
	"encoding/binary"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// bootChainStatusInProgress is NVIDIA's BootChainFwStatus value for a switch
// the firmware has started but not yet judged.
const bootChainStatusInProgress = 1

// keepRunningSlot makes the running slot s the next boot by withdrawing any
// BootChainFwNext request instead of issuing one: nvbootctrl cannot remove a
// request, and the capsule check refuses to stage while one exists. With no
// request the firmware boots the current chain.
func (c *Controller) keepRunningSlot(s connector.Slot) (bool, error) {
	// Only where capsules stage does a request block anything, and only there
	// is withdrawing one validated.
	if !c.capsuleUpdateEffective() {
		return false, nil
	}
	cur, err := c.CurrentSlot()
	if err != nil {
		return false, err
	}
	if cur != s {
		return false, nil
	}
	// The firmware falls back to the chain it booted, not to the rootfs slot.
	chain, hasChain, err := c.readBootChainVariable("BootChainFwCurrent")
	if err != nil {
		return false, err
	}
	if !hasChain {
		return false, fmt.Errorf("firmware does not report its boot chain (BootChainFwCurrent missing)")
	}
	if chain != uint32(s) {
		return false, fmt.Errorf("firmware booted chain %d, not the running slot %s", chain, s)
	}
	// Mid-switch the firmware judges the outcome by BootChainFwNext.
	status, hasStatus, err := c.readBootChainVariable("BootChainFwStatus")
	if err != nil {
		return false, err
	}
	if hasStatus && status == bootChainStatusInProgress {
		return false, fmt.Errorf("the firmware is still judging a boot-chain switch")
	}
	// An armed capsule switches the chain at reboot; only a request cancels it.
	osi, err := os.ReadFile(filepath.Join(c.EfivarsDir, "OsIndications-"+EfiGlobalGUID))
	if err != nil && !os.IsNotExist(err) {
		return false, fmt.Errorf("read OsIndications: %w", err)
	}
	if len(osi) >= 5 && osi[4]&osIndicationsProcessCapsule != 0 {
		return false, fmt.Errorf("a capsule is still armed for the next boot")
	}

	next := filepath.Join(c.EfivarsDir, "BootChainFwNext-"+VendorGUID)
	pending, _ := os.ReadFile(next)
	if err := removeVar(next); err != nil {
		return false, fmt.Errorf("withdraw BootChainFwNext: %w", err)
	}
	if len(pending) > 0 {
		slog.Info("rollback: withdrew the pending boot-chain request", "slot", s.String(), "request", fmt.Sprintf("% x", pending))
	}
	return true, nil
}

// checkCapsuleBootChainIdle is deliberately read-only. NVIDIA's FMP check
// aborts with 0x1813 when either boot-chain variable exists, including value
// zero. Clearing these here could discard an actual pending switch. The
// operator must let that request finish and confirm the healthy boot first.
// Firmware never deletes BootChainFwStatus; `nvbootctrl verify`, which
// wendyos-update-verify.service runs every boot, deletes it whatever its value.
// The pinned r39.2 implementation is BootChainCheckAndCancelUpdate:
// https://github.com/NVIDIA/edk2-nvidia/blob/bd49b331a0bbdeef7a34c224a3767f77e36da0c4/Silicon/NVIDIA/Drivers/BootChainDxe/BootChainDxe.c#L223
func (c *Controller) checkCapsuleBootChainIdle() error {
	for _, name := range []string{"BootChainFwNext", "BootChainFwStatus"} {
		value, present, err := c.readBootChainVariable(name)
		if err != nil {
			return err
		}
		if present {
			return fmt.Errorf("cannot stage capsule while %s=%d exists: finish the pending boot-chain operation, confirm the healthy boot with nvbootctrl verify, and retry only after BootChainFwNext and BootChainFwStatus are absent", name, value)
		}
	}
	// Capsule-on-disk honors BootNext before BootOrder. A one-time boot
	// override could make firmware inspect a different disk's ESP.
	path := filepath.Join(c.EfivarsDir, "BootNext-"+EfiGlobalGUID)
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("cannot stage capsule while UEFI BootNext exists: finish the one-time boot override and verify the boot disk before retrying")
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("read UEFI BootNext: %w", err)
	}
	return nil
}

func (c *Controller) readBootChainVariable(name string) (uint32, bool, error) {
	info, err := os.Stat(c.EfivarsDir)
	if err != nil {
		return 0, false, fmt.Errorf("inspect EFI variable directory: %w", err)
	}
	if !info.IsDir() {
		return 0, false, fmt.Errorf("EFI variable path %s is not a directory", c.EfivarsDir)
	}
	raw, err := os.ReadFile(filepath.Join(c.EfivarsDir, name+"-"+VendorGUID))
	if os.IsNotExist(err) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, fmt.Errorf("read %s: %w", name, err)
	}
	if len(raw) != 8 {
		return 0, true, fmt.Errorf("invalid %s size %d: expected EFI attributes plus a 32-bit value", name, len(raw))
	}
	return binary.LittleEndian.Uint32(raw[4:]), true, nil
}
