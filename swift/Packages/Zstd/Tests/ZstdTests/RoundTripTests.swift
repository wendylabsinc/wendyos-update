import Testing

@testable import Zstd

/// Deterministic pseudorandom byte generator (a simple linear congruential
/// generator), so compression round-trip tests exercise ~1 MiB of
/// non-trivial, non-repeating data without depending on `Swift.random`.
private func lcgBuffer(count: Int, seed: UInt64 = 0x1234_5678_9abc_def0) -> [UInt8] {
    var state = seed
    var bytes = [UInt8]()
    bytes.reserveCapacity(count)
    while bytes.count < count {
        // Numerical Recipes LCG constants.
        state = 6_364_136_223_846_793_005 &* state &+ 1_442_695_040_888_963_407
        withUnsafeBytes(of: state) { bytes.append(contentsOf: $0) }
    }
    bytes.removeLast(bytes.count - count)
    return bytes
}

/// Wraps a fixed byte buffer in the pull-source closure shape
/// `DecompressStream` expects: fill `into` with up to `max` bytes, return
/// the count read (0 == EOF).
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

/// Compresses `plain` under `compression`, returning the compressed bytes.
private func compress(_ plain: [UInt8], _ compression: Compression) throws -> [UInt8] {
    var out = [UInt8]()
    let stream = CompressStream(compression) { chunk in out.append(contentsOf: chunk) }
    // Feed in odd-sized chunks to exercise multi-call streaming, not just a
    // single one-shot write.
    var offset = 0
    let chunkSize = 65_537 // deliberately not a power of two
    while offset < plain.count {
        let end = min(offset + chunkSize, plain.count)
        try stream.write(plain[offset..<end])
        offset = end
    }
    try stream.finish()
    return out
}

/// Decompresses `compressed` under `compression`, returning the plaintext.
private func decompress(_ compressed: [UInt8], _ compression: Compression) throws -> [UInt8] {
    let stream = DecompressStream(compression, source: makeSource(compressed))
    var out = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = try stream.read(into: &buf)
        if n == 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}

@Test func zstdRoundTripsOneMebibyte() throws {
    let plain = lcgBuffer(count: 1 << 20)
    let compressed = try compress(plain, .zstd)
    let recovered = try decompress(compressed, .zstd)
    #expect(recovered == plain)
}

@Test func gzipRoundTripsOneMebibyte() throws {
    let plain = lcgBuffer(count: 1 << 20)
    let compressed = try compress(plain, .gzip)
    let recovered = try decompress(compressed, .gzip)
    #expect(recovered == plain)
}

@Test func noneRoundTripsOneMebibyte() throws {
    let plain = lcgBuffer(count: 1 << 20)
    let compressed = try compress(plain, .none)
    #expect(compressed == plain)
    let recovered = try decompress(compressed, .none)
    #expect(recovered == plain)
}

@Test func corruptZstdInputThrowsCorrupt() throws {
    let plain = lcgBuffer(count: 1 << 20)
    var compressed = try compress(plain, .zstd)
    // Flip bytes well past the frame header/magic so the corruption is
    // caught by the content checksum / block decode, not the initial
    // magic-number check (which would also be a valid failure, but this
    // exercises more of the streaming decode path).
    for i in 8..<min(compressed.count, 64) {
        compressed[i] ^= 0xff
    }

    #expect(throws: ZstdError.self) {
        _ = try decompress(compressed, .zstd)
    }
}

@Test func corruptGzipInputThrowsCorrupt() throws {
    let plain = lcgBuffer(count: 1 << 20)
    var compressed = try compress(plain, .gzip)
    for i in 20..<min(compressed.count, 64) {
        compressed[i] ^= 0xff
    }

    #expect(throws: ZstdError.self) {
        _ = try decompress(compressed, .gzip)
    }
}
