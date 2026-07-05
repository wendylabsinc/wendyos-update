import Crypto
import Glibc
import LinuxSys
import Model
import Tar
import Zstd

/// Describes the `.wendy` artifact `ArtifactWriter.pack` should build.
/// Mirrors `artifact.PackOptions` in `internal/artifact/writer.go` and
/// `cmd/wendyos-update/pack.go`'s `pack` verb flags.
public struct PackOptions: Sendable {
    /// The rootfs image to package (e.g. the deployed `.ext4`). May be an
    /// Android sparse image (`.simg`) — it is transparently expanded to
    /// the raw image before packing (see `maybeSparseSource`).
    public var imagePath: String
    /// e.g. "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0".
    public var artifactName: String
    /// e.g. "0.16.0".
    public var artifactVersion: String
    /// `WENDYOS_BOARD_ID` values this artifact may be installed on.
    public var compatibleDevices: [String]
    /// Payload compression scheme. Defaults to `.zstd`, matching Go's
    /// `Pack` defaulting an empty `Compression` string to `"zstd"`.
    public var compression: Compression
    /// Informational: the rootfs marker (not this flag) decides at install
    /// time whether a bootloader capsule update actually runs.
    public var bootloaderUpdate: Bool
    /// Optional forward-compat gate: minimum wendyos-update version able
    /// to install this artifact.
    public var minToolVersion: String

    public init(
        imagePath: String,
        artifactName: String,
        artifactVersion: String,
        compatibleDevices: [String],
        compression: Compression = .zstd,
        bootloaderUpdate: Bool = false,
        minToolVersion: String = ""
    ) {
        self.imagePath = imagePath
        self.artifactName = artifactName
        self.artifactVersion = artifactVersion
        self.compatibleDevices = compatibleDevices
        self.compression = compression
        self.bootloaderUpdate = bootloaderUpdate
        self.minToolVersion = minToolVersion
    }
}

/// Builds `.wendy` artifacts (docs/manifest-schema.md). Lives in the same
/// target as `ArtifactReader` so the format has exactly one implementation
/// — `WriterTests.swift`'s pack -> read round trip is the guarantee the two
/// halves can never drift apart.
///
/// Ports `internal/artifact/writer.go`'s `Pack`.
public enum ArtifactWriter {
    /// Chunk size used for both the image-read and temp-file-replay loops.
    /// Not load-bearing, just a reasonable syscall/allocation size (matches
    /// the order of magnitude Go's `io.Copy` uses internally).
    private static let chunkSize = 1 << 20 // 1 MiB

    /// Streams `opts.imagePath` through the compressor into a private
    /// temporary file — computing the uncompressed digest+size and the
    /// compressed digest in that single pass — then writes the finished
    /// `.wendy` tar to `sink` in the frozen member order: `manifest.json`
    /// FIRST (now that both digests and the compressed size are known),
    /// payload second (streamed back out of the temp file).
    ///
    /// Never buffers the whole image in memory: the source image and the
    /// temp file are both read/written in `chunkSize` pieces.
    public static func pack(to sink: @escaping ([UInt8]) throws -> Void, _ opts: PackOptions) throws -> Manifest {
        let imgFd = try LinuxSys.openRead(opts.imagePath)
        defer { LinuxSys.close(imgFd) }

        // Transparently expand an Android sparse image (.ext4.simg) to the
        // raw image; a raw input passes through unchanged. The payload we
        // store is always the raw image, so the device writes it verbatim.
        let source = try maybeSparseSource(fdSource(imgFd))

        let tmpFd = try createUnlinkedTempFile()
        defer { LinuxSys.close(tmpFd) }

        var plainHasher = SHA256()
        var compHasher = SHA256()
        var plainSize: Int64 = 0
        var compSize: Int64 = 0

        let compressor = CompressStream(opts.compression) { chunk in
            chunk.withUnsafeBytes { raw in
                compHasher.update(bufferPointer: raw)
            }
            compSize += Int64(chunk.count)
            try writeAll(tmpFd, chunk)
        }

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = try source(&buffer, buffer.count)
            if n == 0 { break }
            let body = buffer[0..<n]
            body.withUnsafeBytes { raw in
                plainHasher.update(bufferPointer: raw)
            }
            plainSize += Int64(n)
            try compressor.write(body)
        }
        try compressor.finish()

        let payloadMemberName = payloadName(imagePath: opts.imagePath, compression: opts.compression)
        let manifest = Manifest(
            formatVersion: 1,
            artifactName: opts.artifactName,
            artifactVersion: opts.artifactVersion,
            compatibleDevices: opts.compatibleDevices,
            payload: Payload(
                name: payloadMemberName,
                size: plainSize,
                sha256: hexEncode(plainHasher.finalize()),
                compressedSHA256: hexEncode(compHasher.finalize()),
                compression: opts.compression.rawValue
            ),
            bootloaderUpdate: opts.bootloaderUpdate,
            minToolVersion: opts.minToolVersion
        )
        try manifest.validate()

        let manifestBytes = JSONCodec.encodePretty(manifest.makeJSONObject())

        let tar = TarWriter(sink)
        try tar.writeHeader(name: "manifest.json", size: Int64(manifestBytes.count), mode: 0o644)
        try tar.write(manifestBytes[...])

        try tar.writeHeader(name: payloadMemberName, size: compSize, mode: 0o644)
        try rewind(tmpFd)
        var replay = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = try replay.withUnsafeMutableBytes { try LinuxSys.read(tmpFd, $0) }
            if n == 0 { break }
            try tar.write(replay[0..<n])
        }
        try tar.finish()

        return manifest
    }

    /// Wraps `fd` in the pull-source closure shape `maybeSparseSource`/
    /// `CompressStream` expect: fills `into` with up to `max` bytes read
    /// from `fd`, returning the count read (0 == EOF).
    private static func fdSource(_ fd: Int32) -> (_ into: inout [UInt8], _ max: Int) throws -> Int {
        { buf, max in
            var chunk = [UInt8](repeating: 0, count: max)
            let n = try chunk.withUnsafeMutableBytes { try LinuxSys.read(fd, $0) }
            buf = Array(chunk[0..<n])
            return n
        }
    }

    /// Writes every byte of `bytes` to `fd`, looping over `LinuxSys.write`'s
    /// partial-write return until the whole chunk has landed.
    private static func writeAll(_ fd: Int32, _ bytes: ArraySlice<UInt8>) throws {
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = try LinuxSys.write(fd, UnsafeRawBufferPointer(rebasing: raw[offset...]))
                if n == 0 { break } // shouldn't happen for a regular file; avoid spinning forever
                offset += n
            }
        }
    }

    /// Creates a private temporary file and immediately unlinks its
    /// directory entry: the fd stays valid for read/write, and the file's
    /// storage is reclaimed automatically once every fd referencing it is
    /// closed — even across a crash, which is a stronger guarantee than a
    /// named temp file cleaned up by a `defer`d removal. Same net effect as
    /// Go's `os.CreateTemp` + `defer os.Remove` pairing in `Pack`, just
    /// gets there by unlinking eagerly instead of on the way out.
    ///
    /// Deliberately implemented with raw `Glibc` calls rather than
    /// `LinuxSys`: `LinuxSys`'s `open` wrappers intentionally have no
    /// `O_CREAT` path (see `LinuxSys.openWriteExisting`'s doc comment) — a
    /// design choice this file has no reason to punch a hole in for a
    /// single, self-contained temp-file use site.
    private static func createUnlinkedTempFile() throws -> Int32 {
        let dir = tempDirectory()
        var template = Array("\(dir)/wendy-pack-XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { buf in
            Glibc.mkstemp(buf.baseAddress!)
        }
        guard fd >= 0 else { throw SysError(errno: errno, op: "mkstemp") }

        let path = template.withUnsafeBufferPointer { buf in String(cString: buf.baseAddress!) }
        _ = path.withCString { Glibc.unlink($0) }
        return fd
    }

    /// Seeks `fd` back to its start, for the temp file's second (read-back)
    /// pass once the compressed payload has been fully written. Raw
    /// `Glibc.lseek` rather than `LinuxSys` for the same reason
    /// `createUnlinkedTempFile` is: `LinuxSys.seekEnd` is the one seek
    /// primitive that type exposes, and adding a second (`SEEK_SET`) for
    /// this one call site isn't worth growing that shared surface.
    private static func rewind(_ fd: Int32) throws {
        guard Glibc.lseek(fd, 0, Int32(SEEK_SET)) == 0 else {
            throw SysError(errno: errno, op: "lseek(SEEK_SET)")
        }
    }

    /// Derives the payload tar member's name from the source image's
    /// filename: the stored payload is always the RAW image (even when
    /// the input was a sparse `.simg`), so any `.simg` suffix is dropped,
    /// then the compression's own extension is appended. Ports writer.go's
    /// `payloadName`.
    private static func payloadName(imagePath: String, compression: Compression) -> String {
        var base = String(imagePath.split(separator: "/", omittingEmptySubsequences: false).last ?? Substring(imagePath))
        if base.hasSuffix(".simg") {
            base.removeLast(".simg".count)
        }
        switch compression {
        case .zstd: return base + ".zst"
        case .gzip: return base + ".gz"
        case .none: return base
        }
    }
}

/// Hex-encodes a digest's bytes as lowercase ASCII, without pulling in
/// Foundation. Duplicated from `Reader.swift` (file-private there) rather
/// than shared, matching this target's existing convention of small,
/// self-contained helpers per file.
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

/// Resolves the temp-file directory the way Go's `os.TempDir()` does:
/// `$TMPDIR` if set and non-empty, else `/tmp`.
private func tempDirectory() -> String {
    if let raw = Glibc.getenv("TMPDIR") {
        let value = String(cString: raw)
        if !value.isEmpty { return value }
    }
    return "/tmp"
}
