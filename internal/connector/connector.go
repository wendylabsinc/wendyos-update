// Package connector defines the board abstraction that makes
// wendyos-update generic: supporting a new board means implementing
// this interface and registering it — nothing in the engine, CLI,
// artifact format, or state machine changes per board.
//
// The boundary contract, lifecycle table, and new-board checklist are
// specified in docs/connector-architecture.md (v1, frozen).
//
// Connectors:
//   - tegrauefi: NVIDIA Jetson (UEFI + nvbootctrl + efivars + capsule).
//     Primitives validated on t264/r38 (Phase 1, 2026-06-07) and
//     t234/r36 (production Mender stack).
//   - ubootenv: Raspberry Pi 3/4/5 and other U-Boot boards (plan Phase 7).
package connector

// Slot identifies one of the two A/B rootfs slots.
type Slot int

const (
	SlotA Slot = 0
	SlotB Slot = 1
)

func (s Slot) Other() Slot {
	if s == SlotA {
		return SlotB
	}
	return SlotA
}

func (s Slot) String() string {
	if s == SlotA {
		return "A"
	}
	return "B"
}

// Connector is the platform contract. Every method maps to a platform
// primitive; no method reboots the device. See
// docs/connector-architecture.md for when each method is called and the
// per-platform mapping table.
type Connector interface {
	// Name identifies the connector (config key, logs, state subdir).
	Name() string

	// CurrentSlot returns the slot the system is running from.
	CurrentSlot() (Slot, error)

	// PartitionFor resolves the block device of a slot's rootfs
	// partition (e.g. /dev/nvme0n1p2 for SlotB on Tegra).
	PartitionFor(s Slot) (string, error)

	// PrepareTarget makes a slot eligible to boot before flipping to it
	// (e.g. Tegra: reset a stale "unbootable" status efivar).
	PrepareTarget(s Slot) error

	// SwapSlot makes the given slot the active one for the next boot.
	//
	// stagePlatformUpdate=true is the INSTALL swap: s is the freshly
	// written inactive slot, and the connector inspects its rootfs for a
	// pending platform/bootloader update, staging it if present (Tegra:
	// capsule + OsIndications, and then NOT calling nvbootctrl — the
	// firmware switches the chain itself).
	//
	// stagePlatformUpdate=false is the ROLLBACK swap: a pure re-point of
	// the active slot. The connector must NOT inspect or mount the target
	// rootfs — it may be the running slot (unmountable) or an old slot
	// whose marker is irrelevant — and must never stage an update.
	SwapSlot(s Slot, stagePlatformUpdate bool) error

	// BootIsCompromised reports whether the platform flagged the current
	// boot (Tegra: any RootfsStatusSlot* status != 0; U-Boot: trial-boot
	// state says we fell back).
	BootIsCompromised() (bool, error)

	// VerifyPlatformUpdate gates commit after a platform update
	// (Tegra: bootloader version + ESRT cascade). Must be a cheap
	// no-op when blUpdate is false.
	VerifyPlatformUpdate(blUpdate bool) error

	// AbortPlatformUpdate unstages a platform update that was staged by
	// SwapSlot but should not be processed (rollback before the update
	// is committed). Tegra: remove the capsule from the ESP and disarm
	// OsIndications. Must be a no-op when nothing is staged.
	AbortPlatformUpdate() error

	// MarkGood finalizes a successful boot: clears trial/health
	// bookkeeping and makes the now-inactive slot a valid rollback
	// target.
	MarkGood() error

	// Diagnostics returns board-specific, human-facing status detail for
	// the `status` verb (slot numbers, firmware versions, relevant
	// variables). When verbose is set, it adds a fuller raw snapshot of
	// the slot/EFI-variable state for debugging (raw status bytes, per-slot
	// bootloader state, boot-chain variables). Best-effort and display-only:
	// never required for operation, and unreadable items are simply
	// omitted. May return nil.
	Diagnostics(verbose bool) map[string]string
}
