/// Payload compression scheme, matching the `compression` string used in
/// the artifact manifest (`internal/artifact/manifest.go`) and the
/// `Decompressor` switch in `internal/blockdev/blockdev.go`.
public enum Compression: String, Sendable {
    case zstd
    case gzip
    case none
}

/// Errors surfaced by the zstd/zlib streaming wrappers.
public enum ZstdError: Error, Equatable {
    /// The underlying zstd or zlib stream context could not be created.
    case initFailed
    /// The compressed input failed to decode (bad magic, checksum, or
    /// truncated frame).
    case corrupt(String)
    /// An unsupported `Compression` case was requested (defensive; every
    /// current case is supported).
    case unsupported(String)
}
