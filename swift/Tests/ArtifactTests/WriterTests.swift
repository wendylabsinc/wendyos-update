import Crypto
import Glibc
import Testing

import Artifact
import Model
import Tar
import Zstd

/// Collects everything written by `ArtifactWriter.pack`'s sink into a
/// single in-memory buffer — the "here's the .wendy file" side of the
/// round trip. Mirrors `ReaderTests`' own `ByteSink`.
private final class ByteSink {
    private(set) var bytes: [UInt8] = []

    func write(_ chunk: [UInt8]) {
        bytes.append(contentsOf: chunk)
    }
}

/// Wraps a fixed byte buffer in the pull-source closure shape `TarReader`
/// expects. Mirrors `ReaderTests`' own `makeSource`.
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

private func hexEncode<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    var out = ""
    out.reserveCapacity(64)
    for byte in digest {
        out.append(hexDigitChar(byte >> 4))
        out.append(hexDigitChar(byte & 0x0F))
    }
    return out
}

private func hexDigitChar(_ nibble: UInt8) -> Character {
    nibble < 10
        ? Character(UnicodeScalar(UInt8(ascii: "0") + nibble))
        : Character(UnicodeScalar(UInt8(ascii: "a") + (nibble - 10)))
}

private func sha256Hex(_ bytes: [UInt8]) -> String {
    var h = SHA256()
    h.update(data: bytes)
    return hexEncode(h.finalize())
}

/// Deterministic pseudorandom byte generator (a linear congruential
/// generator), so the fixture "rootfs image" isn't trivially repetitive —
/// ports the same generator `ZstdTests/RoundTripTests.swift` uses.
private func lcgBuffer(count: Int, seed: UInt64 = 0xC0FF_EE12_3456_789A) -> [UInt8] {
    var state = seed
    var bytes = [UInt8]()
    bytes.reserveCapacity(count)
    while bytes.count < count {
        state = 6_364_136_223_846_793_005 &* state &+ 1_442_695_040_888_963_407
        withUnsafeBytes(of: state) { bytes.append(contentsOf: $0) }
    }
    bytes.removeLast(bytes.count - count)
    return bytes
}

/// Writes `bytes` to a fresh regular file under /tmp (named
/// `writer-test-<pid>-<tag>-<random><suffix>`) and returns its path —
/// stands in for "the rootfs image on disk" that `ArtifactWriter.pack`
/// reads via its `imagePath`. The caller is responsible for unlinking it.
private func writeFixtureImage(_ bytes: [UInt8], tag: String, suffix: String = "") -> String {
    let path = "/tmp/writer-test-\(getpid())-\(tag)-\(Int.random(in: 0..<1_000_000))\(suffix)"
    let fd = Glibc.open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    precondition(fd >= 0, "failed to create fixture image at \(path), errno \(errno)")
    bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = Glibc.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            precondition(n > 0, "short write to fixture image at \(path)")
            offset += n
        }
    }
    Glibc.close(fd)
    return path
}

/// Reads a `PayloadStream` fully through `compression`'s decompressor,
/// returning the recovered plaintext — the same decode path a device takes
/// installing a real artifact (and the Swift equivalent of pack.go's
/// `verifyPacked`, minus the digest check which is done separately via
/// `verifyPayloadDigests`).
private func decompressPayload(_ stream: PayloadStream, _ compression: Compression) throws -> [UInt8] {
    let source: (inout [UInt8], Int) throws -> Int = { buf, max in
        var chunk = [UInt8](repeating: 0, count: max)
        let n = try stream.read(into: &chunk)
        buf = Array(chunk.prefix(n))
        return n
    }
    let decompressor = DecompressStream(compression, source: source)
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = try decompressor.read(into: &buf)
        if n == 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}

private func testOptions(imagePath: String, compression: Compression) -> PackOptions {
    PackOptions(
        imagePath: imagePath,
        artifactName: "wendyos-image-test-9.9.9",
        artifactVersion: "9.9.9",
        compatibleDevices: ["jetson-agx-thor"],
        compression: compression,
        minToolVersion: "0.1.0"
    )
}

/// The core round trip: pack a fixture image, then read it back exactly as
/// a device would (manifest parse, payload decompress, digest verify).
/// Ports `TestPackReadRoundTrip` from writer_test.go for one compression
/// scheme.
private func assertPackRoundTrips(_ compression: Compression) throws {
    let image = lcgBuffer(count: 200_003) // deliberately not a round number
    let path = writeFixtureImage(image, tag: compression.rawValue)
    defer { unlink(path) }

    let sink = ByteSink()
    let manifest = try ArtifactWriter.pack(to: { sink.write($0) }, testOptions(imagePath: path, compression: compression))

    #expect(manifest.payload.size == Int64(image.count))
    #expect(manifest.payload.compression == compression.rawValue)
    #expect(manifest.payload.sha256 == sha256Hex(image))
    #expect(manifest.artifactName == "wendyos-image-test-9.9.9")

    let reader = try ArtifactReader.open(TarReader(makeSource(sink.bytes)))
    #expect(reader.manifest == manifest)

    let stream = try reader.payload()
    let recovered = try decompressPayload(stream, compression)
    #expect(recovered == image)

    try reader.verifyPayloadDigests(uncompressedSHA256: sha256Hex(image))
}

@Test func packThenReadRoundTripsWithZstdCompression() throws {
    try assertPackRoundTrips(.zstd)
}

@Test func packThenReadRoundTripsWithGzipCompression() throws {
    try assertPackRoundTrips(.gzip)
}

@Test func packThenReadRoundTripsWithNoCompression() throws {
    try assertPackRoundTrips(.none)
}

@Test func noneCompressionStoresThePayloadUncompressed() throws {
    // With compression "none" the stored (tar member) bytes must equal the
    // raw image bytes exactly -- proves `Pack` doesn't run every scheme
    // through some encoder unconditionally.
    let image = lcgBuffer(count: 4096)
    let path = writeFixtureImage(image, tag: "none-passthrough")
    defer { unlink(path) }

    let sink = ByteSink()
    _ = try ArtifactWriter.pack(to: { sink.write($0) }, testOptions(imagePath: path, compression: .none))

    let reader = try ArtifactReader.open(TarReader(makeSource(sink.bytes)))
    let stream = try reader.payload()
    var stored: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = try stream.read(into: &buf)
        if n == 0 { break }
        stored.append(contentsOf: buf[0..<n])
    }
    #expect(stored == image)
}

@Test func packRejectsEmptyCompatibleDevices() throws {
    let path = writeFixtureImage(Array("x".utf8), tag: "empty-devices")
    defer { unlink(path) }

    let opts = PackOptions(
        imagePath: path,
        artifactName: "a",
        artifactVersion: "1",
        compatibleDevices: [],
        compression: .none
    )
    #expect(throws: ArtifactError.self) {
        _ = try ArtifactWriter.pack(to: { _ in }, opts)
    }
}

@Test func packThrowsWhenImageIsMissing() throws {
    let opts = testOptions(imagePath: "/tmp/writer-test-does-not-exist-\(getpid())", compression: .none)
    #expect(throws: (any Error).self) {
        _ = try ArtifactWriter.pack(to: { _ in }, opts)
    }
}

/// Little-endian helpers for hand-building an Android sparse image, ported
/// from `SparseTests.swift`'s own (private to that file) helpers.
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
private let testChunkDontCare: UInt16 = 0xCAC3
private let testChunkFill: UInt16 = 0xCAC2

/// Builds a minimal Android sparse image (RAW + DONTCARE + FILL, one block
/// each) and the raw image it expands to. Ported from `SparseTests.swift`'s
/// `buildSparse`.
private func buildSparseImage(blkSz: UInt32, rawBlk: [UInt8], fillPattern: [UInt8]) -> (sparse: [UInt8], raw: [UInt8]) {
    let zeroBlk = [UInt8](repeating: 0, count: Int(blkSz))
    var fillBlk = [UInt8](repeating: 0, count: Int(blkSz))
    for i in 0..<fillBlk.count {
        fillBlk[i] = fillPattern[i & 3]
    }
    let rawImage = rawBlk + zeroBlk + fillBlk

    var b: [UInt8] = []
    writeUInt32LE(testSparseMagic, into: &b)
    writeUInt16LE(1, into: &b) // major
    writeUInt16LE(0, into: &b) // minor
    writeUInt16LE(28, into: &b) // file_hdr_sz
    writeUInt16LE(12, into: &b) // chunk_hdr_sz
    writeUInt32LE(blkSz, into: &b)
    writeUInt32LE(3, into: &b) // total_blks
    writeUInt32LE(3, into: &b) // total_chunks
    writeUInt32LE(0, into: &b) // checksum (ignored)

    writeUInt16LE(testChunkRaw, into: &b)
    writeUInt16LE(0, into: &b)
    writeUInt32LE(1, into: &b)
    writeUInt32LE(UInt32(12) + blkSz, into: &b)
    b.append(contentsOf: rawBlk)

    writeUInt16LE(testChunkDontCare, into: &b)
    writeUInt16LE(0, into: &b)
    writeUInt32LE(1, into: &b)
    writeUInt32LE(12, into: &b)

    writeUInt16LE(testChunkFill, into: &b)
    writeUInt16LE(0, into: &b)
    writeUInt32LE(1, into: &b)
    writeUInt32LE(12 + 4, into: &b)
    b.append(contentsOf: fillPattern)

    return (b, rawImage)
}

@Test func packExpandsAnAndroidSparseImageToRawPayload() throws {
    let blkSz: UInt32 = 4096
    let rawBlk = [UInt8](repeating: 0x42, count: Int(blkSz))
    let pattern: [UInt8] = [0x11, 0x22, 0x33, 0x44]
    let (sparseBytes, rawImage) = buildSparseImage(blkSz: blkSz, rawBlk: rawBlk, fillPattern: pattern)

    // Name ends in ".simg" so this test also exercises the payload-name
    // suffix stripping (the stored payload is the expanded raw image, so
    // its name should not carry the sparse-specific suffix).
    let path = writeFixtureImage(sparseBytes, tag: "sparse", suffix: ".ext4.simg")
    defer { unlink(path) }

    let sink = ByteSink()
    let manifest = try ArtifactWriter.pack(to: { sink.write($0) }, testOptions(imagePath: path, compression: .none))

    #expect(manifest.payload.size == Int64(rawImage.count))
    #expect(manifest.payload.sha256 == sha256Hex(rawImage))
    #expect(!manifest.payload.name.contains(".simg"))
    #expect(manifest.payload.name.hasSuffix(".ext4"))

    let reader = try ArtifactReader.open(TarReader(makeSource(sink.bytes)))
    let stream = try reader.payload()
    var stored: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = try stream.read(into: &buf)
        if n == 0 { break }
        stored.append(contentsOf: buf[0..<n])
    }
    #expect(stored == rawImage)
}
