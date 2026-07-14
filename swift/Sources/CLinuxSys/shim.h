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

// linux/fs.h is not shipped in the musl cross-compilation sysroot, so the
// three constants it would provide are defined directly here instead of
// included. They are stable kernel UAPI (unchanged since ext2 in the
// 1990s), so hardcoding them is safe. The #ifndef guards mean a sysroot
// that DOES provide linux/fs.h (glibc) still wins, keeping native and
// musl builds byte-identical in behavior.
#ifndef FS_IMMUTABLE_FL
#define FS_IMMUTABLE_FL 0x00000010
#endif
#ifndef FS_IOC_GETFLAGS
#define FS_IOC_GETFLAGS _IOR('f', 1, long)
#endif
#ifndef FS_IOC_SETFLAGS
#define FS_IOC_SETFLAGS _IOW('f', 2, long)
#endif

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
