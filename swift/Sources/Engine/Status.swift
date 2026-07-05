import Connector
import Model

// The `status` verb (docs/cli-contract.md). Ports `Engine.Status` in
// internal/engine/engine.go.

/// One A/B slot's status. Empty fields mean "not applicable/unreadable" —
/// the CLI formatter omits them, mirroring the Go struct's `omitempty` tags.
/// Ports `engine.SlotState` (internal/engine/slotinfo.go).
public struct SlotState: Sendable {
    public var slot: String
    public var booted: Bool
    public var partition = ""
    public var distro = ""
    public var kernel = ""
    public var rootfsHealth = ""
    public var retries = ""
    public var note = ""

    public init(slot: String, booted: Bool) {
        self.slot = slot
        self.booted = booted
    }
}

/// The `status` verb's full output. Ports `engine.StatusInfo`
/// (internal/engine/engine.go).
public struct StatusInfo: Sendable {
    public var connector: String
    public var currentSlot: String
    public var slots: [SlotState]
    public var system: [KV]
    public var pending: State?
    /// The raw connector snapshot — kept unconditionally (the CLI contract
    /// is additive-only); `verbose` only enriches its contents.
    public var diagnostics: [String: String]

    public init(
        connector: String,
        currentSlot: String,
        slots: [SlotState],
        system: [KV],
        pending: State?,
        diagnostics: [String: String]
    ) {
        self.connector = connector
        self.currentSlot = currentSlot
        self.slots = slots
        self.system = system
        self.pending = pending
        self.diagnostics = diagnostics
    }
}

extension Engine {
    /// Assembles the `status` verb's output: the current slot, per-slot
    /// detail (partition, live-vs-mounted distro/kernel, connector health),
    /// system-wide status lines, any pending update, and the connector's
    /// raw diagnostics. Ports `Engine.Status` verbatim.
    public func status(verbose: Bool) throws -> StatusInfo {
        let cur = try conn.currentSlot()
        let pending = try loadState()

        var slots: [SlotState] = []
        for s in [Slot.a, Slot.b] {
            var ss = SlotState(slot: s.description, booted: s == cur)
            if let dev = try? conn.partition(for: s) {
                ss.partition = dev
            }
            let h = conn.slotStatus(s)
            ss.rootfsHealth = h.rootfsHealth
            ss.retries = h.retries
            ss.note = h.note
            // Distro/kernel: live for the booted slot; a read-only mount of
            // the inactive slot otherwise (best-effort — empty if not
            // root/unreadable).
            if s == cur {
                (ss.distro, ss.kernel) = versionProbe.liveVersions()
            } else {
                (ss.distro, ss.kernel) = versionProbe.slotVersions(partition: ss.partition)
            }
            slots.append(ss)
        }

        return StatusInfo(
            connector: conn.name,
            currentSlot: cur.description,
            slots: slots,
            system: conn.systemStatus(),
            pending: pending,
            diagnostics: conn.diagnostics(verbose: verbose)
        )
    }

    /// The manual escape hatch: reset slot health via the connector, then
    /// clear any pending update state. Ports `Engine.MarkGood` verbatim
    /// (internal/engine/engine.go).
    public func markGood() throws {
        try conn.markGood()
        try clearState()
    }
}
