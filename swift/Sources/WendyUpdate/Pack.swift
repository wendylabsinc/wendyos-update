import Artifact
import CLIError
import Crypto
import Glibc
import LinuxSys
import Model
import Tar
import Zstd

// `pack` verb (Task 10.3): builds a `.wendy` artifact from a rootfs image.
// Host-side only — touches no device state. Ports `cmd/wendyos-update/
// pack.go`'s `cmdPack`/`verifyPacked` end to end; `Command.swift`'s `Pack`
// `AsyncParsableCommand` only parses flags into `PackCLIOptions` and hands
// off to `runPack(_:)` below, which is what carries the actual logic (and
// is exactly what a test drives, with no `ArgumentParser` involved).

/// Every failure this verb can throw maps to exit 1. Go's `exitCode`
/// (`cmd/wendyos-update/main.go`) has no dedicated case for any pack.go
/// error path — missing flags, an `artifact.Pack` failure, or a failed
/// self-verify all fall through to its default `exitError` — and
/// `docs/cli-contract.md` lists `pack`'s exit codes as "n/a" (it's a
/// host-side build step, outside the device-facing 0..4 table).
struct PackError: Error, ExitCoded, CustomStringConvertible {
    let message: String
    var exitCode: Int32 { 1 }
    var description: String { message }
}

/// The raw, unvalidated CLI input for `pack` — exactly pack.go's
/// `flag.FlagSet` surface, before any required-ness or compression-name
/// check has run. Kept separate from the `ArgumentParser` command
/// (`Pack`, in `Command.swift`) so the whole validate -> pack -> verify
/// pipeline is callable from a test without going through argument
/// parsing at all.
struct PackCLIOptions: Sendable {
    var image = ""
    var name = ""
    var version = ""
    var compression = "zstd"
    var bootloaderUpdate = false
    var minToolVersion = ""
    var output = ""
    var noVerify = false
    var devices: [String] = []
}

/// Runs the whole `pack` verb over already-parsed CLI options and returns
/// the human summary line pack.go prints to stderr on success (the
/// `Pack` command writes it; a test can just inspect the returned
/// string). Ports `cmdPack` end to end.
func runPack(_ opts: PackCLIOptions) throws -> String {
    guard !opts.image.isEmpty, !opts.name.isEmpty, !opts.version.isEmpty,
          !opts.output.isEmpty, !opts.devices.isEmpty
    else {
        throw PackError(message: "pack: --image, --name, --version, --device, and -o are required")
    }
    let compression = try resolvePackCompression(opts.compression)

    let manifest = try packArtifact(opts, compression: compression)

    if !opts.noVerify {
        try verifyOrRemove(opts.output)
    }

    return "wendyos-update: packed \(opts.output) (\(manifest.artifactName), payload \(manifest.payload.size) bytes, \(manifest.payload.compression))\n"
}

/// Maps `--compression`'s raw string to `Zstd.Compression`. Go validates
/// the name deep inside `artifact.Pack` (`unsupported compression %q`,
/// from `internal/artifact/writer.go`); here `Compression` is already a
/// closed three-case enum by the time it reaches `ArtifactWriter.pack`
/// (Task 3.4), so the equivalent check has to happen at this mapping
/// step instead — exactly the "validate at parse or map time" the brief
/// calls out.
func resolvePackCompression(_ raw: String) throws -> Compression {
    guard let compression = Compression(rawValue: raw) else {
        throw PackError(message: "pack: unsupported compression \"\(raw)\"")
    }
    return compression
}

/// Opens `opts.output` (create+truncate, matching pack.go's
/// `O_WRONLY|O_CREATE|O_TRUNC`) and streams `ArtifactWriter.pack` into it.
/// On any failure the partial output is removed before rethrowing, wrapped
/// as `"pack: %w"` — ports pack.go's `out.Close(); os.Remove(*output);
/// return fmt.Errorf("pack: %w", err)`. A failure to OPEN the output
/// (before anything has been created) is rethrown as-is, matching pack.go
/// returning `os.OpenFile`'s error unwrapped.
private func packArtifact(_ opts: PackCLIOptions, compression: Compression) throws -> Manifest {
    let outFd = try LinuxSys.openWriteCreateTruncate(opts.output)
    var fdIsOpen = true
    func closeOut() {
        guard fdIsOpen else { return }
        LinuxSys.close(outFd)
        fdIsOpen = false
    }

    let packOptions = PackOptions(
        imagePath: opts.image,
        artifactName: opts.name,
        artifactVersion: opts.version,
        compatibleDevices: opts.devices,
        compression: compression,
        bootloaderUpdate: opts.bootloaderUpdate,
        minToolVersion: opts.minToolVersion
    )

    do {
        let manifest = try ArtifactWriter.pack(to: { try writeAll(outFd, $0) }, packOptions)
        closeOut()
        return manifest
    } catch {
        closeOut()
        removeFileIgnoringErrors(opts.output)
        throw PackError(message: "pack: \(error)")
    }
}

/// Re-reads `path` exactly as `verifyOrRemove` needs and, on failure,
/// removes it before rethrowing wrapped as pack.go's `"pack: self-
/// verification failed (artifact removed): %w"`.
private func verifyOrRemove(_ path: String) throws {
    do {
        try verifyPacked(path)
    } catch {
        removeFileIgnoringErrors(path)
        throw PackError(message: "pack: self-verification failed (artifact removed): \(error)")
    }
}

/// Re-reads the artifact at `path` exactly as a device would: manifest-
/// first parse (`ArtifactReader.open`), then the payload streamed through
/// `Zstd.DecompressStream` with a rolling SHA-256 checked against the
/// manifest — ports pack.go's `verifyPacked` (manifest parse ->
/// `blockdev.Decompressor` -> `io.Copy(h, plain)` size+digest check ->
/// `VerifyPayloadDigests`).
func verifyPacked(_ path: String) throws {
    let fd = try LinuxSys.openRead(path)
    defer { LinuxSys.close(fd) }

    let tar = TarReader { into, max in
        var chunk = [UInt8](repeating: 0, count: max)
        let n = try chunk.withUnsafeMutableBytes { try LinuxSys.read(fd, $0) }
        into = n == max ? chunk : Array(chunk[0..<n])
        return n
    }

    let reader = try ArtifactReader.open(tar)
    let stream = try reader.payload()
    let compression = try resolvePackCompression(reader.manifest.payload.compression)

    let source: (inout [UInt8], Int) throws -> Int = { buf, max in
        var chunk = [UInt8](repeating: 0, count: max)
        let n = try stream.read(into: &chunk)
        buf = n == max ? chunk : Array(chunk[0..<n])
        return n
    }
    let decompressor = DecompressStream(compression, source: source)

    var hasher = SHA256()
    var total: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while true {
        let n = try decompressor.read(into: &buffer)
        if n == 0 { break }
        let chunk = buffer[0..<n]
        chunk.withUnsafeBytes { raw in hasher.update(bufferPointer: raw) }
        total += Int64(n)
    }

    guard total == reader.manifest.payload.size else {
        throw PackError(message: "payload size \(total), manifest says \(reader.manifest.payload.size)")
    }
    try reader.verifyPayloadDigests(uncompressedSHA256: hexEncode(hasher.finalize()))
}

/// Writes every byte of `bytes` to `fd`, looping over `LinuxSys.write`'s
/// partial-write return until the whole chunk has landed. Mirrors
/// `ArtifactWriter`'s own private `writeAll` (`Sources/Artifact/
/// Writer.swift`) — duplicated rather than shared, matching this
/// codebase's convention of small, self-contained per-file helpers.
private func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = try LinuxSys.write(fd, UnsafeRawBufferPointer(rebasing: raw[offset...]))
            if n == 0 { break } // shouldn't happen for a regular file; avoid spinning forever
            offset += n
        }
    }
}

/// Best-effort delete, mirroring pack.go's unchecked `os.Remove(*output)`
/// calls — by the time either cleanup path runs, the pack has already
/// failed, and there is nothing further to do with a removal error.
private func removeFileIgnoringErrors(_ path: String) {
    _ = path.withCString { Glibc.unlink($0) }
}

/// Hex-encodes a digest's bytes as lowercase ASCII, without pulling in
/// Foundation. Duplicated from `Artifact`'s own private helper rather
/// than shared, matching that target's convention of small, self-
/// contained helpers per file.
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
