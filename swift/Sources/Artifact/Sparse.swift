// Streaming expander for the Android sparse image format (the
// `.ext4.simg` that Tegra/AOSP flashing tools produce). It expands to the
// raw image on the fly so the packer can treat a sparse input exactly like
// a raw one — no external simg2img, works on host, CI, and device alike.
//
// Format (little-endian), per AOSP system/core/libsparse/sparse_format.h —
// ports `internal/artifact/sparse.go`:
//
//   file header (28 bytes):
//     magic            uint32  0xed26ff3a
//     major, minor     uint16  (1, 0)
//     file_hdr_sz      uint16  (28)
//     chunk_hdr_sz     uint16  (12)
//     blk_sz           uint32  (multiple of 4, e.g. 4096)
//     total_blks       uint32  blocks in the output image
//     total_chunks     uint32
//     image_checksum   uint32  (crc32; not verified here — the artifact
//                               carries its own sha256)
//   then total_chunks chunks, each a 12-byte header:
//     chunk_type       uint16  RAW 0xCAC1 | FILL 0xCAC2 | DONTCARE 0xCAC3 | CRC32 0xCAC4
//     reserved         uint16
//     chunk_blks       uint32  output blocks this chunk expands to
//     total_sz         uint32  chunk header + payload on disk
//   payloads:
//     RAW      -> chunk_blks*blk_sz raw bytes
//     FILL     -> 4-byte pattern, repeated to fill chunk_blks*blk_sz
//     DONTCARE -> no payload; emit chunk_blks*blk_sz zero bytes
//     CRC32    -> 4-byte crc; no output

/// Everything that can go wrong while parsing an Android sparse image
/// stream. sparse.go doesn't define sentinel error values for this format
/// (every failure is a `fmt.Errorf`-wrapped string) — a message-only struct
/// is the direct port of that shape, rather than splitting these into a
/// case-per-failure enum Go itself doesn't distinguish.
public struct SparseError: Error, Equatable {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }
}

private let sparseMagic: UInt32 = 0xed26ff3a

private let chunkRaw: UInt16 = 0xCAC1
private let chunkFill: UInt16 = 0xCAC2
private let chunkDontCare: UInt16 = 0xCAC3
private let chunkCRC32: UInt16 = 0xCAC4

/// Reports whether `firstBytes` begins with the Android sparse image magic
/// (`0xed26ff3a`, little-endian). Mirrors sparse.go's `isSparseMagic`.
public func isAndroidSparse(_ firstBytes: [UInt8]) -> Bool {
    guard firstBytes.count >= 4 else { return false }
    let magic =
        UInt32(firstBytes[0])
        | (UInt32(firstBytes[1]) << 8)
        | (UInt32(firstBytes[2]) << 16)
        | (UInt32(firstBytes[3]) << 24)
    return magic == sparseMagic
}

/// Mirrors sparse.go's `MaybeSparseReader`: peeks up to the first 4 bytes
/// pulled from `source`. If they are the Android sparse magic, returns a
/// pull closure that expands the sparse image on the fly; otherwise returns
/// a pull closure equivalent to `source`, with the peeked bytes replayed
/// first so non-sparse input (including input shorter than the 4-byte
/// magic) passes through unchanged.
///
/// `source` follows the same pull-source convention as `TarReader`/
/// `Zstd*Backend`: fills `into` with up to `max` bytes and returns the
/// count actually read; 0 means the source is exhausted.
public func maybeSparseSource(
    _ source: @escaping (_ into: inout [UInt8], _ max: Int) throws -> Int
) throws -> (_ into: inout [UInt8], _ max: Int) throws -> Int {
    var peeked: [UInt8] = []
    while peeked.count < 4 {
        var chunk: [UInt8] = []
        let got = try source(&chunk, 4 - peeked.count)
        if got == 0 { break } // exhausted before 4 bytes -> too short to be sparse
        peeked.append(contentsOf: chunk.prefix(got))
    }

    let replayed = replaySource(prefix: peeked, then: source)

    guard isAndroidSparse(peeked) else {
        return replayed
    }

    let expander = try SparseExpander(replayed)
    return { buf, max in
        var chunk = [UInt8](repeating: 0, count: max)
        let n = try expander.read(into: &chunk)
        buf = Array(chunk.prefix(n))
        return n
    }
}

/// Wraps `then` so the first bytes pulled are `prefix`, then falls through
/// to `then` once `prefix` is exhausted. Used to replay the bytes
/// `maybeSparseSource` peeked (to classify the stream) back into it,
/// without requiring the pull-source convention to support push-back.
private func replaySource(
    prefix: [UInt8], then: @escaping (_ into: inout [UInt8], _ max: Int) throws -> Int
) -> (_ into: inout [UInt8], _ max: Int) throws -> Int {
    var pos = 0
    return { buf, max in
        if pos < prefix.count {
            let n = min(max, prefix.count - pos)
            buf = Array(prefix[pos..<(pos + n)])
            pos += n
            return n
        }
        return try then(&buf, max)
    }
}

/// Streaming expander for an Android sparse image, pulling sparse-encoded
/// bytes from a caller-supplied source closure (same pull convention as
/// `TarReader`/`Zstd*Backend`) and exposing the expanded raw bytes through
/// `read(into:)`. Ports sparse.go's `sparseReader`.
///
/// Construct directly when the input is already known to be sparse, or via
/// `maybeSparseSource` when it might not be.
public final class SparseExpander {
    private enum Mode {
        case raw
        case fill
        case zero
    }

    private let source: (_ into: inout [UInt8], _ max: Int) throws -> Int
    private let blkSz: UInt32
    private var chunksLeft: UInt32

    /// Bytes left to emit for the chunk currently being read.
    private var remaining: Int64 = 0
    private var mode: Mode = .zero
    private var fillPattern: [UInt8] = [0, 0, 0, 0]
    private var fillPos = 0

    /// Reads and validates the 28-byte file header. Throws `SparseError` if
    /// the magic doesn't match or the declared block size is invalid.
    public init(_ source: @escaping (_ into: inout [UInt8], _ max: Int) throws -> Int) throws {
        self.source = source

        let header = try Self.readExact(source, 28, whileReading: "read header")
        let magic = Self.uint32LE(header, 0)
        guard magic == sparseMagic else {
            throw SparseError("sparse: bad magic 0x\(String(magic, radix: 16))")
        }
        let fileHdrSz = Self.uint16LE(header, 8)
        let blkSzValue = Self.uint32LE(header, 12)
        let totalChunks = Self.uint32LE(header, 20)

        guard blkSzValue != 0, blkSzValue % 4 == 0 else {
            throw SparseError("sparse: invalid block size \(blkSzValue)")
        }

        self.blkSz = blkSzValue
        self.chunksLeft = totalChunks

        // Skip any extra header bytes the producer declared beyond the 28
        // we read.
        let extra = Int(fileHdrSz) - 28
        if extra > 0 {
            try Self.discard(source, extra, whileReading: "skip header tail")
        }
    }

    /// Reads up to `buf.count` bytes of the expanded raw image into `buf`
    /// (filling from index 0), returning the number of bytes read. Returns
    /// 0 once every chunk has been expanded.
    public func read(into buf: inout [UInt8]) throws -> Int {
        guard !buf.isEmpty else { return 0 }
        while true {
            if remaining > 0 {
                return try emit(into: &buf)
            }
            if chunksLeft == 0 {
                return 0
            }
            try nextChunk()
        }
    }

    private func nextChunk() throws {
        let header = try Self.readExact(source, 12, whileReading: "read chunk header")
        let type = Self.uint16LE(header, 0)
        let blks = Self.uint32LE(header, 4)
        let totalSz = Self.uint32LE(header, 8)
        chunksLeft -= 1

        let outBytes = Int64(blks) * Int64(blkSz)
        let payload = Int64(totalSz) - 12

        switch type {
        case chunkRaw:
            guard payload == outBytes else {
                throw SparseError("sparse: raw chunk payload \(payload) != output \(outBytes)")
            }
            remaining = outBytes
            mode = .raw
        case chunkFill:
            guard payload == 4 else {
                throw SparseError("sparse: fill chunk payload \(payload) != 4")
            }
            fillPattern = try Self.readExact(source, 4, whileReading: "read fill pattern")
            remaining = outBytes
            fillPos = 0
            mode = .fill
        case chunkDontCare:
            if payload != 0 {
                // Some producers store a payload they don't use; discard it.
                try Self.discard(source, Int(payload), whileReading: "skip dontcare payload")
            }
            remaining = outBytes
            mode = .zero
        case chunkCRC32:
            try Self.discard(source, Int(payload), whileReading: "skip crc32")
            remaining = 0 // no output
        default:
            throw SparseError("sparse: unknown chunk type 0x\(String(type, radix: 16))")
        }
    }

    private func emit(into buf: inout [UInt8]) throws -> Int {
        let want = Int(min(remaining, Int64(buf.count)))
        switch mode {
        case .raw:
            var chunk: [UInt8] = []
            let got = try source(&chunk, want)
            if got == 0 {
                throw SparseError("sparse: unexpected EOF in raw chunk")
            }
            for i in 0..<got {
                buf[i] = chunk[i]
            }
            remaining -= Int64(got)
            return got
        case .fill:
            for i in 0..<want {
                buf[i] = fillPattern[fillPos]
                fillPos = (fillPos + 1) & 3
            }
            remaining -= Int64(want)
            return want
        case .zero:
            for i in 0..<want {
                buf[i] = 0
            }
            remaining -= Int64(want)
            return want
        }
    }

    /// Reads exactly `n` bytes from `source`, looping over partial reads.
    /// Throws `SparseError` on a short read (source exhausted before `n`
    /// bytes were available) — sparse.go's equivalent `binary.Read`/
    /// `io.ReadFull` failures.
    private static func readExact(
        _ source: (_ into: inout [UInt8], _ max: Int) throws -> Int,
        _ n: Int,
        whileReading context: String
    ) throws -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(n)
        while result.count < n {
            var chunk: [UInt8] = []
            let got = try source(&chunk, n - result.count)
            if got == 0 {
                throw SparseError("sparse: \(context): unexpected EOF")
            }
            result.append(contentsOf: chunk.prefix(got))
        }
        return result
    }

    /// Discards exactly `n` bytes from `source`. Mirrors sparse.go's use of
    /// `io.CopyN(io.Discard, ...)` to skip a chunk's unused payload.
    private static func discard(
        _ source: (_ into: inout [UInt8], _ max: Int) throws -> Int,
        _ n: Int,
        whileReading context: String
    ) throws {
        var toSkip = n
        while toSkip > 0 {
            var chunk: [UInt8] = []
            let got = try source(&chunk, toSkip)
            if got == 0 {
                throw SparseError("sparse: \(context): unexpected EOF")
            }
            toSkip -= got
        }
    }

    private static func uint16LE(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func uint32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
