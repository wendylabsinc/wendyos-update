import Crypto
import Testing

import BlockDev
import PlatformIO
import PlatformIOTesting
import Zstd

/// Deterministic pseudorandom byte generator (a linear congruential
/// generator), matching the convention `ArtifactTests`/`ZstdTests` use for
/// non-trivial, non-repeating fixture data.
private func lcgBuffer(count: Int, seed: UInt64 = 0x0BAD_F00D_DEAD_BEEF) -> [UInt8] {
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

/// Wraps a fixed byte buffer in the pull-source closure shape
/// `BlockDev.writeImage` expects: fill `into` with up to `max` bytes,
/// return the count read (0 == EOF).
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
    // Feed in odd-sized chunks to exercise multi-call streaming.
    var offset = 0
    let chunkSize = 65_537
    while offset < plain.count {
        let end = min(offset + chunkSize, plain.count)
        try stream.write(plain[offset..<end])
        offset = end
    }
    try stream.finish()
    return out
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

@Test func writeImageDecompressesZstdAndComputesRollingDigest() throws {
    let plain = lcgBuffer(count: 5_000)
    let compressed = try compress(plain, .zstd)
    let target = FakeBlockTarget()
    var progressCalls: [Int64] = []

    let (written, digest) = try BlockDev.writeImage(
        to: "/dev/fake-zstd",
        from: makeSource(compressed),
        compression: .zstd,
        target: target,
        progress: { progressCalls.append($0) }
    )

    #expect(written == Int64(plain.count))
    #expect(digest == sha256Hex(plain))
    #expect(target.devices["/dev/fake-zstd"]?.written == plain)
    #expect(target.devices["/dev/fake-zstd"]?.syncCount == 1)
    #expect(!progressCalls.isEmpty)
    #expect(progressCalls == progressCalls.sorted())
    #expect(progressCalls.last == Int64(plain.count))
}

@Test func writeImageDecompressesGzipAndComputesRollingDigest() throws {
    let plain = lcgBuffer(count: 4_096)
    let compressed = try compress(plain, .gzip)
    let target = FakeBlockTarget()

    let (written, digest) = try BlockDev.writeImage(
        to: "/dev/fake-gzip",
        from: makeSource(compressed),
        compression: .gzip,
        target: target,
        progress: { _ in }
    )

    #expect(written == Int64(plain.count))
    #expect(digest == sha256Hex(plain))
    #expect(target.devices["/dev/fake-gzip"]?.written == plain)
    #expect(target.devices["/dev/fake-gzip"]?.syncCount == 1)
}

@Test func writeImagePassesThroughUncompressedBytes() throws {
    let plain = lcgBuffer(count: 2_048)
    let target = FakeBlockTarget()

    let (written, digest) = try BlockDev.writeImage(
        to: "/dev/fake-none",
        from: makeSource(plain),
        compression: .none,
        target: target,
        progress: { _ in }
    )

    #expect(written == Int64(plain.count))
    #expect(digest == sha256Hex(plain))
    #expect(target.devices["/dev/fake-none"]?.written == plain)
    #expect(target.devices["/dev/fake-none"]?.syncCount == 1)
}

@Test func writeImageReportsIncreasingProgressAcrossMultipleBuffers() throws {
    // Larger than the 1 MiB internal copy buffer so the loop iterates
    // multiple times, each call reporting a strictly increasing total.
    let plain = lcgBuffer(count: (1 << 20) * 2 + 12_345)
    let target = FakeBlockTarget()
    var progressCalls: [Int64] = []

    let (written, _) = try BlockDev.writeImage(
        to: "/dev/fake-progress",
        from: makeSource(plain),
        compression: .none,
        target: target,
        progress: { progressCalls.append($0) }
    )

    #expect(written == Int64(plain.count))
    #expect(progressCalls.count >= 3)
    for (earlier, later) in zip(progressCalls, progressCalls.dropFirst()) {
        #expect(later > earlier)
    }
    #expect(progressCalls.last == Int64(plain.count))
}

@Test func writeImageWrapsCorruptZstdAsReadPayloadError() throws {
    let plain = lcgBuffer(count: 1 << 16)
    var compressed = try compress(plain, .zstd)
    for i in 8..<min(compressed.count, 64) {
        compressed[i] ^= 0xff
    }
    let target = FakeBlockTarget()

    do {
        _ = try BlockDev.writeImage(
            to: "/dev/fake-corrupt",
            from: makeSource(compressed),
            compression: .zstd,
            target: target,
            progress: { _ in }
        )
        Issue.record("expected writeImage to throw on corrupt zstd input")
    } catch let error as BlockDevError {
        guard case .readPayload = error else {
            Issue.record("expected .readPayload, got \(error)")
            return
        }
    }
}

@Test func writeImageThrowsOpenTargetForMissingDevice() {
    let target = RealBlockTarget()

    do {
        _ = try BlockDev.writeImage(
            to: "/nonexistent-blockdev-test-dir/should-not-exist",
            from: makeSource([1, 2, 3]),
            compression: .none,
            target: target,
            progress: { _ in }
        )
        Issue.record("expected writeImage to throw for a missing device node")
    } catch let error as BlockDevError {
        guard case .openTarget = error else {
            Issue.record("expected .openTarget, got \(error)")
            return
        }
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func deviceCapacityDelegatesToTarget() throws {
    let target = FakeBlockTarget()
    target.capacities["/dev/fake-capacity"] = 123_456_789

    let capacity = try BlockDev.deviceCapacity("/dev/fake-capacity", target: target)

    #expect(capacity == 123_456_789)
}
