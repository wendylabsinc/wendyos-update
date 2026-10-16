package tegrauefi

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	nvmeESPUUID = "0b9f3c1e-6a2d-4e57-9a3b-1c2d3e4f5a6b"
	emmcESPUUID = "7c1e2d3f-4a5b-4c6d-8e7f-a0b1c2d3e4f5"
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

// loadOption builds an EFI_LOAD_OPTION with the efivarfs attribute prefix.
func loadOption(nodes ...[]byte) []byte {
	var path []byte
	for _, n := range nodes {
		path = append(path, n...)
	}
	path = append(path, 0x7f, 0xff, 4, 0)
	opt := []byte{7, 0, 0, 0, 1, 0, 0, 0, 0, 0}
	binary.LittleEndian.PutUint16(opt[8:], uint16(len(path)))
	for _, r := range "UEFI NVMe" {
		opt = append(opt, byte(r), 0)
	}
	opt = append(opt, 0, 0)
	return append(opt, path...)
}

func writeBootCurrent(t *testing.T, c *Controller, option []byte) {
	t.Helper()
	files := map[string][]byte{
		"BootCurrent-" + EfiGlobalGUID: {7, 0, 0, 0, 0x0a, 0},
		"Boot000A-" + EfiGlobalGUID:    option,
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(c.EfivarsDir, name), body, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func bootDiskController(t *testing.T) *Controller {
	c := storageController(t)
	c.listPartsFn = func() ([]partitionInfo, error) {
		p := dualDiskParts()
		p[3].PartUUID = emmcESPUUID
		p[7].PartUUID = strings.ToUpper(nvmeESPUUID)
		return p, nil
	}
	return c
}

func TestLoadOptionPartUUID(t *testing.T) {
	vendor := []byte{0x01, 0x04, 8, 0, 1, 2, 3, 4}
	for _, tc := range []struct {
		name string
		opt  []byte
		want string
	}{
		{"hard drive after hardware nodes", loadOption(vendor, hardDriveNode(t, nvmeESPUUID))[4:], nvmeESPUUID},
		{"no hard drive node", loadOption(vendor)[4:], ""},
		{"truncated path", loadOption(hardDriveNode(t, nvmeESPUUID))[4:40], ""},
		{"zero-length node", append(loadOption()[4:len(loadOption())-4], 0x04, 0x01, 0, 0), ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := loadOptionPartUUID(tc.opt); got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}

// Capsule-on-disk is read from the ESP firmware booted from, so a capsule
// must not be staged on another disk's ESP; cleanup is not restricted.
func TestCapsuleESPMustBeOnFirmwareBootDisk(t *testing.T) {
	c := bootDiskController(t)
	writeBootCurrent(t, c, loadOption(hardDriveNode(t, emmcESPUUID)))
	if esp, err := c.capsuleESP(); err == nil {
		t.Fatalf("capsule ESP on the root disk accepted while firmware booted eMMC: %+v", esp)
	}
	if esp, err := c.espPartition(); err != nil || esp.Path != "/dev/nvme0n1p11" {
		t.Fatalf("cleanup ESP = %+v, %v", esp, err)
	}

	for _, tc := range []struct {
		name   string
		option []byte
	}{
		{"firmware booted the root disk", loadOption(hardDriveNode(t, nvmeESPUUID))},
		{"boot option without a partition", loadOption([]byte{0x01, 0x04, 8, 0, 1, 2, 3, 4})},
		{"unlisted partition", loadOption(hardDriveNode(t, "11111111-2222-3333-4444-555555555555"))},
		{"malformed option", []byte{7, 0, 0, 0, 1}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := bootDiskController(t)
			writeBootCurrent(t, c, tc.option)
			if esp, err := c.capsuleESP(); err != nil || esp.Path != "/dev/nvme0n1p11" {
				t.Fatalf("capsule ESP = %+v, %v", esp, err)
			}
		})
	}
}
