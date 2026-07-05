import Testing

import Artifact

/// Wraps a fixed byte buffer in the pull-source closure shape `SparseExpander`
/// / `maybeSparseSource` expect — same convention as `ReaderTests`' own
/// `makeSource` helper for `TarReader`.
private func makeSource(_ bytes: [UInt8]) -> (inout [UInt8], Int) throws -> Int {
    var offset = 0
    return { buf, max in
        guard offset < bytes.count else { return 0 }
        let n = min(max, bytes.count - offset)
        buf = Array(bytes[offset..<(offset + n)])
        offset += n
        return n
    }
}

/// Drains a pull-source closure into a single buffer, pulling at most
/// `chunkSize` bytes per call — `chunkSize: 1` reproduces Go's
/// byte-at-a-time `TestSparseExpandSmallBuffer`.
private func readAll(_ read: (inout [UInt8], Int) throws -> Int, chunkSize: Int = 4096) throws -> [UInt8] {
    var out: [UInt8] = []
    while true {
        var chunk: [UInt8] = []
        let n = try read(&chunk, chunkSize)
        if n == 0 { break }
        out.append(contentsOf: chunk.prefix(n))
    }
    return out
}

private func writeUInt16LE(_ v: UInt16, into b: inout [UInt8]) {
    b.append(UInt8(v & 0xFF))
    b.append(UInt8((v >> 8) & 0xFF))
}

private func writeUInt32LE(_ v: UInt32, into b: inout [UInt8]) {
    b.append(UInt8(v & 0xFF))
    b.append(UInt8((v >> 8) & 0xFF))
    b.append(UInt8((v >> 16) & 0xFF))
    b.append(UInt8((v >> 24) & 0xFF))
}

private let testSparseMagic: UInt32 = 0xed26ff3a
private let testChunkRaw: UInt16 = 0xCAC1
private let testChunkFill: UInt16 = 0xCAC2
private let testChunkDontCare: UInt16 = 0xCAC3
private let testChunkCRC32: UInt16 = 0xCAC4

/// Ports `buildSparse` from sparse_test.go: encodes `rawBlk` into a minimal
/// Android sparse image using all three payload-bearing chunk types (RAW,
/// then DONTCARE, then FILL). `raw` in the returned tuple is laid out as
/// [rawBlk | zeroBlk | fillBlk], each `blkSz` bytes — matching Go's helper
/// exactly so the two implementations are provably byte-for-byte compatible.
private func buildSparse(blkSz: UInt32, rawBlk: [UInt8], fillPattern: [UInt8]) -> (sparse: [UInt8], raw: [UInt8]) {
    precondition(rawBlk.count == Int(blkSz) && fillPattern.count == 4, "bad block/pattern sizes")
    let zeroBlk = [UInt8](repeating: 0, count: Int(blkSz))
    var fillBlk = [UInt8](repeating: 0, count: Int(blkSz))
    for i in 0..<fillBlk.count {
        fillBlk[i] = fillPattern[i & 3]
    }
    let rawImage = rawBlk + zeroBlk + fillBlk

    var b: [UInt8] = []
    // file header (28 bytes)
    writeUInt32LE(testSparseMagic, into: &b)
    writeUInt16LE(1, into: &b) // major
    writeUInt16LE(0, into: &b) // minor
    writeUInt16LE(28, into: &b) // file_hdr_sz
    writeUInt16LE(12, into: &b) // chunk_hdr_sz
    writeUInt32LE(blkSz, into: &b)
    writeUInt32LE(3, into: &b) // total_blks
    writeUInt32LE(3, into: &b) // total_chunks
    writeUInt32LE(0, into: &b) // checksum (ignored)

    // RAW chunk
    writeUInt16LE(testChunkRaw, into: &b)
    writeUInt16LE(0, into: &b)
    writeUInt32LE(1, into: &b) // blks
    writeUInt32LE(UInt32(12) + blkSz, into: &b) // total_sz
    b.append(contentsOf: rawBlk)

    // DONTCARE chunk
    writeUInt16LE(testChunkDontCare, into: &b)
    writeUInt16LE(0, into: &b)
    writeUInt32LE(1, into: &b) // blks
    writeUInt32LE(12, into: &b) // total_sz (no payload)

    // FILL chunk
    writeUInt16LE(testChunkFill, into: &b)
    writeUInt16LE(0, into: &b)
    writeUInt32LE(1, into: &b) // blks
    writeUInt32LE(12 + 4, into: &b) // total_sz
    b.append(contentsOf: fillPattern)

    return (b, rawImage)
}

@Test func sparseExpandsRawDontcareAndFillChunks() throws {
    // Ports TestSparseExpand.
    let blkSz: UInt32 = 4096
    let rawBlk = [UInt8](repeating: 0xAB, count: Int(blkSz))
    let pattern: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]

    let (sparse, wantRaw) = buildSparse(blkSz: blkSz, rawBlk: rawBlk, fillPattern: pattern)

    let read = try maybeSparseSource(makeSource(sparse))
    let got = try readAll(read)
    #expect(got == wantRaw)
}

@Test func sparseExpandsIdenticallyOneByteAtATime() throws {
    // Ports TestSparseExpandSmallBuffer: reading 1 byte at a time must
    // produce the identical stream — guards chunk-boundary handling.
    let blkSz: UInt32 = 4096
    let rawBlk = [UInt8](repeating: 0x5A, count: Int(blkSz))
    let pattern: [UInt8] = [0x01, 0x02, 0x03, 0x04]
    let (sparse, wantRaw) = buildSparse(blkSz: blkSz, rawBlk: rawBlk, fillPattern: pattern)

    let read = try maybeSparseSource(makeSource(sparse))
    let got = try readAll(read, chunkSize: 1)
    #expect(got == wantRaw)
}

@Test func nonSparseInputPassesThroughUnchanged() throws {
    // Ports TestNonSparsePassThrough.
    let raw = Array("not a sparse image, just raw ext4 bytes...".utf8)
    let read = try maybeSparseSource(makeSource(raw))
    let got = try readAll(read)
    #expect(got == raw)
}

@Test func shortInputPassesThroughUnchanged() throws {
    // Ports TestShortInputPassThrough: input shorter than the 4-byte magic.
    let raw: [UInt8] = [1, 2]
    let read = try maybeSparseSource(makeSource(raw))
    let got = try readAll(read)
    #expect(got == raw)
}

// MARK: - Additional coverage beyond sparse_test.go
//
// sparse_test.go's own suite (ported above) never builds a CRC32 chunk or
// exercises the header validation in isolation — `buildSparse` only emits
// RAW/DONTCARE/FILL, and MaybeSparseReader's tests only probe the
// magic-detection short-circuit. The task brief calls out CRC32 and bad
// header handling explicitly as required format coverage, so these round
// out the port.

@Test func sparseSkipsCRC32ChunkWithoutOutput() throws {
    // A CRC32 chunk carries a 4-byte crc payload and contributes zero bytes
    // to the expanded output (sparse.go's nextChunk: `s.rem = 0`).
    let blkSz: UInt32 = 4096
    let rawBlk = [UInt8](repeating: 0x7C, count: Int(blkSz))

    var b: [UInt8] = []
    writeUInt32LE(testSparseMagic, into: &b)
    writeUInt16LE(1, into: &b)
    writeUInt16LE(0, into: &b)
    writeUInt16LE(28, into: &b)
    writeUInt16LE(12, into: &b)
    writeUInt32LE(blkSz, into: &b)
    writeUInt32LE(1, into: &b) // total_blks
    writeUInt32LE(2, into: &b) // total_chunks: RAW + CRC32
    writeUInt32LE(0, into: &b)

    writeUInt16LE(testChunkRaw, into: &b)
    writeUInt16LE(0, into: &b)
    writeUInt32LE(1, into: &b)
    writeUInt32LE(UInt32(12) + blkSz, into: &b)
    b.append(contentsOf: rawBlk)

    writeUInt16LE(testChunkCRC32, into: &b)
    writeUInt16LE(0, into: &b)
    writeUInt32LE(0, into: &b) // blks: CRC32 contributes no output blocks
    writeUInt32LE(12 + 4, into: &b) // total_sz: header + 4-byte crc
    writeUInt32LE(0xDEAD_BEEF, into: &b) // crc value, discarded

    let read = try maybeSparseSource(makeSource(b))
    let got = try readAll(read)
    #expect(got == rawBlk)
}

@Test func sparseExpanderThrowsOnBadMagic() throws {
    // Exercises SparseExpander's own header validation directly (Go:
    // `newSparseReader` returning "sparse: bad magic %#x").
    // MaybeSparseReader-level tests never reach this path since a mismatched
    // magic makes it take the passthrough branch instead.
    var b: [UInt8] = []
    writeUInt32LE(0x1234_5678, into: &b) // not the sparse magic
    b.append(contentsOf: [UInt8](repeating: 0, count: 24)) // pad to 28 bytes

    #expect(throws: SparseError.self) {
        _ = try SparseExpander(makeSource(b))
    }
}

@Test func sparseExpanderThrowsOnInvalidBlockSize() throws {
    // sparse.go rejects blk_sz == 0 or not a multiple of 4 before any chunk
    // is read.
    var b: [UInt8] = []
    writeUInt32LE(testSparseMagic, into: &b)
    writeUInt16LE(1, into: &b)
    writeUInt16LE(0, into: &b)
    writeUInt16LE(28, into: &b)
    writeUInt16LE(12, into: &b)
    writeUInt32LE(5, into: &b) // not a multiple of 4
    writeUInt32LE(0, into: &b)
    writeUInt32LE(0, into: &b)
    writeUInt32LE(0, into: &b)

    #expect(throws: SparseError.self) {
        _ = try SparseExpander(makeSource(b))
    }
}

@Test func isAndroidSparseDetectsMagicAndRejectsOther() throws {
    var magic: [UInt8] = []
    writeUInt32LE(testSparseMagic, into: &magic)
    #expect(isAndroidSparse(magic))
    #expect(isAndroidSparse(magic + [0xFF, 0xFF])) // extra trailing bytes still fine
    #expect(!isAndroidSparse([0x00, 0x00, 0x00, 0x00]))
    #expect(!isAndroidSparse([1, 2])) // too short
}
