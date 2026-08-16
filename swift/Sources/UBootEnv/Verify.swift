// Boot-health and platform-update verification. Ports
// `internal/connector/ubootenv/verify.go`. Where TegraUEFI reads
// RootfsStatusSlot efivars and runs the ESRT capsule cascade, U-Boot's
// verdict lives entirely in the trial-boot env: a still-armed trial
// running the wrong slot means bootcount/altbootcmd already fell back.
extension UBootEnv {
    /// Reports whether U-Boot fell back during an armed trial. Signal: a
    /// trial is still armed (`upgrade_available=1`) yet the slot we are
    /// running is not the slot we asked U-Boot to boot — i.e. bootcount
    /// exceeded bootlimit and `altbootcmd` switched us back. (Once a
    /// trial commits, a future `markGood` clears `upgrade_available`, so
    /// a committed system never reads as compromised.)
    ///
    /// The engine also independently checks running-slot != target-slot
    /// via `currentSlot`; this is the connector-level corroboration the
    /// interface asks for, and the only one that can see U-Boot's own
    /// fallback verdict. Ports `verify.go`'s `BootIsCompromised`.
    public func bootIsCompromised() throws -> Bool {
        guard env.get(Self.envUpgradeAvailable) == "1" else {
            return false  // no trial in flight
        }

        let intended = env.get(Self.envBootSlot)
        guard let cur = try? currentSlot() else {
            // Can't prove a fallback; don't cry wolf. The engine's own
            // running-vs-target check still guards the commit.
            return false
        }
        if !intended.isEmpty && intended != Self.slotEnvValue(cur) {
            return true
        }
        return false
    }

    /// A no-op in v1: RPi has no in-payload bootloader update path
    /// (rpi-eeprom has its own independent flow). Ports `verify.go`'s
    /// `VerifyPlatformUpdate`.
    public func verifyPlatformUpdate(bootloaderUpdate: Bool) throws {}

    /// A no-op in v1: nothing is ever staged outside the env, and the
    /// trial flag is cleared by the rollback `swapSlot` itself. Ports
    /// `verify.go`'s `AbortPlatformUpdate`.
    public func abortPlatformUpdate() throws {}
}
