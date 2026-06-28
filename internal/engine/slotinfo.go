package engine

// Per-slot status detail for the `status` verb. Distro/kernel are read live
// for the booted slot and via a read-only mount of the inactive slot's
// rootfs. All of it is best-effort and display-only.

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// SlotState is one A/B slot's status. Empty fields are omitted by the
// formatter (e.g. distro/kernel when the inactive slot can't be mounted,
// or RootfsHealth on boards with no per-slot health marker).
type SlotState struct {
	Slot         string `json:"slot"`
	Booted       bool   `json:"booted"`
	Partition    string `json:"partition,omitempty"`
	Distro       string `json:"distro,omitempty"`
	Kernel       string `json:"kernel,omitempty"`
	RootfsHealth string `json:"rootfs_health,omitempty"`
	Retries      string `json:"retries,omitempty"`
	Note         string `json:"note,omitempty"`
}

func currentDistro() string { return osReleaseVersion("/etc/os-release") }

func currentKernel() string {
	var u unix.Utsname
	if err := unix.Uname(&u); err != nil {
		return ""
	}
	return unix.ByteSliceToString(u.Release[:])
}

// slotVersions mounts dev read-only and reads an inactive slot's distro and
// kernel version. Best-effort: returns empty strings on any failure (not
// root, unmountable, unexpected layout). The mount is detached on return.
func slotVersions(dev string) (distro, kernel string) {
	if dev == "" {
		return "", ""
	}
	dir, err := os.MkdirTemp("", "wendyos-slot-")
	if err != nil {
		return "", ""
	}
	defer os.RemoveAll(dir)
	if err := unix.Mount(dev, dir, "ext4", unix.MS_RDONLY|unix.MS_NOATIME, ""); err != nil {
		return "", ""
	}
	defer unix.Unmount(dir, unix.MNT_DETACH)
	return osReleaseVersion(filepath.Join(dir, "etc/os-release")),
		kernelFromModules(filepath.Join(dir, "lib/modules"))
}

// osReleaseVersion returns VERSION (preferred — it carries the codename) or
// VERSION_ID from an os-release file. Empty if the file or keys are absent.
func osReleaseVersion(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	var versionID string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if v, ok := strings.CutPrefix(line, "VERSION="); ok {
			return strings.Trim(v, `"`)
		}
		if v, ok := strings.CutPrefix(line, "VERSION_ID="); ok {
			versionID = strings.Trim(v, `"`)
		}
	}
	return versionID
}

// kernelFromModules returns the kernel version from a /lib/modules directory
// (the highest-sorted entry — normally the only one). Empty if none exist.
func kernelFromModules(dir string) string {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	best := ""
	for _, e := range ents {
		if e.IsDir() && e.Name() > best {
			best = e.Name()
		}
	}
	return best
}
