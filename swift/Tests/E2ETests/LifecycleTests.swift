import Glibc
import Testing

import Artifact
import Connector
import Engine
import Model
import PlatformIO
import PlatformIOTesting
import Tar
import Zstd

// End-to-end lifecycle coverage (Task 11.1): drives the REAL `Engine` over
// a `.wendy` artifact built with the REAL `ArtifactWriter.pack` (not a
// hand-rolled tar the way EngineTests/InstallTests.swift's fixtures are),
// with fakes only at the platform seam — `FakeConnector`/`FakeFileStore`/
// `FakeBlockTarget`, all shared with EngineTests via `PlatformIOTesting`
// (Task 11.1 moved `FakeConnector` there for exactly this reuse). Unlike
// EngineTests (which drills into each verb's individual branches), this
// suite asserts the exact connector call SEQUENCE across a whole multi-verb
// flow and the on-disk state at each milestone:
//
//   1. installThenCommitAfterHealthyReboot: install -> (simulated reboot
//      onto the target slot) -> commit.
//   2. installThenFirmwareFallbackVerifyBootThenRollback: install ->
//      (simulated firmware fallback: still running the ORIGIN slot) ->
//      verifyBoot (marks the deployment failed, but still confirms the
//      boot itself since the platform did not flag it compromised) ->
//      rollback.

private let deviceType = "jetson-agx-thor"

private func makeEngine(
    conn: FakeConnector,
    fs: any FileStore,
    toolVersion: String = "0.2.0"
) -> Engine {
    Engine(
        conn: conn,
        hooksDir: "/hooks", // no hooks are ever staged under it -> every phase is a no-op pass
        toolVersion: toolVersion,
        fs: fs,
        runner: FakeCommandRunner(),
        clock: FixedClock("2026-07-06T12:00:00Z"),
        env: MapEnv([:])
    )
}

private func writeDeviceType(_ fs: FakeFileStore, board: String = deviceType) {
    try! fs.writeAtomic(DefaultDeviceTypePath, Array("BOARD=\(board)\n".utf8), mode: 0o644)
}

/// Deterministic pseudorandom byte generator (a linear congruential
/// generator) so the fixture "rootfs image" isn't trivially repetitive.
/// Mirrors ArtifactTests/WriterTests.swift's `lcgBuffer`.
private func lcgBuffer(count: Int, seed: UInt64) -> [UInt8] {
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

/// Writes `bytes` to a fresh regular file under /tmp and returns its path —
/// stands in for "the rootfs image on disk" that `ArtifactWriter.pack`
/// reads via `imagePath`. Mirrors ArtifactTests/WriterTests.swift's
/// `writeFixtureImage`. The caller is responsible for unlinking it.
private func writeFixtureImage(_ bytes: [UInt8], tag: String) -> String {
    let path = "/tmp/e2e-lifecycle-\(getpid())-\(tag)-\(Int.random(in: 0..<1_000_000))"
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

/// Collects everything written by `ArtifactWriter.pack`'s sink into a
/// single in-memory buffer. Mirrors ArtifactTests/WriterTests.swift's
/// `ByteSink`.
private final class ByteSink {
    private(set) var bytes: [UInt8] = []
    func write(_ chunk: [UInt8]) { bytes.append(contentsOf: chunk) }
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

/// Packs a REAL `.wendy` artifact (via `ArtifactWriter.pack`, compression
/// "none" so the on-disk payload bytes are the raw image bytes) over a real
/// temp-file rootfs image, then opens it as an `ArtifactReader` — the same
/// object `Engine.install` consumes in production (the CLI/download layer
/// is responsible for producing one; this layer only sequences the engine
/// verbs over it). The fixture image file is removed before returning; by
/// then the packed `.wendy` bytes are fully in memory.
private func packAndOpenArtifact(
    tag: String,
    imageSize: Int = 4096,
    artifactName: String = "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0",
    artifactVersion: String = "0.16.0",
    compatibleDevices: [String] = [deviceType],
    minToolVersion: String = "0.1.0"
) throws -> (reader: ArtifactReader, imageSize: Int) {
    let image = lcgBuffer(count: imageSize, seed: 0xC0FF_EE12_3456_789A &+ UInt64(bitPattern: Int64(tag.hashValue)))
    let path = writeFixtureImage(image, tag: tag)
    defer { unlink(path) }

    let sink = ByteSink()
    _ = try ArtifactWriter.pack(
        to: { sink.write($0) },
        PackOptions(
            imagePath: path,
            artifactName: artifactName,
            artifactVersion: artifactVersion,
            compatibleDevices: compatibleDevices,
            compression: .none,
            minToolVersion: minToolVersion
        )
    )

    let reader = try ArtifactReader.open(TarReader(makeSource(sink.bytes)))
    return (reader, image.count)
}

/// A `FakeBlockTarget` with `capacity` scripted for slot B (the target slot
/// every test resolves to, since every `FakeConnector` starts on slot A).
private func makeBlockTarget(capacity: Int64) -> FakeBlockTarget {
    let target = FakeBlockTarget()
    target.capacities["/dev/fake-b"] = capacity
    return target
}

@Suite("E2E lifecycle")
struct LifecycleTests {
    @Test func installThenCommitAfterHealthyReboot() async throws {
        let fs = FakeFileStore()
        writeDeviceType(fs)
        let conn = FakeConnector() // starts on slot A
        let engine = makeEngine(conn: conn, fs: fs)

        let (reader, imageSize) = try packAndOpenArtifact(tag: "happy")
        let blockTarget = makeBlockTarget(capacity: Int64(imageSize) + 1024)

        let result = try await engine.install(reader, blockTarget: blockTarget)

        #expect(result.artifactName == reader.manifest.artifactName)
        #expect(result.targetSlot == .b) // current .a -> target .other == .b
        #expect(try engine.loadState()?.phase == PhaseSwapped)
        #expect(try engine.loadState()?.targetSlot == Slot.b.rawValue)
        // The payload actually landed on the target device.
        #expect(blockTarget.devices["/dev/fake-b"]?.written.count == imageSize)
        #expect(conn.callLog == ["preflightInstall", "prepareTarget(B)", "swapSlot(B, stage:true)"])

        // Simulate a healthy reboot: the firmware landed on the target
        // slot we just installed.
        conn.currentSlotValue = .b

        try await engine.commit()

        // The full connector call sequence across BOTH verbs, in order.
        #expect(conn.callLog == [
            "preflightInstall", "prepareTarget(B)", "swapSlot(B, stage:true)",
            "verifyPlatformUpdate(bootloaderUpdate:false)", "markGood",
        ])
        #expect(try engine.loadState() == nil) // state.json cleared

        let installedBytes = try fs.read("\(StateDir)/installed.json")
        let history = try JSONCodec.decodeInstalled(installedBytes)
        #expect(history.history.count == 1)
        #expect(history.history[0].artifactName == reader.manifest.artifactName)
        #expect(history.history[0].artifactVersion == reader.manifest.artifactVersion)
        #expect(history.history[0].slot == Slot.b.rawValue)
    }

    @Test func installThenFirmwareFallbackVerifyBootThenRollback() async throws {
        let fs = FakeFileStore()
        writeDeviceType(fs)
        let conn = FakeConnector() // starts on slot A
        let engine = makeEngine(conn: conn, fs: fs)

        let (reader, imageSize) = try packAndOpenArtifact(tag: "fallback")
        let blockTarget = makeBlockTarget(capacity: Int64(imageSize) + 1024)

        _ = try await engine.install(reader, blockTarget: blockTarget)
        #expect(try engine.loadState()?.phase == PhaseSwapped)
        #expect(conn.callLog == ["preflightInstall", "prepareTarget(B)", "swapSlot(B, stage:true)"])

        // Simulate a firmware FALLBACK: the platform did not flag the
        // trial slot as compromised, but on reboot it stayed on the
        // ORIGIN slot (A) rather than actually landing on the trial
        // target (B) `install` swapped to.
        conn.currentSlotValue = .a
        conn.bootIsCompromisedValue = false

        try await engine.verifyBoot()

        // Compromised-vs-fallback rule: since the platform itself did NOT
        // flag this boot as compromised, the (fine) fallback boot is still
        // confirmed to the firmware -- only the pending deployment is
        // marked failed.
        #expect(conn.callLog == [
            "preflightInstall", "prepareTarget(B)", "swapSlot(B, stage:true)",
            "bootIsCompromised", "confirmBoot",
        ])
        #expect(try engine.loadState()?.phase == PhaseFailed)

        let result = try engine.rollback()

        #expect(result.originSlot == .a)
        #expect(result.rebootRequired == false) // already running the origin slot (A)
        // Pre-reboot-style rollback (we're on the origin already): abort
        // any staged platform update THEN re-point back to the origin.
        #expect(conn.callLog == [
            "preflightInstall", "prepareTarget(B)", "swapSlot(B, stage:true)",
            "bootIsCompromised", "confirmBoot",
            "abortPlatformUpdate", "swapSlot(A, stage:false)",
        ])
        #expect(try engine.loadState() == nil) // state.json cleared
    }
}
