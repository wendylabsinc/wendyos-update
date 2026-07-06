import Connector

// Shared `Connector` test double for every test target whose assertions
// ride on the exact sequence of connector calls (install, commit, rollback,
// switch, verify-boot). Originally introduced by EngineTests/InstallTests.swift
// (Task 6.3) as a `private` fake there, later promoted to an EngineTests-
// target-visible shared type (Task 6.4), and promoted again here (Task 11.1)
// into `PlatformIOTesting` — a shared test-support target — so `E2ETests`
// (which drives the real `Engine` end to end and needs the exact same
// call-log idiom) can use it too, without EngineTests and E2ETests each
// carrying their own copy.

public struct FakeConnectorError: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// A `Connector` that records every call (in order) it receives, with
/// scriptable per-method errors/results and a scriptable
/// `InstallPreflighter` result. Also conforms to `BootConfirmer` so
/// verify-boot tests can exercise `Engine.confirmBoot`'s cast-and-call path
/// without a second fake type.
public final class FakeConnector: Connector, InstallPreflighter, BootConfirmer, @unchecked Sendable {
    public let name = "fake"

    public var currentSlotValue: Slot = .a
    public var partitions: [Slot: String] = [.a: "/dev/fake-a", .b: "/dev/fake-b"]
    /// When set, `partition(for:)` throws this for every slot instead of
    /// looking up `partitions` — models a board that can't resolve a
    /// slot's device node (`status` must fall back to an empty string, not
    /// propagate the error).
    public var partitionError: Error?
    public var slotStatuses: [Slot: SlotStatus] = [:]
    public var systemStatusValue: [KV] = []
    public var diagnosticsValue: [String: String] = [:]

    public var preflightError: Error?
    public var prepareTargetError: Error?
    public var swapSlotInstallError: Error?
    public var swapSlotRollbackError: Error?
    public var abortPlatformUpdateError: Error?
    public var verifyPlatformUpdateError: Error?
    public var markGoodError: Error?
    public var confirmBootError: Error?

    /// `nil` (the default) means "the connector could not determine
    /// compromised status" (Go's `err != nil` branch of `if compromised,
    /// err := ...; err == nil && compromised`) — `verifyBoot` treats that
    /// exactly like `false` (ignores the value). Tests that care use
    /// `.success(true)`/`.success(false)` explicitly; `bootIsCompromisedError`
    /// takes precedence when set.
    public var bootIsCompromisedValue: Bool = false
    public var bootIsCompromisedError: Error?

    public private(set) var callLog: [String] = []

    public init() {}

    // `currentSlot`/`partition(for:)` are deliberately NOT logged:
    // `install` calls both before `preflightInstall` runs, and
    // InstallTests.swift asserts `callLog == ["preflightInstall"]` at that
    // point (see `payloadLargerThanCapacityRejectsBeforeAnyWrite` and
    // `installPreflighterErrorRejectsWithNothingWrittenOrSaved`) — no
    // commit/rollback/switch/verify-boot test needs either call's
    // position in the shared log, only its return value or thrown error.
    public func currentSlot() throws -> Slot { currentSlotValue }
    public func partition(for s: Slot) throws -> String {
        if let err = partitionError { throw err }
        return partitions[s] ?? ""
    }

    public func prepareTarget(_ s: Slot) throws {
        callLog.append("prepareTarget(\(s))")
        if let err = prepareTargetError { throw err }
    }

    public func swapSlot(_ s: Slot, stagePlatformUpdate: Bool) throws {
        callLog.append("swapSlot(\(s), stage:\(stagePlatformUpdate))")
        if stagePlatformUpdate {
            if let err = swapSlotInstallError { throw err }
        } else {
            if let err = swapSlotRollbackError { throw err }
        }
    }

    public func bootIsCompromised() throws -> Bool {
        callLog.append("bootIsCompromised")
        if let err = bootIsCompromisedError { throw err }
        return bootIsCompromisedValue
    }

    public func verifyPlatformUpdate(bootloaderUpdate: Bool) throws {
        callLog.append("verifyPlatformUpdate(bootloaderUpdate:\(bootloaderUpdate))")
        if let err = verifyPlatformUpdateError { throw err }
    }

    public func abortPlatformUpdate() throws {
        callLog.append("abortPlatformUpdate")
        if let err = abortPlatformUpdateError { throw err }
    }

    public func markGood() throws {
        callLog.append("markGood")
        if let err = markGoodError { throw err }
    }

    public func diagnostics(verbose: Bool) -> [String: String] { diagnosticsValue }
    public func slotStatus(_ s: Slot) -> SlotStatus { slotStatuses[s] ?? SlotStatus() }
    public func systemStatus() -> [KV] { systemStatusValue }

    public func preflightInstall() throws {
        callLog.append("preflightInstall")
        if let err = preflightError { throw err }
    }

    public func confirmBoot() throws {
        callLog.append("confirmBoot")
        if let err = confirmBootError { throw err }
    }
}
