//go:build linux

package systemdboot

import (
	"os"

	"golang.org/x/sys/unix"
)

// defaultMount mounts a slot's ext4 rootfs read-only under /run and returns the
// mount dir plus an unmount func. Used at install to read the target slot's
// kernel/initrd for staging onto the ESP (tests substitute mountFn).
func defaultMount(dev string) (string, func(), error) {
	dir, err := os.MkdirTemp("/run", "wendyos-update-sdboot-slot-*")
	if err != nil {
		return "", nil, err
	}
	if err := unix.Mount(dev, dir, "ext4", unix.MS_RDONLY, ""); err != nil {
		os.Remove(dir)
		return "", nil, err
	}
	unmount := func() {
		_ = unix.Unmount(dir, 0)
		_ = os.Remove(dir)
	}
	return dir, unmount, nil
}
