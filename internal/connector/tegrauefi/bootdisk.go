package tegrauefi

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// espTypeGUID is the GPT type of an EFI system partition, the only kind of
// partition firmware reads capsules from.
const espTypeGUID = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

var (
	nvmeDiskName = regexp.MustCompile(`^nvme[0-9]+n[0-9]+$`)
	mmcDiskName  = regexp.MustCompile(`^mmcblk[0-9]+$`)
)

// checkFirmwareCapsuleDisk refuses an ESP the firmware would not read. Capsule
// on disk takes the ESP of the first active BootNext/BootOrder option whose
// disk has one and looks no further (edk2 GetEfiSysPartitionFromActiveBootOption);
// BootCurrent plays no part. With every ESP on the root disk there is no choice.
func (c *Controller) checkFirmwareCapsuleDisk(esp partitionInfo) error {
	l, err := c.layout()
	if err != nil {
		return err
	}
	disk := devPath(esp.Parent)
	espDisks := firmwareESPDisks(l.parts)
	if len(espDisks) == 0 || (len(espDisks) == 1 && espDisks[disk]) {
		return nil
	}
	order, err := c.bootOptionOrder()
	if err != nil {
		return fmt.Errorf("ESPs on several disks, cannot tell which one firmware reads capsules from: %w", err)
	}
	for _, num := range order {
		target, err := c.bootOptionDisk(l.parts, num, espDisks)
		if err != nil {
			return err
		}
		if target == disk {
			return nil
		}
		if target != "" {
			return fmt.Errorf("firmware reads capsules from the ESP on %s (Boot%04X comes first in BootNext/BootOrder), not from %s on the running root's disk; put the root disk's boot option first", target, num, esp.Path)
		}
	}
	return fmt.Errorf("no active boot option leads firmware to the ESP %s on the running root's disk", esp.Path)
}

// firmwareESPDisks lists the disks carrying a GPT ESP with a FAT filesystem.
func firmwareESPDisks(parts []partitionInfo) map[string]bool {
	disks := make(map[string]bool)
	for _, part := range parts {
		if isFirmwareESP(part) {
			disks[devPath(part.Parent)] = true
		}
	}
	return disks
}

func isFirmwareESP(part partitionInfo) bool {
	return part.Type == "part" && strings.EqualFold(part.PartType, espTypeGUID) && part.FSType == "vfat"
}

// bootOptionOrder is the order firmware searches: BootNext, then BootOrder.
func (c *Controller) bootOptionOrder() ([]uint16, error) {
	var order []uint16
	if raw, err := os.ReadFile(filepath.Join(c.EfivarsDir, "BootNext-"+EfiGlobalGUID)); err == nil && len(raw) == 6 {
		order = append(order, binary.LittleEndian.Uint16(raw[4:]))
	} else if err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("read BootNext: %w", err)
	}
	raw, err := os.ReadFile(filepath.Join(c.EfivarsDir, "BootOrder-"+EfiGlobalGUID))
	if err != nil {
		return nil, fmt.Errorf("read BootOrder: %w", err)
	}
	if len(raw) < 4 || len(raw)%2 != 0 {
		return nil, fmt.Errorf("malformed BootOrder")
	}
	for i := 4; i < len(raw); i += 2 {
		order = append(order, binary.LittleEndian.Uint16(raw[i:]))
	}
	return order, nil
}

// bootOptionDisk returns the disk whose ESP firmware takes through boot option
// num, or "" when firmware finds no ESP there and moves on to the next option.
func (c *Controller) bootOptionDisk(parts []partitionInfo, num uint16, espDisks map[string]bool) (string, error) {
	name := fmt.Sprintf("Boot%04X", num)
	raw, err := os.ReadFile(filepath.Join(c.EfivarsDir, name+"-"+EfiGlobalGUID))
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("read %s: %w", name, err)
	}
	if len(raw) < 4 {
		return "", fmt.Errorf("%s: malformed load option", name)
	}
	attrs, nodes, err := parseLoadOption(raw[4:])
	if err != nil {
		return "", fmt.Errorf("%s: %w", name, err)
	}
	// Inactive and legacy (BBS) options are skipped by firmware.
	if attrs&0x1 == 0 || (len(nodes) > 0 && nodes[0].typ == 0x05) {
		return "", nil
	}
	// A GPT partition node narrows the option to exactly that partition.
	for _, n := range nodes {
		if n.typ == 0x04 && n.sub == 0x01 && len(n.data) == 38 && n.data[36] == 0x02 && n.data[37] == 0x02 {
			guid := formatGUID(n.data[20:36])
			for _, part := range parts {
				if strings.EqualFold(part.PartUUID, guid) && isFirmwareESP(part) {
					return devPath(part.Parent), nil
				}
			}
			return "", nil
		}
	}
	disk := ""
	for _, n := range nodes {
		switch {
		case n.typ == 0x03 && n.sub == 0x17 && len(n.data) == 12: // NVMe namespace
			disk, err = c.nvmeDisk(parts, binary.LittleEndian.Uint32(n.data[:4]), n.data[4:])
		case n.typ == 0x03 && n.sub == 0x1d: // eMMC
			disk, err = c.mmcDisk(parts, "MMC")
		case n.typ == 0x03 && n.sub == 0x1a: // SD
			disk, err = c.mmcDisk(parts, "SD")
		case n.typ == 0x03 && slices.Contains([]byte{0x0b, 0x0c, 0x0d, 0x18}, n.sub),
			n.typ == 0x04 && (n.sub == 0x06 || n.sub == 0x07):
			return "", nil // network boot or a firmware application
		default:
			continue
		}
		if err != nil {
			return "", fmt.Errorf("%s: %w", name, err)
		}
		if !espDisks[disk] {
			return "", nil
		}
		return disk, nil
	}
	// USB, SATA, UFS and the like cannot reach an NVMe or MMC disk's ESP.
	for d := range espDisks {
		if base := filepath.Base(d); !nvmeDiskName.MatchString(base) && !mmcDiskName.MatchString(base) {
			return "", fmt.Errorf("%s matches no disk, and firmware may reach the ESP on %s through it", name, d)
		}
	}
	return "", nil
}

// nvmeDisk finds the namespace an NVMe node names; its EUI-64, when set, is
// stored in the byte order sysfs prints. An absent drive matches nothing.
func (c *Controller) nvmeDisk(parts []partitionInfo, nsid uint32, eui []byte) (string, error) {
	var found []string
	for _, part := range parts {
		name := filepath.Base(part.Path)
		if part.Type != "disk" || !nvmeDiskName.MatchString(name) {
			continue
		}
		if c.sysBlock(name, "nsid") != fmt.Sprint(nsid) {
			continue
		}
		if !bytes.Equal(eui, make([]byte, 8)) {
			got, err := hex.DecodeString(strings.ReplaceAll(c.sysBlock(name, "eui"), " ", ""))
			if err != nil || !bytes.Equal(got, eui) {
				continue
			}
		}
		found = append(found, part.Path)
	}
	return onlyDisk(found, "NVMe namespace")
}

// mmcDisk finds the MMC block device of a card type; boot partitions
// (mmcblkNbootM) share the card's type and are not disks of their own.
func (c *Controller) mmcDisk(parts []partitionInfo, cardType string) (string, error) {
	var found []string
	for _, part := range parts {
		name := filepath.Base(part.Path)
		if part.Type == "disk" && mmcDiskName.MatchString(name) && c.sysBlock(name, "device/type") == cardType {
			found = append(found, part.Path)
		}
	}
	return onlyDisk(found, cardType+" card")
}

func onlyDisk(found []string, what string) (string, error) {
	if len(found) > 1 {
		return "", fmt.Errorf("names a %s that matches %s", what, strings.Join(found, ", "))
	}
	if len(found) == 1 {
		return found[0], nil
	}
	return "", nil
}

func (c *Controller) sysBlock(name, attr string) string {
	raw, err := os.ReadFile(c.RootDir + "/sys/block/" + name + "/" + attr)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

type devicePathNode struct {
	typ, sub byte
	data     []byte
}

// parseLoadOption parses an EFI_LOAD_OPTION (UEFI 2.10, 3.1.3) into its
// attributes and the nodes of its first device path.
func parseLoadOption(opt []byte) (uint32, []devicePathNode, error) {
	malformed := errors.New("malformed load option")
	if len(opt) < 6 {
		return 0, nil, malformed
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
		return 0, nil, malformed
	}
	var nodes []devicePathNode
	for path := opt[start : start+pathLen]; len(path) >= 4; {
		typ, sub, n := path[0], path[1], int(binary.LittleEndian.Uint16(path[2:4]))
		if n < 4 || n > len(path) {
			return 0, nil, malformed
		}
		if typ == 0x7f && sub == 0xff {
			return binary.LittleEndian.Uint32(opt[:4]), nodes, nil
		}
		nodes = append(nodes, devicePathNode{typ, sub, path[4:n]})
		path = path[n:]
	}
	return 0, nil, malformed
}

// formatGUID renders an EFI_GUID, whose first three fields are little-endian,
// the way lsblk prints PARTUUID.
func formatGUID(b []byte) string {
	return fmt.Sprintf("%08x-%04x-%04x-%x-%x",
		binary.LittleEndian.Uint32(b[0:4]), binary.LittleEndian.Uint16(b[4:6]),
		binary.LittleEndian.Uint16(b[6:8]), b[8:10], b[10:16])
}
