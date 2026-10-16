package blockdev

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// ErrNotPartition reports a device that no single disk partition backs: an
// overlay or network root, a whole-disk filesystem, or a device-mapper target
// spanning several devices.
var ErrNotPartition = errors.New("not backed by a single disk partition")

// Node is a block device as the kernel reports it in sysfs.
type Node struct {
	Path     string // /dev node, from the kernel's DEVNAME
	DeviceID string // MAJ:MIN; empty when sysfs does not report it
}

// maxStackDepth bounds the device-mapper walk in PartitionDisk.
const maxStackDepth = 8

// RootDeviceID returns the MAJ:MIN of the filesystem mounted at /. Unlike the
// mount source, it cannot name a /dev/root alias or depend on mount stacking.
func RootDeviceID() (string, error) {
	var st unix.Stat_t
	if err := unix.Stat("/", &st); err != nil {
		return "", fmt.Errorf("stat /: %w", err)
	}
	dev := uint64(st.Dev)
	return fmt.Sprintf("%d:%d", unix.Major(dev), unix.Minor(dev)), nil
}

// SysfsByID returns the sysfs entry of the device numbered id (MAJ:MIN).
func SysfsByID(sysfs, id string) string {
	return filepath.Join(sysfs, "dev", "block", id)
}

// SysfsByName returns the sysfs entry of the device with kernel name name.
func SysfsByName(sysfs, name string) string {
	return filepath.Join(sysfs, "class", "block", name)
}

// PartitionDisk returns the partition behind a sysfs block entry and the
// whole disk that holds it, from the kernel's own topology rather than device
// names or labels. Device-mapper layers are followed while each has exactly
// one slave.
func PartitionDisk(entry string) (part, disk Node, err error) {
	for range maxStackDepth {
		dir, err := filepath.EvalSymlinks(entry)
		if err != nil {
			return Node{}, Node{}, fmt.Errorf("%s: %w", entry, ErrNotPartition)
		}
		if _, err := os.Stat(filepath.Join(dir, "partition")); err == nil {
			parent := filepath.Dir(dir)
			if base := filepath.Base(parent); base == "." || base == "/" || base == "block" {
				return Node{}, Node{}, fmt.Errorf("partition %s has no parent disk: %w", dir, ErrNotPartition)
			}
			return sysfsNode(dir), sysfsNode(parent), nil
		}
		slaves, err := os.ReadDir(filepath.Join(dir, "slaves"))
		if err != nil || len(slaves) != 1 {
			return Node{}, Node{}, fmt.Errorf("%s: %w", dir, ErrNotPartition)
		}
		entry = filepath.Join(dir, "slaves", slaves[0].Name())
	}
	return Node{}, Node{}, fmt.Errorf("%s: device stack deeper than %d: %w", entry, maxStackDepth, ErrNotPartition)
}

// sysfsNode reads a device's /dev name and number. A kernel name such as
// cciss!c0d0 lives at /dev/cciss/c0d0, which DEVNAME states directly.
func sysfsNode(dir string) Node {
	n := Node{Path: "/dev/" + strings.ReplaceAll(filepath.Base(dir), "!", "/")}
	if raw, err := os.ReadFile(filepath.Join(dir, "uevent")); err == nil {
		for _, line := range strings.Split(string(raw), "\n") {
			if name, ok := strings.CutPrefix(line, "DEVNAME="); ok && name != "" {
				n.Path = "/dev/" + name
			}
		}
	}
	if raw, err := os.ReadFile(filepath.Join(dir, "dev")); err == nil {
		n.DeviceID = strings.TrimSpace(string(raw))
	}
	return n
}
