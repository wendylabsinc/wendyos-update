import Crypto
import Glibc
import Testing

import Artifact
import Model
import Tar

@testable import WendyUpdate

// Task 10.3: the `pack` verb. Exercises `runPack(_:)` directly — the
// function `Pack` (the `ArgumentParser` command in `Command.swift`) hands
// off to once flags are gathered — against a REAL temp rootfs image and a
// REAL output `.wendy` path on disk, mirroring writer_test.go's own
// on-disk fixture style rather than mocking the filesystem.

/// Deterministic pseudorandom byte generator (a linear congruential
/// generator) so the fixture "rootfs image" isn't trivially repetitive —
/// ports the same generator `ArtifactTests/WriterTests.swift` uses.
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

/// Writes `bytes` to a fresh regular file under /tmp and returns its path
/// — stands in for the rootfs image `--image` points at. The caller is
/// responsible for unlinking it.
private func writeFixtureImage(_ bytes: [UInt8], tag: String) -> String {
    let path = "/tmp/pack-cli-test-\(getpid())-\(tag)-\(Int.random(in: 0..<1_000_000)).img"
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

/// A not-yet-existing path under /tmp for `-o`'s output — never
/// pre-created, so a successful pack proves `openWriteCreateTruncate`
/// actually creates it.
private func freshOutputPath(tag: String) -> String {
    "/tmp/pack-cli-test-\(getpid())-\(tag)-\(Int.random(in: 0..<1_000_000)).wendy"
}

private func fileExists(_ path: String) -> Bool {
    var st = stat()
    return stat(path, &st) == 0
}

private func readWholeFile(_ path: String) -> [UInt8] {
    let fd = Glibc.open(path, O_RDONLY)
    guard fd >= 0 else { return [] }
    defer { Glibc.close(fd) }
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = chunk.withUnsafeMutableBytes { buf in Glibc.read(fd, buf.baseAddress, buf.count) }
        if n <= 0 { break }
        out.append(contentsOf: chunk[0..<n])
    }
    return out
}

/// Wraps a fixed byte buffer in the pull-source closure shape `TarReader`
/// expects, mirroring `WriterTests.swift`'s own `makeSource`.
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

private func baseOptions(image: String, output: String, compression: String = "zstd") -> PackCLIOptions {
    PackCLIOptions(
        image: image, name: "wendyos-image-test-9.9.9", version: "9.9.9",
        compression: compression, minToolVersion: "0.1.0", output: output,
        devices: ["jetson-agx-thor"]
    )
}

@Suite("pack CLI")
struct PackCLITests {
    // MARK: - happy path: pack -> re-open -> verify

    @Test func packProducesAnArtifactThatReopensAndVerifies() throws {
        let image = lcgBuffer(count: 200_003) // deliberately not a round number
        let imagePath = writeFixtureImage(image, tag: "zstd")
        defer { unlink(imagePath) }
        let outputPath = freshOutputPath(tag: "zstd")
        defer { unlink(outputPath) }

        #expect(!fileExists(outputPath))
        let summary = try runPack(baseOptions(image: imagePath, output: outputPath, compression: "zstd"))

        #expect(fileExists(outputPath))
        #expect(summary == "wendyos-update: packed \(outputPath) (wendyos-image-test-9.9.9, payload 200003 bytes, zstd)\n")

        // Re-open exactly as a device would, independent of `runPack`'s
        // own internal self-verify -- this is the "produces a file that
        // re-opens and verifies" half of the brief.
        let reader = try ArtifactReader.open(TarReader(makeSource(readWholeFile(outputPath))))
        #expect(reader.manifest.payload.size == Int64(image.count))
        #expect(reader.manifest.payload.compression == "zstd")
        try verifyPacked(outputPath) // payload digests + size, via the same helper runPack itself uses
    }

    @Test func packWorksWithNoCompression() throws {
        let image = lcgBuffer(count: 4096)
        let imagePath = writeFixtureImage(image, tag: "none")
        defer { unlink(imagePath) }
        let outputPath = freshOutputPath(tag: "none")
        defer { unlink(outputPath) }

        let summary = try runPack(baseOptions(image: imagePath, output: outputPath, compression: "none"))
        #expect(summary.contains("payload 4096 bytes, none"))
        try verifyPacked(outputPath)

        // "none" stores the payload uncompressed -- the tar member's
        // bytes should equal the raw image bytes exactly.
        let reader = try ArtifactReader.open(TarReader(makeSource(readWholeFile(outputPath))))
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

    // MARK: - required flags

    @Test func missingImageIsAUsageError() throws {
        let outputPath = freshOutputPath(tag: "missing-image")
        var opts = baseOptions(image: "", output: outputPath)
        opts.image = ""
        #expect(throws: PackError.self) { _ = try runPack(opts) }
        #expect(!fileExists(outputPath))
    }

    @Test func missingNameIsAUsageError() throws {
        let imagePath = writeFixtureImage([1, 2, 3], tag: "missing-name")
        defer { unlink(imagePath) }
        var opts = baseOptions(image: imagePath, output: freshOutputPath(tag: "missing-name"))
        opts.name = ""
        #expect(throws: PackError.self) { _ = try runPack(opts) }
    }

    @Test func missingVersionIsAUsageError() throws {
        let imagePath = writeFixtureImage([1, 2, 3], tag: "missing-version")
        defer { unlink(imagePath) }
        var opts = baseOptions(image: imagePath, output: freshOutputPath(tag: "missing-version"))
        opts.version = ""
        #expect(throws: PackError.self) { _ = try runPack(opts) }
    }

    @Test func missingOutputIsAUsageError() throws {
        let imagePath = writeFixtureImage([1, 2, 3], tag: "missing-output")
        defer { unlink(imagePath) }
        var opts = baseOptions(image: imagePath, output: "")
        opts.output = ""
        #expect(throws: PackError.self) { _ = try runPack(opts) }
    }

    @Test func missingDevicesIsAUsageError() throws {
        let imagePath = writeFixtureImage([1, 2, 3], tag: "missing-devices")
        defer { unlink(imagePath) }
        var opts = baseOptions(image: imagePath, output: freshOutputPath(tag: "missing-devices"))
        opts.devices = []
        #expect(throws: PackError.self) { _ = try runPack(opts) }
    }

    @Test func requiredFlagErrorMessageMatchesPackGoVerbatim() throws {
        do {
            _ = try runPack(PackCLIOptions())
            Issue.record("expected PackError")
        } catch let error as PackError {
            #expect(error.message == "pack: --image, --name, --version, --device, and -o are required")
            #expect(error.exitCode == 1)
        } catch {
            Issue.record("expected PackError, got \(error)")
        }
    }

    // MARK: - invalid --compression

    @Test func invalidCompressionIsRejected() throws {
        let imagePath = writeFixtureImage([1, 2, 3], tag: "bad-compression")
        defer { unlink(imagePath) }
        let outputPath = freshOutputPath(tag: "bad-compression")
        let opts = baseOptions(image: imagePath, output: outputPath, compression: "lz4")

        do {
            _ = try runPack(opts)
            Issue.record("expected PackError")
        } catch let error as PackError {
            #expect(error.message == "pack: unsupported compression \"lz4\"")
        } catch {
            Issue.record("expected PackError, got \(error)")
        }
        // Nothing should have been written for a flag-time rejection.
        #expect(!fileExists(outputPath))
    }

    // MARK: - cleanup on pack failure

    /// Drives `packArtifact`'s remove-on-catch branch end to end. The
    /// required-flag and invalid-`--compression` rejections all fire BEFORE
    /// any file I/O, so they never open `-o` and thus never exercise the
    /// cleanup. Here `-o` IS opened by `openWriteCreateTruncate` and then
    /// `ArtifactWriter.pack` fails reading a nonexistent `--image`, so the
    /// partial output must be removed before `runPack` rethrows.
    ///
    /// The sibling cleanup path -- verify-failure-through-`runPack` removing
    /// the output -- is covered only indirectly: `verifyPackedDetectsA-
    /// CorruptedPayload` proves the detection is real, but triggering it
    /// organically through `runPack` would require corrupting the artifact
    /// in the window between pack and read-back, which nothing in the
    /// pipeline does. An accepted, documented gap rather than a silent one.
    @Test func packFailureRemovesThePartialOutput() throws {
        let missingImage = "/tmp/pack-cli-test-\(getpid())-does-not-exist-\(Int.random(in: 0..<1_000_000)).img"
        #expect(!fileExists(missingImage))
        let outputPath = freshOutputPath(tag: "cleanup")
        defer { unlink(outputPath) } // in case the assertion below fails

        let opts = baseOptions(image: missingImage, output: outputPath)
        #expect(throws: PackError.self) { _ = try runPack(opts) }
        // The output was created (openWriteCreateTruncate) then the pack
        // failed -- packArtifact's catch must have removed it.
        #expect(!fileExists(outputPath))
    }

    // MARK: - --no-verify

    @Test func noVerifySkipsTheReadBackButStillProducesAValidFile() throws {
        let image = lcgBuffer(count: 65536)
        let imagePath = writeFixtureImage(image, tag: "no-verify")
        defer { unlink(imagePath) }
        let outputPath = freshOutputPath(tag: "no-verify")
        defer { unlink(outputPath) }

        var opts = baseOptions(image: imagePath, output: outputPath, compression: "zstd")
        opts.noVerify = true
        let summary = try runPack(opts)

        #expect(summary.contains("payload 65536 bytes, zstd"))
        #expect(fileExists(outputPath))
        // Still a genuinely valid artifact -- --no-verify only skips the
        // extra read-back pass, it doesn't change what gets written.
        try verifyPacked(outputPath)
    }

    /// Proves the mechanism `--no-verify` skips actually does real work:
    /// `verifyPacked` (exactly what `runPack` calls unless `noVerify` is
    /// set) must reject a corrupted artifact. Combined with the test
    /// above (a pristine artifact + `noVerify: true` succeeds), this
    /// shows `--no-verify` is a genuine "skip the check" rather than the
    /// check being a no-op.
    @Test func verifyPackedDetectsACorruptedPayload() throws {
        let image = lcgBuffer(count: 65536)
        let imagePath = writeFixtureImage(image, tag: "corrupt-src")
        defer { unlink(imagePath) }
        let outputPath = freshOutputPath(tag: "corrupt")
        defer { unlink(outputPath) }

        _ = try runPack(baseOptions(image: imagePath, output: outputPath, compression: "none"))

        // Flip one byte well inside the payload region: the middle of the
        // file safely clears manifest.json + its tar header (a few
        // hundred bytes in) and stays well clear of the two 512-byte
        // zero blocks ustar pads the archive with at EOF, which flipping
        // a byte near the tail would land in instead.
        var bytes = readWholeFile(outputPath)
        let flipIndex = bytes.count / 2
        bytes[flipIndex] ^= 0xFF
        let fd = Glibc.open(outputPath, O_WRONLY | O_TRUNC)
        precondition(fd >= 0)
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Glibc.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                precondition(n > 0)
                offset += n
            }
        }
        Glibc.close(fd)

        #expect(throws: (any Error).self) { try verifyPacked(outputPath) }
    }
}
