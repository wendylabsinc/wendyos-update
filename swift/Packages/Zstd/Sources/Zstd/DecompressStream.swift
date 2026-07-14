/// Streaming pull-decompressor over zstd, gzip, or an uncompressed
/// passthrough, selected by `compression`. Mirrors `Decompressor` in Go's
/// `internal/blockdev/blockdev.go`, but as a pull (rather than
/// `io.Reader`-wrapping) API to match this package's streaming
/// conventions.
///
/// `source` fills its buffer argument with up to the requested byte count
/// and returns the count actually read; 0 means the compressed input is
/// exhausted. `read(into:)` follows the same convention on the
/// decompressed side.
///
/// The underlying zstd/zlib stream context is created lazily on the first
/// `read(into:)` call (rather than in `init`, which cannot throw) so a
/// context-creation failure surfaces as `ZstdError.initFailed` from that
/// first call.
public struct DecompressStream {
    /// Boxes the lazily-created backend so `read(into:)` can stay
    /// non-mutating (the struct is typically held as a `let`).
    private final class State {
        let compression: Compression
        let source: (inout [UInt8], Int) throws -> Int
        var backend: DecompressBackend?

        init(compression: Compression, source: @escaping (inout [UInt8], Int) throws -> Int) {
            self.compression = compression
            self.source = source
        }
    }

    private let state: State

    public init(_ compression: Compression, source: @escaping (inout [UInt8], Int) throws -> Int) {
        state = State(compression: compression, source: source)
    }

    /// Fills `into` (from index 0) with up to `into.count` decompressed
    /// bytes, returning the count actually written. Returns 0 once the
    /// compressed stream has been fully decoded.
    public func read(into buf: inout [UInt8]) throws -> Int {
        let backend = try resolvedBackend()
        return try backend.read(into: &buf)
    }

    private func resolvedBackend() throws -> DecompressBackend {
        if let backend = state.backend { return backend }
        let backend: DecompressBackend
        switch state.compression {
        case .zstd:
            backend = try ZstdDecompressBackend(source: state.source)
        case .gzip:
            backend = try GzipDecompressBackend(source: state.source)
        case .none:
            backend = PassthroughDecompressBackend(source: state.source)
        }
        state.backend = backend
        return backend
    }
}
