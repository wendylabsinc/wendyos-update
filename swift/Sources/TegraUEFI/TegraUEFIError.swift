import CLIError
import Connector

/// Errors from the `TegraUEFI` connector. Ports the `fmt.Errorf` failure
/// paths across `tegrauefi.go`/`swap-slot.go`/`efivar.go` that this task's
/// methods (`currentSlot`, `partition(for:)`, `prepareTarget`, `swapSlot`,
/// `bootIsCompromised`, `preflightInstall`, `confirmBoot`) can produce.
/// All are fatal to the in-progress connector operation.
public enum TegraUEFIError: Error, Equatable, ExitCoded {
    /// `nvbootctrl -t rootfs get-current-slot` exited non-zero.
    case currentSlotCommandFailed(String)
    /// `nvbootctrl -t rootfs get-current-slot` printed something other
    /// than `0`/`1`.
    case currentSlotUnexpectedOutput(String)
    /// Tiers 1-3 (by-partlabel symlink, `lsblk` scan,
    /// `nv_boot_control.conf` PARTUUID) all failed AND the tier-4
    /// arithmetic fallback couldn't even determine the current slot.
    case partitionCurrentSlotUnknown(Slot, String)
    /// Tiers 1-3 all failed and the tier-4 fallback couldn't determine
    /// the current root block device (`findmnt / SOURCE`).
    case partitionRootDeviceUnknown(Slot, String)
    /// Tier-4 fallback: the current root device isn't a recognized
    /// `<base>p<n>` partition device, so its partition number can't be
    /// toggled.
    case partitionUnrecognizedDevice(Slot, String)
    /// Tier-4 fallback: the arithmetically-derived candidate partition
    /// for the slot doesn't exist on disk.
    case partitionCandidateMissing(Slot, String)
    /// Reading/writing/verifying the slot's `RootfsStatusSlot*` efivar
    /// failed while preparing it as a swap target.
    case prepareTargetFailed(Slot, String)
    /// Reading the booted slot's `RootfsStatusSlot*` efivar failed while
    /// checking boot health (a well-formed-but-unreadable variable, e.g.
    /// permissions — a missing or wrong-sized variable is NOT an error,
    /// see `bootIsCompromised`).
    case bootHealthCheckFailed(Slot, String)
    /// Rootfs A/B redundancy is not armed in firmware (the
    /// `RootfsRedundancyLevel` efivar is missing, too short, or zero) —
    /// a slot switch would be a silent firmware no-op.
    case redundancyNotArmed
    /// `nvbootctrl -t rootfs set-active-boot-slot <n>` exited non-zero.
    case swapCommandFailed(Slot, String)
    /// Mounting the target rootfs (install swap) or the ESP (capsule
    /// staging) failed.
    case mountFailed(String)
    /// Recording the double-boot-detector's `boot_attempted` bookkeeping
    /// file failed.
    case recordBootAttemptFailed(Slot, String)
    /// The rootfs marker requested a bootloader update but the capsule
    /// file it should ship alongside is missing.
    case capsuleMissing(String)
    /// Saving the pre-update bootloader version (for post-reboot
    /// verification) failed.
    case saveBootloaderVersionFailed(Slot, String)
    /// `nvbootctrl dump-slots-info` failed, or its output had no
    /// `Current version:` line.
    case bootloaderVersionUnavailable(String)
    /// The ESP could not be located/mounted (neither already mounted at
    /// `/boot/efi` nor resolvable via a by-partlabel symlink).
    case espUnavailable(String)
    /// Staging the capsule file onto the ESP failed.
    case stageCapsuleFailed(Slot, String)
    /// Setting (and verifying) the `OsIndications` capsule-processing bit
    /// failed.
    case osIndicationsFailed(String)
    /// `nvbootctrl -t rootfs mark-boot-successful` exited non-zero.
    case confirmBootFailed(String)

    /// All `TegraUEFI` failures are fatal to the in-progress connector
    /// operation.
    public var exitCode: Int32 { 1 }
}

extension TegraUEFIError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .currentSlotCommandFailed(let detail):
            return "nvbootctrl get-current-slot: \(detail)"
        case .currentSlotUnexpectedOutput(let out):
            return "nvbootctrl get-current-slot: unexpected output \"\(out)\""
        case .partitionCurrentSlotUnknown(let slot, let detail):
            return "partition for slot \(slot): all lookups failed and current slot unknown: \(detail)"
        case .partitionRootDeviceUnknown(let slot, let detail):
            return "partition for slot \(slot): all lookups failed: \(detail)"
        case .partitionUnrecognizedDevice(let slot, let dev):
            return "partition for slot \(slot): unrecognized partition device \"\(dev)\""
        case .partitionCandidateMissing(let slot, let cand):
            return "partition for slot \(slot): candidate \(cand) does not exist"
        case .prepareTargetFailed(let slot, let detail):
            return "prepare slot \(slot): \(detail)"
        case .bootHealthCheckFailed(let slot, let detail):
            return "boot health: slot \(slot): \(detail)"
        case .redundancyNotArmed:
            return "rootfs A/B redundancy is not armed on this device "
                + "(UEFI variable RootfsRedundancyLevel missing or zero): a rootfs slot switch is ignored by "
                + "firmware, so the update would install and then roll back. Arm redundancy "
                + "(the wendyos-tegra-rootfs-redundancy boot service, or system-status.sh "
                + "--dual) and reboot, then retry the update"
        case .swapCommandFailed(let slot, let detail):
            return "swap to slot \(slot): nvbootctrl set-active-boot-slot: \(detail)"
        case .mountFailed(let detail):
            return "mount: \(detail)"
        case .recordBootAttemptFailed(let slot, let detail):
            return "swap to slot \(slot): record boot attempt: \(detail)"
        case .capsuleMissing(let path):
            return "bootloader update requested by rootfs marker but capsule missing at \(path)"
        case .saveBootloaderVersionFailed(let slot, let detail):
            return "swap to slot \(slot): save bootloader version: \(detail)"
        case .bootloaderVersionUnavailable(let detail):
            return "nvbootctrl dump-slots-info: \(detail)"
        case .espUnavailable(let labels):
            return "ESP not mounted at /boot/efi and no by-partlabel match (\(labels))"
        case .stageCapsuleFailed(let slot, let detail):
            return "swap to slot \(slot): stage capsule: \(detail)"
        case .osIndicationsFailed(let detail):
            return "OsIndications: \(detail)"
        case .confirmBootFailed(let detail):
            return "confirm boot: nvbootctrl mark-boot-successful: \(detail)"
        }
    }
}
