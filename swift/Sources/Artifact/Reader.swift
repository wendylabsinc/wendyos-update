import Crypto
import Model
import Tar

/// Bounds `manifest.json` so a malformed artifact cannot exhaust memory
/// (the manifest is a few hundred bytes in practice). Mirrors
/// `maxManifestSize` in `internal/artifact/reader.go`.
private let maxManifestSize: Int64 = 4 << 20

/// Streams a `.wendy` artifact (docs/manifest-schema.md): a tar with
/// `manifest.json` FIRST, then the payload — one pass, no temp copy.
/// Construct with `open`, then call `payload()` exactly once, consume it
/// fully, and finish with `verifyPayloadDigests(uncompressedSHA256:)`.
///
/// Ports `internal/artifact/reader.go`'s `Reader` type.
public final class ArtifactReader {
    public let manifest: Manifest

    private let tar: TarReader
    private var payloadTaken = false
    /// Shared with the `PayloadStream` returned by `payload()` so the
    /// compressed-bytes digest accumulated while the caller drains the
    /// stream is still visible here once `verifyPayloadDigests` runs.
    private var compressedHasher: HasherBox?

    private init(manifest: Manifest, tar: TarReader) {
        self.manifest = manifest
        self.tar = tar
    }

    /// Reads and validates the manifest (the first tar member).
    public static func open(_ tar: TarReader) throws -> ArtifactReader {
        guard let header = try tar.next() else {
            throw ArtifactError.notTar("not a tar stream or empty")
        }
        guard header.name == "manifest.json" else {
            throw ArtifactError.invalidManifest(
                "first member must be manifest.json, got \"\(header.name)\""
            )
        }
        guard header.size <= maxManifestSize else {
            throw ArtifactError.invalidManifest("manifest.json too large (\(header.size) bytes)")
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(Int(header.size))
        var remaining = Int(header.size)
        while remaining > 0 {
            var chunk = [UInt8](repeating: 0, count: remaining)
            let n = try tar.read(into: &chunk)
            if n == 0 { break }
            bytes.append(contentsOf: chunk[0..<n])
            remaining -= n
        }

        let manifest: Manifest
        do {
            manifest = try JSONCodec.decodeManifest(bytes)
        } catch {
            throw ArtifactError.invalidManifest("parse manifest.json: \(error)")
        }
        try manifest.validate()

        return ArtifactReader(manifest: manifest, tar: tar)
    }

    /// Advances to the payload member and returns a stream over its (still
    /// compressed) bytes. The stream tees into a SHA-256 so the
    /// stored-bytes digest can be verified after consumption.
    /// `manifest.sig` members are skipped (reserved, unverified in v1).
    public func payload() throws -> PayloadStream {
        guard !payloadTaken else {
            throw ArtifactError.payloadAlreadyTaken
        }

        while true {
            guard let header = try tar.next() else {
                throw ArtifactError.payloadNotFound(
                    "payload member \"\(manifest.payload.name)\" not found"
                )
            }
            if header.name == "manifest.sig" {
                continue // reserved for future signing; ignored in v1
            }
            guard header.name == manifest.payload.name else {
                throw ArtifactError.payloadNotFound(
                    "unexpected member \"\(header.name)\" before payload \"\(manifest.payload.name)\""
                )
            }

            payloadTaken = true
            let box = HasherBox()
            compressedHasher = box
            return PayloadStream(tar: tar, hasherBox: box)
        }
    }

    /// Called after the payload has been fully consumed.
    /// `uncompressedSHA256` is the rolling digest the caller computed over
    /// the decompressed stream; the compressed-bytes digest was
    /// accumulated by the tee in `payload()`. Both must match the
    /// manifest.
    public func verifyPayloadDigests(uncompressedSHA256: String) throws {
        guard payloadTaken, let box = compressedHasher else {
            throw ArtifactError.payloadNotFound("payload was never read")
        }
        guard uncompressedSHA256.caseInsensitiveEqual(to: manifest.payload.sha256) else {
            throw ArtifactError.sha256Mismatch(
                "payload sha256 mismatch: got \(uncompressedSHA256), manifest \(manifest.payload.sha256)"
            )
        }
        let want = manifest.payload.compressedSHA256
        if !want.isEmpty {
            let got = hexEncode(box.hasher.finalize())
            guard got.caseInsensitiveEqual(to: want) else {
                throw ArtifactError.sha256Mismatch(
                    "compressed payload sha256 mismatch: got \(got), manifest \(want)"
                )
            }
        }
    }

    /// Boxes the incremental compressed-bytes `SHA256` hasher in a
    /// reference type so both the `ArtifactReader` and the (value-type)
    /// `PayloadStream` it hands out can share and mutate the same running
    /// digest.
    fileprivate final class HasherBox {
        var hasher = SHA256()
    }
}

/// A stream over a `.wendy` artifact's (still compressed) payload member,
/// returned by `ArtifactReader.payload()`. Every byte read through
/// `read(into:)` is teed into the reader's compressed-bytes SHA-256.
public struct PayloadStream {
    private let tar: TarReader
    private let hasherBox: ArtifactReader.HasherBox

    fileprivate init(tar: TarReader, hasherBox: ArtifactReader.HasherBox) {
        self.tar = tar
        self.hasherBox = hasherBox
    }

    /// Reads up to `buf.count` bytes of the payload body into `buf`
    /// (filling from index 0), returning the number of bytes read. Returns
    /// 0 once the payload has been fully consumed.
    public func read(into buf: inout [UInt8]) throws -> Int {
        let n = try tar.read(into: &buf)
        if n > 0 {
            buf.withUnsafeBufferPointer { pointer in
                hasherBox.hasher.update(bufferPointer: UnsafeRawBufferPointer(start: pointer.baseAddress, count: n))
            }
        }
        return n
    }
}

/// Case-insensitive ASCII-hex digest comparison, matching Go's
/// `strings.EqualFold`.
extension String {
    fileprivate func caseInsensitiveEqual(to other: String) -> Bool {
        self.lowercased() == other.lowercased()
    }
}

/// Hex-encodes a digest's bytes as lowercase ASCII, without pulling in
/// Foundation.
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
