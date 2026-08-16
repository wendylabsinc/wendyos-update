import CLIError
import Crypto
import PlatformIO
import Zstd

/// Everything that can go wrong while streaming a payload onto a block
/// device. Every case maps to the same process exit code (1) — a device
/// write failure is always fatal to the install in progress; there is no
/// case where the caller can usefully distinguish these at the CLI level.
public enum BlockDevError: Error, ExitCoded {
    /// The device node could not be opened for writing (typically: it
    /// doesn't exist — `writeImage` never creates it).
    case openTarget(String)
    /// A write (or the final `sync()`) to the device failed.
    case write(String)
    /// Reading/decompressing the payload source failed.
    case readPayload(String)
    /// `compression` named a scheme `Zstd.DecompressStream` doesn't
    /// support. Currently unreachable — `Compression` is a closed enum of
    /// three supported cases — but kept to mirror Go's `Decompressor`
    /// default-case error for API parity.
    case unsupportedCompression(String)

    /// All block-device failures are fatal to the in-progress install.
    public var exitCode: Int32 { 1 }
}

/// Streams a payload onto a block device, decompressing on the fly and
/// computing a rolling digest of what was actually written. Ports
/// `internal/blockdev/blockdev.go`'s `WriteImage`/`DeviceCapacity`/
/// `Decompressor`.
///
/// Deliberately takes a pull-source closure (mirroring Go's `io.Reader`
/// via this repo's read-closure convention) rather than any `Artifact`
/// type, so `BlockDev` has no dependency on how the payload bytes are
/// produced — the engine (a later task) is the one that knows how to pull
/// from an `ArtifactReader`.
public enum BlockDev {
    /// Balances syscall count against memory; 1 MiB keeps a large slot
    /// write to a manageable write-call count. Matches Go's `copyBufSize`.
    private static let copyBufSize = 1 << 20

    /// Decompresses `source` (still-compressed bytes) per `compression`
    /// and streams the DECOMPRESSED bytes to `devicePath`, computing a
    /// rolling SHA-256 over those decompressed bytes as they're written.
    ///
    /// `devicePath` is opened via `target.openForWrite`, which — like Go's
    /// `os.OpenFile(dst, os.O_WRONLY, 0)` — never creates the target: a
    /// missing device node is a configuration error, not something to
    /// paper over by writing a regular file in its place.
    ///
    /// The device is `sync()`ed before returning, so a caller comparing
    /// the returned digest against a manifest afterward knows the bytes it
    /// checked are actually durable, not just buffered.
    ///
    /// `progress` is called after each internal buffer's worth of bytes
    /// has been written (buffer granularity, not per-byte) with the
    /// running total of decompressed bytes written so far.
    public static func writeImage(
        to devicePath: String,
        from source: @escaping (_ into: inout [UInt8], _ max: Int) throws -> Int,
        compression: Compression,
        target: any BlockTarget,
        progress: (Int64) -> Void
    ) throws -> (Int64, String) {
        let device: any WritableDevice
        do {
            device = try target.openForWrite(devicePath)
        } catch {
            throw BlockDevError.openTarget("open target \(devicePath): \(error)")
        }
        defer { device.close() }

        let stream = DecompressStream(compression, source: source)
        var hasher = SHA256()
        var written: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: copyBufSize)

        while true {
            let n: Int
            do {
                n = try stream.read(into: &buffer)
            } catch {
                throw BlockDevError.readPayload("read payload: \(error)")
            }
            if n == 0 { break }

            let chunk = buffer[0..<n]
            do {
                try device.write(chunk)
            } catch {
                throw BlockDevError.write("write \(devicePath): \(error)")
            }
            chunk.withUnsafeBytes { raw in
                hasher.update(bufferPointer: raw)
            }

            written += Int64(n)
            progress(written)
        }

        do {
            try device.sync()
        } catch {
            throw BlockDevError.write("sync \(devicePath): \(error)")
        }

        return (written, hexEncode(hasher.finalize()))
    }

    /// The size, in bytes, of the device (or regular file) at `path`.
    /// Ports `blockdev.DeviceCapacity`; delegates straight to
    /// `target.capacity`, which implements the `lseek(SEEK_END)` probe.
    public static func deviceCapacity(_ path: String, target: any BlockTarget) throws -> Int64 {
        try target.capacity(path)
    }
}

/// Hex-encodes a digest's bytes as lowercase ASCII, without pulling in
/// Foundation. Duplicated from `Artifact`'s own private helper rather than
/// shared, matching that target's convention of small, self-contained
/// helpers per file.
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
