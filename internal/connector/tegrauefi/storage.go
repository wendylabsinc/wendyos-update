package tegrauefi

import (
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

// Use the kernel device identity for mounted filesystems. findmnt may name the
// root /dev/root even when that alias no longer exists in /dev.
type partitionInfo struct {
	Path      string `json:"path"`
	Parent    string `json:"pkname"`
	PartLabel string `json:"partlabel"`
	Type      string `json:"type"`
	FSType    string `json:"fstype"`
	DeviceID  string `json:"maj:min"`
}

func listPartitions() ([]partitionInfo, error) {
	out, err := exec.Command("lsblk", "--json", "--list", "--paths", "--output",
		"PATH,PKNAME,PARTLABEL,TYPE,FSTYPE,MAJ:MIN").Output()
	if err != nil {
		return nil, fmt.Errorf("lsblk: %w", err)
	}
	var result struct {
		Partitions []partitionInfo `json:"blockdevices"`
	}
	if err := json.Unmarshal(out, &result); err != nil {
		return nil, fmt.Errorf("lsblk: %w", err)
	}
	return result.Partitions, nil
}

type mountInfo struct {
	Source   string `json:"source"`
	Target   string `json:"target"`
	FSType   string `json:"fstype"`
	Options  string `json:"options"`
	DeviceID string `json:"maj:min"`
}

// --mountpoint requires an exact mount, rather than returning the filesystem
// containing an unmounted directory. In particular, /boot/efi on the rootfs
// must never be accepted as an ESP.
func mountedFilesystem(path string) (mountInfo, bool, error) {
	out, err := exec.Command("findmnt", "--json", "--output",
		"SOURCE,TARGET,FSTYPE,OPTIONS,MAJ:MIN", "--mountpoint", path).Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && exit.ExitCode() == 1 && len(out) == 0 && len(exit.Stderr) == 0 {
			return mountInfo{}, false, nil
		}
		return mountInfo{}, false, fmt.Errorf("findmnt %s: %w", path, err)
	}
	var result struct {
		Filesystems []mountInfo `json:"filesystems"`
	}
	if err := json.Unmarshal(out, &result); err != nil {
		return mountInfo{}, false, fmt.Errorf("findmnt %s: %w", path, err)
	}
	if len(result.Filesystems) != 1 || result.Filesystems[0].Target != path || result.Filesystems[0].DeviceID == "" {
		return mountInfo{}, false, fmt.Errorf("findmnt %s: expected one exact mount with a device identity", path)
	}
	return result.Filesystems[0], true, nil
}

func currentRootID() (string, error) {
	root, found, err := mountedFilesystem("/")
	if err != nil {
		return "", err
	}
	if !found {
		return "", fmt.Errorf("running root mount not found")
	}
	return root.DeviceID, nil
}

// partitionOnBootDisk has no global-label fallback. On AGX Orin, eMMC and
// NVMe can both have APP and esp, and udev's global links can select either.
// An unknown root or an ambiguous label must stop the update before any write.
func (c *Controller) partitionOnBootDisk(labels []string) (partitionInfo, error) {
	rootID, err := c.rootIDFn()
	if err != nil {
		return partitionInfo{}, fmt.Errorf("identify running root: %w", err)
	}
	parts, err := c.listPartsFn()
	if err != nil {
		return partitionInfo{}, err
	}
	var roots []partitionInfo
	for _, part := range parts {
		if rootID != "" && part.DeviceID == rootID {
			roots = append(roots, part)
		}
	}
	if len(roots) != 1 {
		return partitionInfo{}, fmt.Errorf("running root device %q matches %d block devices", rootID, len(roots))
	}
	root := roots[0]
	if root.Type != "part" || root.Parent == "" || (root.PartLabel != "APP" && root.PartLabel != "APP_b") {
		return partitionInfo{}, fmt.Errorf("unsupported running root %s: expected an APP or APP_b partition on a physical disk", root.Path)
	}
	current, err := c.CurrentSlot()
	if err != nil {
		return partitionInfo{}, fmt.Errorf("identify running slot: %w", err)
	}
	if root.PartLabel != partlabelFor(current) {
		return partitionInfo{}, fmt.Errorf("running root %s is labelled %s but firmware reports slot %s; refusing an unsafe slot mapping", root.Path, root.PartLabel, current)
	}
	// --paths normally expands PKNAME too; normalize the bare kernel name for
	// util-linux versions that return it without /dev/.
	disk := root.Parent
	if !filepath.IsAbs(disk) {
		disk = "/dev/" + disk
	}
	disks := 0
	for _, part := range parts {
		if part.Path == disk && part.Type == "disk" {
			disks++
		}
	}
	if disks != 1 {
		return partitionInfo{}, fmt.Errorf("running root %s has no unique physical parent disk %q", root.Path, disk)
	}
	var matches []partitionInfo
	for _, part := range parts {
		parent := part.Parent
		if parent != "" && !filepath.IsAbs(parent) {
			parent = "/dev/" + parent
		}
		if parent == disk && part.Type == "part" && slices.Contains(labels, part.PartLabel) {
			matches = append(matches, part)
		}
	}
	if len(matches) != 1 {
		return partitionInfo{}, fmt.Errorf("expected one partition labelled %v on boot disk %s, found %d", labels, disk, len(matches))
	}
	part := matches[0]
	if !strings.HasPrefix(part.Path, "/dev/") || part.DeviceID == "" {
		return partitionInfo{}, fmt.Errorf("partition %q on %s has no usable device identity", part.Path, disk)
	}
	return part, nil
}

func (c *Controller) espPartition() (partitionInfo, error) {
	part, err := c.partitionOnBootDisk(espPartlabels)
	if err != nil {
		return partitionInfo{}, fmt.Errorf("resolve ESP: %w", err)
	}
	if part.FSType != "vfat" {
		return partitionInfo{}, fmt.Errorf("ESP %s has filesystem %q, expected vfat", part.Path, part.FSType)
	}
	return part, nil
}

func (c *Controller) privateESPMountpoint() string {
	return c.RootDir + "/run/wendyos-update/esp"
}

// existingESPMount never mounts or remounts anything. A mount on the wrong
// /boot/efi is left alone; a conflicting mount on our private path is an error.
func (c *Controller) existingESPMount(esp partitionInfo) (string, error) {
	for _, path := range []string{c.RootDir + "/boot/efi", c.privateESPMountpoint()} {
		mount, found, err := c.mountInfoFn(path)
		if err != nil {
			return "", err
		}
		if !found {
			continue
		}
		if mount.DeviceID != esp.DeviceID {
			if path == c.privateESPMountpoint() {
				return "", fmt.Errorf("private ESP mount %s is occupied by %s, expected %s", path, mount.Source, esp.Path)
			}
			continue
		}
		if mount.FSType != "vfat" || !slices.Contains(strings.Split(mount.Options, ","), "rw") {
			return "", fmt.Errorf("ESP %s at %s must be mounted read-write as vfat", esp.Path, path)
		}
		return path, nil
	}
	return "", nil
}
