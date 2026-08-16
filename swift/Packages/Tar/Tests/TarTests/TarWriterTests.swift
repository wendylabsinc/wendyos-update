import Testing

@testable import Tar

/// Collects everything written by a `TarWriter` into a single byte buffer,
/// then hands it back to `TarReader` to verify round-tripping.
private final class ByteSink {
    private(set) var bytes: [UInt8] = []

    func write(_ chunk: [UInt8]) {
        bytes.append(contentsOf: chunk)
    }
}

/// Wraps a fixed byte buffer in the pull-source closure shape `TarReader` expects.
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

@Test func roundTripsManifestThenPayloadInOrder() throws {
    let bodyA = Array("hello manifest".utf8)
    let bodyB = Array("payload-bytes-go-here".utf8)

    let sink = ByteSink()
    let writer = TarWriter { sink.write($0) }

    try writer.writeHeader(name: "manifest.json", size: Int64(bodyA.count), mode: 0o644)
    try writer.write(bodyA[...])

    try writer.writeHeader(name: "payload", size: Int64(bodyB.count), mode: 0o644)
    try writer.write(bodyB[...])

    try writer.finish()

    // Archive must be a whole number of 512-byte blocks.
    #expect(sink.bytes.count % 512 == 0)

    let reader = TarReader(makeSource(sink.bytes))

    let first = try reader.next()
    #expect(first?.name == "manifest.json")
    #expect(first?.size == Int64(bodyA.count))
    var bufA = [UInt8](repeating: 0, count: bodyA.count)
    let nA = try reader.read(into: &bufA)
    #expect(nA == bodyA.count)
    #expect(bufA == bodyA)

    let second = try reader.next()
    #expect(second?.name == "payload")
    #expect(second?.size == Int64(bodyB.count))
    var bufB = [UInt8](repeating: 0, count: bodyB.count)
    let nB = try reader.read(into: &bufB)
    #expect(nB == bodyB.count)
    #expect(bufB == bodyB)

    let end = try reader.next()
    #expect(end == nil)
}

@Test func writesTwoZeroBlockTrailerOnFinish() throws {
    let sink = ByteSink()
    let writer = TarWriter { sink.write($0) }

    try writer.writeHeader(name: "empty.txt", size: 0, mode: 0o644)
    try writer.finish()

    // One header block + two zero trailer blocks.
    #expect(sink.bytes.count == 512 * 3)
    let trailer = sink.bytes.suffix(1024)
    #expect(trailer.allSatisfy { $0 == 0 })
}
