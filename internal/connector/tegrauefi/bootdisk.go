package tegrauefi

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// checkFirmwareBootDisk refuses an ESP on another disk than the one firmware
// booted from, whose ESP is where capsule-on-disk is read. Only positive
// evidence counts: a boot option naming no listed partition passes.
func (c *Controller) checkFirmwareBootDisk(esp partitionInfo) error {
	guid := c.bootCurrentPartUUID()
	if guid == "" {
		return nil
	}
	l, err := c.layout()
	if err != nil {
		return err
	}
	var booted []partitionInfo
	for _, part := range l.parts {
		if part.Type == "part" && strings.EqualFold(part.PartUUID, guid) {
			if devPath(part.Parent) == devPath(esp.Parent) {
				return nil
			}
			booted = append(booted, part)
		}
	}
	if len(booted) == 0 {
		return nil
	}
	return fmt.Errorf("firmware booted from %s (UEFI BootCurrent), which is not on the disk of ESP %s; a capsule staged there would be ignored, and a split firmware/root disk layout is not supported for bootloader updates", booted[0].Path, esp.Path)
}

// bootCurrentPartUUID returns the GPT partition GUID named by the boot option
// the firmware used for this boot, or "" when it cannot be read or names none.
func (c *Controller) bootCurrentPartUUID() string {
	raw, err := os.ReadFile(filepath.Join(c.EfivarsDir, "BootCurrent-"+EfiGlobalGUID))
	if err != nil || len(raw) != 6 {
		return ""
	}
	option := fmt.Sprintf("Boot%04X-%s", binary.LittleEndian.Uint16(raw[4:]), EfiGlobalGUID)
	raw, err = os.ReadFile(filepath.Join(c.EfivarsDir, option))
	if err != nil || len(raw) < 4 {
		return ""
	}
	return loadOptionPartUUID(raw[4:])
}

// loadOptionPartUUID parses an EFI_LOAD_OPTION (UEFI 2.10, 3.1.3) and returns
// the signature of its first GPT hard-drive device-path node.
func loadOptionPartUUID(opt []byte) string {
	if len(opt) < 6 {
		return ""
	}
	pathLen := int(binary.LittleEndian.Uint16(opt[4:6]))
	start := -1
	for i := 6; i+1 < len(opt); i += 2 {
		if opt[i] == 0 && opt[i+1] == 0 {
			start = i + 2
			break
		}
	}
	if start < 0 || start+pathLen > len(opt) {
		return ""
	}
	path := opt[start : start+pathLen]
	for len(path) >= 4 {
		typ, sub, n := path[0], path[1], int(binary.LittleEndian.Uint16(path[2:4]))
		if n < 4 || n > len(path) || (typ == 0x7f && sub == 0xff) {
			return ""
		}
		// Media / hard drive, GPT partition format, GUID signature.
		if typ == 0x04 && sub == 0x01 && n == 42 && path[40] == 0x02 && path[41] == 0x02 {
			return formatGUID(path[24:40])
		}
		path = path[n:]
	}
	return ""
}

// formatGUID renders an EFI_GUID, whose first three fields are little-endian,
// the way lsblk prints PARTUUID.
func formatGUID(b []byte) string {
	return fmt.Sprintf("%08x-%04x-%04x-%x-%x",
		binary.LittleEndian.Uint32(b[0:4]), binary.LittleEndian.Uint16(b[4:6]),
		binary.LittleEndian.Uint16(b[6:8]), b[8:10], b[10:16])
}
