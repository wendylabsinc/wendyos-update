import Crypto
import Testing

import Artifact
import Model
import Tar

/// Collects everything written by a `TarWriter` into a single byte buffer.
private final class ByteSink {
    private(set) var bytes: [UInt8] = []

    func write(_ chunk: [UInt8]) {
        bytes.append(contentsOf: chunk)
    }
}

/// Wraps a fixed byte buffer in the pull-source closure shape `TarReader`
/// expects.
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

/// A structurally valid v1 manifest (matches `manifest.go`'s `Validate()`)
/// with `payload.compression == "none"` so the tar-stored bytes are
/// identical to the uncompressed bytes — the digests can be computed
/// directly over `payloadBody` in-test without a real (de)compressor.
private func manifestJSON(payloadBody: [UInt8], compressedSHA256: String = "") -> [UInt8] {
    manifestJSON(payloadSize: payloadBody.count, sha256: sha256Hex(payloadBody), compressedSHA256: compressedSHA256)
}

/// Like `manifestJSON(payloadBody:...)` but lets a test set
/// `payload.sha256` to an arbitrary 64-hex value independent of the stored
/// bytes — needed to prove the tee hashes the STORED (compressed) bytes
/// while `verifyPayloadDigests` compares the caller-supplied uncompressed
/// digest against `payload.sha256`.
private func manifestJSON(payloadSize: Int, sha256: String, compressedSHA256: String) -> [UInt8] {
    let json = """
        {
          "format_version": 1,
          "artifact_name": "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0",
          "artifact_version": "0.16.0",
          "compatible_devices": ["jetson-agx-thor"],
          "payload": {
            "name": "payload",
            "size": \(payloadSize),
            "sha256": "\(sha256)",
            "compressed_sha256": "\(compressedSHA256)",
            "compression": "none"
          },
          "bootloader_update": false,
          "min_tool_version": "0.1.0"
        }
        """
    return Array(json.utf8)
}

/// Builds an in-memory `.wendy` tar: `manifest.json` first, then whichever
/// additional members `members` describes, in order.
private func buildArchive(manifestBytes: [UInt8], members: [(name: String, body: [UInt8])]) throws -> [UInt8] {
    let sink = ByteSink()
    let writer = TarWriter { sink.write($0) }

    try writer.writeHeader(name: "manifest.json", size: Int64(manifestBytes.count), mode: 0o644)
    try writer.write(manifestBytes[...])

    for member in members {
        try writer.writeHeader(name: member.name, size: Int64(member.body.count), mode: 0o644)
        try writer.write(member.body[...])
    }

    try writer.finish()
    return sink.bytes
}

private func readAll(_ stream: PayloadStream) throws -> [UInt8] {
    var out: [UInt8] = []
    while true {
        var chunk = [UInt8](repeating: 0, count: 64)
        let n = try stream.read(into: &chunk)
        if n == 0 { break }
        out.append(contentsOf: chunk[0..<n])
    }
    return out
}

@Test func opensAndParsesTheManifest() throws {
    let payloadBody = Array("payload-bytes-go-here".utf8)
    let manifestBytes = manifestJSON(payloadBody: payloadBody)
    let archive = try buildArchive(manifestBytes: manifestBytes, members: [("payload", payloadBody)])

    let reader = try ArtifactReader.open(TarReader(makeSource(archive)))

    #expect(reader.manifest.artifactName == "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0")
    #expect(reader.manifest.payload.name == "payload")
}

@Test func readsPayloadAndVerifiesDigestsSuccessfully() throws {
    let payloadBody = Array("payload-bytes-go-here".utf8)
    let compressedSHA256 = sha256Hex(payloadBody) // compression "none" -> stored bytes == uncompressed bytes
    let manifestBytes = manifestJSON(payloadBody: payloadBody, compressedSHA256: compressedSHA256)
    let archive = try buildArchive(manifestBytes: manifestBytes, members: [("payload", payloadBody)])

    let reader = try ArtifactReader.open(TarReader(makeSource(archive)))
    let stream = try reader.payload()
    let got = try readAll(stream)
    #expect(got == payloadBody)

    try reader.verifyPayloadDigests(uncompressedSHA256: sha256Hex(payloadBody))
}

@Test func verifyPayloadDigestsThrowsOnWrongUncompressedHash() throws {
    let payloadBody = Array("payload-bytes-go-here".utf8)
    let manifestBytes = manifestJSON(payloadBody: payloadBody)
    let archive = try buildArchive(manifestBytes: manifestBytes, members: [("payload", payloadBody)])

    let reader = try ArtifactReader.open(TarReader(makeSource(archive)))
    let stream = try reader.payload()
    _ = try readAll(stream)

    let wrongHash = String(repeating: "0", count: 64)
    #expect(throws: ArtifactError.self) {
        try reader.verifyPayloadDigests(uncompressedSHA256: wrongHash)
    }
    do {
        try reader.verifyPayloadDigests(uncompressedSHA256: wrongHash)
        Issue.record("expected sha256Mismatch")
    } catch let ArtifactError.sha256Mismatch(message) {
        #expect(message.contains(wrongHash))
    } catch {
        Issue.record("expected .sha256Mismatch, got \(error)")
    }
}

@Test func openThrowsWhenFirstMemberIsNotManifestJSON() throws {
    let payloadBody = Array("payload-bytes-go-here".utf8)
    let sink = ByteSink()
    let writer = TarWriter { sink.write($0) }
    try writer.writeHeader(name: "payload", size: Int64(payloadBody.count), mode: 0o644)
    try writer.write(payloadBody[...])
    try writer.finish()

    #expect(throws: ArtifactError.self) {
        _ = try ArtifactReader.open(TarReader(makeSource(sink.bytes)))
    }
}

@Test func openThrowsArtifactErrorOnGarbageNonTarStream() throws {
    // A block of non-zero garbage is neither a valid ustar header nor a
    // clean EOF: `TarReader.next()` throws `TarError`, which `open` must
    // wrap as `ArtifactError.notTar` — no raw `TarError` may escape.
    let garbage = [UInt8](repeating: 0x41, count: 512)

    #expect(throws: ArtifactError.self) {
        _ = try ArtifactReader.open(TarReader(makeSource(garbage)))
    }
}

@Test func openThrowsInvalidManifestOnTruncatedManifestBody() throws {
    // Declare a manifest member whose size is larger than the bytes that
    // actually follow, so `tar.read` hits `TarError.truncated` mid-body.
    // reader.go surfaces this through the manifest decode ("parse
    // manifest.json: %w"), so it must map to `.invalidManifest`.
    let manifestBytes = manifestJSON(payloadBody: Array("x".utf8))
    let sink = ByteSink()
    let writer = TarWriter { sink.write($0) }
    // Header claims the real manifest size, but we only write the first
    // half of the body and then stop the stream (no finish/trailer).
    try writer.writeHeader(name: "manifest.json", size: Int64(manifestBytes.count), mode: 0o644)
    let half = manifestBytes.count / 2
    try writer.write(manifestBytes[0..<half])
    // Truncate: feed only the bytes emitted so far, so the reader runs out
    // mid-manifest.
    #expect(throws: ArtifactError.self) {
        _ = try ArtifactReader.open(TarReader(makeSource(sink.bytes)))
    }
}

@Test func payloadThrowsArtifactErrorOnUnexpectedMemberBeforePayload() throws {
    let payloadBody = Array("payload-bytes-go-here".utf8)
    let manifestBytes = manifestJSON(payloadBody: payloadBody)
    // A member named neither "manifest.sig" nor the payload name appears
    // before the payload -> `.payloadNotFound`.
    let archive = try buildArchive(
        manifestBytes: manifestBytes,
        members: [("some-stray-file", Array("nope".utf8)), ("payload", payloadBody)]
    )

    let reader = try ArtifactReader.open(TarReader(makeSource(archive)))
    #expect(throws: ArtifactError.self) {
        _ = try reader.payload()
    }
}

@Test func verifyPayloadDigestsThrowsWhenCalledBeforePayload() throws {
    let payloadBody = Array("payload-bytes-go-here".utf8)
    let manifestBytes = manifestJSON(payloadBody: payloadBody)
    let archive = try buildArchive(manifestBytes: manifestBytes, members: [("payload", payloadBody)])

    let reader = try ArtifactReader.open(TarReader(makeSource(archive)))
    #expect(throws: ArtifactError.self) {
        try reader.verifyPayloadDigests(uncompressedSHA256: sha256Hex(payloadBody))
    }
}

@Test func verifyPayloadDigestsHashesStoredBytesNotUncompressed() throws {
    // Stored (compressed) bytes and the "uncompressed" digest are made
    // deliberately DIFFERENT: with compression "none" the tar-stored bytes
    // == `storedBytes`, so the tee's digest is sha256(storedBytes). We set
    // that as `compressed_sha256`, and set `sha256` (the uncompressed
    // digest) to an unrelated value we then pass to verify. If the tee
    // mistakenly hashed the "uncompressed" side, the compressed check would
    // fail — so this passing proves the tee hashes the stored bytes.
    let storedBytes = Array("stored-compressed-bytes".utf8)
    let compressedDigest = sha256Hex(storedBytes)
    let fakeUncompressedDigest = String(repeating: "1", count: 64)
    #expect(compressedDigest != fakeUncompressedDigest)

    let manifestBytes = manifestJSON(
        payloadSize: storedBytes.count,
        sha256: fakeUncompressedDigest,
        compressedSHA256: compressedDigest
    )
    let archive = try buildArchive(manifestBytes: manifestBytes, members: [("payload", storedBytes)])

    let reader = try ArtifactReader.open(TarReader(makeSource(archive)))
    let stream = try reader.payload()
    _ = try readAll(stream)

    // Passes: uncompressed matches manifest.sha256 (both the fake value),
    // and the tee's digest of the stored bytes matches compressed_sha256.
    try reader.verifyPayloadDigests(uncompressedSHA256: fakeUncompressedDigest)
}

@Test func verifyPayloadDigestsThrowsOnWrongCompressedHash() throws {
    let storedBytes = Array("stored-compressed-bytes".utf8)
    let fakeUncompressedDigest = String(repeating: "1", count: 64)
    let wrongCompressedDigest = String(repeating: "2", count: 64)
    #expect(sha256Hex(storedBytes) != wrongCompressedDigest)

    let manifestBytes = manifestJSON(
        payloadSize: storedBytes.count,
        sha256: fakeUncompressedDigest,
        compressedSHA256: wrongCompressedDigest
    )
    let archive = try buildArchive(manifestBytes: manifestBytes, members: [("payload", storedBytes)])

    let reader = try ArtifactReader.open(TarReader(makeSource(archive)))
    let stream = try reader.payload()
    _ = try readAll(stream)

    // Uncompressed digest matches, but the tee's digest of the stored
    // bytes disagrees with `compressed_sha256` -> `.sha256Mismatch`.
    do {
        try reader.verifyPayloadDigests(uncompressedSHA256: fakeUncompressedDigest)
        Issue.record("expected .sha256Mismatch on wrong compressed digest")
    } catch let ArtifactError.sha256Mismatch(message) {
        #expect(message.contains(wrongCompressedDigest))
    } catch {
        Issue.record("expected .sha256Mismatch, got \(error)")
    }
}

@Test func payloadThrowsPayloadAlreadyTakenOnSecondCall() throws {
    let payloadBody = Array("payload-bytes-go-here".utf8)
    let manifestBytes = manifestJSON(payloadBody: payloadBody)
    let archive = try buildArchive(manifestBytes: manifestBytes, members: [("payload", payloadBody)])

    let reader = try ArtifactReader.open(TarReader(makeSource(archive)))
    _ = try reader.payload()

    #expect(throws: ArtifactError.payloadAlreadyTaken) {
        _ = try reader.payload()
    }
}

@Test func payloadSkipsAManifestSigMemberBeforeThePayload() throws {
    let payloadBody = Array("payload-bytes-go-here".utf8)
    let manifestBytes = manifestJSON(payloadBody: payloadBody)
    let sigBody = Array("not-verified-in-v1".utf8)
    let archive = try buildArchive(
        manifestBytes: manifestBytes,
        members: [("manifest.sig", sigBody), ("payload", payloadBody)]
    )

    let reader = try ArtifactReader.open(TarReader(makeSource(archive)))
    let stream = try reader.payload()
    let got = try readAll(stream)
    #expect(got == payloadBody)

    try reader.verifyPayloadDigests(uncompressedSHA256: sha256Hex(payloadBody))
}
