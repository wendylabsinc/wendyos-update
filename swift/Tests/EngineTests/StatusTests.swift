import Testing

import Connector
import Engine
import Model
import PlatformIO
import PlatformIOTesting

// Exercises `Engine.status(verbose:)` against engine.go's `Status`: the
// booted slot's distro/kernel come from the live source, the inactive
// slot's from a (best-effort) mount of its partition — proven here by a
// `FakeVersionProbe` returning distinct, easily-told-apart values for each
// branch so a status() that mixed them up would fail the assertions.

/// A scripted `VersionProbe`: `live` stands in for `liveVersions()`,
/// `perPartition` for `slotVersions(partition:)` keyed by the partition
/// string `status()` resolved for that slot. An unscripted partition
/// mirrors the real best-effort contract and returns `("", "")`.
private struct FakeVersionProbe: VersionProbe {
    var live: (distro: String, kernel: String) = ("", "")
    var perPartition: [String: (distro: String, kernel: String)] = [:]

    func liveVersions() -> (distro: String, kernel: String) { live }

    func slotVersions(partition: String) -> (distro: String, kernel: String) {
        perPartition[partition] ?? ("", "")
    }
}

private func makeEngine(
    conn: FakeConnector,
    versionProbe: any VersionProbe = FakeVersionProbe()
) -> Engine {
    Engine(
        conn: conn,
        fs: FakeFileStore(),
        runner: FakeCommandRunner(),
        clock: FixedClock("2026-07-05T12:00:00Z"),
        env: MapEnv([:]),
        versionProbe: versionProbe
    )
}

private func pendingState() -> State {
    State(
        schema: 1,
        phase: PhaseWritten,
        targetSlot: 1,
        artifactName: "demo-image",
        artifactVersion: "0.3.0",
        payloadSHA256: String(repeating: "a", count: 64),
        bootloaderUpdate: false,
        created: "2026-07-05T00:00:00Z"
    )
}

@Suite("Engine.status")
struct StatusTests {
    @Test func reportsConnectorNameCurrentSlotSystemAndDiagnostics() throws {
        let conn = FakeConnector()
        conn.currentSlotValue = .a
        conn.systemStatusValue = [KV("bootloader", "1.2.3")]
        conn.diagnosticsValue = ["raw": "snapshot"]
        let engine = makeEngine(conn: conn)

        let status = try engine.status(verbose: true)

        #expect(status.connector == "fake")
        #expect(status.currentSlot == "A")
        #expect(status.system.count == 1)
        #expect(status.system[0].key == "bootloader")
        #expect(status.system[0].value == "1.2.3")
        #expect(status.diagnostics == ["raw": "snapshot"])
    }

    @Test func reportsPendingStateWhenOneIsInFlight() throws {
        let conn = FakeConnector()
        let engine = makeEngine(conn: conn)

        // No state saved: pending is nil.
        #expect(try engine.status(verbose: false).pending == nil)

        try engine.saveState(pendingState())
        let status = try engine.status(verbose: false)
        #expect(status.pending == pendingState())
    }

    @Test func slotsCoverBothAAndBWithBootedMatchingCurrentSlot() throws {
        let conn = FakeConnector()
        conn.currentSlotValue = .b
        let engine = makeEngine(conn: conn)

        let status = try engine.status(verbose: false)

        #expect(status.slots.map(\.slot) == ["A", "B"])
        let booted = status.slots.filter(\.booted)
        #expect(booted.count == 1)
        #expect(booted[0].slot == status.currentSlot)
        #expect(status.slots.first { $0.slot == "A" }?.booted == false)
    }

    @Test func bootedSlotVersionsComeFromLiveSourceInactiveFromMount() throws {
        let conn = FakeConnector()
        conn.currentSlotValue = .a
        conn.partitions = [.a: "/dev/fake-a", .b: "/dev/fake-b"]
        let probe = FakeVersionProbe(
            live: (distro: "live-distro", kernel: "live-kernel"),
            perPartition: ["/dev/fake-b": (distro: "mounted-distro", kernel: "mounted-kernel")]
        )
        let engine = makeEngine(conn: conn, versionProbe: probe)

        let status = try engine.status(verbose: false)

        let a = try #require(status.slots.first { $0.slot == "A" })
        let b = try #require(status.slots.first { $0.slot == "B" })
        #expect(a.booted)
        #expect(a.distro == "live-distro")
        #expect(a.kernel == "live-kernel")
        #expect(!b.booted)
        #expect(b.distro == "mounted-distro")
        #expect(b.kernel == "mounted-kernel")
    }

    @Test func perSlotHealthComesFromConnectorSlotStatus() throws {
        let conn = FakeConnector()
        conn.currentSlotValue = .a
        conn.slotStatuses = [
            .a: SlotStatus(rootfsHealth: "normal", retries: "3", note: "trial"),
            .b: SlotStatus(),
        ]
        let engine = makeEngine(conn: conn)

        let status = try engine.status(verbose: false)

        let a = try #require(status.slots.first { $0.slot == "A" })
        let b = try #require(status.slots.first { $0.slot == "B" })
        #expect(a.rootfsHealth == "normal")
        #expect(a.retries == "3")
        #expect(a.note == "trial")
        // Unscripted (default) health stays empty, not some placeholder.
        #expect(b.rootfsHealth == "")
        #expect(b.retries == "")
        #expect(b.note == "")
    }

    @Test func partitionErrorLeavesPartitionEmptyRatherThanThrowing() throws {
        let conn = FakeConnector()
        conn.currentSlotValue = .a
        conn.partitionError = FakeConnectorError(message: "no such partition")
        let engine = makeEngine(conn: conn)

        let status = try engine.status(verbose: false)

        #expect(status.slots.allSatisfy { $0.partition == "" })
    }
}
