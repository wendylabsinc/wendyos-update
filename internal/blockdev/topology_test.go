package blockdev

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeSysfs builds the parts of /sys that PartitionDisk reads.
type fakeSysfs struct {
	t    *testing.T
	root string
}

func newFakeSysfs(t *testing.T) *fakeSysfs {
	return &fakeSysfs{t: t, root: filepath.Join(t.TempDir(), "sys")}
}

// device creates a device directory under /sys/devices with its attributes and
// the dev/block and class/block links the kernel provides.
func (f *fakeSysfs) device(rel, id, devname string, partition bool) string {
	f.t.Helper()
	dir := filepath.Join(f.root, "devices", rel)
	files := map[string]string{"dev": id + "\n"}
	if devname != "" {
		files["uevent"] = "MAJOR=0\nDEVNAME=" + devname + "\nDEVTYPE=x\n"
	}
	if partition {
		files["partition"] = "1\n"
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		f.t.Fatal(err)
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			f.t.Fatal(err)
		}
	}
	f.link(SysfsByID(f.root, id), dir)
	f.link(SysfsByName(f.root, filepath.Base(dir)), dir)
	return dir
}

func (f *fakeSysfs) link(path, target string) {
	f.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.Symlink(target, path); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fakeSysfs) slave(holder, slave string) {
	f.t.Helper()
	f.link(filepath.Join(holder, "slaves", filepath.Base(slave)), slave)
}

func TestPartitionDiskFromKernelTopology(t *testing.T) {
	f := newFakeSysfs(t)
	f.device("pci0/nvme/nvme0n1", "259:0", "nvme0n1", false)
	p1 := f.device("pci0/nvme/nvme0n1/nvme0n1p1", "259:1", "nvme0n1p1", true)
	f.device("pci1/cciss!c0d0", "104:0", "cciss/c0d0", false)
	f.device("pci1/cciss!c0d0/cciss!c0d0p1", "104:1", "", true)
	dm := f.device("virtual/block/dm-0", "253:0", "dm-0", false)
	f.slave(dm, p1)
	crypt := f.device("virtual/block/dm-1", "253:1", "dm-1", false)
	f.slave(crypt, dm)

	for _, tc := range []struct {
		name, entry, part, disk, diskID string
	}{
		{"partition by number", SysfsByID(f.root, "259:1"), "/dev/nvme0n1p1", "/dev/nvme0n1", "259:0"},
		{"partition by name", SysfsByName(f.root, "nvme0n1p1"), "/dev/nvme0n1p1", "/dev/nvme0n1", "259:0"},
		{"device-mapper over a partition", SysfsByID(f.root, "253:0"), "/dev/nvme0n1p1", "/dev/nvme0n1", "259:0"},
		{"stacked device-mapper", SysfsByID(f.root, "253:1"), "/dev/nvme0n1p1", "/dev/nvme0n1", "259:0"},
		{"DEVNAME differs from kernel name", SysfsByID(f.root, "104:1"), "/dev/cciss/c0d0p1", "/dev/cciss/c0d0", "104:0"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			part, disk, err := PartitionDisk(tc.entry)
			if err != nil || part.Path != tc.part || disk.Path != tc.disk || disk.DeviceID != tc.diskID {
				t.Fatalf("got part=%+v disk=%+v err=%v", part, disk, err)
			}
		})
	}
}

func TestPartitionDiskRejectsUnknownTopology(t *testing.T) {
	f := newFakeSysfs(t)
	f.device("pci0/sda", "8:0", "sda", false)
	sda1 := f.device("pci0/sda/sda1", "8:1", "sda1", true)
	sda2 := f.device("pci0/sda/sda2", "8:2", "sda2", true)
	raid := f.device("virtual/block/dm-0", "253:0", "dm-0", false)
	f.slave(raid, sda1)
	f.slave(raid, sda2)
	orphan := filepath.Join(f.root, "block", "orphan1")
	if err := os.MkdirAll(orphan, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(orphan, "partition"), []byte("1\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct{ name, entry string }{
		{"overlay or other anonymous device", SysfsByID(f.root, "0:35")},
		{"whole-disk filesystem", SysfsByID(f.root, "8:0")},
		{"device-mapper over several devices", SysfsByID(f.root, "253:0")},
		{"partition without a parent disk", orphan},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if part, disk, err := PartitionDisk(tc.entry); !errors.Is(err, ErrNotPartition) {
				t.Fatalf("got part=%+v disk=%+v err=%v, want ErrNotPartition", part, disk, err)
			}
		})
	}
}

func TestRootDeviceIDIsMajorMinor(t *testing.T) {
	id, err := RootDeviceID()
	if err != nil {
		t.Fatal(err)
	}
	if major, minor, ok := strings.Cut(id, ":"); !ok || major == "" || minor == "" {
		t.Fatalf("root device id %q is not MAJ:MIN", id)
	}
}
