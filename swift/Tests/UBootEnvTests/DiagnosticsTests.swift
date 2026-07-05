import Connector
import Testing

@testable import UBootEnv

// Ports `internal/connector/ubootenv/diagnostics.go`'s `TestDiagnostics`
// plus new coverage for `SlotStatus`/`SystemStatus` designed directly
// against the Go source (which has no dedicated slot/system status
// tests): exact key names, the verbose/non-verbose boundary, and
// best-effort omission of unset vars.

// MARK: - diagnostics

@Test func diagnosticsNonVerboseReportsEnvVarsButNotDevicePaths() {
    let env = FakeUBootEnvStore([
        UBootEnv.envBootSlot: "1", UBootEnv.envUpgradeAvailable: "0", UBootEnv.envBootCount: "0",
    ])
    let (conn, _, _, _) = testController(env: env, running: .b, makeSlots: true)

    let d = conn.diagnostics(verbose: false)

    #expect(d["wendyos_boot_slot"] == "1")
    #expect(d["wendyos_upgrade_available"] == "0")
    #expect(d["bootcount"] == "0")
    #expect(d["rootfsA_dev"] == nil)
    #expect(d["rootfsB_dev"] == nil)
}

@Test func diagnosticsVerboseAddsResolvedPerSlotDevicePaths() {
    let env = FakeUBootEnvStore([UBootEnv.envBootSlot: "1"])
    let (conn, _, devA, devB) = testController(env: env, running: .b, makeSlots: true)

    let d = conn.diagnostics(verbose: true)

    #expect(d["rootfsA_dev"] == devA)
    #expect(d["rootfsB_dev"] == devB)
}

@Test func diagnosticsOmitsUnsetVars() {
    let (conn, _, _, _) = testController(env: FakeUBootEnvStore(), running: .a, makeSlots: true)

    let d = conn.diagnostics(verbose: false)

    #expect(d.isEmpty)
}

// MARK: - slotStatus

@Test func slotStatusReportsTrialArmedForTheArmedSlot() {
    let env = FakeUBootEnvStore([UBootEnv.envUpgradeAvailable: "1", UBootEnv.envBootSlot: "1"])
    let (conn, _, _, _) = testController(env: env, running: .b, makeSlots: true)

    let st = conn.slotStatus(.b)

    #expect(st.note == "trial armed")
    #expect(st.rootfsHealth == "")
    #expect(st.retries == "")
}

@Test func slotStatusIncludesBootcountInNoteWhenSet() {
    let env = FakeUBootEnvStore([
        UBootEnv.envUpgradeAvailable: "1", UBootEnv.envBootSlot: "0", UBootEnv.envBootCount: "2",
    ])
    let (conn, _, _, _) = testController(env: env, running: .a, makeSlots: true)

    let st = conn.slotStatus(.a)

    #expect(st.note == "trial armed (bootcount 2)")
}

@Test func slotStatusEmptyForTheNonArmedSlot() {
    let env = FakeUBootEnvStore([UBootEnv.envUpgradeAvailable: "1", UBootEnv.envBootSlot: "1"])
    let (conn, _, _, _) = testController(env: env, running: .b, makeSlots: true)

    let st = conn.slotStatus(.a)  // trial is armed for B, not A

    #expect(st.note == "")
}

@Test func slotStatusEmptyWhenNoTrialArmed() {
    let env = FakeUBootEnvStore([UBootEnv.envUpgradeAvailable: "0", UBootEnv.envBootSlot: "1"])
    let (conn, _, _, _) = testController(env: env, running: .b, makeSlots: true)

    let st = conn.slotStatus(.b)

    #expect(st.note == "")
}

// MARK: - systemStatus

@Test func systemStatusIsAlwaysEmpty() {
    let (conn, _, _, _) = testController(env: FakeUBootEnvStore(), running: .a, makeSlots: true)

    #expect(conn.systemStatus().isEmpty)
}
