import Testing

import Connector
import Engine
import Model
import PlatformIO
import PlatformIOTesting

// Exercises `Engine.rollback` against commit.go's `Rollback`: no state ->
// throws; pre-reboot (still on the origin slot) aborts a staged platform
// update THEN re-points the slot, no reboot needed; post-reboot (running
// the target slot) skips the abort, reboot is required.

private func makeEngine(conn: FakeConnector, fs: any FileStore = FakeFileStore()) -> Engine {
    Engine(
        conn: conn,
        fs: fs,
        runner: FakeCommandRunner(),
        clock: FixedClock("2026-07-05T12:00:00Z"),
        env: MapEnv([:])
    )
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

@Suite("Engine.rollback")
struct RollbackTests {
    @Test func noStateThrows() throws {
        let engine = makeEngine(conn: FakeConnector())

        #expect(throws: RollbackError.self) {
            _ = try engine.rollback()
        }
    }

    @Test func preRebootAbortsThenSwapsAndRebootIsNotRequired() throws {
        // Target is B (origin A); still running A (pre-reboot).
        let fs = FakeFileStore()
        let conn = FakeConnector()
        conn.currentSlotValue = .a
        let engine = makeEngine(conn: conn, fs: fs)
        try engine.saveState(swappedState(targetSlot: .b))

        let result = try engine.rollback()

        #expect(result.originSlot == .a)
        #expect(result.rebootRequired == false)

        let abortIdx = try #require(conn.callLog.firstIndex(of: "abortPlatformUpdate"))
        let swapIdx = try #require(conn.callLog.firstIndex(of: "swapSlot(A, stage:false)"))
        #expect(abortIdx < swapIdx)

        #expect(try engine.loadState() == nil)
    }

    @Test func postRebootSkipsAbortAndRebootIsRequired() throws {
        // Target is B (origin A); already running B (post-reboot).
        let fs = FakeFileStore()
        let conn = FakeConnector()
        conn.currentSlotValue = .b
        let engine = makeEngine(conn: conn, fs: fs)
        try engine.saveState(swappedState(targetSlot: .b))

        let result = try engine.rollback()

        #expect(result.originSlot == .a)
        #expect(result.rebootRequired == true)

        #expect(!conn.callLog.contains("abortPlatformUpdate"))
        #expect(conn.callLog.contains("swapSlot(A, stage:false)"))

        #expect(try engine.loadState() == nil)
    }

    @Test func abortFailurePropagatesBeforeSwap() throws {
        let fs = FakeFileStore()
        let conn = FakeConnector()
        conn.currentSlotValue = .a
        conn.abortPlatformUpdateError = FakeConnectorError(message: "abort failed")
        let engine = makeEngine(conn: conn, fs: fs)
        try engine.saveState(swappedState(targetSlot: .b))

        #expect(throws: FakeConnectorError.self) {
            _ = try engine.rollback()
        }

        // The swap must never have been attempted: abort's failure aborts
        // rollback immediately.
        #expect(!conn.callLog.contains(where: { $0.hasPrefix("swapSlot") }))
        // State survives on disk since rollback never reached clearState.
        #expect(try engine.loadState() != nil)
    }
}
