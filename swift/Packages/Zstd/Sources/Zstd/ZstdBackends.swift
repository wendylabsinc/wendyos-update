import CZstd

/// Default compression level, matching zstd's own `ZSTD_CLEVEL_DEFAULT`
/// (hardcoded here rather than imported since it's a simple `#define` we
/// don't want to depend on the Clang importer's macro handling for).
private let defaultCompressionLevel: Int32 = 3

/// Decompresses a zstd frame via the `ZSTD_createDStream` /
/// `ZSTD_decompressStream` streaming API, pulling compressed bytes from a
/// caller-supplied source closure. Mirrors the read side of Go's
/// `github.com/klauspost/compress/zstd` usage in
/// `internal/blockdev/blockdev.go`'s `Decompressor`.
final class ZstdDecompressBackend: DecompressBackend {
    private let source: (inout [UInt8], Int) throws -> Int
    private let dstream: OpaquePointer

    /// Most recently pulled (and not yet fully consumed) compressed chunk.
    private var pending: [UInt8] = []
    /// Offset into `pending` of the next unconsumed byte.
    private var pendingPos = 0
    /// Set once `source` has returned 0 (no more compressed bytes to pull).
    private var sourceExhausted = false
    /// Set once the zstd frame has been fully decoded and flushed.
    private var finished = false

    init(source: @escaping (inout [UInt8], Int) throws -> Int) throws {
        guard let ds = ZSTD_createDStream() else { throw ZstdError.initFailed }
        let ret = ZSTD_initDStream(ds)
        if ZSTD_isError(ret) != 0 {
            _ = ZSTD_freeDStream(ds)
            throw ZstdError.initFailed
        }
        self.dstream = ds
        self.source = source
    }

    deinit {
        _ = ZSTD_freeDStream(dstream)
    }

    func read(into buf: inout [UInt8]) throws -> Int {
        guard !buf.isEmpty else { return 0 }
        if finished { return 0 }

        while true {
            if pendingPos == pending.count && !sourceExhausted {
                var chunk: [UInt8] = []
                let got = try source(&chunk, Int(ZSTD_DStreamInSize()))
                if got == 0 {
                    sourceExhausted = true
                } else {
                    pending = chunk
                    pendingPos = 0
                }
            }

            var produced = 0
            var consumed = 0
            var frameComplete = false
            var errorMessage: String?

            buf.withUnsafeMutableBufferPointer { outPtr in
                pending.withUnsafeBytes { inRaw in
                    let inSlice = UnsafeRawBufferPointer(rebasing: inRaw[pendingPos...])
                    var outBuffer = ZSTD_outBuffer(dst: outPtr.baseAddress, size: outPtr.count, pos: 0)
                    var inBuffer = ZSTD_inBuffer(src: inSlice.baseAddress, size: inSlice.count, pos: 0)

                    let ret = ZSTD_decompressStream(dstream, &outBuffer, &inBuffer)
                    if ZSTD_isError(ret) != 0 {
                        errorMessage = String(cString: ZSTD_getErrorName(ret))
                    } else if ret == 0 {
                        frameComplete = true
                    }
                    produced = outBuffer.pos
                    consumed = inBuffer.pos
                }
            }

            if let errorMessage { throw ZstdError.corrupt(errorMessage) }

            pendingPos += consumed

            // Mark completion before returning: the final decompressStream
            // call can both produce its last bytes AND report the frame as
            // complete in the same call, so `finished` must be set even
            // when we're about to return early for `produced > 0` below —
            // otherwise the *next* call sees an exhausted source with no
            // pending bytes and (wrongly) reports a truncated stream.
            if frameComplete { finished = true }

            if produced > 0 { return produced }

            if frameComplete { return 0 }

            if sourceExhausted && pendingPos == pending.count {
                // No more compressed bytes available, but the frame was
                // neither complete nor did this call make any progress:
                // the input was truncated mid-frame.
                throw ZstdError.corrupt("truncated zstd stream")
            }
            // Otherwise: made progress but need more input to produce
            // output (or vice versa) — loop and try again.
        }
    }
}

/// Compresses to a zstd frame via the `ZSTD_createCStream` /
/// `ZSTD_compressStream2` streaming API, pushing compressed bytes to a
/// caller-supplied sink closure. Mirrors the write side of Go's
/// `github.com/klauspost/compress/zstd` usage in
/// `internal/artifact/writer.go`'s `Pack`. Enables the frame content
/// checksum (`ZSTD_c_checksumFlag`) so corrupted input is reliably
/// detected on decode even when the corruption doesn't itself desync the
/// block structure.
final class ZstdCompressBackend: CompressBackend {
    private let sink: (ArraySlice<UInt8>) throws -> Void
    private let cstream: OpaquePointer
    private var outBuf: [UInt8]
    private var finished = false

    init(sink: @escaping (ArraySlice<UInt8>) throws -> Void) throws {
        guard let cs = ZSTD_createCStream() else { throw ZstdError.initFailed }
        let levelRet = ZSTD_CCtx_setParameter(cs, ZSTD_c_compressionLevel, defaultCompressionLevel)
        let checksumRet = ZSTD_CCtx_setParameter(cs, ZSTD_c_checksumFlag, 1)
        if ZSTD_isError(levelRet) != 0 || ZSTD_isError(checksumRet) != 0 {
            _ = ZSTD_freeCStream(cs)
            throw ZstdError.initFailed
        }
        self.cstream = cs
        self.sink = sink
        self.outBuf = [UInt8](repeating: 0, count: ZSTD_CStreamOutSize())
    }

    deinit {
        _ = ZSTD_freeCStream(cstream)
    }

    func write(_ bytes: ArraySlice<UInt8>) throws {
        guard !bytes.isEmpty else { return }
        try bytes.withUnsafeBytes { raw in
            var pos = 0
            while pos < raw.count {
                let inSlice = UnsafeRawBufferPointer(rebasing: raw[pos...])
                var inBuffer = ZSTD_inBuffer(src: inSlice.baseAddress, size: inSlice.count, pos: 0)
                try pump(&inBuffer, endOp: ZSTD_e_continue)
                pos += inBuffer.pos
            }
        }
    }

    func finish() throws {
        guard !finished else { return }
        finished = true

        var inBuffer = ZSTD_inBuffer(src: nil, size: 0, pos: 0)
        var done = false
        while !done {
            done = try pump(&inBuffer, endOp: ZSTD_e_end)
        }
    }

    /// Runs one `ZSTD_compressStream2` call, pushing any produced bytes to
    /// the sink. Returns whether the operation (flush/end) has fully
    /// drained — i.e. the library returned 0 pending bytes.
    ///
    /// Produced bytes are copied out of `outBuf` and `sink` is invoked only
    /// after `withUnsafeMutableBufferPointer` returns: indexing `outBuf`
    /// for the slice while still inside its own mutable-pointer closure
    /// would be an overlapping access to the same array and trap at
    /// runtime.
    @discardableResult
    private func pump(_ inBuffer: inout ZSTD_inBuffer, endOp: ZSTD_EndDirective) throws -> Bool {
        var isDrained = false
        var produced: [UInt8] = []
        try outBuf.withUnsafeMutableBufferPointer { outPtr in
            var outBuffer = ZSTD_outBuffer(dst: outPtr.baseAddress, size: outPtr.count, pos: 0)
            let ret = ZSTD_compressStream2(cstream, &outBuffer, &inBuffer, endOp)
            if ZSTD_isError(ret) != 0 {
                throw ZstdError.corrupt(String(cString: ZSTD_getErrorName(ret)))
            }
            if outBuffer.pos > 0 {
                produced = Array(UnsafeBufferPointer(rebasing: outPtr[0..<outBuffer.pos]))
            }
            isDrained = (ret == 0)
        }
        if !produced.isEmpty { try sink(produced[...]) }
        return isDrained
    }
}
