/// Streaming push-compressor over zstd, gzip, or an uncompressed
/// passthrough, selected by `compression`. Mirrors the compression paths
/// used by `internal/artifact/writer.go`'s `Pack` (`github.com/
/// klauspost/compress/zstd` and `compress/gzip`), exposed as a push API
/// to match this package's streaming conventions.
///
/// Call `write(_:)` any number of times with the plaintext, then
/// `finish()` exactly once to flush and emit any format trailers (e.g.
/// the gzip footer, or the zstd frame's end marker and checksum).
///
/// The underlying zstd/zlib stream context is created lazily on the first
/// `write(_:)` or `finish()` call (rather than in `init`, which cannot
/// throw) so a context-creation failure surfaces as `ZstdError.initFailed`
/// from that first call.
public struct CompressStream {
    /// Boxes the lazily-created backend so `write`/`finish` can stay
    /// non-mutating (the struct is typically held as a `let`).
    private final class State {
        let compression: Compression
        let sink: (ArraySlice<UInt8>) throws -> Void
        var backend: CompressBackend?

        init(compression: Compression, sink: @escaping (ArraySlice<UInt8>) throws -> Void) {
            self.compression = compression
            self.sink = sink
        }
    }

    private let state: State

    public init(_ compression: Compression, sink: @escaping (ArraySlice<UInt8>) throws -> Void) {
        state = State(compression: compression, sink: sink)
    }

    /// Compresses `bytes` and pushes any resulting output to the sink.
    /// May buffer internally; not every call produces output immediately.
    public func write(_ bytes: ArraySlice<UInt8>) throws {
        let backend = try resolvedBackend()
        try backend.write(bytes)
    }

    /// Flushes and finalizes the stream, pushing any remaining output
    /// (including format trailers) to the sink. Safe to call even if no
    /// bytes were ever written (e.g. an empty payload).
    public func finish() throws {
        let backend = try resolvedBackend()
        try backend.finish()
    }

    private func resolvedBackend() throws -> CompressBackend {
        if let backend = state.backend { return backend }
        let backend: CompressBackend
        switch state.compression {
        case .zstd:
            backend = try ZstdCompressBackend(sink: state.sink)
        case .gzip:
            backend = try GzipCompressBackend(sink: state.sink)
        case .none:
            backend = PassthroughCompressBackend(sink: state.sink)
        }
        state.backend = backend
        return backend
    }
}
