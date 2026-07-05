import Testing

import Connector
import Engine
import Model
import PlatformIO
import PlatformIOTesting

// Exercises `Engine.markGood` against `engine.go`'s `MarkGood`: the manual
// escape hatch calls the connector's `MarkGood` then clears any pending
// state — ports `TestMarkGoodClearsState` (internal/engine/engine_test.go).

private func makeEngine(conn: FakeConnector, fs: any FileStore = FakeFileStore()) -> Engine {
    Engine(
        conn: conn,
        fs: fs,
        runner: FakeCommandRunner(),
        clock: FixedClock("2026-07-05T12:00:00Z"),
        env: MapEnv([:])
    )
}

private func writtenState() -> State {
    State(
        schema: 1,
        phase: PhaseWritten,
        targetSlot: Slot.b.rawValue,
        artifactName: "demo-image",
        artifactVersion: "0.2.0",
        payloadSHA256: String(repeating: "a", count: 64),
        bootloaderUpdate: false,
        created: "2026-07-05T00:00:00Z"
    )
}

@Suite("Engine.markGood")
struct MarkGoodTests {
    @Test func callsConnectorMarkGoodAndClearsState() throws {
        let fs = FakeFileStore()
        let conn = FakeConnector()
        conn.currentSlotValue = .a
        let engine = makeEngine(conn: conn, fs: fs)
        try engine.saveState(writtenState())

        try engine.markGood()

        #expect(conn.callLog.contains("markGood"))
        #expect(try engine.loadState() == nil)
    }

    @Test func noPendingStateIsNotAnError() throws {
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn)

        try engine.markGood()

        #expect(conn.callLog.contains("markGood"))
        #expect(try engine.loadState() == nil)
    }

    @Test func connectorFailurePropagatesBeforeClearingState() throws {
        let fs = FakeFileStore()
        let conn = FakeConnector()
        conn.markGoodError = FakeConnectorError(message: "mark-good failed")
        let engine = makeEngine(conn: conn, fs: fs)
        try engine.saveState(writtenState())

        #expect(throws: FakeConnectorError.self) {
            try engine.markGood()
        }

        // State survives on disk: markGood never reached clearState.
        #expect(try engine.loadState() != nil)
    }
}
