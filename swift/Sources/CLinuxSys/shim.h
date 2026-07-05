// Umbrella header exposing the handful of raw Linux syscall/ioctl
// primitives LinuxSys needs that Swift cannot express directly:
//
//   - FS_IOC_GETFLAGS / FS_IOC_SETFLAGS (linux/fs.h) are defined via the
//     _IOR/_IOW macros, which expand using sizeof() and are not
//     computable from Swift. These static-inline wrappers give them a
//     fixed C signature callable from Swift.
//   - FS_IMMUTABLE_FL is a #define, not a symbol Swift's C-interop can
//     import; expose it via a helper function instead.
//
// The flags argument is `int`, matching golang.org/x/sys/unix's
// IoctlGetInt/IoctlSetPointerInt (which this ports): despite the kernel
// header's macro encoding sizeof(long), the ext2/ext4/efivarfs ioctl
// handlers actually copy an int-sized value, and that is the layout
// every real-world caller (chattr, Go's unix package) uses.
#ifndef CLINUXSYS_SHIM_H
#define CLINUXSYS_SHIM_H

#include <sys/ioctl.h>
#include <linux/fs.h>

static inline int wos_ioctl_get_flags(int fd, int *flags) {
    return ioctl(fd, FS_IOC_GETFLAGS, flags);
}

static inline int wos_ioctl_set_flags(int fd, int *flags) {
    return ioctl(fd, FS_IOC_SETFLAGS, flags);
}

static inline int wos_fs_immutable_fl(void) {
    return (int)FS_IMMUTABLE_FL;
}

#endif /* CLINUXSYS_SHIM_H */
