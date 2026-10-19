package tegrauefi

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	nvmeESPUUID = "0b9f3c1e-6a2d-4e57-9a3b-1c2d3e4f5a6b"
	emmcESPUUID = "7c1e2d3f-4a5b-4c6d-8e7f-a0b1c2d3e4f5"
	emmcAPPUUID = "5d6e7f80-9a1b-4c2d-8e3f-405162738495"
)

var (
	nvmeEUI  = []byte{0x00, 0x25, 0x38, 0x89, 0x81, 0xb2, 0x14, 0x80}
	hwNode   = []byte{0x01, 0x04, 8, 0, 1, 2, 3, 4}
	emmcNode = []byte{0x03, 0x1d, 5, 0, 0}
	usbNode  = []byte{0x03, 0x05, 6, 0, 1, 0}
	macNode  = append([]byte{0x03, 0x0b, 37, 0}, make([]byte, 33)...)
	fvNode   = append([]byte{0x04, 0x06, 20, 0}, make([]byte, 16)...)
)

// guidBytes encodes a GUID the way EFI stores it: the first three fields
// little-endian, the rest in order.
func guidBytes(t *testing.T, s string) []byte {
	t.Helper()
	hex := strings.ReplaceAll(s, "-", "")
	raw := make([]byte, 16)
	for i := range raw {
		var b byte
		for _, c := range hex[2*i : 2*i+2] {
			b <<= 4
			switch {
			case c >= '0' && c <= '9':
				b |= byte(c - '0')
			default:
				b |= byte(c-'a') + 10
			}
		}
		raw[i] = b
	}
	for _, r := range [][2]int{{0, 4}, {4, 6}, {6, 8}} {
		for i, j := r[0], r[1]-1; i < j; i, j = i+1, j-1 {
			raw[i], raw[j] = raw[j], raw[i]
		}
	}
	return raw
}

func hardDriveNode(t *testing.T, guid string) []byte {
	node := make([]byte, 42)
	node[0], node[1] = 0x04, 0x01
	binary.LittleEndian.PutUint16(node[2:], 42)
	binary.LittleEndian.PutUint32(node[4:], 11)
	copy(node[24:40], guidBytes(t, guid))
	node[40], node[41] = 0x02, 0x02
	return node
}

func nvmeNode(nsid uint32, eui []byte) []byte {
	node := []byte{0x03, 0x17, 16, 0, 0, 0, 0, 0}
	binary.LittleEndian.PutUint32(node[4:], nsid)
	return append(node, eui...)
}

// loadOption builds an active EFI_LOAD_OPTION with the efivarfs attribute prefix.
func loadOption(nodes ...[]byte) []byte {
	var path []byte
	for _, n := range nodes {
		path = append(path, n...)
	}
	path = append(path, 0x7f, 0xff, 4, 0)
	opt := []byte{7, 0, 0, 0, 1, 0, 0, 0, 0, 0}
	binary.LittleEndian.PutUint16(opt[8:], uint16(len(path)))
	for _, r := range "UEFI disk" {
		opt = append(opt, byte(r), 0)
	}
	opt = append(opt, 0, 0)
	return append(opt, path...)
}

func inactive(opt []byte) []byte {
	opt = append([]byte(nil), opt...)
	opt[4] &^= 1
	return opt
}

func writeEfivar(t *testing.T, c *Controller, name string, body []byte) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(c.EfivarsDir, name+"-"+EfiGlobalGUID), body, 0o644); err != nil {
		t.Fatal(err)
	}
}

func bootNumbers(nums ...uint16) []byte {
	raw := []byte{7, 0, 0, 0}
	for _, n := range nums {
		raw = binary.LittleEndian.AppendUint16(raw, n)
	}
	return raw
}

func writeSysBlock(t *testing.T, c *Controller, rel, body string) {
	t.Helper()
	path := filepath.Join(c.RootDir, "sys/block", rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// bootOrderController is the two-disk AGX: root on NVMe, a second WendyOS on
// eMMC, a GPT ESP on both, and the boot options its firmware creates.
func bootOrderController(t *testing.T) *Controller {
	c := storageController(t)
	c.listPartsFn = func() ([]partitionInfo, error) {
		p := dualDiskParts()
		p[1].PartUUID = emmcAPPUUID
		p[3].PartUUID, p[3].PartType = emmcESPUUID, espTypeGUID
		p[7].PartUUID, p[7].PartType = strings.ToUpper(nvmeESPUUID), strings.ToUpper(espTypeGUID)
		return append(p, partitionInfo{Path: "/dev/mmcblk0boot0", Type: "disk", DeviceID: "179:32"}), nil
	}
	writeSysBlock(t, c, "nvme0n1/nsid", "1")
	writeSysBlock(t, c, "nvme0n1/eui", "00 25 38 89 81 b2 14 80")
	writeSysBlock(t, c, "mmcblk0/device/type", "MMC")
	writeSysBlock(t, c, "mmcblk0boot0/device/type", "MMC")
	writeEfivar(t, c, "Boot0001", loadOption(hwNode, emmcNode))
	writeEfivar(t, c, "Boot0002", loadOption(hwNode, macNode))
	writeEfivar(t, c, "Boot0006", loadOption(fvNode))
	writeEfivar(t, c, "Boot0008", loadOption(hwNode, nvmeNode(1, nvmeEUI)))
	return c
}

// Capsule-on-disk reads the ESP of the first active BootNext/BootOrder option
// whose disk has one, never the option this boot came from.
func TestCapsuleESPFollowsFirmwareBootOrder(t *testing.T) {
	for _, tc := range []struct {
		name    string
		order   []uint16 // nil: no BootOrder variable
		next    []uint16
		options map[string][]byte
		ok      bool
	}{
		{name: "root disk first", order: []uint16{8, 1}, ok: true},
		{name: "other disk first", order: []uint16{1, 8}},
		{name: "inactive other disk first", order: []uint16{1, 8},
			options: map[string][]byte{"Boot0001": inactive(loadOption(hwNode, emmcNode))}, ok: true},
		{name: "firmware apps and network first", order: []uint16{6, 2, 8, 1}, ok: true},
		{name: "BootNext names the other disk", order: []uint16{8, 1}, next: []uint16{1}},
		{name: "partition option on the root ESP", order: []uint16{0xa, 1},
			options: map[string][]byte{"Boot000A": loadOption(hwNode, hardDriveNode(t, nvmeESPUUID))}, ok: true},
		{name: "partition option on the other ESP", order: []uint16{0xa, 8},
			options: map[string][]byte{"Boot000A": loadOption(hwNode, nvmeNode(1, nvmeEUI), hardDriveNode(t, emmcESPUUID))}},
		{name: "partition option on a non-ESP partition", order: []uint16{0xa, 8},
			options: map[string][]byte{"Boot000A": loadOption(hwNode, emmcNode, hardDriveNode(t, emmcAPPUUID))}, ok: true},
		{name: "absent NVMe drive", order: []uint16{0xa, 8},
			options: map[string][]byte{"Boot000A": loadOption(hwNode, nvmeNode(1, []byte{1, 2, 3, 4, 5, 6, 7, 8}))}, ok: true},
		{name: "unmatched option while every ESP is on NVMe or eMMC", order: []uint16{0xa, 8},
			options: map[string][]byte{"Boot000A": loadOption(hwNode, usbNode)}, ok: true},
		{name: "dangling BootOrder entry", order: []uint16{0xf, 8}, ok: true},
		{name: "no option reaches an ESP", order: []uint16{6, 2}},
		{name: "no BootOrder"},
		{name: "malformed option", order: []uint16{0xa, 8},
			options: map[string][]byte{"Boot000A": {7, 0, 0, 0, 1}}},
		{name: "zero-length node", order: []uint16{0xa, 8},
			options: map[string][]byte{"Boot000A": loadOption([]byte{0x01, 0x04, 0, 0})}},
		{name: "truncated device path", order: []uint16{0xa, 8},
			options: map[string][]byte{"Boot000A": loadOption(hwNode, emmcNode)[:40]}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := bootOrderController(t)
			if tc.order != nil {
				writeEfivar(t, c, "BootOrder", bootNumbers(tc.order...))
			}
			if tc.next != nil {
				writeEfivar(t, c, "BootNext", bootNumbers(tc.next...))
			}
			for name, body := range tc.options {
				writeEfivar(t, c, name, body)
			}
			esp, err := c.capsuleESP()
			if tc.ok && (err != nil || esp.Path != "/dev/nvme0n1p11") {
				t.Fatalf("capsule ESP = %+v, %v", esp, err)
			}
			if !tc.ok && err == nil {
				t.Fatalf("capsule ESP %s accepted", esp.Path)
			}
			// Cleanup finds the root disk's ESP whatever the boot order says.
			if esp, err := c.espPartition(); err != nil || esp.Path != "/dev/nvme0n1p11" {
				t.Fatalf("cleanup ESP = %+v, %v", esp, err)
			}
		})
	}
}

// With an ESP on the root disk only, firmware can read no other one: single-disk
// boards must not depend on boot variables at all.
func TestCapsuleESPIgnoresBootOrderWithOneESPDisk(t *testing.T) {
	for _, other := range []partitionInfo{
		{PartType: "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7", FSType: "vfat"},
		{PartType: espTypeGUID, FSType: ""},
	} {
		t.Run(fmt.Sprintf("eMMC esp %s %q", other.PartType, other.FSType), func(t *testing.T) {
			c := bootOrderController(t)
			c.listPartsFn = func() ([]partitionInfo, error) {
				p := dualDiskParts()
				p[3].PartType, p[3].FSType = other.PartType, other.FSType
				p[7].PartType = espTypeGUID
				return p, nil
			}
			if esp, err := c.capsuleESP(); err != nil || esp.Path != "/dev/nvme0n1p11" {
				t.Fatalf("without BootOrder: capsule ESP = %+v, %v", esp, err)
			}
			writeEfivar(t, c, "BootOrder", bootNumbers(1, 8))
			if esp, err := c.capsuleESP(); err != nil || esp.Path != "/dev/nvme0n1p11" {
				t.Fatalf("eMMC first: capsule ESP = %+v, %v", esp, err)
			}
		})
	}
}

// The eMMC option names the card itself, not its boot partitions.
func TestCapsuleESPOnEMMCRootFollowsBootOrder(t *testing.T) {
	c := bootOrderController(t)
	c.rootIDFn = func() (string, error) { return "179:1", nil }
	writeEfivar(t, c, "BootOrder", bootNumbers(1, 8))
	if esp, err := c.capsuleESP(); err != nil || esp.Path != "/dev/mmcblk0p10" {
		t.Fatalf("eMMC first: capsule ESP = %+v, %v", esp, err)
	}
	c = bootOrderController(t)
	c.rootIDFn = func() (string, error) { return "179:1", nil }
	writeEfivar(t, c, "BootOrder", bootNumbers(8, 1))
	if esp, err := c.capsuleESP(); err == nil {
		t.Fatalf("capsule ESP %s accepted behind the NVMe option", esp.Path)
	}
}

// An SD option names the SD card, as on the SD-card Orin Nano devkit.
func TestCapsuleESPOnSDRootFollowsBootOrder(t *testing.T) {
	c := bootOrderController(t)
	c.rootIDFn = func() (string, error) { return "179:1", nil }
	writeSysBlock(t, c, "mmcblk0/device/type", "SD")
	writeEfivar(t, c, "Boot0001", loadOption(hwNode, []byte{0x03, 0x1a, 5, 0, 0}))
	writeEfivar(t, c, "BootOrder", bootNumbers(1, 8))
	if esp, err := c.capsuleESP(); err != nil || esp.Path != "/dev/mmcblk0p10" {
		t.Fatalf("SD first: capsule ESP = %+v, %v", esp, err)
	}
}

// withSATAESP keeps an ESP off the root disk on a transport no option is
// matched against, so only options firmware skips may come before the root.
func withSATAESP(c *Controller) {
	parts, _ := c.listPartsFn()
	parts = append(parts,
		partitionInfo{Path: "/dev/sda", Type: "disk", DeviceID: "8:0"},
		partitionInfo{Path: "/dev/sda1", Parent: "/dev/sda", Type: "part", PartType: espTypeGUID, FSType: "vfat", DeviceID: "8:1"})
	c.listPartsFn = func() ([]partitionInfo, error) { return parts, nil }
}

// Firmware moves past options that lead to no ESP: a disk without one, network
// boot, firmware applications.
func TestBootOrderSkipsOptionsWithoutAnESP(t *testing.T) {
	for _, tc := range []struct {
		name  string
		order []uint16
		ok    bool
	}{
		{"eMMC without an ESP", []uint16{1, 8}, true},
		{"network boot", []uint16{2, 8}, true},
		{"firmware application", []uint16{6, 8}, true},
		{"nothing reaches the root ESP", []uint16{1, 2, 6}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := bootOrderController(t)
			parts, _ := c.listPartsFn()
			parts[3].PartType = "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"
			c.listPartsFn = func() ([]partitionInfo, error) { return parts, nil }
			withSATAESP(c)
			writeEfivar(t, c, "BootOrder", bootNumbers(tc.order...))
			esp, err := c.capsuleESP()
			if tc.ok != (err == nil) {
				t.Fatalf("capsule ESP = %+v, %v; want ok=%t", esp, err, tc.ok)
			}
		})
	}
}

// An option that names no NVMe or MMC device may still reach an ESP on a disk
// of another transport, so it cannot be skipped.
func TestUnmatchedBootOptionBeforeAnESPOnAnotherTransport(t *testing.T) {
	c := bootOrderController(t)
	withSATAESP(c)
	writeEfivar(t, c, "Boot000A", loadOption(hwNode, usbNode))
	writeEfivar(t, c, "BootOrder", bootNumbers(0xa, 8))
	if esp, err := c.capsuleESP(); err == nil {
		t.Fatalf("capsule ESP %s accepted behind an unmatched option", esp.Path)
	}
	writeEfivar(t, c, "BootOrder", bootNumbers(8, 0xa))
	if esp, err := c.capsuleESP(); err != nil || esp.Path != "/dev/nvme0n1p11" {
		t.Fatalf("root disk first: capsule ESP = %+v, %v", esp, err)
	}
}

// Two NVMe drives both expose namespace 1; the EUI-64 in the option decides.
func TestNVMeBootOptionMatchesNamespaceEUI(t *testing.T) {
	other := []byte{0x00, 0x25, 0x38, 0x42, 0x61, 0x40, 0xe8, 0x0f}
	for _, tc := range []struct {
		name string
		eui  []byte
		ok   bool
	}{
		{"root drive", nvmeEUI, true},
		{"second drive", other, false},
		{"no EUI in the option", make([]byte, 8), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := bootOrderController(t)
			parts, _ := c.listPartsFn()
			parts = append(parts,
				partitionInfo{Path: "/dev/nvme1n1", Type: "disk", DeviceID: "259:20"},
				partitionInfo{Path: "/dev/nvme1n1p11", Parent: "/dev/nvme1n1", PartLabel: "esp", Type: "part", PartType: espTypeGUID, FSType: "vfat", DeviceID: "259:31"})
			c.listPartsFn = func() ([]partitionInfo, error) { return parts, nil }
			writeSysBlock(t, c, "nvme1n1/nsid", "1")
			writeSysBlock(t, c, "nvme1n1/eui", "00 25 38 42 61 40 e8 0f")
			writeEfivar(t, c, "Boot000A", loadOption(hwNode, nvmeNode(1, tc.eui)))
			writeEfivar(t, c, "BootOrder", bootNumbers(0xa, 8))
			esp, err := c.capsuleESP()
			if tc.ok != (err == nil) {
				t.Fatalf("capsule ESP = %+v, %v; want ok=%t", esp, err, tc.ok)
			}
		})
	}
}
