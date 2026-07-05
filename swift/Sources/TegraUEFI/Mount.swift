import Glibc

// Mount seams for `SwapSlot`'s install path: mounting the freshly-written
// target rootfs read-only (to inspect the bootloader marker/capsule) and,
// separately, mounting the ESP read-write (to stage the capsule). Ports
// the `mountFn func(dev string) (string, func(), error)` field and
// `mountVfat` method from `swap-slot.go`.
//
// Both are real `mount(2)` calls in production and are never exercised by
// tests — tests substitute the closures wholesale, exactly as the Go
// tests replace `c.mountFn`, because a real mount needs a real block
// device and (for the read-write ESP case) root privilege.

/// A mounted filesystem: the directory it's mounted at, plus a closure
/// that unmounts it. Ports the `(dir string, unmount func(), err error)`
/// return shape of Go's `mountFn`/`mountVfat`.
public struct TegraMount: Sendable {
    public let directory: String
    public let unmount: @Sendable () -> Void

    public init(directory: String, unmount: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.unmount = unmount
    }
}

/// Mounts `devicePath`'s rootfs read-only and returns the mount point.
/// Ports `defaultMount`/`c.mountFn`.
public typealias RootfsMounter = @Sendable (_ devicePath: String) throws -> TegraMount

/// Mounts `devicePath` (the ESP) read-write and returns the mount point.
/// Ports `c.mountVfat`.
public typealias EspMounter = @Sendable (_ devicePath: String) throws -> TegraMount

/// Real `mount(2)`-backed implementations. Best-effort: never covered by
/// unit tests (no real block device / privilege in CI), so correctness
/// here rests on matching `swap-slot.go`'s `unix.Mount` calls rather than
/// on test coverage.
public enum TegraRealMount {
    /// Ports `defaultMount`: `os.MkdirTemp("/run", "wendyos-update-slot-*")`
    /// + `unix.Mount(dev, dir, "ext4", unix.MS_RDONLY, "")`.
    public static let rootfsReadOnly: RootfsMounter = { dev in
        var template = Array("/run/wendyos-update-slot-XXXXXX".utf8CString)
        let dirPtr: UnsafeMutablePointer<CChar>? = template.withUnsafeMutableBufferPointer { buf in
            mkdtemp(buf.baseAddress!)
        }
        guard dirPtr != nil else {
            throw TegraUEFIError.mountFailed("mkdtemp under /run: errno \(errno)")
        }
        let bytes = template.map { UInt8(bitPattern: $0) }
        let nulIndex = bytes.firstIndex(of: 0) ?? bytes.count
        let dir = String(decoding: bytes[0..<nulIndex], as: UTF8.self)

        let rc = mount(dev, dir, "ext4", UInt(MS_RDONLY), nil)
        guard rc == 0 else {
            let mountErrno = errno
            _ = rmdir(dir)
            throw TegraUEFIError.mountFailed("mount \(dev) at \(dir) (ext4, ro): errno \(mountErrno)")
        }
        return TegraMount(
            directory: dir,
            unmount: {
                _ = umount(dir)
                _ = rmdir(dir)
            }
        )
    }

    /// Ports `c.mountVfat`: mounts the ESP read-write at a fixed
    /// `/run/wendyos-update/esp`, left mounted on success (the staged
    /// capsule must be on disk at reboot).
    public static let espReadWrite: EspMounter = { dev in
        let dir = "/run/wendyos-update/esp"
        _ = mkdir("/run/wendyos-update", 0o755)
        _ = mkdir(dir, 0o755)

        let rc = mount(dev, dir, "vfat", 0, nil)
        guard rc == 0 else {
            throw TegraUEFIError.mountFailed("mount ESP \(dev) at \(dir) (vfat, rw): errno \(errno)")
        }
        return TegraMount(directory: dir, unmount: { _ = umount(dir) })
    }
}
