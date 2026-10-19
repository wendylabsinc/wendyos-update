package tegrauefi

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/wendylabsinc/wendyos-update/internal/blockdev"
	"github.com/wendylabsinc/wendyos-update/internal/connector"
	"golang.org/x/sys/unix"
)

// partitionInfo is one lsblk row. Partitions are matched by kernel identity
// (MAJ:MIN), never by a /dev name such as the /dev/root alias.
type partitionInfo struct {
	Path      string `json:"path"`
	Parent    string `json:"pkname"`
	PartLabel string `json:"partlabel"`
	PartUUID  string `json:"partuuid"`
	PartType  string `json:"parttype"`
	Type      string `json:"type"`
	FSType    string `json:"fstype"`
	DeviceID  string `json:"maj:min"`
}

func listPartitions() ([]partitionInfo, error) {
	out, err := exec.Command("lsblk", "--json", "--list", "--paths", "--output",
		"PATH,PKNAME,PARTLABEL,PARTUUID,PARTTYPE,TYPE,FSTYPE,MAJ:MIN").Output()
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

// rootPartitionID returns the MAJ:MIN of the partition behind the running root,
// following device-mapper layers. blockdev.ErrNotPartition means the root has
// no single backing partition (overlay, network, multi-device).
func rootPartitionID() (string, error) {
	id, err := blockdev.RootDeviceID()
	if err != nil {
		return "", err
	}
	part, _, err := blockdev.PartitionDisk(blockdev.SysfsByID("/sys", id))
	if err != nil {
		return "", err
	}
	if part.DeviceID == "" {
		return "", fmt.Errorf("partition %s reports no device number", part.Path)
	}
	return part.DeviceID, nil
}

// mountID accepts findmnt's numeric mount IDs, which older util-linux prints
// as JSON strings.
type mountID string

func (m *mountID) UnmarshalJSON(b []byte) error {
	*m = mountID(strings.Trim(string(b), `"`))
	return nil
}

type mountInfo struct {
	ID       mountID `json:"id"`
	Parent   mountID `json:"parent"`
	Source   string  `json:"source"`
	Target   string  `json:"target"`
	FSType   string  `json:"fstype"`
	Options  string  `json:"options"`
	DeviceID string  `json:"maj:min"`
}

const findmntColumns = "ID,PARENT,SOURCE,TARGET,FSTYPE,OPTIONS,MAJ:MIN"

func parseFindmnt(out []byte) ([]mountInfo, error) {
	var result struct {
		Filesystems []mountInfo `json:"filesystems"`
	}
	if err := json.Unmarshal(out, &result); err != nil {
		return nil, err
	}
	return result.Filesystems, nil
}

// mountedFilesystem returns the filesystem visible at path. --mountpoint
// requires an exact mount, rather than returning the filesystem containing an
// unmounted directory: /boot/efi on the rootfs must never be accepted as an ESP.
func mountedFilesystem(path string) (mountInfo, bool, error) {
	out, err := exec.Command("findmnt", "--json", "--output", findmntColumns, "--mountpoint", path).Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && exit.ExitCode() == 1 && len(out) == 0 && len(exit.Stderr) == 0 {
			return mountInfo{}, false, nil
		}
		return mountInfo{}, false, fmt.Errorf("findmnt %s: %w", path, err)
	}
	mounts, err := parseFindmnt(out)
	if err != nil {
		return mountInfo{}, false, fmt.Errorf("findmnt %s: %w", path, err)
	}
	top, err := topMount(mounts, path)
	if err != nil {
		return mountInfo{}, false, fmt.Errorf("findmnt %s: %w", path, err)
	}
	return top, true, nil
}

// topMount picks the one mount at path that no other mount there covers: an
// automount trap or a remount stacks on the same target, and only the top
// filesystem receives writes.
func topMount(mounts []mountInfo, path string) (mountInfo, error) {
	covered := make(map[mountID]bool)
	for _, m := range mounts {
		covered[m.Parent] = true
	}
	var tops []mountInfo
	for _, m := range mounts {
		if m.Target != path {
			return mountInfo{}, fmt.Errorf("unexpected mount %s", m.Target)
		}
		if !covered[m.ID] {
			tops = append(tops, m)
		}
	}
	if len(tops) != 1 || tops[0].DeviceID == "" {
		return mountInfo{}, fmt.Errorf("expected one top-most mount with a device identity, found %d of %d", len(tops), len(mounts))
	}
	return tops[0], nil
}

// deviceMountpoints lists every place the filesystem numbered id is mounted.
func deviceMountpoints(id string) ([]string, error) {
	out, err := exec.Command("findmnt", "--json", "--list", "--output", findmntColumns).Output()
	if err != nil {
		return nil, fmt.Errorf("findmnt: %w", err)
	}
	mounts, err := parseFindmnt(out)
	if err != nil {
		return nil, fmt.Errorf("findmnt: %w", err)
	}
	var dirs []string
	for _, m := range mounts {
		if m.DeviceID == id {
			dirs = append(dirs, m.Target)
		}
	}
	return dirs, nil
}

// bootLayout is the partition inventory and the running root's place in it.
type bootLayout struct {
	parts   []partitionInfo
	root    partitionInfo // zero when the root has no backing partition
	disk    string        // the root's whole disk; "" when unknown
	rootErr error         // why disk is unknown
}

// layout reads the inventory once per Controller: a Controller serves one CLI
// command, during which neither the partition table nor the root changes.
func (c *Controller) layout() (*bootLayout, error) {
	if c.cachedLayout != nil {
		return c.cachedLayout, nil
	}
	parts, err := c.listPartsFn()
	if err != nil {
		return nil, err
	}
	l := &bootLayout{parts: parts}
	rootID, err := c.rootIDFn()
	switch {
	case errors.Is(err, blockdev.ErrNotPartition):
		l.rootErr = err
	case err != nil:
		return nil, fmt.Errorf("identify running root: %w", err)
	default:
		if l.root, l.disk, err = rootOnDisk(parts, rootID); err != nil {
			return nil, err
		}
	}
	c.cachedLayout = l
	return l, nil
}

// rootOnDisk finds the running root partition and its physical disk. An
// identity lsblk does not list exactly once is a contradiction, not a layout.
func rootOnDisk(parts []partitionInfo, rootID string) (partitionInfo, string, error) {
	var roots []partitionInfo
	for _, part := range parts {
		if rootID != "" && part.DeviceID == rootID {
			roots = append(roots, part)
		}
	}
	if len(roots) != 1 {
		return partitionInfo{}, "", fmt.Errorf("running root device %q matches %d block devices", rootID, len(roots))
	}
	root := roots[0]
	if root.Type != "part" || root.Parent == "" {
		return partitionInfo{}, "", fmt.Errorf("unsupported running root %s: expected a partition on a physical disk", root.Path)
	}
	disk := devPath(root.Parent)
	disks := 0
	for _, part := range parts {
		if part.Path == disk && part.Type == "disk" {
			disks++
		}
	}
	if disks != 1 {
		return partitionInfo{}, "", fmt.Errorf("running root %s has no unique physical parent disk %q", root.Path, disk)
	}
	return root, disk, nil
}

// devPath normalizes a bare kernel name for util-linux versions whose --paths
// does not expand PKNAME.
func devPath(name string) string {
	if name != "" && !filepath.IsAbs(name) {
		return "/dev/" + name
	}
	return name
}

// onBootDisk has no global-label fallback. On AGX Orin, eMMC and NVMe can both
// have APP and esp, and udev's global links can select either.
func (l *bootLayout) onBootDisk(labels []string) (partitionInfo, error) {
	var matches []partitionInfo
	for _, part := range l.parts {
		if devPath(part.Parent) == l.disk && part.Type == "part" && slices.Contains(labels, part.PartLabel) {
			matches = append(matches, part)
		}
	}
	if len(matches) != 1 {
		return partitionInfo{}, fmt.Errorf("expected one partition labelled %v on boot disk %s, found %d", labels, l.disk, len(matches))
	}
	return usable(matches[0])
}

// anyDisk serves a root with no backing partition. Without a disk to scope to,
// only a label that no other disk shares is safe to use.
func (l *bootLayout) anyDisk(labels []string) (partitionInfo, error) {
	var matches []partitionInfo
	for _, part := range l.parts {
		if part.Type == "part" && slices.Contains(labels, part.PartLabel) {
			matches = append(matches, part)
		}
	}
	if len(matches) != 1 {
		return partitionInfo{}, fmt.Errorf("running root has no boot disk (%v) and %d partitions are labelled %v; refusing to guess", l.rootErr, len(matches), labels)
	}
	return usable(matches[0])
}

func (l *bootLayout) find(labels []string) (partitionInfo, error) {
	if l.disk == "" {
		return l.anyDisk(labels)
	}
	return l.onBootDisk(labels)
}

func usable(part partitionInfo) (partitionInfo, error) {
	if !strings.HasPrefix(part.Path, "/dev/") || part.DeviceID == "" {
		return partitionInfo{}, fmt.Errorf("partition %q has no usable device identity", part.Path)
	}
	return part, nil
}

// slotPartition resolves a rootfs slot. When the root is labelled, its label
// must agree with the firmware slot, or the A/B mapping is unsafe to use.
func (c *Controller) slotPartition(s connector.Slot) (partitionInfo, error) {
	l, err := c.layout()
	if err != nil {
		return partitionInfo{}, err
	}
	if l.disk == "" {
		return l.anyDisk([]string{partlabelFor(s)})
	}
	if l.unlabelled() {
		return c.slotByNumber(l, s)
	}
	if l.root.PartLabel != "APP" && l.root.PartLabel != "APP_b" {
		return partitionInfo{}, fmt.Errorf("unsupported running root %s: expected an APP or APP_b partition", l.root.Path)
	}
	current, err := c.CurrentSlot()
	if err != nil {
		return partitionInfo{}, fmt.Errorf("identify running slot: %w", err)
	}
	if l.root.PartLabel != partlabelFor(current) {
		return partitionInfo{}, fmt.Errorf("running root %s is labelled %s but firmware reports slot %s, so the spare slot is unknown and neither slot is touched; this follows a firmware fallback or a slot written by hand: check nvbootctrl dump-slots-info, then switch the firmware to the running slot or reflash", l.root.Path, l.root.PartLabel, current)
	}
	return l.onBootDisk([]string{partlabelFor(s)})
}

// unlabelled reports a boot disk whose partition names lsblk cannot read.
func (l *bootLayout) unlabelled() bool {
	for _, part := range l.parts {
		if devPath(part.Parent) == l.disk && part.PartLabel != "" {
			return false
		}
	}
	return true
}

// slotByNumber tells the slots apart without labels: A and B are adjacent
// partitions on the boot disk, so the other slot is one number away.
func (c *Controller) slotByNumber(l *bootLayout, s connector.Slot) (partitionInfo, error) {
	current, err := c.CurrentSlot()
	if err != nil {
		return partitionInfo{}, fmt.Errorf("identify running slot: %w", err)
	}
	if s == current {
		return usable(l.root)
	}
	base, num, err := splitPartDev(l.root.Path)
	if err != nil {
		return partitionInfo{}, err
	}
	want := fmt.Sprintf("%sp%d", base, num+int(s)-int(current))
	for _, part := range l.parts {
		if part.Path == want && part.Type == "part" && devPath(part.Parent) == l.disk {
			return usable(part)
		}
	}
	return partitionInfo{}, fmt.Errorf("boot disk %s has no partition labels and no partition %s", l.disk, want)
}

// splitPartDev splits /dev/nvme0n1p2 -> (/dev/nvme0n1, 2) and
// /dev/mmcblk0p1 -> (/dev/mmcblk0, 1).
func splitPartDev(dev string) (string, int, error) {
	i := strings.LastIndex(dev, "p")
	if i < 0 || i == len(dev)-1 {
		return "", 0, fmt.Errorf("unrecognized partition device %q", dev)
	}
	num, err := strconv.Atoi(dev[i+1:])
	if err != nil {
		return "", 0, fmt.Errorf("unrecognized partition device %q", dev)
	}
	return dev[:i], num, nil
}

// espPartition resolves the ESP from the root's disk alone; unlike a slot it
// does not depend on the firmware slot, so a slot query failing cannot hide it.
func (c *Controller) espPartition() (partitionInfo, error) {
	l, err := c.layout()
	if err != nil {
		return partitionInfo{}, fmt.Errorf("resolve ESP: %w", err)
	}
	part, err := l.find(espPartlabels)
	if err != nil {
		return partitionInfo{}, fmt.Errorf("resolve ESP: %w", err)
	}
	if part.FSType != "vfat" {
		return partitionInfo{}, fmt.Errorf("ESP %s has filesystem %q, expected vfat", part.Path, part.FSType)
	}
	return part, nil
}

// capsuleESP is the ESP a capsule is staged on: the boot disk's, unless the
// firmware's boot order leads it to an ESP on another disk first.
func (c *Controller) capsuleESP() (partitionInfo, error) {
	esp, err := c.espPartition()
	if err != nil {
		return partitionInfo{}, err
	}
	if err := c.checkFirmwareCapsuleDisk(esp); err != nil {
		return partitionInfo{}, err
	}
	return esp, nil
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

// espMeasureMount returns a directory showing esp for a free-space reading,
// without ever writing to it: any existing mount, else a read-only one.
func (c *Controller) espMeasureMount(esp partitionInfo) (string, func(), error) {
	if dirs, err := c.deviceMountsFn(esp.DeviceID); err == nil {
		for _, dir := range dirs {
			if showsDevice(c.RootDir+dir, esp.DeviceID) {
				return c.RootDir + dir, func() {}, nil
			}
		}
	}
	dir, unmount, err := c.mountESPReadOnlyFn(esp.Path)
	if err != nil {
		return "", nil, fmt.Errorf("ESP %s is not mounted and could not be mounted read-only to measure it: %w", esp.Path, err)
	}
	return dir, unmount, nil
}

// showsDevice reports whether dir is on the filesystem numbered id, which also
// rules out a mount that another mount now covers.
func showsDevice(dir, id string) bool {
	var st unix.Stat_t
	if err := unix.Stat(dir, &st); err != nil {
		return false
	}
	dev := uint64(st.Dev)
	return fmt.Sprintf("%d:%d", unix.Major(dev), unix.Minor(dev)) == id
}

// mountVfatReadOnly mounts dev read-only on a temporary directory.
func mountVfatReadOnly(dev string) (string, func(), error) {
	dir, err := os.MkdirTemp("/run", "wendyos-update-esp-*")
	if err != nil {
		return "", nil, err
	}
	flags := uintptr(unix.MS_RDONLY | unix.MS_NOSUID | unix.MS_NODEV | unix.MS_NOEXEC)
	if err := unix.Mount(dev, dir, "vfat", flags, ""); err != nil {
		os.Remove(dir)
		return "", nil, err
	}
	return dir, func() {
		_ = unix.Unmount(dir, 0)
		_ = os.Remove(dir)
	}, nil
}
