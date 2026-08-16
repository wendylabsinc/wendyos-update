import Testing

import Connector
import Engine
import Model
import PlatformIO
import PlatformIOTesting

// Exercises `Engine.verifyBoot` against commit.go's `VerifyBoot`: it must
// always confirm the boot except in the "platform flagged this slot as
// compromised" case, and it must mark the pending deployment failed
// whenever the platform is unhealthy OR we fell back to the origin slot —
// while still confirming the (fine) fallback boot itself. Always
// best-effort: only an unreadable state file's error is ever rethrown.

private func makeEngine(
    conn: FakeConnector,
    fs: any FileStore = FakeFileStore(),
    runner: any CommandRunner = FakeCommandRunner()
) -> Engine {
    Engine(
        conn: conn,
        hooksDir: "/hooks",
        fs: fs,
        runner: runner,
        clock: FixedClock("2026-07-05T12:00:00Z"),
        env: MapEnv([:])
    )
}

private func writeHook(_ fs: FakeFileStore, _ path: String, executable: Bool) {
    try! fs.writeAtomic(path, Array("#!/bin/sh\n".utf8), mode: executable ? 0o755 : 0o644)
}

private func swappedState(targetSlot: Slot = .b) -> State {
    State(
        schema: 1,
        phase: PhaseSwapped,
        targetSlot: targetSlot.rawValue,
        artifactName: "demo-image",
        artifactVersion: "0.2.0",
        payloadSHA256: String(repeating: "a", count: 64),
        bootloaderUpdate: false,
        created: "2026-07-05T00:00:00Z"
    )
}

@Suite("Engine.verifyBoot")
struct VerifyBootTests {
    @Test func noStateConfirmsBootAndDoesNotFail() async throws {
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn)

        try await engine.verifyBoot()

        #expect(conn.callLog.contains("confirmBoot"))
        #expect(try engine.loadState() == nil)
    }

    @Test func nonSwappedPhaseConfirmsBootWithoutInspectingPlatform() async throws {
        let fs = FakeFileStore()
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: fs)
        var st = swappedState()
        st.phase = PhaseFailed
        try engine.saveState(st)

        try await engine.verifyBoot()

        #expect(conn.callLog.contains("confirmBoot"))
        #expect(!conn.callLog.contains("bootIsCompromised"))
        // Untouched: verifyBoot only confirms, it never rewrites a
        // non-`swapped` phase.
        #expect(try engine.loadState()?.phase == PhaseFailed)
    }

    @Test func compromisedBootMarksFailedAndDoesNotConfirm() async throws {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/on-failure.d/10-notify", executable: true)
        let runner = FakeCommandRunner()
        let conn = FakeConnector()
        conn.currentSlotValue = .b // matches target: only the compromised flag trips failure
        conn.bootIsCompromisedValue = true
        let engine = makeEngine(conn: conn, fs: fs, runner: runner)
        try engine.saveState(swappedState(targetSlot: .b))

        try await engine.verifyBoot()

        #expect(try engine.loadState()?.phase == PhaseFailed)
        #expect(!conn.callLog.contains("confirmBoot"))
        #expect(runner.invocations.map { $0[0] } == ["/hooks/on-failure.d/10-notify"])
    }

    @Test func fallbackToOriginSlotMarksFailedButStillConfirms() async throws {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/on-failure.d/10-notify", executable: true)
        let runner = FakeCommandRunner()
        let conn = FakeConnector()
        conn.currentSlotValue = .a // target was B; firmware fell back to A
        conn.bootIsCompromisedValue = false
        let engine = makeEngine(conn: conn, fs: fs, runner: runner)
        try engine.saveState(swappedState(targetSlot: .b))

        try await engine.verifyBoot()

        #expect(try engine.loadState()?.phase == PhaseFailed)
        #expect(conn.callLog.contains("confirmBoot"))
        #expect(runner.invocations.map { $0[0] } == ["/hooks/on-failure.d/10-notify"])
    }

    @Test func healthySwappedBootConfirmsAndStaysSwapped() async throws {
        let fs = FakeFileStore()
        let runner = FakeCommandRunner()
        let conn = FakeConnector()
        conn.currentSlotValue = .b // matches target
        conn.bootIsCompromisedValue = false
        let engine = makeEngine(conn: conn, fs: fs, runner: runner)
        try engine.saveState(swappedState(targetSlot: .b))

        try await engine.verifyBoot()

        #expect(conn.callLog.contains("confirmBoot"))
        #expect(try engine.loadState()?.phase == PhaseSwapped)
        #expect(runner.invocations.isEmpty)
    }

    @Test func unreadableStateStillConfirmsBootThenRethrows() async throws {
        let fs = FakeFileStore()
        // A present-but-corrupt state.json: `exists` is true, but decode
        // fails, so `loadState()` throws (rather than returning nil).
        try fs.writeAtomic("\(StateDir)/state.json", Array("not json".utf8), mode: 0o644)
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: fs)

        await #expect(throws: (any Error).self) {
            try await engine.verifyBoot()
        }
        #expect(conn.callLog.contains("confirmBoot"))
    }
}
