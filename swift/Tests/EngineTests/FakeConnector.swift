import Connector

// Shared `Connector` test double for every EngineTests file whose
// assertions ride on the exact sequence of connector calls (install,
// commit, rollback, switch, verify-boot). Originally introduced by
// InstallTests.swift (Task 6.3) as a `private` fake; promoted to a
// target-visible shared type here (Task 6.4) rather than duplicated,
// since commit/rollback/switch/verify-boot all need the same call-log
// idiom PLUS a few connector methods `install` never exercised
// (`verifyPlatformUpdate`, `bootIsCompromised`, `markGood`,
// `abortPlatformUpdate` failures, and `BootConfirmer`).

struct FakeConnectorError: Error, Equatable {
    let message: String
}

/// A `Connector` that records every call (in order) it receives, with
/// scriptable per-method errors/results and a scriptable
/// `InstallPreflighter` result. Also conforms to `BootConfirmer` so
/// verify-boot tests can exercise `Engine.confirmBoot`'s cast-and-call path
/// without a second fake type.
final class FakeConnector: Connector, InstallPreflighter, BootConfirmer, @unchecked Sendable {
    let name = "fake"

    var currentSlotValue: Slot = .a
    var partitions: [Slot: String] = [.a: "/dev/fake-a", .b: "/dev/fake-b"]
    /// When set, `partition(for:)` throws this for every slot instead of
    /// looking up `partitions` — models a board that can't resolve a
    /// slot's device node (`status` must fall back to an empty string, not
    /// propagate the error).
    var partitionError: Error?
    var slotStatuses: [Slot: SlotStatus] = [:]
    var systemStatusValue: [KV] = []
    var diagnosticsValue: [String: String] = [:]

    var preflightError: Error?
    var prepareTargetError: Error?
    var swapSlotInstallError: Error?
    var swapSlotRollbackError: Error?
    var abortPlatformUpdateError: Error?
    var verifyPlatformUpdateError: Error?
    var markGoodError: Error?
    var confirmBootError: Error?

    /// `nil` (the default) means "the connector could not determine
    /// compromised status" (Go's `err != nil` branch of `if compromised,
    /// err := ...; err == nil && compromised`) — `verifyBoot` treats that
    /// exactly like `false` (ignores the value). Tests that care use
    /// `.success(true)`/`.success(false)` explicitly; `bootIsCompromisedError`
    /// takes precedence when set.
    var bootIsCompromisedValue: Bool = false
    var bootIsCompromisedError: Error?

    private(set) var callLog: [String] = []

    // `currentSlot`/`partition(for:)` are deliberately NOT logged:
    // `install` calls both before `preflightInstall` runs, and
    // InstallTests.swift asserts `callLog == ["preflightInstall"]` at that
    // point (see `payloadLargerThanCapacityRejectsBeforeAnyWrite` and
    // `installPreflighterErrorRejectsWithNothingWrittenOrSaved`) — no
    // commit/rollback/switch/verify-boot test needs either call's
    // position in the shared log, only its return value or thrown error.
    func currentSlot() throws -> Slot { currentSlotValue }
    func partition(for s: Slot) throws -> String {
        if let err = partitionError { throw err }
        return partitions[s] ?? ""
    }

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

    func bootIsCompromised() throws -> Bool {
        callLog.append("bootIsCompromised")
        if let err = bootIsCompromisedError { throw err }
        return bootIsCompromisedValue
    }

    func verifyPlatformUpdate(bootloaderUpdate: Bool) throws {
        callLog.append("verifyPlatformUpdate(bootloaderUpdate:\(bootloaderUpdate))")
        if let err = verifyPlatformUpdateError { throw err }
    }

    func abortPlatformUpdate() throws {
        callLog.append("abortPlatformUpdate")
        if let err = abortPlatformUpdateError { throw err }
    }

    func markGood() throws {
        callLog.append("markGood")
        if let err = markGoodError { throw err }
    }

    func diagnostics(verbose: Bool) -> [String: String] { diagnosticsValue }
    func slotStatus(_ s: Slot) -> SlotStatus { slotStatuses[s] ?? SlotStatus() }
    func systemStatus() -> [KV] { systemStatusValue }

    func preflightInstall() throws {
        callLog.append("preflightInstall")
        if let err = preflightError { throw err }
    }

    func confirmBoot() throws {
        callLog.append("confirmBoot")
        if let err = confirmBootError { throw err }
    }
}
