// The board abstraction that makes wendyos-update generic: supporting a
// new board means implementing this protocol and registering it (see
// `ConnectorRegistry`) — nothing in the engine, CLI, artifact format, or
// state machine changes per board.
//
// Ports `internal/connector/connector.go`'s `Connector` interface. The
// boundary contract, lifecycle table, and new-board checklist are
// specified in docs/connector-architecture.md (v1, frozen).
public protocol Connector: AnyObject, Sendable {
    /// Identifies the connector (config key, logs, state subdir).
    var name: String { get }

    /// The slot the system is running from.
    func currentSlot() throws -> Slot

    /// Resolves the block device of a slot's rootfs partition (e.g.
    /// /dev/nvme0n1p2 for slot B on Tegra).
    func partition(for s: Slot) throws -> String

    /// Makes a slot eligible to boot before flipping to it (e.g. Tegra:
    /// reset a stale "unbootable" status efivar).
    func prepareTarget(_ s: Slot) throws

    /// Makes the given slot the active one for the next boot.
    ///
    /// `stagePlatformUpdate == true` is the INSTALL swap: `s` is the
    /// freshly written inactive slot, and the connector inspects its
    /// rootfs for a pending platform/bootloader update, staging it if
    /// present (Tegra: capsule + OsIndications, and then NOT calling
    /// nvbootctrl — the firmware switches the chain itself).
    ///
    /// `stagePlatformUpdate == false` is the ROLLBACK swap: a pure
    /// re-point of the active slot. The connector must NOT inspect or
    /// mount the target rootfs — it may be the running slot (unmountable)
    /// or an old slot whose marker is irrelevant — and must never stage
    /// an update.
    func swapSlot(_ s: Slot, stagePlatformUpdate: Bool) throws

    /// Reports whether the platform flagged the current boot (Tegra: any
    /// RootfsStatusSlot* status != 0; U-Boot: trial-boot state says we
    /// fell back).
    func bootIsCompromised() throws -> Bool

    /// Gates commit after a platform update (Tegra: bootloader version +
    /// ESRT cascade). Must be a cheap no-op when `bootloaderUpdate` is
    /// false.
    func verifyPlatformUpdate(bootloaderUpdate: Bool) throws

    /// Unstages a platform update that was staged by `swapSlot` but
    /// should not be processed (rollback before the update is committed).
    /// Tegra: remove the capsule from the ESP and disarm OsIndications.
    /// Must be a no-op when nothing is staged.
    func abortPlatformUpdate() throws

    /// Finalizes a successful boot: clears trial/health bookkeeping and
    /// makes the now-inactive slot a valid rollback target.
    func markGood() throws

    /// Board-specific, human-facing status detail for the `status` verb
    /// (slot numbers, firmware versions, relevant variables). When
    /// `verbose` is set, adds a fuller raw snapshot of the slot/EFI-
    /// variable state for debugging. Best-effort and display-only: never
    /// required for operation, and unreadable items are simply omitted.
    /// May return an empty dictionary.
    func diagnostics(verbose: Bool) -> [String: String]

    /// Board-specific per-slot health for the `status` verb (rootfs
    /// health, retry budget, trial note). Display-only and best-effort;
    /// empty fields are omitted by the formatter.
    func slotStatus(_ s: Slot) -> SlotStatus

    /// Ordered, system-wide status lines for the `status` verb (e.g.
    /// bootloader version, last capsule outcome) that are not per-slot.
    /// Display-only and best-effort; may return an empty array.
    func systemStatus() -> [KV]
}

/// Optional extension for boards whose firmware arms a boot-validation
/// watchdog on EVERY boot and reboots the SoC unless userspace confirms it
/// (Jetson rootfs A/B: UEFI decrements the slot's retry budget per
/// attempt; stock L4T stops the countdown from nv_update_verifier.service,
/// which WendyOS does not ship). The boot verifier calls `confirmBoot` on
/// every boot it deems healthy; a boot that dies before the verifier is
/// never confirmed, so the firmware retry/fallback machinery still
/// abandons the slot on its own.
///
/// Boards whose trial machinery must stay armed until an explicit commit
/// (ubootenv: U-Boot bootcount, no watchdog) simply do not implement this.
///
/// Ports `connector.go`'s `BootConfirmer` interface.
public protocol BootConfirmer: AnyObject {
    /// Tells the firmware the current boot succeeded.
    func confirmBoot() throws
}

/// Optional connector extension that validates the platform can actually
/// carry out an A/B slot switch BEFORE the engine writes anything. A
/// thrown error aborts the install with nothing changed.
///
/// Connectors whose slot switch can silently no-op on a mis-provisioned
/// device implement this to fail loud and early instead of downloading,
/// writing, and rebooting only to roll back at commit. Tegra is the
/// motivating case: without rootfs A/B redundancy armed in firmware,
/// `nvbootctrl -t rootfs set-active-boot-slot` is ignored and every
/// update rolls back.
///
/// Ports `connector.go`'s `InstallPreflighter` interface.
public protocol InstallPreflighter: AnyObject {
    /// Returns normally when an A/B switch can take effect, or throws an
    /// actionable error describing what must be fixed on the device
    /// first.
    func preflightInstall() throws
}
