package systemdboot

import "syscall"

// syncFS flushes filesystem buffers to disk. Slot arming/commit renames loader
// entry files on the FAT ESP and stages kernels there; the device reboots almost
// immediately after, so the writes must be durable first (mirrors ubootenv's
// syscall.Sync after an env write).
func syncFS() { syscall.Sync() }
