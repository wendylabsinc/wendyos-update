package tegrauefi

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wendylabsinc/wendyos-update/internal/blockdev"
	"github.com/wendylabsinc/wendyos-update/internal/connector"
	"golang.org/x/sys/unix"
)

func dualDiskParts() []partitionInfo {
	return []partitionInfo{
		{Path: "/dev/mmcblk0", Type: "disk", DeviceID: "179:0"},
		{Path: "/dev/mmcblk0p1", Parent: "/dev/mmcblk0", PartLabel: "APP", Type: "part", FSType: "ext4", DeviceID: "179:1"},
		{Path: "/dev/mmcblk0p2", Parent: "/dev/mmcblk0", PartLabel: "APP_b", Type: "part", FSType: "ext4", DeviceID: "179:2"},
		{Path: "/dev/mmcblk0p10", Parent: "/dev/mmcblk0", PartLabel: "esp", Type: "part", FSType: "vfat", DeviceID: "179:10"},
		{Path: "/dev/nvme0n1", Type: "disk", DeviceID: "259:0"},
		{Path: "/dev/nvme0n1p1", Parent: "/dev/nvme0n1", PartLabel: "APP", Type: "part", FSType: "ext4", DeviceID: "259:1"},
		{Path: "/dev/nvme0n1p2", Parent: "/dev/nvme0n1", PartLabel: "APP_b", Type: "part", FSType: "ext4", DeviceID: "259:2"},
		{Path: "/dev/nvme0n1p11", Parent: "/dev/nvme0n1", PartLabel: "esp", Type: "part", FSType: "vfat", DeviceID: "259:11"},
	}
}

func storageController(t *testing.T) *Controller {
	t.Helper()
	c := testController(t)
	c.Nvbootctrl = fakeNvbootctrl(t, "0\n")
	writeCompatible(t, c, "nvidia,tegra234")
	c.rootIDFn = func() (string, error) { return "259:1", nil }
	c.listPartsFn = func() ([]partitionInfo, error) { return dualDiskParts(), nil }
	c.mountInfoFn = func(string) (mountInfo, bool, error) { return mountInfo{}, false, nil }
	c.mountESPFn = func(string) (string, func(), error) {
		t.Fatal("unexpected mount")
		return "", nil, nil
	}
	c.deviceMountsFn = func(string) ([]string, error) { return nil, nil }
	c.mountESPReadOnlyFn = func(string) (string, func(), error) {
		t.Fatal("unexpected read-only mount")
		return "", nil, nil
	}
	return c
}

// stagingMount resolves and mounts the ESP the way capsule staging does.
func stagingMount(c *Controller) (string, error) {
	esp, err := c.capsuleESP()
	if err != nil {
		return "", err
	}
	return c.espMountpoint(esp)
}

func TestPartitionForUsesRunningDisk(t *testing.T) {
	for _, tc := range []struct{ name, rootID, disk, slot string }{
		{"NVMe A with eMMC labels first", "259:1", "/dev/nvme0n1", "0\n"},
		{"eMMC A with NVMe attached", "179:1", "/dev/mmcblk0", "0\n"},
		{"NVMe B", "259:2", "/dev/nvme0n1", "1\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := storageController(t)
			c.rootIDFn = func() (string, error) { return tc.rootID, nil }
			c.Nvbootctrl = fakeNvbootctrl(t, tc.slot)
			for _, slot := range []connector.Slot{connector.SlotA, connector.SlotB} {
				got, err := c.PartitionFor(slot)
				want := tc.disk + "p1"
				if slot == connector.SlotB {
					want = tc.disk + "p2"
				}
				if err != nil || got != want {
					t.Fatalf("slot %s: got %s, %v, want %s", slot, got, err, want)
				}
			}
		})
	}
}

func TestPartitionForFailsClosed(t *testing.T) {
	for _, tc := range []struct {
		name   string
		rootID string
		edit   func([]partitionInfo) []partitionInfo
	}{
		{"root missing", "8:99", func(p []partitionInfo) []partitionInfo { return p }},
		{"duplicate root identity", "259:1", func(p []partitionInfo) []partitionInfo { return append(p, p[5]) }},
		{"stacked root", "259:1", func(p []partitionInfo) []partitionInfo { p[5].Type = "crypt"; return p }},
		{"unknown root label", "259:1", func(p []partitionInfo) []partitionInfo { p[5].PartLabel = "other"; return p }},
		{"missing parent", "259:1", func(p []partitionInfo) []partitionInfo { p[5].Parent = ""; return p }},
		{"parent not a disk", "259:1", func(p []partitionInfo) []partitionInfo { p[4].Type = "lvm"; return p }},
		{"missing target even though other disk has it", "259:1", func(p []partitionInfo) []partitionInfo { return append(p[:6], p[7:]...) }},
		{"duplicate target label", "259:1", func(p []partitionInfo) []partitionInfo {
			q := p[6]
			q.Path = "/dev/nvme0n1p20"
			q.DeviceID = "259:20"
			return append(p, q)
		}},
		{"firmware A but mounted root B", "259:2", func(p []partitionInfo) []partitionInfo { return p }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := storageController(t)
			c.rootIDFn = func() (string, error) { return tc.rootID, nil }
			c.listPartsFn = func() ([]partitionInfo, error) { return tc.edit(dualDiskParts()), nil }
			if dev, err := c.PartitionFor(connector.SlotB); err == nil {
				t.Fatalf("unsafe mapping accepted: %s", dev)
			}
		})
	}
	t.Run("enumeration failure", func(t *testing.T) {
		c := storageController(t)
		c.listPartsFn = func() ([]partitionInfo, error) { return nil, errors.New("lsblk failed") }
		if _, err := c.PartitionFor(connector.SlotB); err == nil {
			t.Fatal("must not guess after lsblk failure")
		}
	})
}

func TestESPResolutionRejectsMissingOrAmbiguousLayout(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func([]partitionInfo) []partitionInfo
	}{
		{"ESP only on other disk", func(p []partitionInfo) []partitionInfo { return p[:7] }},
		{"two ESP labels on boot disk", func(p []partitionInfo) []partitionInfo {
			q := p[7]
			q.Path = "/dev/nvme0n1p14"
			q.DeviceID = "259:14"
			q.PartLabel = "UEFI-ESP"
			return append(p, q)
		}},
		{"wrong filesystem", func(p []partitionInfo) []partitionInfo { p[7].FSType = "ext4"; return p }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := storageController(t)
			c.listPartsFn = func() ([]partitionInfo, error) { return tc.edit(dualDiskParts()), nil }
			if _, err := stagingMount(c); err == nil {
				t.Fatal("unsafe ESP accepted")
			}
		})
	}
}

func TestESPReusesVerifiedMount(t *testing.T) {
	for _, where := range []string{"/boot/efi", "/run/wendyos-update/esp"} {
		t.Run(where, func(t *testing.T) {
			c := storageController(t)
			path := c.RootDir + where
			c.mountInfoFn = func(p string) (mountInfo, bool, error) {
				return mountInfo{Source: "/dev/disk/by-partuuid/alias", DeviceID: "259:11", FSType: "vfat", Options: "rw,relatime"}, p == path, nil
			}
			got, err := stagingMount(c)
			if err != nil || got != path {
				t.Fatalf("got %s, %v", got, err)
			}
		})
	}
}

func TestESPMountValidation(t *testing.T) {
	for _, tc := range []struct{ name, where, id, fs, opts string }{
		{"conflicting private mount", "/run/wendyos-update/esp", "179:10", "vfat", "rw"},
		{"ESP mounted read-only", "/boot/efi", "259:11", "vfat", "ro,relatime"},
		{"ESP bind with unexpected filesystem", "/boot/efi", "259:11", "ext4", "rw"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := storageController(t)
			c.mountInfoFn = func(p string) (mountInfo, bool, error) {
				return mountInfo{Source: "fixture", DeviceID: tc.id, FSType: tc.fs, Options: tc.opts}, p == c.RootDir+tc.where, nil
			}
			if _, err := stagingMount(c); err == nil {
				t.Fatal("unsafe mounted ESP accepted")
			}
		})
	}
}

func TestESPStagingAndCleanupLeaveOtherDiskUntouched(t *testing.T) {
	c := storageController(t)
	wrong := c.RootDir + "/boot/efi"
	correct := c.privateESPMountpoint()
	for _, dir := range []string{wrong, correct} {
		if err := os.MkdirAll(filepath.Join(dir, filepath.Dir(ESPCapsuleRel)), 0755); err != nil {
			t.Fatal(err)
		}
	}
	wrongCapsule := filepath.Join(wrong, ESPCapsuleRel)
	if err := os.WriteFile(wrongCapsule, []byte("other disk capsule"), 0644); err != nil {
		t.Fatal(err)
	}
	mounts := map[string]mountInfo{
		wrong: {Source: "/dev/mmcblk0p10", DeviceID: "179:10", FSType: "vfat", Options: "rw"},
	}
	c.mountInfoFn = func(p string) (mountInfo, bool, error) { m, ok := mounts[p]; return m, ok, nil }
	mountCount := 0
	c.mountESPFn = func(dev string) (string, func(), error) {
		mountCount++
		if dev != "/dev/nvme0n1p11" {
			t.Fatalf("wrong device mounted: %s", dev)
		}
		mounts[correct] = mountInfo{Source: dev, DeviceID: "259:11", FSType: "vfat", Options: "rw"}
		return correct, func() { delete(mounts, correct) }, nil
	}
	next := t.TempDir()
	for _, path := range []string{MarkerPath, CapsuleSrcPath} {
		file := filepath.Join(next, strings.TrimPrefix(path, "/"))
		if err := os.MkdirAll(filepath.Dir(file), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(file, []byte("new capsule"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	c.mountFn = func(dev string) (string, func(), error) {
		if dev != "/dev/nvme0n1p2" {
			t.Fatalf("wrong target root: %s", dev)
		}
		return next, func() {}, nil
	}
	if err := c.SwapSlot(connector.SlotB, true); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(filepath.Join(correct, ESPCapsuleRel)); err != nil || string(got) != "new capsule" {
		t.Fatalf("staged=%q, err=%v", got, err)
	}
	if err := c.AbortPlatformUpdate(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(correct, ESPCapsuleRel)); !os.IsNotExist(err) {
		t.Fatalf("capsule was not cleaned up: %v", err)
	}
	if got, err := os.ReadFile(wrongCapsule); err != nil || string(got) != "other disk capsule" {
		t.Fatalf("other ESP changed: %q, %v", got, err)
	}
	if mountCount != 1 {
		t.Fatalf("mounted %d times", mountCount)
	}
}

func writeRunningCapsule(t *testing.T, c *Controller) {
	t.Helper()
	for _, path := range []string{MarkerPath, CapsuleSrcPath} {
		file := c.RootDir + path
		if err := os.MkdirAll(filepath.Dir(file), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(file, []byte("capsule"), 0644); err != nil {
			t.Fatal(err)
		}
	}
}

func headroomCheck(t *testing.T, c *Controller) connector.Check {
	t.Helper()
	for _, check := range c.CheckReadiness() {
		if check.Name == "ESP capsule headroom" {
			return check
		}
	}
	t.Fatal("ESP check missing")
	return connector.Check{}
}

// `check` measures an ESP that staging would mount privately, but never
// mounts it read-write to do so.
func TestReadinessMeasuresUnmountedESPReadOnly(t *testing.T) {
	c := storageController(t)
	writeRunningCapsule(t, c)
	released := false
	c.mountESPReadOnlyFn = func(dev string) (string, func(), error) {
		if dev != "/dev/nvme0n1p11" {
			t.Fatalf("measured the wrong ESP: %s", dev)
		}
		return t.TempDir(), func() { released = true }, nil
	}
	if check := headroomCheck(t, c); !check.OK {
		t.Fatalf("unmounted ESP with free space reported not ready: %+v", check)
	}
	if !released {
		t.Fatal("measurement mount was not released")
	}

	c = storageController(t)
	writeRunningCapsule(t, c)
	c.mountESPReadOnlyFn = func(string) (string, func(), error) { return "", nil, errors.New("permission denied") }
	if check := headroomCheck(t, c); check.OK || !strings.Contains(check.Detail, "read-only") {
		t.Fatalf("an unmeasurable ESP must be explicit: %+v", check)
	}
}

// An ESP already mounted somewhere other than /boot/efi is measured there.
func TestReadinessMeasuresESPMountedElsewhere(t *testing.T) {
	c := storageController(t)
	writeRunningCapsule(t, c)
	dir := filepath.Join(c.RootDir, "efi")
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	var st unix.Stat_t
	if err := unix.Stat(dir, &st); err != nil {
		t.Fatal(err)
	}
	id := fmt.Sprintf("%d:%d", unix.Major(uint64(st.Dev)), unix.Minor(uint64(st.Dev)))
	c.listPartsFn = func() ([]partitionInfo, error) {
		p := dualDiskParts()
		p[7].DeviceID = id
		return p, nil
	}
	c.deviceMountsFn = func(got string) ([]string, error) {
		if got != id {
			t.Fatalf("looked up mounts of %s, want %s", got, id)
		}
		return []string{"/elsewhere", "/efi"}, nil
	}
	if check := headroomCheck(t, c); !check.OK {
		t.Fatalf("ESP mounted elsewhere reported not ready: %+v", check)
	}
}

func TestESPOnEMMCAndSingleDiskThor(t *testing.T) {
	for _, tc := range []struct{ name, root, want, soc string }{
		{"eMMC boot with NVMe attached", "179:1", "/dev/mmcblk0p10", "nvidia,tegra234"},
		{"single-disk Thor with legacy ESP label", "259:1", "/dev/nvme0n1p11", "nvidia,tegra264"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := storageController(t)
			writeCompatible(t, c, tc.soc)
			c.rootIDFn = func() (string, error) { return tc.root, nil }
			if tc.soc == "nvidia,tegra264" {
				c.listPartsFn = func() ([]partitionInfo, error) {
					p := dualDiskParts()[4:]
					p[3].PartLabel = "UEFI-ESP"
					return p, nil
				}
			}
			p, err := c.espPartition()
			if err != nil || p.Path != tc.want {
				t.Fatalf("ESP=%+v, err=%v, want %s", p, err, tc.want)
			}
		})
	}
}

func TestESPMountRechecksDeviceAndUnmountsOnMismatch(t *testing.T) {
	c := storageController(t)
	mounted, cleaned := false, false
	c.mountESPFn = func(string) (string, func(), error) {
		mounted = true
		return c.privateESPMountpoint(), func() { cleaned = true }, nil
	}
	c.mountInfoFn = func(path string) (mountInfo, bool, error) {
		return mountInfo{Source: "/dev/mmcblk0p10", DeviceID: "179:10", FSType: "vfat", Options: "rw"}, mounted && path == c.privateESPMountpoint(), nil
	}
	if _, err := stagingMount(c); err == nil {
		t.Fatal("post-mount mismatch accepted")
	}
	if !cleaned {
		t.Fatal("our unverified mount was not cleaned up")
	}
}

// Exercise the actual command/JSON readers, including nullable lsblk columns,
// stacked mounts and the string IDs older util-linux prints.
func TestStorageCommandJSONReaders(t *testing.T) {
	bin := t.TempDir()
	command := func(name, body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"+body+"\n"), 0755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	command("lsblk", `test "$*" = '--json --list --paths --output PATH,PKNAME,PARTLABEL,PARTUUID,PARTTYPE,TYPE,FSTYPE,MAJ:MIN' || exit 2
printf '%s\n' '{"blockdevices":[{"path":"/dev/nvme0n1","pkname":null,"partlabel":null,"partuuid":null,"parttype":null,"type":"disk","fstype":null,"maj:min":"259:0"},{"path":"/dev/nvme0n1p1","pkname":"/dev/nvme0n1","partlabel":"APP","partuuid":"a1b2c3d4-0000-4000-8000-000000000001","parttype":"0fc63daf-8483-4772-8e79-3d69d8477de4","type":"part","fstype":"ext4","maj:min":"259:1"}]}'`)
	parts, err := listPartitions()
	if err != nil || len(parts) != 2 || parts[0].Parent != "" || parts[1].DeviceID != "259:1" || parts[1].PartUUID == "" || parts[1].PartType == "" {
		t.Fatalf("lsblk parsed %+v, %v", parts, err)
	}
	command("findmnt", "exit 1")
	if _, found, err := mountedFilesystem("/boot/efi"); found || err != nil {
		t.Fatalf("absent mount: found=%t err=%v", found, err)
	}
	command("findmnt", "echo 'inspection failed' >&2; exit 1")
	if _, _, err := mountedFilesystem("/boot/efi"); err == nil {
		t.Fatal("findmnt error treated as absent mount")
	}
	command("findmnt", `printf '%s\n' '{"filesystems":[{"id":1,"parent":0,"source":"/dev/root","target":"/","fstype":"ext4","options":"rw","maj:min":"259:1"}]}'`)
	if _, _, err := mountedFilesystem("/boot/efi"); err == nil {
		t.Fatal("containing filesystem accepted as exact mount")
	}
	for _, ids := range [][2]string{{"41", "113"}, {`"41"`, `"113"`}} {
		command("findmnt", `test "$*" = '--json --output ID,PARENT,SOURCE,TARGET,FSTYPE,OPTIONS,MAJ:MIN --mountpoint /boot/efi' || exit 2
printf '%s\n' '{"filesystems":[{"id":`+ids[0]+`,"parent":29,"source":"systemd-1","target":"/boot/efi","fstype":"autofs","options":"rw","maj:min":"0:35"},{"id":`+ids[1]+`,"parent":`+ids[0]+`,"source":"/dev/nvme0n1p11","target":"/boot/efi","fstype":"vfat","options":"rw,relatime","maj:min":"259:11"}]}'`)
		if m, found, err := mountedFilesystem("/boot/efi"); !found || err != nil || m.DeviceID != "259:11" {
			t.Fatalf("stacked mount ids %v: got %+v, found=%t, err=%v; want the top vfat mount", ids, m, found, err)
		}
	}
	command("findmnt", `printf '%s\n' '{"filesystems":[{"id":41,"parent":29,"source":"a","target":"/boot/efi","fstype":"vfat","options":"rw","maj:min":"259:11"},{"id":42,"parent":29,"source":"b","target":"/boot/efi","fstype":"vfat","options":"rw","maj:min":"179:10"}]}'`)
	if _, _, err := mountedFilesystem("/boot/efi"); err == nil {
		t.Fatal("two uncovered mounts at one path accepted")
	}
	command("findmnt", `test "$*" = '--json --list --output ID,PARENT,SOURCE,TARGET,FSTYPE,OPTIONS,MAJ:MIN' || exit 2
printf '%s\n' '{"filesystems":[{"id":1,"parent":0,"source":"/dev/nvme0n1p1","target":"/","fstype":"ext4","options":"rw","maj:min":"259:1"},{"id":2,"parent":1,"source":"/dev/nvme0n1p11","target":"/efi","fstype":"vfat","options":"rw","maj:min":"259:11"}]}'`)
	if dirs, err := deviceMountpoints("259:11"); err != nil || len(dirs) != 1 || dirs[0] != "/efi" {
		t.Fatalf("device mounts = %q, %v", dirs, err)
	}
	command("lsblk", "echo not-json")
	if _, err := listPartitions(); err == nil {
		t.Fatal("malformed lsblk accepted")
	}
}

func TestReadinessRejectsPendingCapsuleBootChain(t *testing.T) {
	c := storageController(t)
	marker := c.RootDir + MarkerPath
	if err := os.MkdirAll(filepath.Dir(marker), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(marker, nil, 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(c.EfivarsDir, "BootChainFwNext-"+VendorGUID), []byte{7, 0, 0, 0, 0, 0, 0, 0}, 0644); err != nil {
		t.Fatal(err)
	}
	for _, check := range c.CheckReadiness() {
		if check.Name == "capsule boot-chain state" {
			if check.OK {
				t.Fatal("pending boot-chain operation reported ready")
			}
			return
		}
	}
	t.Fatal("capsule boot-chain state check missing")
}

// Finding the ESP needs only the root's disk; a firmware slot that cannot be
// read or disagrees with the root must not hide it.
func TestESPResolutionDoesNotNeedFirmwareSlot(t *testing.T) {
	for _, tc := range []struct{ name, rootID, nvbootctrl string }{
		{"nvbootctrl missing", "259:1", ""},
		{"firmware slot disagrees with root", "259:2", "0\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := storageController(t)
			c.rootIDFn = func() (string, error) { return tc.rootID, nil }
			c.Nvbootctrl = filepath.Join(t.TempDir(), "absent")
			if tc.nvbootctrl != "" {
				c.Nvbootctrl = fakeNvbootctrl(t, tc.nvbootctrl)
			}
			if esp, err := c.espPartition(); err != nil || esp.Path != "/dev/nvme0n1p11" {
				t.Fatalf("ESP = %+v, %v", esp, err)
			}
			if dev, err := c.PartitionFor(connector.SlotB); err == nil {
				t.Fatalf("slot resolved without a verified firmware slot: %s", dev)
			}
		})
	}
}

func notPartition() (string, error) {
	return "", fmt.Errorf("root is overlay: %w", blockdev.ErrNotPartition)
}

// A root with no backing partition has no disk to scope to: a label is used
// only when no other disk carries it.
func TestRootWithoutBackingPartitionNeedsUniqueLabels(t *testing.T) {
	c := storageController(t)
	c.rootIDFn = notPartition
	c.listPartsFn = func() ([]partitionInfo, error) { return dualDiskParts()[4:], nil }
	for slot, want := range map[connector.Slot]string{connector.SlotA: "/dev/nvme0n1p1", connector.SlotB: "/dev/nvme0n1p2"} {
		if got, err := c.PartitionFor(slot); err != nil || got != want {
			t.Fatalf("single disk slot %s = %q, %v; want %s", slot, got, err, want)
		}
	}
	if esp, err := c.espPartition(); err != nil || esp.Path != "/dev/nvme0n1p11" {
		t.Fatalf("single disk ESP = %+v, %v", esp, err)
	}

	c = storageController(t)
	c.rootIDFn = notPartition
	if dev, err := c.PartitionFor(connector.SlotB); err == nil {
		t.Fatalf("ambiguous label accepted: %s", dev)
	}
	if esp, err := c.espPartition(); err == nil {
		t.Fatalf("ambiguous ESP accepted: %+v", esp)
	}
}

// When lsblk reads no partition names on the boot disk, the slots are the
// adjacent partitions there, never a partition on another disk.
func TestUnlabelledBootDiskUsesAdjacentPartitions(t *testing.T) {
	unlabelled := func() ([]partitionInfo, error) {
		p := dualDiskParts()
		for i := 5; i <= 7; i++ {
			p[i].PartLabel = ""
		}
		return p, nil
	}
	for _, tc := range []struct{ name, rootID, slot, a, b string }{
		{"running A", "259:1", "0\n", "/dev/nvme0n1p1", "/dev/nvme0n1p2"},
		{"running B", "259:2", "1\n", "/dev/nvme0n1p1", "/dev/nvme0n1p2"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := storageController(t)
			c.rootIDFn = func() (string, error) { return tc.rootID, nil }
			c.Nvbootctrl = fakeNvbootctrl(t, tc.slot)
			c.listPartsFn = unlabelled
			for slot, want := range map[connector.Slot]string{connector.SlotA: tc.a, connector.SlotB: tc.b} {
				if got, err := c.PartitionFor(slot); err != nil || got != want {
					t.Fatalf("slot %s = %q, %v; want %s", slot, got, err, want)
				}
			}
		})
	}
	t.Run("labels elsewhere on the boot disk", func(t *testing.T) {
		c := storageController(t)
		c.listPartsFn = func() ([]partitionInfo, error) {
			p := dualDiskParts()
			p[5].PartLabel = ""
			return p, nil
		}
		if dev, err := c.PartitionFor(connector.SlotB); err == nil {
			t.Fatalf("unlabelled root on a labelled disk accepted: %s", dev)
		}
	})
}

// One command reads the inventory once, however many lookups it makes; a
// failed read is not remembered.
func TestLayoutIsReadOncePerCommand(t *testing.T) {
	c := storageController(t)
	scans, roots := 0, 0
	fail := true
	c.listPartsFn = func() ([]partitionInfo, error) {
		scans++
		if fail {
			return nil, errors.New("lsblk failed")
		}
		return dualDiskParts(), nil
	}
	c.rootIDFn = func() (string, error) { roots++; return "259:1", nil }
	if _, err := c.espPartition(); err == nil {
		t.Fatal("failed inventory accepted")
	}
	fail = false
	for _, slot := range []connector.Slot{connector.SlotA, connector.SlotB} {
		if _, err := c.PartitionFor(slot); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := c.capsuleESP(); err != nil {
		t.Fatal(err)
	}
	if scans != 2 || roots != 1 {
		t.Fatalf("inventory read %d times and root %d times, want 2 and 1", scans, roots)
	}
}
