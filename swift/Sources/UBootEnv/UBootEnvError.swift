import CLIError
import Connector

/// Errors from the `UBootEnv` connector. Ports the `fmt.Errorf` failure
/// paths across `ubootenv.go`/`swap-slot.go` that this task's methods
/// (`currentSlot`, `partition(for:)`, `prepareTarget`, `swapSlot`,
/// `bootIsCompromised`) can produce. All are fatal to the in-progress
/// connector operation.
public enum UBootEnvError: Error, Equatable, ExitCoded {
    /// The running root device could not be determined (`findmnt /`
    /// failed, or the injected `rootDeviceFn` failed).
    case currentSlotRootDeviceUnknown(String)
    /// The running root partition matched neither slot's resolved
    /// device.
    case currentSlotNoMatch(root: String)
    /// `partition(for:)`: no partition labelled `rootfsA`/`rootfsB` (by
    /// GPT partlabel, fs label, or `/dev/disk/by-{partlabel,label}`
    /// symlink) exists on the boot disk.
    case partitionNoLabelledPartition(Slot, label: String)
    /// `partition(for:)`: the boot disk is an MBR table (no GPT
    /// partlabels) but the fixed rootfs partition number (2 for A, 3 for
    /// B) is missing from it.
    case partitionNoMBRPartition(Slot, want: Int, disk: String)
    /// `prepareTarget`: writing the cleared trial-state env vars failed.
    case prepareTargetFailed(Slot, String)
    /// `swapSlot`: the U-Boot env is not on a mounted boot partition, so
    /// `fw_setenv` would write a shadow copy the bootloader never reads
    /// (see `assertEnvWritable`).
    case swapEnvNotWritable(Slot, String)
    /// `swapSlot` (install): writing the trial-arming env vars failed.
    case swapArmTrialFailed(Slot, String)
    /// `swapSlot` (rollback): writing the re-point env vars failed.
    case swapRepointFailed(Slot, String)

    /// All `UBootEnv` failures are fatal to the in-progress connector
    /// operation.
    public var exitCode: Int32 { 1 }
}

extension UBootEnvError: CustomStringConvertible {
    /// Matches `ubootenv.go`/`swap-slot.go`'s `fmt.Errorf` messages as
    /// closely as Swift's string interpolation allows, so a caller that
    /// surfaces this text to a user or log sees the same wording either
    /// implementation produces.
    public var description: String {
        switch self {
        case .currentSlotRootDeviceUnknown(let detail):
            return "current slot: \(detail)"
        case .currentSlotNoMatch(let root):
            return "current slot: running root \"\(root)\" matches neither rootfs slot (rootfsA/rootfsB)"
        case .partitionNoLabelledPartition(let slot, let label):
            return "partition for slot \(slot): no partition labelled \"\(label)\" on the boot disk"
        case .partitionNoMBRPartition(let slot, let want, let disk):
            return "partition for slot \(slot): no partition \(want) on MBR boot disk \"\(disk)\""
        case .prepareTargetFailed(let slot, let detail):
            return "prepare slot \(slot): \(detail)"
        case .swapEnvNotWritable(let slot, let detail):
            return "swap to slot \(slot): \(detail)"
        case .swapArmTrialFailed(let slot, let detail):
            return "swap to slot \(slot): arm trial: \(detail)"
        case .swapRepointFailed(let slot, let detail):
            return "swap to slot \(slot): re-point: \(detail)"
        }
    }
}
