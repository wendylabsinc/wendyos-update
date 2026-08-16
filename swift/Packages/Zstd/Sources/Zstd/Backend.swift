/// Backing implementation for `DecompressStream`, selected by `Compression`.
protocol DecompressBackend: AnyObject {
    /// Fills `buf` (from index 0) with up to `buf.count` decompressed bytes,
    /// returning the count actually written; 0 means the stream is
    /// exhausted (matches the pull-source convention used throughout this
    /// package).
    func read(into buf: inout [UInt8]) throws -> Int
}

/// Backing implementation for `CompressStream`, selected by `Compression`.
protocol CompressBackend: AnyObject {
    /// Compresses `bytes` and pushes any resulting output to the sink.
    /// May buffer internally; not every call produces output immediately.
    func write(_ bytes: ArraySlice<UInt8>) throws
    /// Flushes and finalizes the stream, pushing any remaining output
    /// (including format trailers) to the sink. Idempotent.
    func finish() throws
}

/// `.none`: passes bytes through unchanged in both directions.
final class PassthroughDecompressBackend: DecompressBackend {
    private let source: (inout [UInt8], Int) throws -> Int

    init(source: @escaping (inout [UInt8], Int) throws -> Int) {
        self.source = source
    }

    func read(into buf: inout [UInt8]) throws -> Int {
        guard !buf.isEmpty else { return 0 }
        var chunk: [UInt8] = []
        let got = try source(&chunk, buf.count)
        precondition(got <= buf.count, "source closure returned more bytes than requested")
        for i in 0..<got { buf[i] = chunk[i] }
        return got
    }
}

/// `.none`: passes bytes through unchanged in both directions.
final class PassthroughCompressBackend: CompressBackend {
    private let sink: (ArraySlice<UInt8>) throws -> Void

    init(sink: @escaping (ArraySlice<UInt8>) throws -> Void) {
        self.sink = sink
    }

    func write(_ bytes: ArraySlice<UInt8>) throws {
        guard !bytes.isEmpty else { return }
        try sink(bytes)
    }

    func finish() throws {}
}
