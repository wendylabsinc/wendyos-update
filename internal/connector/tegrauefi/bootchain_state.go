package tegrauefi

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

// rollbackAlreadyActive avoids creating a new BootChainFwNext request after
// firmware has already fallen back to the rollback slot. Only Orin uses the
// boot-chain slot-switch path. A still-pending switch must retain the normal
// rollback path, even when userspace is still running the origin slot.
func (c *Controller) rollbackAlreadyActive(s connector.Slot) (bool, error) {
	if !c.bootChainSlotAB() {
		return false, nil
	}
	cur, err := c.CurrentSlot()
	if err != nil {
		return false, err
	}
	if cur != s {
		return false, nil
	}

	next, hasNext, err := c.readBootChainVariable("BootChainFwNext")
	if err != nil {
		return false, err
	}
	if hasNext && next > 1 {
		return false, fmt.Errorf("invalid BootChainFwNext value %d; refusing to infer a settled rollback", next)
	}
	_, hasStatus, err := c.readBootChainVariable("BootChainFwStatus")
	if err != nil {
		return false, err
	}
	if hasNext || hasStatus {
		return false, nil
	}

	out, err := runCmd(c.Nvbootctrl, "dump-slots-info")
	if err != nil {
		return false, fmt.Errorf("check rollback boot chain: nvbootctrl dump-slots-info: %w (%s)", err, out)
	}
	current, active, err := parseBootloaderSlots(out)
	if err != nil {
		return false, err
	}
	if current != cur {
		return false, fmt.Errorf("bootloader slot changed while checking rollback: current-slot=%s dump=%s", cur, current)
	}
	return active == s, nil
}

func parseBootloaderSlots(out string) (current, active connector.Slot, err error) {
	values := make(map[string]connector.Slot)
	for _, line := range strings.Split(out, "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok || (key != "Current bootloader slot" && key != "Active bootloader slot") {
			continue
		}
		if _, exists := values[key]; exists {
			return 0, 0, fmt.Errorf("nvbootctrl dump-slots-info: duplicate %s", key)
		}
		switch strings.TrimSpace(value) {
		case "A":
			values[key] = connector.SlotA
		case "B":
			values[key] = connector.SlotB
		default:
			return 0, 0, fmt.Errorf("nvbootctrl dump-slots-info: invalid %s %q", key, value)
		}
	}
	var ok bool
	if current, ok = values["Current bootloader slot"]; !ok {
		return 0, 0, fmt.Errorf("nvbootctrl dump-slots-info: missing current bootloader slot")
	}
	if active, ok = values["Active bootloader slot"]; !ok {
		return 0, 0, fmt.Errorf("nvbootctrl dump-slots-info: missing active bootloader slot")
	}
	return current, active, nil
}

// checkCapsuleBootChainIdle is deliberately read-only. NVIDIA's FMP check
// aborts with 0x1813 when either boot-chain variable exists, including value
// zero. Clearing these here could discard an actual pending switch. The
// operator must let that request finish and confirm the healthy boot first.
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
