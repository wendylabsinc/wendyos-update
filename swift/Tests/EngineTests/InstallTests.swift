import Crypto
import Testing

import Artifact
import Connector
import Engine
import Model
import PlatformIO
import PlatformIOTesting
import Tar

// Exercises `Engine.install` end to end against the exact ordering ported
// from `engine.go`'s `Install` (see docs/state-schema.md's "Ordering
// rules"): one-in-flight guard, device/version gates, target resolution,
// preflight, capacity gate, pre-install hook, write, verify BEFORE
// persisting state, save(written), prepareTarget, swap, save(swapped),
// post-install hook with unwind-then-rethrow on failure.

// MARK: - FakeConnector

private struct FakeConnectorError: Error, Equatable {
    let message: String
}

/// A `Connector` that records every call (in order) it receives, with
/// scriptable per-method errors and a scriptable `InstallPreflighter`
/// result. Unlike the minimal fakes in StateTests.swift/HooksTests.swift
/// (which `install` never exercises), this one is driven directly by the
/// sequence under test, so its call log IS the assertion surface for
/// ordering.
private final class FakeConnector: Connector, InstallPreflighter, @unchecked Sendable {
    let name = "fake"

    var currentSlotValue: Slot = .a
    var partitions: [Slot: String] = [.a: "/dev/fake-a", .b: "/dev/fake-b"]

    var preflightError: Error?
    var prepareTargetError: Error?
    var swapSlotInstallError: Error?
    var swapSlotRollbackError: Error?
    var abortPlatformUpdateError: Error?

    private(set) var callLog: [String] = []

    func currentSlot() throws -> Slot { currentSlotValue }
    func partition(for s: Slot) throws -> String { partitions[s] ?? "" }

    func prepareTarget(_ s: Slot) throws {
        callLog.append("prepareTarget(\(s))")
        if let err = prepareTargetError { throw err }
    }

    func swapSlot(_ s: Slot, stagePlatformUpdate: Bool) throws {
        callLog.append("swapSlot(\(s), stage:\(stagePlatformUpdate))")
        if stagePlatformUpdate {
            if let err = swapSlotInstallError { throw err }
        } else {
            if let err = swapSlotRollbackError { throw err }
        }
    }

    func bootIsCompromised() throws -> Bool { false }
    func verifyPlatformUpdate(bootloaderUpdate: Bool) throws {}

    func abortPlatformUpdate() throws {
        callLog.append("abortPlatformUpdate")
        if let err = abortPlatformUpdateError { throw err }
    }

    func markGood() throws {}
    func diagnostics(verbose: Bool) -> [String: String] { [:] }
    func slotStatus(_ s: Slot) -> SlotStatus { SlotStatus() }
    func systemStatus() -> [KV] { [] }

    func preflightInstall() throws {
        callLog.append("preflightInstall")
        if let err = preflightError { throw err }
    }
}

// MARK: - FileStore that records every state.json write, in order

/// Wraps a `FakeFileStore`, additionally decoding and recording every
/// `state.json` write — the only way to observe the written->swapped
/// transition (and that NO save happened at all) since `FakeFileStore`
/// only exposes final content, not write history.
private final class RecordingFileStore: FileStore, @unchecked Sendable {
    private let inner: FakeFileStore
    private(set) var savedStates: [State] = []

    init(_ inner: FakeFileStore) { self.inner = inner }

    func read(_ path: String) throws -> [UInt8] { try inner.read(path) }
    func exists(_ path: String) -> Bool { inner.exists(path) }

    func writeAtomic(_ path: String, _ bytes: [UInt8], mode: UInt32) throws {
        try inner.writeAtomic(path, bytes, mode: mode)
        if path.hasSuffix("state.json"), let state = try? JSONCodec.decodeState(bytes) {
            savedStates.append(state)
        }
    }

    func remove(_ path: String) throws { try inner.remove(path) }
    func mkdirp(_ path: String, mode: UInt32) throws { try inner.mkdirp(path, mode: mode) }
    func listDir(_ path: String) throws -> [DirEntry] { try inner.listDir(path) }
}

// MARK: - Test fixtures

private func writeDeviceType(_ fs: FakeFileStore, board: String = "jetson-agx-thor") {
    try! fs.writeAtomic("/etc/wendyos/device-type", Array("BOARD=\(board)\n".utf8), mode: 0o644)
}

private func writeHook(_ fs: FakeFileStore, _ path: String, executable: Bool) {
    try! fs.writeAtomic(path, Array("#!/bin/sh\n".utf8), mode: executable ? 0o755 : 0o644)
}

/// Builds an `Engine` wired to fakes, overriding just the pieces a given
/// test cares about. `toolVersion` defaults high enough to clear
/// `makeReader`'s default `min_tool_version` so tests that don't care about
/// the version gate aren't tripped by it.
private func makeEngine(
    conn: FakeConnector,
    fs: any FileStore = FakeFileStore(),
    runner: any CommandRunner = FakeCommandRunner(),
    hooksDir: String = "/hooks",
    toolVersion: String = "0.2.0",
    progress: (@Sendable (String, Int) -> Void)? = nil
) -> Engine {
    Engine(
        conn: conn,
        hooksDir: hooksDir,
        toolVersion: toolVersion,
        fs: fs,
        runner: runner,
        clock: FixedClock("2026-07-05T12:00:00Z"),
        env: MapEnv([:]),
        progress: progress
    )
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

/// Collects everything written by a `TarWriter` into a single byte buffer.
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

/// A structurally valid v1 manifest with `payload.compression == "none"` so
/// the tar-stored bytes equal the uncompressed bytes: tests can compute
/// digests directly over the payload body without a real (de)compressor.
private func manifestJSON(
    artifactName: String,
    artifactVersion: String,
    compatibleDevices: [String],
    payloadSize: Int,
    sha256: String,
    bootloaderUpdate: Bool,
    minToolVersion: String
) -> [UInt8] {
    let devicesJSON = compatibleDevices.map { "\"\($0)\"" }.joined(separator: ", ")
    let json = """
        {
          "format_version": 1,
          "artifact_name": "\(artifactName)",
          "artifact_version": "\(artifactVersion)",
          "compatible_devices": [\(devicesJSON)],
          "payload": {
            "name": "payload",
            "size": \(payloadSize),
            "sha256": "\(sha256)",
            "compressed_sha256": "",
            "compression": "none"
          },
          "bootloader_update": \(bootloaderUpdate),
          "min_tool_version": "\(minToolVersion)"
        }
        """
    return Array(json.utf8)
}

private func buildArchive(manifestBytes: [UInt8], payloadBody: [UInt8]) throws -> [UInt8] {
    let sink = ByteSink()
    let writer = TarWriter { sink.write($0) }
    try writer.writeHeader(name: "manifest.json", size: Int64(manifestBytes.count), mode: 0o644)
    try writer.write(manifestBytes[...])
    try writer.writeHeader(name: "payload", size: Int64(payloadBody.count), mode: 0o644)
    try writer.write(payloadBody[...])
    try writer.finish()
    return sink.bytes
}

/// Builds an already-opened `ArtifactReader` over an in-memory `.wendy`
/// archive — `install` takes an opened reader; opening it is a different
/// task's concern (the CLI/download wiring).
private func makeReader(
    payloadBody: [UInt8] = Array("payload-bytes-go-here".utf8),
    artifactName: String = "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0",
    artifactVersion: String = "0.16.0",
    compatibleDevices: [String] = ["jetson-agx-thor"],
    bootloaderUpdate: Bool = false,
    minToolVersion: String = "0.1.0",
    sha256Override: String? = nil
) throws -> ArtifactReader {
    let sha256 = sha256Override ?? sha256Hex(payloadBody)
    let manifestBytes = manifestJSON(
        artifactName: artifactName,
        artifactVersion: artifactVersion,
        compatibleDevices: compatibleDevices,
        payloadSize: payloadBody.count,
        sha256: sha256,
        bootloaderUpdate: bootloaderUpdate,
        minToolVersion: minToolVersion
    )
    let archive = try buildArchive(manifestBytes: manifestBytes, payloadBody: payloadBody)
    return try ArtifactReader.open(TarReader(makeSource(archive)))
}

/// A `FakeBlockTarget` with ample capacity scripted for slot B (the target
/// slot every test resolves to, since every `FakeConnector` starts on
/// slot A) unless a test overrides it.
private func makeBlockTarget(capacity: Int64 = 1 << 30) -> FakeBlockTarget {
    let target = FakeBlockTarget()
    target.capacities["/dev/fake-b"] = capacity
    return target
}

// MARK: - Tests

@Suite("Engine.install")
struct InstallTests {
    @Test func happyPathTransitionsWrittenThenSwappedAndReturnsResult() async throws {
        let fs = FakeFileStore()
        writeDeviceType(fs)
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: recording)
        let payload = Array("payload-bytes-go-here".utf8)
        let reader = try makeReader(payloadBody: payload)
        let blockTarget = makeBlockTarget()

        let result = try await engine.install(reader, blockTarget: blockTarget)

        #expect(result.artifactName == reader.manifest.artifactName)
        #expect(result.artifactVersion == reader.manifest.artifactVersion)
        #expect(result.targetSlot == .b) // current .a -> target .other == .b
        #expect(result.bootloaderUpdate == false)

        // The payload landed on the target device, decompressed correctly.
        #expect(blockTarget.devices["/dev/fake-b"]?.written == payload)

        // State transitions: written, then swapped — in that order, and no
        // more than those two saves.
        #expect(recording.savedStates.map(\.phase) == [PhaseWritten, PhaseSwapped])
        #expect(recording.savedStates.allSatisfy { $0.targetSlot == Slot.b.rawValue })

        // Connector call order: prepareTarget(target) strictly before
        // swapSlot(target, stage:true).
        let prepIdx = try #require(conn.callLog.firstIndex(of: "prepareTarget(B)"))
        let swapIdx = try #require(conn.callLog.firstIndex(of: "swapSlot(B, stage:true)"))
        #expect(prepIdx < swapIdx)

        // Final on-disk state agrees with the last recorded save.
        let finalState = try engine.loadState()
        #expect(finalState?.phase == PhaseSwapped)
    }

    @Test func alreadyInFlightThrowsUpdateInFlightWithoutTouchingAnything() async throws {
        let fs = FakeFileStore()
        writeDeviceType(fs)
        // Seed the in-flight state directly on `fs`, BEFORE wrapping it in
        // `RecordingFileStore`, so the recorder only observes saves made by
        // `install()` itself.
        let seedEngine = makeEngine(conn: FakeConnector(), fs: fs)
        try seedEngine.saveState(State(
            schema: 1, phase: PhaseWritten, targetSlot: 1,
            artifactName: "already-installing", artifactVersion: "0.1.0",
            payloadSHA256: String(repeating: "a", count: 64),
            bootloaderUpdate: false, created: "2026-07-05T00:00:00Z"
        ))
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: recording)
        let reader = try makeReader()
        let blockTarget = makeBlockTarget()

        do {
            _ = try await engine.install(reader, blockTarget: blockTarget)
            Issue.record("expected updateInFlight")
        } catch EngineError.updateInFlight(let phase, let artifact) {
            #expect(phase == PhaseWritten)
            #expect(artifact == "already-installing")
        } catch {
            Issue.record("expected .updateInFlight, got \(error)")
        }

        #expect(blockTarget.openedPaths.isEmpty)
        #expect(recording.savedStates.isEmpty)
        #expect(conn.callLog.isEmpty)
    }

    @Test func deviceMismatchRejectsWithNothingWrittenOrSaved() async throws {
        let fs = FakeFileStore()
        writeDeviceType(fs, board: "rpi5") // artifact below targets jetson-agx-thor only
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: recording)
        let reader = try makeReader(compatibleDevices: ["jetson-agx-thor"])
        let blockTarget = makeBlockTarget()

        do {
            _ = try await engine.install(reader, blockTarget: blockTarget)
            Issue.record("expected reject")
        } catch EngineError.rejected(let message) {
            #expect(message.contains("jetson-agx-thor"))
            #expect(message.contains("rpi5"))
        } catch {
            Issue.record("expected .rejected, got \(error)")
        }

        #expect(blockTarget.openedPaths.isEmpty)
        #expect(recording.savedStates.isEmpty)
        // Rejected before slot resolution even runs.
        #expect(conn.callLog.isEmpty)
    }

    @Test func toolVersionTooLowRejectsWithNothingWrittenOrSaved() async throws {
        let fs = FakeFileStore()
        writeDeviceType(fs)
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: recording, toolVersion: "0.0.1")
        let reader = try makeReader(minToolVersion: "9.0.0")
        let blockTarget = makeBlockTarget()

        await #expect(throws: EngineError.self) {
            _ = try await engine.install(reader, blockTarget: blockTarget)
        }
        #expect(blockTarget.openedPaths.isEmpty)
        #expect(recording.savedStates.isEmpty)
    }

    @Test func payloadLargerThanCapacityRejectsBeforeAnyWrite() async throws {
        let fs = FakeFileStore()
        writeDeviceType(fs)
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: recording)
        let payload = [UInt8](repeating: 0x41, count: 4096)
        let reader = try makeReader(payloadBody: payload)
        let blockTarget = makeBlockTarget(capacity: 1024) // smaller than the payload

        do {
            _ = try await engine.install(reader, blockTarget: blockTarget)
            Issue.record("expected reject")
        } catch EngineError.rejected(let message) {
            #expect(message.contains("rootfs payload is 4096 bytes"))
            #expect(message.contains("holds only 1024 bytes"))
        } catch {
            Issue.record("expected .rejected, got \(error)")
        }

        #expect(blockTarget.openedPaths.isEmpty)
        #expect(recording.savedStates.isEmpty)
        // Capacity gate runs after slot resolution/preflight but before
        // any hook or write.
        #expect(conn.callLog == ["preflightInstall"])
    }

    @Test func unreadableCapacityFailsOpenRatherThanRejecting() async throws {
        // Fail-open: if capacity can't be probed at all (no scripted value
        // for the path), the gate must not trip — the boundary write error
        // remains the backstop. Proven by reaching (and completing) the
        // write stage successfully.
        let fs = FakeFileStore()
        writeDeviceType(fs)
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: recording)
        let payload = Array("payload-bytes-go-here".utf8)
        let reader = try makeReader(payloadBody: payload)
        let blockTarget = FakeBlockTarget() // no capacities scripted at all

        let result = try await engine.install(reader, blockTarget: blockTarget)

        #expect(result.targetSlot == .b)
        #expect(blockTarget.devices["/dev/fake-b"]?.written == payload)
    }

    @Test func installPreflighterErrorRejectsWithNothingWrittenOrSaved() async throws {
        let fs = FakeFileStore()
        writeDeviceType(fs)
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        conn.preflightError = FakeConnectorError(message: "rootfs A/B redundancy not armed")
        let engine = makeEngine(conn: conn, fs: recording)
        let reader = try makeReader()
        let blockTarget = makeBlockTarget()

        do {
            _ = try await engine.install(reader, blockTarget: blockTarget)
            Issue.record("expected reject")
        } catch EngineError.rejected(let message) {
            #expect(message.contains("rootfs A/B redundancy not armed"))
        } catch {
            Issue.record("expected .rejected, got \(error)")
        }

        #expect(blockTarget.openedPaths.isEmpty)
        #expect(recording.savedStates.isEmpty)
        #expect(conn.callLog == ["preflightInstall"])
    }

    @Test func preInstallHookFailureAbortsWithNothingWrittenOrSaved() async throws {
        let fs = FakeFileStore()
        writeDeviceType(fs)
        writeHook(fs, "/hooks/pre-install.d/10-check", executable: true)
        let runner = FakeCommandRunner()
        runner.script("/hooks/pre-install.d/10-check", result: CommandResult(exitCode: 1, stdout: [], stderr: []))
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: recording, runner: runner)
        let reader = try makeReader()
        let blockTarget = makeBlockTarget()

        await #expect(throws: HookError.self) {
            _ = try await engine.install(reader, blockTarget: blockTarget)
        }

        #expect(blockTarget.openedPaths.isEmpty)
        #expect(recording.savedStates.isEmpty)
        // Never reached prepareTarget/swapSlot.
        #expect(!conn.callLog.contains("prepareTarget(B)"))
        #expect(!conn.callLog.contains(where: { $0.hasPrefix("swapSlot") }))
    }

    @Test func prepareTargetFailureLeavesStateWrittenAndNeverSwaps() async throws {
        // engine.go: PrepareTarget error returns immediately with "state
        // stays phase=written; rollback/mark-good recovers" — the swap must
        // NOT have happened, and the persisted state must read `written`
        // (never `swapped`) so recovery has an accurate record.
        let fs = FakeFileStore()
        writeDeviceType(fs)
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        conn.prepareTargetError = FakeConnectorError(message: "prepare failed")
        let engine = makeEngine(conn: conn, fs: recording)
        let reader = try makeReader()
        let blockTarget = makeBlockTarget()

        await #expect(throws: FakeConnectorError.self) {
            _ = try await engine.install(reader, blockTarget: blockTarget)
        }

        // Only the written state was ever persisted (saveState(swapped)
        // was never reached), and it survives on disk for recovery.
        #expect(recording.savedStates.map(\.phase) == [PhaseWritten])
        #expect(try engine.loadState()?.phase == PhaseWritten)
        // The install swap never happened.
        #expect(!conn.callLog.contains("swapSlot(B, stage:true)"))
    }

    @Test func installSwapFailureLeavesStateWrittenNotSwapped() async throws {
        // engine.go: SwapSlot(target, true) error returns immediately,
        // before saveState(swapped) — so the persisted phase must stay
        // `written` for rollback/mark-good recovery.
        let fs = FakeFileStore()
        writeDeviceType(fs)
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        conn.swapSlotInstallError = FakeConnectorError(message: "install swap failed")
        let engine = makeEngine(conn: conn, fs: recording)
        let reader = try makeReader()
        let blockTarget = makeBlockTarget()

        await #expect(throws: FakeConnectorError.self) {
            _ = try await engine.install(reader, blockTarget: blockTarget)
        }

        // prepareTarget ran and the install swap was attempted (and threw)...
        #expect(conn.callLog.contains("prepareTarget(B)"))
        #expect(conn.callLog.contains("swapSlot(B, stage:true)"))
        // ...but saveState(swapped) was never reached: phase stays written.
        #expect(recording.savedStates.map(\.phase) == [PhaseWritten])
        #expect(try engine.loadState()?.phase == PhaseWritten)
    }

    @Test func digestMismatchRejectsAfterWriteButBeforeAnyStateIsSaved() async throws {
        let fs = FakeFileStore()
        writeDeviceType(fs)
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: recording)
        let payload = Array("payload-bytes-go-here".utf8)
        let wrongHash = String(repeating: "0", count: 64)
        let reader = try makeReader(payloadBody: payload, sha256Override: wrongHash)
        let blockTarget = makeBlockTarget()

        do {
            _ = try await engine.install(reader, blockTarget: blockTarget)
            Issue.record("expected reject")
        } catch EngineError.rejected {
            // expected
        } catch {
            Issue.record("expected .rejected, got \(error)")
        }

        // The write itself happened (verify runs after write)...
        #expect(blockTarget.devices["/dev/fake-b"]?.written == payload)
        // ...but no state was ever persisted, since verify precedes
        // saveState(written).
        #expect(recording.savedStates.isEmpty)
        #expect(!conn.callLog.contains("prepareTarget(B)"))
    }

    @Test func payloadSizeMismatchRejectsBeforeAnyStateIsSaved() async throws {
        let fs = FakeFileStore()
        writeDeviceType(fs)
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: recording)
        let payload = Array("payload-bytes-go-here".utf8)
        // Declare a manifest payload size larger than what's actually
        // stored in the archive (and thus what gets written).
        let manifestBytes = manifestJSON(
            artifactName: "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0",
            artifactVersion: "0.16.0",
            compatibleDevices: ["jetson-agx-thor"],
            payloadSize: payload.count + 1000,
            sha256: sha256Hex(payload),
            bootloaderUpdate: false,
            minToolVersion: "0.1.0"
        )
        let archive = try buildArchive(manifestBytes: manifestBytes, payloadBody: payload)
        let reader = try ArtifactReader.open(TarReader(makeSource(archive)))
        let blockTarget = makeBlockTarget()

        do {
            _ = try await engine.install(reader, blockTarget: blockTarget)
            Issue.record("expected reject")
        } catch EngineError.rejected(let message) {
            #expect(message.contains("payload size mismatch"))
        } catch {
            Issue.record("expected .rejected, got \(error)")
        }

        #expect(recording.savedStates.isEmpty)
    }

    @Test func postInstallHookFailureUnwindsInOrderThenRethrows() async throws {
        let fs = FakeFileStore()
        writeDeviceType(fs)
        writeHook(fs, "/hooks/post-install.d/10-check", executable: true)
        let runner = FakeCommandRunner()
        runner.script("/hooks/post-install.d/10-check", result: CommandResult(exitCode: 1, stdout: [], stderr: []))
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: recording, runner: runner)
        let reader = try makeReader()
        let blockTarget = makeBlockTarget()

        await #expect(throws: HookError.self) {
            _ = try await engine.install(reader, blockTarget: blockTarget)
        }

        // Both writes happened before the hook ran.
        #expect(recording.savedStates.map(\.phase) == [PhaseWritten, PhaseSwapped])

        // Unwind order: abortPlatformUpdate, THEN swapSlot(cur, stage:false).
        let abortIdx = try #require(conn.callLog.firstIndex(of: "abortPlatformUpdate"))
        let rollbackSwapIdx = try #require(conn.callLog.firstIndex(of: "swapSlot(A, stage:false)"))
        #expect(abortIdx < rollbackSwapIdx)
        // And both happen after the install swap.
        let installSwapIdx = try #require(conn.callLog.firstIndex(of: "swapSlot(B, stage:true)"))
        #expect(installSwapIdx < abortIdx)

        // clearState ran last: no pending state left on disk.
        #expect(try engine.loadState() == nil)
    }

    @Test func postInstallUnwindContinuesPastFailingStepsAndStillRethrows() async throws {
        // Even if abortPlatformUpdate and the rollback swap both fail, the
        // unwind must still attempt every step (logging, not throwing) and
        // ultimately rethrow the ORIGINAL hook error, not an unwind error.
        let fs = FakeFileStore()
        writeDeviceType(fs)
        writeHook(fs, "/hooks/post-install.d/10-check", executable: true)
        let runner = FakeCommandRunner()
        runner.script("/hooks/post-install.d/10-check", result: CommandResult(exitCode: 1, stdout: [], stderr: []))
        let recording = RecordingFileStore(fs)
        let conn = FakeConnector()
        conn.abortPlatformUpdateError = FakeConnectorError(message: "abort failed")
        conn.swapSlotRollbackError = FakeConnectorError(message: "rollback swap failed")
        let engine = makeEngine(conn: conn, fs: recording, runner: runner)
        let reader = try makeReader()
        let blockTarget = makeBlockTarget()

        await #expect(throws: HookError.self) {
            _ = try await engine.install(reader, blockTarget: blockTarget)
        }

        // clearState still ran despite the two prior unwind steps failing.
        #expect(try engine.loadState() == nil)
        #expect(conn.callLog.contains("abortPlatformUpdate"))
        #expect(conn.callLog.contains("swapSlot(A, stage:false)"))
    }
}
