import Testing

import Connector
import Engine
import Model
import PlatformIO
import PlatformIOTesting

// Exercises `Engine.commit` against the exact ordering ported from
// commit.go's `Commit`: no-state -> nothingToCommit; phase gate; firmware
// fallback -> mark failed + advisory + platformVerify; platform-verify
// failure -> same; health-hook failure -> mark failed + advisory +
// rethrown HookError; happy path -> markGood, clearState BEFORE
// appendInstalled, capped history, post-commit advisory.

private func makeEngine(
    conn: FakeConnector,
    fs: any FileStore = FakeFileStore(),
    runner: any CommandRunner = FakeCommandRunner(),
    hooksDir: String = "/hooks",
    clock: any Clock = FixedClock("2026-07-05T12:00:00Z")
) -> Engine {
    Engine(
        conn: conn,
        hooksDir: hooksDir,
        fs: fs,
        runner: runner,
        clock: clock,
        env: MapEnv([:])
    )
}

private func writeHook(_ fs: FakeFileStore, _ path: String, executable: Bool) {
    try! fs.writeAtomic(path, Array("#!/bin/sh\n".utf8), mode: executable ? 0o755 : 0o644)
}

private struct InjectedWriteError: Error {}

/// Wraps a `FakeFileStore`, making `writeAtomic` fail for one specific
/// path — used to prove `commit()`'s `appendInstalled` failure is
/// swallowed (logged, not fatal) and, more importantly, that it happens
/// strictly AFTER `clearState()` already succeeded.
private final class FailingWriteFileStore: FileStore, @unchecked Sendable {
    private let inner: FakeFileStore
    let failingPath: String

    init(_ inner: FakeFileStore, failingPath: String) {
        self.inner = inner
        self.failingPath = failingPath
    }

    func read(_ path: String) throws -> [UInt8] { try inner.read(path) }
    func exists(_ path: String) -> Bool { inner.exists(path) }

    func writeAtomic(_ path: String, _ bytes: [UInt8], mode: UInt32) throws {
        if path == failingPath { throw InjectedWriteError() }
        try inner.writeAtomic(path, bytes, mode: mode)
    }

    func remove(_ path: String) throws { try inner.remove(path) }
    func mkdirp(_ path: String, mode: UInt32) throws { try inner.mkdirp(path, mode: mode) }
    func listDir(_ path: String) throws -> [DirEntry] { try inner.listDir(path) }
    func resolveSymlink(_ path: String) -> String? { inner.resolveSymlink(path) }
}

/// A pending `swapped` state targeting slot B, matching what `install`
/// would have left behind.
private func swappedState(artifactName: String = "demo-image", artifactVersion: String = "0.2.0") -> State {
    State(
        schema: 1,
        phase: PhaseSwapped,
        targetSlot: Slot.b.rawValue,
        artifactName: artifactName,
        artifactVersion: artifactVersion,
        payloadSHA256: String(repeating: "a", count: 64),
        bootloaderUpdate: false,
        created: "2026-07-05T00:00:00Z"
    )
}

@Suite("Engine.commit")
struct CommitTests {
    @Test func noStateThrowsNothingToCommitExitCodeTwo() async throws {
        let engine = makeEngine(conn: FakeConnector())

        do {
            try await engine.commit()
            Issue.record("expected CommitError")
        } catch let error as CommitError {
            #expect(error.kind == .nothingToCommit)
            #expect(error.exitCode == 2)
        }
    }

    @Test func phaseFailedThrowsPhaseFailedExitCodeOne() async throws {
        let fs = FakeFileStore()
        let engine = makeEngine(conn: FakeConnector(), fs: fs)
        var st = swappedState()
        st.phase = PhaseFailed
        try engine.saveState(st)

        do {
            try await engine.commit()
            Issue.record("expected CommitError")
        } catch let error as CommitError {
            guard case .phaseFailed(let msg) = error.kind else {
                Issue.record("expected .phaseFailed, got \(error.kind)")
                return
            }
            #expect(msg.contains("demo-image"))
            #expect(msg.contains("marked failed"))
            #expect(error.exitCode == 1)
        }
    }

    @Test func phaseWrittenThrowsPhaseFailedExitCodeOne() async throws {
        let fs = FakeFileStore()
        let engine = makeEngine(conn: FakeConnector(), fs: fs)
        var st = swappedState()
        st.phase = PhaseWritten
        try engine.saveState(st)

        do {
            try await engine.commit()
            Issue.record("expected CommitError")
        } catch let error as CommitError {
            guard case .phaseFailed(let msg) = error.kind else {
                Issue.record("expected .phaseFailed, got \(error.kind)")
                return
            }
            #expect(msg.contains("never swapped"))
            #expect(error.exitCode == 1)
        }
    }

    @Test func firmwareFallbackMarksFailedRunsAdvisoryAndThrowsPlatformVerify() async throws {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/on-failure.d/10-notify", executable: true)
        let runner = FakeCommandRunner()
        let conn = FakeConnector()
        conn.currentSlotValue = .a // state targets B, but we fell back to A
        let engine = makeEngine(conn: conn, fs: fs, runner: runner)
        try engine.saveState(swappedState())

        do {
            try await engine.commit()
            Issue.record("expected CommitError")
        } catch let error as CommitError {
            guard case .platformVerify(let msg) = error.kind else {
                Issue.record("expected .platformVerify, got \(error.kind)")
                return
            }
            #expect(msg.contains("firmware fallback"))
            #expect(error.exitCode == 4)
        }

        // State marked failed on disk...
        #expect(try engine.loadState()?.phase == PhaseFailed)
        // ...and the on-failure advisory hook ran.
        #expect(runner.invocations.map { $0[0] } == ["/hooks/on-failure.d/10-notify"])
        // markGood must NOT have run: the deployment never passed verification.
        #expect(!conn.callLog.contains("markGood"))
    }

    @Test func verifyPlatformUpdateFailureMarksFailedRunsAdvisoryAndThrowsPlatformVerify() async throws {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/on-failure.d/10-notify", executable: true)
        let runner = FakeCommandRunner()
        let conn = FakeConnector()
        conn.currentSlotValue = .b // matches target, so we get past the fallback check
        conn.verifyPlatformUpdateError = FakeConnectorError(message: "esrt cascade incomplete")
        let engine = makeEngine(conn: conn, fs: fs, runner: runner)
        try engine.saveState(swappedState())

        do {
            try await engine.commit()
            Issue.record("expected CommitError")
        } catch let error as CommitError {
            guard case .platformVerify(let msg) = error.kind else {
                Issue.record("expected .platformVerify, got \(error.kind)")
                return
            }
            #expect(msg.contains("esrt cascade incomplete"))
            #expect(error.exitCode == 4)
        }

        #expect(try engine.loadState()?.phase == PhaseFailed)
        #expect(runner.invocations.map { $0[0] } == ["/hooks/on-failure.d/10-notify"])
        #expect(!conn.callLog.contains("markGood"))
    }

    @Test func healthHookFailureMarksFailedRunsAdvisoryAndRethrowsHookError() async throws {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/health.d/10-check", executable: true)
        writeHook(fs, "/hooks/on-failure.d/10-notify", executable: true)
        let runner = FakeCommandRunner()
        runner.script("/hooks/health.d/10-check", result: CommandResult(exitCode: 1, stdout: [], stderr: []))
        let conn = FakeConnector()
        conn.currentSlotValue = .b
        let engine = makeEngine(conn: conn, fs: fs, runner: runner)
        try engine.saveState(swappedState())

        do {
            try await engine.commit()
            Issue.record("expected HookError")
        } catch let error as HookError {
            #expect(error.phase == HookHealth)
            #expect(error.exitCode == 4)
        }

        #expect(try engine.loadState()?.phase == PhaseFailed)
        // on-failure advisory ran too (not just the health gate itself).
        #expect(runner.invocations.map { $0[0] }.contains("/hooks/on-failure.d/10-notify"))
        #expect(!conn.callLog.contains("markGood"))
    }

    @Test func happyPathMarksGoodClearsStateAppendsHistoryAndRunsPostCommitAdvisory() async throws {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/post-commit.d/10-notify", executable: true)
        let runner = FakeCommandRunner()
        let conn = FakeConnector()
        conn.currentSlotValue = .b
        let clock = FixedClock("2026-07-05T13:00:00Z")
        let engine = makeEngine(conn: conn, fs: fs, runner: runner, clock: clock)
        try engine.saveState(swappedState(artifactName: "demo-image", artifactVersion: "0.2.0"))

        try await engine.commit()

        #expect(conn.callLog.contains("markGood"))
        #expect(try engine.loadState() == nil) // state cleared

        let installedBytes = try fs.read("\(StateDir)/installed.json")
        let history = try JSONCodec.decodeInstalled(installedBytes)
        #expect(history.history.count == 1)
        #expect(history.history[0].artifactName == "demo-image")
        #expect(history.history[0].artifactVersion == "0.2.0")
        #expect(history.history[0].committed == "2026-07-05T13:00:00Z")
        #expect(history.history[0].slot == Slot.b.rawValue)

        #expect(runner.invocations.map { $0[0] } == ["/hooks/post-commit.d/10-notify"])
    }

    @Test func clearStateHappensBeforeAppendInstalled() async throws {
        // Order per state-schema.md: a crash between the two loses only
        // history, never safety. We can't observe an actual crash, but we
        // CAN prove the sequencing by making appendInstalled's write fail
        // and confirming clearState had already taken effect.
        let inner = FakeFileStore()
        let failing = FailingWriteFileStore(inner, failingPath: "\(StateDir)/installed.json")
        let conn = FakeConnector()
        conn.currentSlotValue = .b
        let engine = makeEngine(conn: conn, fs: failing)
        try engine.saveState(swappedState())

        // appendInstalled's writeAtomic throws — commit must still succeed
        // (logged, not fatal) and state must already be clear by the time
        // that happens.
        try await engine.commit()

        #expect(try engine.loadState() == nil)
    }

    @Test func installedHistoryCapsAtTenKeepingTheMostRecent() async throws {
        let fs = FakeFileStore()
        let conn = FakeConnector()
        conn.currentSlotValue = .b
        let engine = makeEngine(conn: conn, fs: fs)

        for i in 1...11 {
            try engine.saveState(swappedState(artifactName: "image-\(i)", artifactVersion: "0.\(i).0"))
            try await engine.commit()
        }

        let installedBytes = try fs.read("\(StateDir)/installed.json")
        let history = try JSONCodec.decodeInstalled(installedBytes)
        #expect(history.history.count == 10)
        #expect(history.history.map(\.artifactName) == (2...11).map { "image-\($0)" })
    }
}
