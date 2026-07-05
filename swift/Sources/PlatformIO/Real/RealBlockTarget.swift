import LinuxSys

/// `BlockTarget` over `LinuxSys`'s raw open/write/fsync/lseek shims. Ports
/// `internal/blockdev`'s no-create `open`, `write`, `fsync`, and
/// `lseek(SEEK_END)`-based capacity probe.
public struct RealBlockTarget: BlockTarget {
    public init() {}

    public func openForWrite(_ path: String) throws -> any WritableDevice {
        let fd = try LinuxSys.openWriteExisting(path)
        return RealWritableDevice(fd: fd)
    }

    public func capacity(_ path: String) throws -> Int64 {
        let fd = try LinuxSys.openRead(path)
        defer { LinuxSys.close(fd) }
        return try LinuxSys.seekEnd(fd)
    }
}

/// A `WritableDevice` backed by a raw file descriptor. `write` loops to
/// send `b` in full — `LinuxSys.write` is a thin, single-syscall shim that
/// may report a short write, same as `write(2)`.
final class RealWritableDevice: WritableDevice {
    private let fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    func write(_ b: ArraySlice<UInt8>) throws {
        var remaining = b
        while !remaining.isEmpty {
            let n = try remaining.withUnsafeBytes { buf in
                try LinuxSys.write(fd, buf)
            }
            if n == 0 { break }  // shouldn't happen for a block device; avoid spinning forever
            remaining = remaining.dropFirst(n)
        }
    }

    func sync() throws {
        try LinuxSys.fsync(fd)
    }

    func close() {
        LinuxSys.close(fd)
    }
}
