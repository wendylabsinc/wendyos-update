import CLinuxSys
import Glibc

/// A raw syscall/ioctl failure, carrying the failing `errno` and the
/// operation name for diagnostics. Callers compare `errno` against the
/// Glibc constants (`ENOENT`, `EOPNOTSUPP`, ...).
public struct SysError: Error, Equatable {
    public let errno: Int32
    public let op: String
}

/// Thin wrapper over the raw Linux syscalls/ioctls wendyos-update needs
/// to talk to block devices, terminals, and efivarfs. Ports the ops
/// behind Go's `internal/blockdev` (no-create `open`, `fsync`,
/// `lseek(SEEK_END)` for capacity), `internal/log.IsTTY`, and
/// `internal/connector/tegrauefi`'s immutable inode flag toggling.
///
/// Every call here is a thin syscall wrapper: no buffering, and no retry
/// beyond `EINTR`. `write`/`read` do not loop to fill/drain `buf` — they
/// return whatever the underlying syscall returned, exactly as `write(2)`
/// / `read(2)` do; callers loop if they need a full transfer.
public enum LinuxSys {
    /// Opens `path` for writing. Deliberately does NOT pass `O_CREAT`:
    /// callers writing to a block device partition must fail loudly if
    /// the device node doesn't exist rather than silently creating a
    /// regular file in its place (ports `os.OpenFile(dst, os.O_WRONLY,
    /// 0)` from `blockdev.WriteImage`).
    public static func openWriteExisting(_ path: String) throws -> Int32 {
        try rawOpen(path, O_WRONLY, op: "open(O_WRONLY)")
    }

    /// Opens `path` read-only.
    public static func openRead(_ path: String) throws -> Int32 {
        try rawOpen(path, O_RDONLY, op: "open(O_RDONLY)")
    }

    /// Writes `buf` via a single `write(2)` call (retried across
    /// `EINTR`), returning the byte count the syscall reported — which
    /// may be less than `buf.count`.
    public static func write(_ fd: Int32, _ buf: UnsafeRawBufferPointer) throws -> Int {
        try retrying(op: "write") {
            Glibc.write(fd, buf.baseAddress, buf.count)
        }
    }

    /// Reads into `buf` via a single `read(2)` call (retried across
    /// `EINTR`), returning the byte count read (0 == EOF).
    public static func read(_ fd: Int32, _ buf: UnsafeMutableRawBufferPointer) throws -> Int {
        try retrying(op: "read") {
            Glibc.read(fd, buf.baseAddress, buf.count)
        }
    }

    /// Flushes `fd`'s data and metadata to stable storage.
    public static func fsync(_ fd: Int32) throws {
        _ = try retrying(op: "fsync") { Glibc.fsync(fd) }
    }

    /// Seeks to end-of-file, returning the resulting offset. Used as the
    /// capacity of a block device (a Linux partition node reports its
    /// exact size this way) or a regular file's length (ports
    /// `blockdev.DeviceCapacity`).
    public static func seekEnd(_ fd: Int32) throws -> Int64 {
        let off = try retrying(op: "lseek(SEEK_END)") {
            Glibc.lseek(fd, 0, Int32(SEEK_END))
        }
        return Int64(off)
    }

    /// Closes `fd`. Errors are not surfaced: retrying `close()` after
    /// `EINTR` risks closing an unrelated descriptor reused by a racing
    /// thread, and by the time `close` fails there is nothing actionable
    /// left to do with this fd. This matches the guidance in `close(2)`.
    public static func close(_ fd: Int32) {
        _ = Glibc.close(fd)
    }

    /// Reports whether `fd` refers to a terminal — the same `TCGETS`
    /// ioctl underlies both `isatty(3)` and Go's
    /// `unix.IoctlGetTermios`/`log.IsTTY`.
    public static func isatty(_ fd: Int32) -> Bool {
        Glibc.isatty(fd) == 1
    }

    /// Sets or clears the inode's immutable flag (the `chattr +i`/`-i`
    /// equivalent) via `FS_IOC_GETFLAGS`/`FS_IOC_SETFLAGS`. efivarfs
    /// marks variables immutable by default, so this must run before a
    /// write (ports `tegrauefi.clearImmutable`). Filesystems without
    /// flag support (tmpfs, some overlayfs configurations) fail with
    /// `ENOTTY`/`EOPNOTSUPP`, surfaced as a `SysError` like any other
    /// failure; callers that consider that acceptable catch and ignore
    /// it, as the Tegra efivar path does.
    public static func setImmutable(_ path: String, _ on: Bool) throws {
        let fd = try rawOpen(path, O_RDONLY, op: "open(O_RDONLY)")
        defer { close(fd) }

        var flags: Int32 = 0
        guard wos_ioctl_get_flags(fd, &flags) == 0 else {
            throw SysError(errno: errno, op: "ioctl(FS_IOC_GETFLAGS)")
        }

        let immutableBit = wos_fs_immutable_fl()
        if on {
            flags |= immutableBit
        } else {
            flags &= ~immutableBit
        }

        guard wos_ioctl_set_flags(fd, &flags) == 0 else {
            throw SysError(errno: errno, op: "ioctl(FS_IOC_SETFLAGS)")
        }
    }

    /// Opens `path` with `flags` (no `O_CREAT` — callers of this shim
    /// never create files), retrying across `EINTR` and translating any
    /// other failure into a `SysError` tagged with `op`.
    private static func rawOpen(_ path: String, _ flags: Int32, op: String) throws -> Int32 {
        try retrying(op: op) {
            path.withCString { cPath in
                Glibc.open(cPath, flags)
            }
        }
    }

    /// Runs `body` (a raw syscall returning a negative sentinel on
    /// failure), retrying transparently on `EINTR` and translating any
    /// other failure into a `SysError` tagged with `op`.
    private static func retrying<T: FixedWidthInteger>(op: String, _ body: () -> T) throws -> T {
        while true {
            let rc = body()
            if rc >= 0 { return rc }
            if errno == EINTR { continue }
            throw SysError(errno: errno, op: op)
        }
    }
}
