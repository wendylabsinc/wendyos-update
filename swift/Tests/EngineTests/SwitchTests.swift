import Testing

import Connector
import Engine
import Model
import PlatformIO
import PlatformIOTesting

// Exercises `Engine.switch(to:)` against commit.go's `Switch`: refuses
// while an update is pending, refuses a no-op switch to the current slot,
// otherwise prepares then swaps the target — in that order.

private func makeEngine(conn: FakeConnector, fs: any FileStore = FakeFileStore()) -> Engine {
    Engine(
        conn: conn,
        fs: fs,
        runner: FakeCommandRunner(),
        clock: FixedClock("2026-07-05T12:00:00Z"),
        env: MapEnv([:])
    )
}

private func pendingState() -> State {
    State(
        schema: 1,
        phase: PhaseSwapped,
        targetSlot: Slot.b.rawValue,
        artifactName: "demo-image",
        artifactVersion: "0.2.0",
        payloadSHA256: String(repeating: "a", count: 64),
        bootloaderUpdate: false,
        created: "2026-07-05T00:00:00Z"
    )
}

@Suite("Engine.switch")
struct SwitchTests {
    @Test func pendingUpdateRefusesTheSwitch() throws {
        let fs = FakeFileStore()
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn, fs: fs)
        try engine.saveState(pendingState())

        #expect(throws: SwitchError.self) {
            try engine.switch(to: .a)
        }
        #expect(conn.callLog.isEmpty)
    }

    @Test func targetEqualToCurrentRefuses() throws {
        let conn = FakeConnector()
        conn.currentSlotValue = .a
        let engine = makeEngine(conn: conn)

        #expect(throws: SwitchError.self) {
            try engine.switch(to: .a)
        }
        #expect(!conn.callLog.contains(where: { $0.hasPrefix("prepareTarget") || $0.hasPrefix("swapSlot") }))
    }

    @Test func prepareTargetThenSwapSlotInOrder() throws {
        let conn = FakeConnector()
        conn.currentSlotValue = .a
        let engine = makeEngine(conn: conn)

        try engine.switch(to: .b)

        let prepIdx = try #require(conn.callLog.firstIndex(of: "prepareTarget(B)"))
        let swapIdx = try #require(conn.callLog.firstIndex(of: "swapSlot(B, stage:false)"))
        #expect(prepIdx < swapIdx)
    }

    @Test func prepareTargetFailurePropagatesAndNeverSwaps() throws {
        let conn = FakeConnector()
        conn.currentSlotValue = .a
        conn.prepareTargetError = FakeConnectorError(message: "prepare failed")
        let engine = makeEngine(conn: conn)

        #expect(throws: SwitchError.self) {
            try engine.switch(to: .b)
        }
        #expect(!conn.callLog.contains(where: { $0.hasPrefix("swapSlot") }))
    }

    @Test func swapSlotFailurePropagates() throws {
        let conn = FakeConnector()
        conn.currentSlotValue = .a
        conn.swapSlotRollbackError = FakeConnectorError(message: "swap failed")
        let engine = makeEngine(conn: conn)

        #expect(throws: SwitchError.self) {
            try engine.switch(to: .b)
        }
        #expect(conn.callLog.contains("prepareTarget(B)"))
    }
}
