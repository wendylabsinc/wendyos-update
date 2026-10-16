package grubenv

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/connector"
)

func TestStatusSnapshotIsFreshAndDoesNotCacheOperations(t *testing.T) {
	c := testController(t, newFakeEnv(nil), connector.SlotA, true)
	root := c.RootDir + "/dev/rootfsA"
	rootCalls, scans := 0, 0
	c.rootDeviceFn = func() (string, error) { rootCalls++; return root, nil }
	parts := []partInfo{
		{path: "/dev/otherA", partlabel: partlabelA, pkname: "other"},
		{path: "/dev/otherB", partlabel: partlabelB, pkname: "other"},
		{path: c.RootDir + "/dev/rootfsA", partlabel: partlabelA, pkname: "boot"},
		{path: c.RootDir + "/dev/rootfsB", partlabel: partlabelB, pkname: "boot"},
	}
	c.listPartsFn = func(gotRoot string) ([]partInfo, error) {
		scans++
		if gotRoot != root {
			t.Fatalf("scan root = %q, want %q", gotRoot, root)
		}
		return parts, nil
	}

	first := c.StatusSnapshot()
	if got, err := first.CurrentSlot(); err != nil || got != connector.SlotA {
		t.Fatalf("CurrentSlot = %v, %v", got, err)
	}
	for _, slot := range []connector.Slot{connector.SlotA, connector.SlotB} {
		want := c.RootDir + "/dev/rootfs" + slot.String()
		if got, err := first.PartitionFor(slot); err != nil || got != want {
			t.Fatalf("PartitionFor(%v) = %q, %v; want boot disk %q", slot, got, err, want)
		}
	}
	if got := first.Diagnostics(true)["rootfsB_dev"]; got != c.RootDir+"/dev/rootfsB" {
		t.Fatalf("verbose B = %q", got)
	}
	if rootCalls != 1 || scans != 1 {
		t.Fatalf("one snapshot used %d root reads and %d scans", rootCalls, scans)
	}

	// The next status sees new running-root state; the old snapshot stays fixed.
	root = c.RootDir + "/dev/rootfsB"
	second := c.StatusSnapshot()
	if got, err := second.CurrentSlot(); err != nil || got != connector.SlotB {
		t.Fatalf("fresh CurrentSlot = %v, %v", got, err)
	}
	if got, err := first.CurrentSlot(); err != nil || got != connector.SlotA {
		t.Fatalf("old CurrentSlot = %v, %v", got, err)
	}
	if rootCalls != 2 || scans != 2 {
		t.Fatalf("second snapshot used %d root reads and %d scans total", rootCalls, scans)
	}

	// Operations on the original controller must still re-read the disk. A
	// changed partition mapping cannot remain hidden by a preceding status.
	parts = []partInfo{
		{path: root, partlabel: partlabelB, pkname: "boot"},
		{path: "/dev/newA", partlabel: partlabelA, pkname: "boot"},
	}
	if got, err := c.PartitionFor(connector.SlotA); err != nil || got != "/dev/newA" {
		t.Fatalf("live PartitionFor(A) = %q, %v", got, err)
	}
	if rootCalls != 3 || scans != 3 {
		t.Fatalf("live lookup did not refresh: %d root reads, %d scans", rootCalls, scans)
	}
}

func TestStatusSnapshotRetainsResolutionFailuresAndFallback(t *testing.T) {
	t.Run("root error", func(t *testing.T) {
		c := testController(t, newFakeEnv(nil), connector.SlotA, true)
		want := errors.New("findmnt unavailable")
		c.rootDeviceFn = func() (string, error) { return "", want }
		c.listPartsFn = func(string) ([]partInfo, error) {
			t.Fatal("partition scan after root lookup failed")
			return nil, nil
		}
		if _, err := c.StatusSnapshot().CurrentSlot(); !errors.Is(err, want) {
			t.Fatalf("CurrentSlot error = %v, want %v", err, want)
		}
	})
	for _, listingErr := range []error{nil, errors.New("lsblk failed")} {
		name := "root not listed"
		if listingErr != nil {
			name = "listing error"
		}
		t.Run(name, func(t *testing.T) {
			c := testController(t, newFakeEnv(nil), connector.SlotB, true)
			scans := 0
			c.listPartsFn = func(string) ([]partInfo, error) { scans++; return nil, listingErr }
			view := c.StatusSnapshot()
			if got, err := view.CurrentSlot(); err != nil || got != connector.SlotB {
				t.Fatalf("fallback CurrentSlot = %v, %v", got, err)
			}
			if got := view.Diagnostics(true)["rootfsA_dev"]; got != c.RootDir+"/dev/rootfsA" {
				t.Fatalf("fallback partition = %q", got)
			}
			if scans != 1 {
				t.Fatalf("fallback performed %d scans, want 1", scans)
			}
		})
	}
}

func TestRootDiskDeviceFromKernelTopology(t *testing.T) {
	for _, tc := range []struct{ partition, disk string }{
		{"sda3", "sda"}, {"nvme0n1p2", "nvme0n1"}, {"mmcblk0p3", "mmcblk0"},
	} {
		t.Run(tc.partition, func(t *testing.T) {
			dir := t.TempDir()
			sysfs := filepath.Join(dir, "sys")
			class := filepath.Join(sysfs, "class/block")
			real := filepath.Join(sysfs, "devices/platform/block", tc.disk, tc.partition)
			for _, path := range []string{class, real} {
				if err := os.MkdirAll(path, 0o755); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(filepath.Join(real, "partition"), []byte("3\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(real, filepath.Join(class, tc.partition)); err != nil {
				t.Fatal(err)
			}
			want := "/dev/" + tc.disk
			if got := rootDiskDevice("/dev/"+tc.partition, sysfs); got != want {
				t.Fatalf("disk = %q, want %q", got, want)
			}
			// findmnt can report /dev/root or another symlink to the partition.
			device := filepath.Join(dir, tc.partition)
			if err := os.WriteFile(device, nil, 0o644); err != nil {
				t.Fatal(err)
			}
			alias := filepath.Join(dir, "root")
			if err := os.Symlink(device, alias); err != nil {
				t.Fatal(err)
			}
			if got := rootDiskDevice(alias, sysfs); got != want {
				t.Fatalf("alias disk = %q, want %q", got, want)
			}
		})
	}
}

func TestRootDiskDeviceRetainsFullScanForUnknownTopology(t *testing.T) {
	sysfs := t.TempDir()
	class := filepath.Join(sysfs, "class/block")
	for _, root := range []string{"", "/dev/missing", "/dev/dm-0", "/dev/sda"} {
		// Stacked and whole-disk roots have no partition attribute in sysfs.
		if root != "" {
			if err := os.MkdirAll(filepath.Join(class, filepath.Base(root)), 0o755); err != nil {
				t.Fatal(err)
			}
		}
		if got := rootDiskDevice(root, sysfs); got != "" {
			t.Fatalf("root %q scoped to %q, want a full scan", root, got)
		}
	}
}

// A scoped scan that fails, e.g. on a disk whose /dev node differs from its
// kernel name, must fall back to the full scan rather than to global labels.
func TestScopedScanFailureFallsBackToFullScan(t *testing.T) {
	bin := t.TempDir()
	script := `#!/bin/sh
case "$*" in
*" -- /dev/broken") exit 32 ;;
*" -- /dev/nvme0n1") echo 'PATH="/dev/nvme0n1p3" PARTLABEL="rootfsA" LABEL="" PKNAME="nvme0n1"' ;;
*) echo 'PATH="/dev/sda3" PARTLABEL="rootfsA" LABEL="" PKNAME="sda"'
   echo 'PATH="/dev/nvme0n1p3" PARTLABEL="rootfsA" LABEL="" PKNAME="nvme0n1"' ;;
esac
`
	if err := os.WriteFile(filepath.Join(bin, "lsblk"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	for _, tc := range []struct {
		disk string
		want int
	}{{"/dev/nvme0n1", 1}, {"/dev/broken", 2}, {"", 2}} {
		parts, err := lsblkPartsOn(tc.disk)
		if err != nil || len(parts) != tc.want {
			t.Fatalf("disk %q: %d parts, %v; want %d", tc.disk, len(parts), err, tc.want)
		}
	}
}
