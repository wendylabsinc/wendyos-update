/// Opens a block device (or a regular file standing in for one) for
/// writing, and reports its capacity. Ports `internal/blockdev`'s
/// no-create `open`/`write`/`fsync` and `lseek(SEEK_END)`-based capacity
/// probe.
public protocol BlockTarget: Sendable {
    /// Opens `path` for writing. Never creates the target — the node
    /// must already exist (writing to a partition that doesn't exist is
    /// a configuration error, not something to paper over).
    func openForWrite(_ path: String) throws -> any WritableDevice

    /// The size, in bytes, of the device or file at `path`.
    func capacity(_ path: String) throws -> Int64
}

/// A writable target opened by `BlockTarget.openForWrite`.
public protocol WritableDevice {
    /// Writes `b` in full, retrying short writes as needed.
    func write(_ b: ArraySlice<UInt8>) throws

    /// Flushes written data and metadata to stable storage.
    func sync() throws

    /// Closes the device. Errors are not surfaced (mirrors `LinuxSys.close`).
    func close()
}
