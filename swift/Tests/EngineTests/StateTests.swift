import Testing

import Connector
import Engine
import Model
import PlatformIO
import PlatformIOTesting

/// Minimal fake `Connector` — Task 6.1 only exercises state persistence and
/// the policy helpers (`deviceType`/`versionAtLeast`), neither of which
/// calls into the connector, so every method just throws a sentinel if
/// that assumption is ever wrong. (`ConnectorTests`'s own fake is
/// `private` to that test target, so this is a small standalone copy
/// rather than a shared import.)
private final class FakeConnector: Connector {
    let name = "fake"
    func currentSlot() throws -> Slot { .a }
    func partition(for s: Slot) throws -> String { "" }
    func prepareTarget(_ s: Slot) throws {}
    func swapSlot(_ s: Slot, stagePlatformUpdate: Bool) throws {}
    func bootIsCompromised() throws -> Bool { false }
    func verifyPlatformUpdate(bootloaderUpdate: Bool) throws {}
    func abortPlatformUpdate() throws {}
    func markGood() throws {}
    func diagnostics(verbose: Bool) -> [String: String] { [:] }
    func slotStatus(_ s: Slot) -> SlotStatus { SlotStatus() }
    func systemStatus() -> [KV] { [] }
}

/// Builds an `Engine` wired to fakes, overriding just the pieces a given
/// test cares about.
private func makeEngine(
    fs: any FileStore = FakeFileStore(),
    deviceTypePath: String = ""
) -> Engine {
    Engine(
        conn: FakeConnector(),
        deviceTypePath: deviceTypePath,
        fs: fs,
        runner: FakeCommandRunner(),
        clock: FixedClock("2026-07-05T12:00:00Z"),
        env: MapEnv([:])
    )
}

private func sampleState() -> State {
    State(
        schema: 1,
        phase: "written",
        targetSlot: 1,
        artifactName: "wendyos-image-jetson-agx-thor",
        artifactVersion: "0.2.0",
        payloadSHA256: String(repeating: "a", count: 64),
        bootloaderUpdate: false,
        created: "2026-07-05T12:00:00Z"
    )
}

@Suite("Engine state persistence")
struct StatePersistenceTests {
    @Test func saveStateThenLoadStateRoundTrips() throws {
        let engine = makeEngine()
        let state = sampleState()

        try engine.saveState(state)
        let loaded = try engine.loadState()

        #expect(loaded == state)
    }

    @Test func loadStateWithNoFileReturnsNil() throws {
        let engine = makeEngine()

        #expect(try engine.loadState() == nil)
    }

    @Test func clearStateOnAbsentStateIsNotAnError() throws {
        let engine = makeEngine()

        try engine.clearState()
        #expect(try engine.loadState() == nil)
    }

    @Test func clearStateRemovesAPreviouslySavedState() throws {
        let engine = makeEngine()
        try engine.saveState(sampleState())

        try engine.clearState()

        #expect(try engine.loadState() == nil)
    }

    @Test func saveStateWritesTwoSpacePrettyJSONWithTrailingNewline() throws {
        let fs = FakeFileStore()
        let engine = makeEngine(fs: fs)

        try engine.saveState(sampleState())

        let bytes = try fs.read("\(StateDir)/state.json")
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"schema\": 1,\n"))
        #expect(text.hasSuffix("}\n"))
    }
}

@Suite("Engine.deviceType")
struct DeviceTypeTests {
    @Test func parsesBoardLineFromDefaultPath() throws {
        let fs = FakeFileStore()
        try fs.writeAtomic(
            "/etc/wendyos/device-type",
            Array("SOME_KEY=x\nBOARD=jetson-agx-thor\nOTHER=y\n".utf8),
            mode: 0o644
        )
        let engine = makeEngine(fs: fs)

        #expect(try engine.deviceType() == "jetson-agx-thor")
    }

    @Test func parsesBoardLineFromCustomPath() throws {
        let fs = FakeFileStore()
        try fs.writeAtomic(
            "/custom/device-type",
            Array("BOARD=rpi5\n".utf8),
            mode: 0o644
        )
        let engine = makeEngine(fs: fs, deviceTypePath: "/custom/device-type")

        #expect(try engine.deviceType() == "rpi5")
    }

    @Test func firstNonEmptyBoardLineWins() throws {
        let fs = FakeFileStore()
        try fs.writeAtomic(
            "/etc/wendyos/device-type",
            Array("BOARD=\nBOARD=  \nBOARD=jetson-agx-thor\nBOARD=rpi5\n".utf8),
            mode: 0o644
        )
        let engine = makeEngine(fs: fs)

        // "BOARD=  " has a non-empty value once considered without the Go
        // TrimSpace-before-cut semantics it's `BOARD=` cut from a
        // whitespace-only trimmed line — trimmed first, so it becomes
        // empty and is skipped just like the outright-empty line above it.
        #expect(try engine.deviceType() == "jetson-agx-thor")
    }

    @Test func errorsWhenNoBoardLinePresent() {
        let fs = FakeFileStore()
        try? fs.writeAtomic(
            "/etc/wendyos/device-type",
            Array("SOME_KEY=x\n".utf8),
            mode: 0o644
        )
        let engine = makeEngine(fs: fs)

        #expect(throws: EngineError.self) {
            try engine.deviceType()
        }
    }

    @Test func errorsWhenFileIsMissing() {
        let engine = makeEngine(fs: FakeFileStore())

        #expect(throws: EngineError.self) {
            try engine.deviceType()
        }
    }
}

@Suite("versionAtLeast / parseVersion")
struct VersionPolicyTests {
    @Test func haveGreaterThanMinIsAtLeast() {
        #expect(versionAtLeast("0.2.0", "0.1.0") == true)
    }

    @Test func haveLessThanMinIsNotAtLeast() {
        #expect(versionAtLeast("0.1.0", "0.2.0") == false)
    }

    @Test func equalVersionsAreAtLeast() {
        #expect(versionAtLeast("0.1.0", "0.1.0") == true)
    }

    @Test func emptyMinGatesNothing() {
        #expect(versionAtLeast("x", "") == true)
    }

    @Test func malformedMinGatesNothing() {
        #expect(versionAtLeast("0.1.0", "not-a-version") == true)
        #expect(versionAtLeast("garbage", "not-a-version") == true)
    }

    @Test func unparseableHaveWithValidMinIsNotAtLeast() {
        #expect(versionAtLeast("not-a-version", "0.1.0") == false)
    }

    @Test func preReleaseSuffixIsIgnored() {
        #expect(versionAtLeast("0.2.0-rc1", "0.2.0") == true)
        #expect(versionAtLeast("0.2.0", "0.2.0-rc1") == true)
    }

    @Test func parseVersionRejectsWrongComponentCount() {
        #expect(throws: VersionParseError.self) {
            try parseVersion("0.1")
        }
        #expect(throws: VersionParseError.self) {
            try parseVersion("0.1.2.3")
        }
    }

    @Test func parseVersionParsesEachComponent() throws {
        let parsed = try parseVersion("1.2.3")
        #expect(parsed == (1, 2, 3))
    }
}
