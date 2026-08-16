import Connector
import Testing

@testable import UBootEnv

// Ports the `Controller`-level scenarios from
// `internal/connector/ubootenv/ubootenv_test.go` that are in Task 9.1's
// scope: `Name`, `CurrentSlot`, `PartitionFor`, `PrepareTarget`,
// `BootIsCompromised`, `detect`, and the `envScript`/`slotEnvValue` pure
// helpers. `SwapSlot`'s own scenarios (including the boot-not-mounted
// guard) live in `SwapSlotTests.swift`.

// MARK: - Name / registration / detect

@Test func nameIsUbootenv() {
    #expect(UBootEnv().name == "ubootenv")
}

@Test func factoryNameIsUbootenv() {
    #expect(UBootEnv.factory.name == "ubootenv")
}

@Test func selectableByExplicitName() throws {
    let conn = try ConnectorRegistry.select(explicit: "ubootenv", from: [UBootEnv.factory])
    #expect(conn.name == "ubootenv")
}

/// `fw_printenv` is not installed in CI, so the real `detect()` (which
/// does a real `PATH` scan) must report false — pinning that this
/// connector never appears "detected" on a machine without the U-Boot
/// tools, mirroring `TegraUEFITests`' analogous `nvbootctrl`-absent test.
@Test func detectFalseWhenFwPrintenvNotOnPath() {
    #expect(UBootEnv.factory.detect() == false)
}

// MARK: - envScript / slotEnvValue (pure helpers)

/// `envScript` MUST emit `"key=value"` lines. libubootenv's
/// `fw_setenv -s` silently ignores any line without `=`, so a
/// `"key value"` (space) format made every real write a no-op. Ports
/// `ubootenv_test.go`'s `TestEnvScriptUsesEqualsFormat`.
@Test func envScriptUsesEqualsFormat() {
    let got = FwEnv.envScript(["wendyos_boot_slot": "0", "bootcount": "0"])
    #expect(got.contains("wendyos_boot_slot=0\n"))
    #expect(got.contains("bootcount=0\n"))
    #expect(!got.contains("wendyos_boot_slot 0"))
    for line in got.trimmingCharactersAtEnds().split(separator: "\n") {
        #expect(line.contains("="), "envScript produced a line without '=': \(line)")
    }
}

/// Ports `ubootenv_test.go`'s `TestSlotEnvValue`.
@Test func slotEnvValueMapping() {
    #expect(UBootEnv.slotEnvValue(.a) == "0")
    #expect(UBootEnv.slotEnvValue(.b) == "1")
}

// MARK: - CurrentSlot (ports TestCurrentSlot / TestCurrentSlotNoMatch)

@Test func currentSlotResolvesBothSlots() throws {
    for running: Slot in [.a, .b] {
        let (conn, _, _, _) = testController(env: FakeUBootEnvStore(), running: running, makeSlots: true)
        #expect(try conn.currentSlot() == running, "running \(running)")
    }
}

@Test func currentSlotThrowsWhenRootMatchesNeitherSlot() {
    let (conn, _, _, _) = testController(env: FakeUBootEnvStore(), running: nil, makeSlots: true)
    #expect(throws: UBootEnvError.self) { try conn.currentSlot() }
}

// MARK: - PartitionFor (ports TestPartitionFor / TestPartitionForMissing)

@Test func partitionForResolvesBothSlots() throws {
    let (conn, _, devA, devB) = testController(env: FakeUBootEnvStore(), running: .a, makeSlots: true)
    #expect(try conn.partition(for: .a) == devA)
    #expect(try conn.partition(for: .b) == devB)
}

@Test func partitionForMissingThrows() {
    // No partlabels and no listed partitions, so this must error rather
    // than guess.
    let (conn, _, _, _) = testController(env: FakeUBootEnvStore(), running: .a, makeSlots: false)
    #expect(throws: UBootEnvError.self) { try conn.partition(for: .a) }
}

// MARK: - PrepareTarget (ports TestPrepareTargetClearsStaleTrial)

@Test func prepareTargetClearsStaleTrial() throws {
    let env = FakeUBootEnvStore([UBootEnv.envUpgradeAvailable: "1", UBootEnv.envBootCount: "3"])
    let (conn, _, _, _) = testController(env: env, running: .a, makeSlots: true)

    try conn.prepareTarget(.b)

    #expect(env.vars[UBootEnv.envUpgradeAvailable] == "0")
    #expect(env.vars[UBootEnv.envBootCount] == "0")
}

// MARK: - BootIsCompromised (ports TestBootIsCompromised)

struct BootCompromisedCase: Sendable {
    let name: String
    let armed: String
    let intended: String  // wendyos_boot_slot
    let running: Slot
    let want: Bool
}

private let bootCompromisedCases: [BootCompromisedCase] = [
    .init(name: "no trial armed", armed: "0", intended: "1", running: .a, want: false),
    .init(name: "trial armed, running requested slot", armed: "1", intended: "1", running: .b, want: false),
    .init(name: "trial armed, fell back to other slot", armed: "1", intended: "1", running: .a, want: true),
]

@Test(arguments: bootCompromisedCases)
func bootIsCompromisedMatchesTrialVsRunningSlot(_ tc: BootCompromisedCase) throws {
    let env = FakeUBootEnvStore([UBootEnv.envUpgradeAvailable: tc.armed, UBootEnv.envBootSlot: tc.intended])
    let (conn, _, _, _) = testController(env: env, running: tc.running, makeSlots: true)

    #expect(try conn.bootIsCompromised() == tc.want, "case: \(tc.name)")
}

// MARK: - Platform-update no-ops (ports TestPlatformUpdateNoOps)

@Test func platformUpdateMethodsAreNoOps() throws {
    let env = FakeUBootEnvStore()
    let (conn, _, _, _) = testController(env: env, running: .a, makeSlots: true)
    try conn.verifyPlatformUpdate(bootloaderUpdate: true)
    try conn.abortPlatformUpdate()
    #expect(env.setCalls == 0, "verify/abort must be clean no-ops: no env write")
}

// MARK: - MarkGood (ports TestMarkGood)

@Test func markGoodPinsSlotDisarmsTrialAndZeroesBootcount() throws {
    let env = FakeUBootEnvStore([
        UBootEnv.envBootSlot: "0", UBootEnv.envUpgradeAvailable: "1", UBootEnv.envBootCount: "1",
    ])
    let (conn, _, _, _) = testController(env: env, running: .b, makeSlots: true)  // committed onto slot B

    try conn.markGood()

    #expect(env.vars[UBootEnv.envBootSlot] == "1", "boot_slot must be pinned to the running slot")
    #expect(env.vars[UBootEnv.envUpgradeAvailable] == "0", "trial must be disarmed once committed")
    #expect(env.vars[UBootEnv.envBootCount] == "0")
    #expect(env.setCalls == 1, "must be a single atomic write")
}

@Test func markGoodFailsWhenCurrentSlotCannotBeResolved() {
    let env = FakeUBootEnvStore()
    let (conn, _, _, _) = testController(env: env, running: nil, makeSlots: true)

    #expect(throws: UBootEnvError.self) { try conn.markGood() }
    #expect(env.setCalls == 0, "must not write a partial env when the running slot is unknown")
}

extension String {
    /// Trims ASCII whitespace from both ends, without pulling in
    /// `Foundation` for a single trim — test-side twin of
    /// `UBootEnv.trimmed`.
    fileprivate func trimmingCharactersAtEnds() -> String {
        var view = Substring(self)
        while let f = view.first, f == " " || f == "\n" || f == "\t" || f == "\r" {
            view.removeFirst()
        }
        while let l = view.last, l == " " || l == "\n" || l == "\t" || l == "\r" {
            view.removeLast()
        }
        return String(view)
    }
}
