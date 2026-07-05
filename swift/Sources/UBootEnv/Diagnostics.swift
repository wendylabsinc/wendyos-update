import Connector

// Display-only status detail for the `status` verb (mirrors
// `tegrauefi/Diagnostics.swift`). Best-effort: never required for
// operation, and unreadable items are simply omitted. Ports
// `internal/connector/ubootenv/diagnostics.go`.
extension UBootEnv {
    /// Human-facing env/slot detail. The non-verbose set is the U-Boot
    /// variables that drive A/B selection; verbose adds the resolved
    /// per-slot rootfs devices. Ports `diagnostics.go`'s `Diagnostics`.
    public func diagnostics(verbose: Bool) -> [String: String] {
        var d: [String: String] = [:]

        let bootSlot = env.get(Self.envBootSlot)
        if !bootSlot.isEmpty { d["wendyos_boot_slot"] = bootSlot }

        let upgradeAvailable = env.get(Self.envUpgradeAvailable)
        if !upgradeAvailable.isEmpty { d["wendyos_upgrade_available"] = upgradeAvailable }

        let bootCount = env.get(Self.envBootCount)
        if !bootCount.isEmpty { d["bootcount"] = bootCount }

        guard verbose else { return d }

        for s: Slot in [.a, .b] {
            if let dev = try? partition(for: s) {
                d["rootfs\(s.description)_dev"] = dev
            }
        }
        return d
    }

    /// Surfaces the only per-slot signal U-Boot exposes: the trial state
    /// on the slot a trial is armed for. RPi has no persistent per-slot
    /// rootfs health marker (unlike Tegra's `RootfsStatusSlot`), so
    /// `rootfsHealth` stays empty and the formatter omits it. Ports
    /// `diagnostics.go`'s `SlotStatus`.
    public func slotStatus(_ s: Slot) -> SlotStatus {
        var st = SlotStatus()
        let armed = env.get(Self.envUpgradeAvailable)
        let bootSlot = env.get(Self.envBootSlot)
        guard armed == "1" && bootSlot == Self.slotEnvValue(s) else { return st }

        st.note = "trial armed"
        let bootCount = env.get(Self.envBootCount)
        if !bootCount.isEmpty {
            st.note = "trial armed (bootcount \(bootCount))"
        }
        return st
    }

    /// No system-wide A/B detail to add on U-Boot boards (the bootloader
    /// is shared, not per-slot, and carries no version this connector
    /// reads). Ports `diagnostics.go`'s `SystemStatus`.
    public func systemStatus() -> [KV] { [] }
}
