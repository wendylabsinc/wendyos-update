import CZstd

/// Window bits requesting gzip-wrapped (not raw or zlib-wrapped) streams
/// for both `inflate`/`deflate`, per zlib's convention of `15 + 16`.
private let gzipWindowBits: Int32 = 15 + 16
/// Recommended chunk size for pulling compressed bytes from the source
/// closure; not load-bearing, just a reasonable syscall/allocation size.
private let pullChunkSize = 64 * 1024

/// Decompresses a gzip stream via zlib's `inflateInit2_`/`inflate` streaming
/// API, pulling compressed bytes from a caller-supplied source closure.
/// Mirrors the read side of Go's `compress/gzip` usage in
/// `internal/blockdev/blockdev.go`'s `Decompressor`.
final class GzipDecompressBackend: DecompressBackend {
    private let source: (inout [UInt8], Int) throws -> Int
    private var strm = z_stream()

    private var pending: [UInt8] = []
    private var pendingPos = 0
    private var sourceExhausted = false
    private var finished = false

    init(source: @escaping (inout [UInt8], Int) throws -> Int) throws {
        self.source = source
        let ret = inflateInit2_(&strm, gzipWindowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        if ret != Z_OK { throw ZstdError.initFailed }
    }

    deinit {
        _ = inflateEnd(&strm)
    }

    func read(into buf: inout [UInt8]) throws -> Int {
        guard !buf.isEmpty else { return 0 }
        if finished { return 0 }

        while true {
            if pendingPos == pending.count && !sourceExhausted {
                var chunk: [UInt8] = []
                let got = try source(&chunk, pullChunkSize)
                if got == 0 {
                    sourceExhausted = true
                } else {
                    pending = chunk
                    pendingPos = 0
                }
            }

            var ret: Int32 = Z_OK
            var produced = 0
            var consumed = 0

            buf.withUnsafeMutableBufferPointer { outPtr in
                pending.withUnsafeMutableBufferPointer { fullIn in
                    let inPtr = UnsafeMutableBufferPointer(rebasing: fullIn[pendingPos...])
                    strm.next_in = inPtr.baseAddress
                    strm.avail_in = UInt32(inPtr.count)
                    strm.next_out = outPtr.baseAddress
                    strm.avail_out = UInt32(outPtr.count)

                    ret = inflate(&strm, Z_NO_FLUSH)

                    consumed = inPtr.count - Int(strm.avail_in)
                    produced = outPtr.count - Int(strm.avail_out)
                }
            }

            pendingPos += consumed

            if ret == Z_STREAM_END {
                finished = true
                return produced
            }
            if ret != Z_OK && ret != Z_BUF_ERROR {
                let message = strm.msg.map { String(cString: $0) } ?? "zlib inflate error \(ret)"
                throw ZstdError.corrupt(message)
            }

            if produced > 0 { return produced }

            if sourceExhausted && pendingPos == pending.count {
                // Out of compressed bytes without having reached
                // Z_STREAM_END: the gzip stream was truncated.
                throw ZstdError.corrupt("truncated gzip stream")
            }
            // Otherwise: no output yet but progress is still possible
            // (need more input) — loop and try again.
        }
    }
}

/// Compresses to a gzip stream via zlib's `deflateInit2_`/`deflate`
/// streaming API, pushing compressed bytes to a caller-supplied sink
/// closure. Mirrors the write side of Go's `compress/gzip` usage in
/// `internal/artifact/writer.go`'s `Pack`.
final class GzipCompressBackend: CompressBackend {
    private let sink: (ArraySlice<UInt8>) throws -> Void
    private var strm = z_stream()
    private var outBuf: [UInt8]
    private var finished = false

    init(sink: @escaping (ArraySlice<UInt8>) throws -> Void) throws {
        self.sink = sink
        self.outBuf = [UInt8](repeating: 0, count: pullChunkSize)
        let ret = deflateInit2_(
            &strm,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            gzipWindowBits,
            8, // default memLevel
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        if ret != Z_OK { throw ZstdError.initFailed }
    }

    deinit {
        _ = deflateEnd(&strm)
    }

    func write(_ bytes: ArraySlice<UInt8>) throws {
        guard !bytes.isEmpty else { return }
        try bytes.withUnsafeBufferPointer { fullIn in
            var pos = 0
            while pos < fullIn.count {
                let inPtr = UnsafeBufferPointer(rebasing: fullIn[pos...])
                let consumed = try pump(inputBase: inPtr.baseAddress, inputCount: inPtr.count, flush: Z_NO_FLUSH)
                pos += consumed
            }
        }
    }

    func finish() throws {
        guard !finished else { return }
        finished = true

        var done = false
        while !done {
            let ret = try pumpFinish()
            done = (ret == Z_STREAM_END)
        }
    }

    /// Runs one `deflate` call over `inputCount` bytes at `inputBase` with
    /// the given flush mode, pushing any produced bytes to the sink.
    /// Returns the number of input bytes actually consumed.
    ///
    /// Produced bytes are copied out of `outBuf` and `sink` is invoked only
    /// after `withUnsafeMutableBufferPointer` returns: calling `sink` (which
    /// may itself touch `outBuf` indirectly, or simply take a while) from
    /// inside that closure while also indexing `outBuf` for the slice would
    /// be an overlapping access to the same array and trap at runtime.
    private func pump(inputBase: UnsafePointer<UInt8>?, inputCount: Int, flush: Int32) throws -> Int {
        var consumed = 0
        var produced: [UInt8] = []
        try outBuf.withUnsafeMutableBufferPointer { outPtr in
            strm.next_in = UnsafeMutablePointer(mutating: inputBase)
            strm.avail_in = UInt32(inputCount)
            strm.next_out = outPtr.baseAddress
            strm.avail_out = UInt32(outPtr.count)

            let ret = deflate(&strm, flush)
            if ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR {
                let message = strm.msg.map { String(cString: $0) } ?? "zlib deflate error \(ret)"
                throw ZstdError.corrupt(message)
            }

            let producedCount = outPtr.count - Int(strm.avail_out)
            if producedCount > 0 {
                produced = Array(UnsafeBufferPointer(rebasing: outPtr[0..<producedCount]))
            }
            consumed = inputCount - Int(strm.avail_in)
        }
        if !produced.isEmpty { try sink(produced[...]) }
        return consumed
    }

    /// Runs one `deflate(Z_FINISH)` call with no new input, to flush and
    /// finalize the gzip trailer. Returns the raw zlib return code so the
    /// caller can loop until `Z_STREAM_END`. See `pump(inputBase:inputCount:flush:)`
    /// for why `sink` is invoked after the unsafe-pointer closure returns.
    private func pumpFinish() throws -> Int32 {
        var result: Int32 = Z_OK
        var produced: [UInt8] = []
        try outBuf.withUnsafeMutableBufferPointer { outPtr in
            strm.next_in = nil
            strm.avail_in = 0
            strm.next_out = outPtr.baseAddress
            strm.avail_out = UInt32(outPtr.count)

            let ret = deflate(&strm, Z_FINISH)
            if ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR {
                let message = strm.msg.map { String(cString: $0) } ?? "zlib deflate error \(ret)"
                throw ZstdError.corrupt(message)
            }

            let producedCount = outPtr.count - Int(strm.avail_out)
            if producedCount > 0 {
                produced = Array(UnsafeBufferPointer(rebasing: outPtr[0..<producedCount]))
            }
            result = ret
        }
        if !produced.isEmpty { try sink(produced[...]) }
        return result
    }
}
