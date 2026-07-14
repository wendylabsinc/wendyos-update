import Connector
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
// The static-musl cross-compilation SDK exposes libc under the
// `Musl` overlay module instead of `Glibc` (see LinuxSys.swift for
// the fuller explanation); every symbol this file uses exists
// identically in both.
import Musl
#endif
import PlatformIO

// Direct port of `internal/connector/tegrauefi/tegrauefi.go`'s
// `Controller` (Task 8.2 slice: `Name`, `CurrentSlot`, `PartitionFor`,
// `PrepareTarget`, `BootIsCompromised`, `PreflightInstall`, `ConfirmBoot`,
// plus `detect`; Task 8.3 adds `MarkGood`, below). `SwapSlot` lives in
// `SwapSlot.swift` (ports `swap-slot.go`); `VerifyPlatformUpdate`/
// `AbortPlatformUpdate` live in `Verify.swift` (ports `verify.go`, Task
// 8.3). `Diagnostics`/`slotStatus`/`systemStatus` live in
// `Diagnostics.swift` (ports `diagnostics.go`, Task 8.4).
//
// Platform facts (see `tegrauefi.go`'s package doc, validated on t234/r36
// and t264/r38): efivar names + GUID identical across generations; the
// `RootfsStatusSlot*` status var is 4-byte attrs (0x07 = NV+BS+RT) +
// UINT32 status (0x00 normal, 0xFF unbootable); a rootfs slot swap
// switches the whole boot chain, same as a processed capsule.
public final class TegraUEFI: Connector, BootConfirmer, InstallPreflighter, @unchecked Sendable {
    public let name = "tegrauefi"

    /// `nvbootctrl` binary name/path. A bare name is resolved against
    /// `PATH` by the command runner (matches Go's `exec.LookPath`
    /// reliance); a `/`-containing value is used directly. Tests point
    /// this at a fake stub script.
    public var nvbootctrl: String
    /// The efivarfs mountpoint the Tegra RootfsStatusSlot/
    /// RootfsRedundancyLevel/OsIndications variables live under. Tests
    /// point this at a real temp directory (matching `EfiVar`'s own
    /// real-file testing style and Go's `testController`, which does the
    /// same with `t.TempDir()`).
    public var efivarsDir: String
    /// Prefix for `/dev`, `/etc`, `/proc`, `/data` lookups (Go's
    /// `c.RootDir`). Deliberately NOT applied to `efivarsDir` paths,
    /// matching `tegrauefi.go`'s `statusVar`/`redundancyLevelVar`, which
    /// join only against `EfivarsDir`.
    public var rootDir: String

    let commandRunner: any TegraCommandRunner
    let fileStore: any FileStore
    let mountRootfs: RootfsMounter
    let mountESP: EspMounter

    /// NVIDIA's rootfs A/B efivar namespace.
    static let vendorGUID = "781e084c-a330-417c-b678-38e696380cb9"
    /// The standard UEFI namespace (`OsIndications`).
    static let efiGlobalGUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"

    public init(
        nvbootctrl: String = "nvbootctrl",
        efivarsDir: String = EfiVar.efivarsDir,
        rootDir: String = "",
        commandRunner: any TegraCommandRunner = RealTegraCommandRunner(),
        fileStore: any FileStore = RealFileStore(),
        mountRootfs: @escaping RootfsMounter = TegraRealMount.rootfsReadOnly,
        mountESP: @escaping EspMounter = TegraRealMount.espReadWrite
    ) {
        self.nvbootctrl = nvbootctrl
        self.efivarsDir = efivarsDir
        self.rootDir = rootDir
        self.commandRunner = commandRunner
        self.fileStore = fileStore
        self.mountRootfs = mountRootfs
        self.mountESP = mountESP
    }

    /// `detect`: `nvbootctrl` present on `PATH` AND the NVIDIA rootfs A/B
    /// efivars exist. Ports `tegrauefi.go`'s package-level `detect()`.
    public static let factory = ConnectorFactory(
        name: "tegrauefi",
        make: { TegraUEFI() },
        detect: {
            guard TegraUEFI.commandExistsOnPath("nvbootctrl") else { return false }
            let probe = TegraUEFI()
            return probe.efivarExists(probe.statusVarPath(.a))
        }
    )

    // MARK: - CurrentSlot

    /// Runs `nvbootctrl [-t rootfs] get-current-slot` — the boot-chain
    /// slot on Orin (`bootChainSlotAB`), the rootfs-redundancy slot
    /// elsewhere. The two are coupled, so the running rootfs slot is the
    /// same either way. Output validated on r36 and r38: a single digit,
    /// `0` or `1`.
    public func currentSlot() throws -> Slot {
        let result = commandRunner.run([nvbootctrl] + nvbootctrlSlotArgs() + ["get-current-slot"])
        guard result.exitCode == 0 else {
            throw TegraUEFIError.currentSlotCommandFailed(Self.decodeCombined(result))
        }
        let out = Self.trimmed(String(decoding: result.stdout, as: UTF8.self))
        switch out {
        case "0": return .a
        case "1": return .b
        default: throw TegraUEFIError.currentSlotUnexpectedOutput(out)
        }
    }

    // MARK: - PartitionFor

    /// Maps a slot to the NVIDIA rootfs partition label.
    static func partlabel(for s: Slot) -> String {
        s == .a ? "APP" : "APP_b"
    }

    /// Resolves the slot's rootfs block device: (1) `by-partlabel`
    /// symlink, (2) `lsblk -rno PATH,PARTLABEL` scan, (3)
    /// `ROOTFS_PARTUUID_{A,B}` from `nv_boot_control.conf` ->
    /// `by-partuuid` symlink, (4) arithmetic toggle of the CURRENT root
    /// device's partition number (slots are consecutive: A=pN, B=pN+1).
    /// Full port of `tegrauefi.go`'s `PartitionFor`, all four tiers.
    public func partition(for s: Slot) throws -> String {
        let label = Self.partlabel(for: s)

        // 1) by-partlabel symlink
        let link = rootDir + "/dev/disk/by-partlabel/" + label
        if let dev = fileStore.resolveSymlink(link) {
            return dev
        }

        // 2) lsblk PARTLABEL scan
        let lsblkResult = commandRunner.run(["lsblk", "-rno", "PATH,PARTLABEL"])
        if lsblkResult.exitCode == 0 {
            let out = String(decoding: lsblkResult.stdout, as: UTF8.self)
            for line in out.split(separator: "\n") {
                let fields = Self.whitespaceFields(line)
                if fields.count == 2 && fields[1] == label {
                    return fields[0]
                }
            }
        }

        // 3) PARTUUID from nv_boot_control.conf
        let key = s == .a ? "ROOTFS_PARTUUID_A" : "ROOTFS_PARTUUID_B"
        if let data = try? fileStore.read(rootDir + "/etc/nv_boot_control.conf") {
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") {
                let fields = Self.whitespaceFields(line)
                if fields.count == 2 && fields[0] == key {
                    let uuidLink = rootDir + "/dev/disk/by-partuuid/" + fields[1]
                    if let dev = fileStore.resolveSymlink(uuidLink) {
                        return dev
                    }
                }
            }
        }

        // 4) toggle the partition number of the current root device.
        let cur: Slot
        do {
            cur = try currentSlot()
        } catch {
            throw TegraUEFIError.partitionCurrentSlotUnknown(s, "\(error)")
        }
        let rootDev: String
        do {
            rootDev = try currentRootDevice()
        } catch {
            throw TegraUEFIError.partitionRootDeviceUnknown(s, "\(error)")
        }
        if s == cur {
            return rootDev
        }
        guard let (base, num) = Self.splitPartDev(rootDev) else {
            throw TegraUEFIError.partitionUnrecognizedDevice(s, rootDev)
        }
        let target = num + s.rawValue - cur.rawValue
        let candidate = "\(base)p\(target)"
        guard fileStore.exists(rootDir + candidate) else {
            throw TegraUEFIError.partitionCandidateMissing(s, candidate)
        }
        return candidate
    }

    /// A plain "findmnt /: ..." failure. Kept lightweight (its
    /// interpolation is the raw Go `currentRootDevice` message) so the
    /// tier-4 caller can wrap it once into
    /// `partitionRootDeviceUnknown` — matching Go's `all lookups failed:
    /// %w` without nesting a second "partition for slot X:" prefix.
    struct FindmntError: Error, CustomStringConvertible {
        let detail: String
        var description: String { detail }
    }

    /// Returns the block device mounted at `/` via `findmnt -no SOURCE
    /// /`. Ports `tegrauefi.go`'s `currentRootDevice`.
    func currentRootDevice() throws -> String {
        let result = commandRunner.run(["findmnt", "-no", "SOURCE", "/"])
        guard result.exitCode == 0 else {
            throw FindmntError(detail: "findmnt /: exit \(result.exitCode)")
        }
        let dev = Self.trimmed(String(decoding: result.stdout, as: UTF8.self))
        guard !dev.isEmpty else {
            throw FindmntError(detail: "findmnt /: empty source")
        }
        return dev
    }

    /// Splits `/dev/nvme0n1p2` -> (`/dev/nvme0n1`, 2) and
    /// `/dev/mmcblk0p1` -> (`/dev/mmcblk0`, 1) by the LAST `p`. Returns
    /// `nil` for a device with no `p` separator, a trailing `p`, or a
    /// non-numeric partition suffix. Ports `tegrauefi.go`'s
    /// `splitPartDev`.
    static func splitPartDev(_ dev: String) -> (base: String, num: Int)? {
        guard let pIdx = dev.lastIndex(of: "p") else { return nil }
        let numStart = dev.index(after: pIdx)
        guard numStart < dev.endIndex else { return nil }  // trailing 'p'
        guard let num = Int(dev[numStart...]) else { return nil }
        return (String(dev[dev.startIndex..<pIdx]), num)
    }

    // MARK: - PrepareTarget

    /// Resets the slot's `RootfsStatusSlot` efivar to "normal". A
    /// previous rollback leaves the slot `0xFF` (unbootable); UEFI
    /// refuses to boot it regardless of content, so a freshly written
    /// slot must be reset before swapping. The single 8-byte write also
    /// re-seeds the firmware retry budget. A missing variable is
    /// tolerated (nothing to reset); a failed write or read-back
    /// mismatch is an error. Ports `tegrauefi.go`'s `PrepareTarget`.
    public func prepareTarget(_ s: Slot) throws {
        let path = statusVarPath(s)
        guard efivarExists(path) else { return }

        let raw: [UInt8]
        do {
            raw = try EfiVar.readStatus(path)
        } catch {
            throw TegraUEFIError.prepareTargetFailed(s, "\(error)")
        }
        if EfiVar.statusIsNormal(raw) { return }

        do {
            try EfiVar.writeStatusNormal(path)
        } catch {
            throw TegraUEFIError.prepareTargetFailed(s, "\(error)")
        }
    }

    // MARK: - BootIsCompromised

    /// Reports whether the firmware flagged the slot we actually booted
    /// (`RootfsStatusSlot` status != 0). Conservative on uncertainty: an
    /// undeterminable current slot, a missing status var, or an
    /// unvalidated (wrong-sized) status var all report "not compromised"
    /// rather than forcing a false rollback (the JP6 incident). Ports
    /// `verify.go`'s `BootIsCompromised`.
    public func bootIsCompromised() throws -> Bool {
        guard let cur = try? currentSlot() else { return false }

        let path = statusVarPath(cur)
        guard efivarExists(path) else { return false }

        let raw: [UInt8]
        do {
            raw = try EfiVar.readStatus(path)
        } catch {
            throw TegraUEFIError.bootHealthCheckFailed(cur, "\(error)")
        }
        guard EfiVar.statusIsWellFormed(raw) else { return false }
        return !EfiVar.statusIsNormal(raw)
    }

    // MARK: - PreflightInstall

    /// Refuses the install when rootfs A/B redundancy is not armed in
    /// firmware (`RootfsRedundancyLevel` efivar missing, too short, or
    /// zero): without it, `set-active-boot-slot` is silently ignored, so
    /// every update would install and then roll back. A read failure
    /// other than "missing" does not block the update (the commit-time
    /// running-slot vs target-slot check still catches a genuine no-op
    /// fallback). Ports `tegrauefi.go`'s `PreflightInstall`.
    public func preflightInstall() throws {
        // Boot-chain A/B (Orin) does not use RootfsRedundancyLevel at all
        // — the chain switch moves the coupled rootfs slot without it —
        // so there is nothing to arm and nothing to preflight. (The var
        // is unarmable from the OS on Orin anyway; blocking on it is
        // exactly what this replaces.)
        if bootChainSlotAB() { return }

        let path = redundancyLevelVarPath()
        guard efivarExists(path) else {
            throw TegraUEFIError.redundancyNotArmed
        }

        let raw: [UInt8]
        do {
            raw = try EfiVar.readStatus(path)
        } catch {
            // Probe failed unexpectedly: don't block the update on a read
            // error.
            return
        }
        let armed = raw.count >= 8 && (raw[4] != 0 || raw[5] != 0 || raw[6] != 0 || raw[7] != 0)
        guard armed else {
            throw TegraUEFIError.redundancyNotArmed
        }
    }

    // MARK: - ConfirmBoot

    /// `nvbootctrl [-t rootfs] mark-boot-successful`: tells UEFI this boot
    /// succeeded, stopping the boot-validation watchdog and retry
    /// countdown for the running slot's layer (boot-chain on Orin,
    /// rootfs-redundancy elsewhere). Ports `tegrauefi.go`'s `ConfirmBoot`.
    public func confirmBoot() throws {
        let result = commandRunner.run([nvbootctrl] + nvbootctrlSlotArgs() + ["mark-boot-successful"])
        guard result.exitCode == 0 else {
            throw TegraUEFIError.confirmBootFailed(Self.decodeCombined(result))
        }
    }

    // MARK: - MarkGood

    /// Finalizes a healthy, committed boot:
    ///   - confirms the running slot to the bootloader (stops the
    ///     trial-boot retry countdown; WendyOS does not ship NVIDIA's
    ///     `nv_update_verifier.service`, so this connector's `confirmBoot`
    ///     is the only thing that does it),
    ///   - resets the now-INACTIVE slot's status var so it is a valid
    ///     rollback target for the next cycle,
    ///   - clears this connector's double-boot bookkeeping.
    ///
    /// Ports `tegrauefi.go`'s `MarkGood`.
    public func markGood() throws {
        let cur: Slot
        do {
            cur = try currentSlot()
        } catch {
            throw TegraUEFIError.markGoodFailed("\(error)")
        }
        do {
            try confirmBoot()
        } catch {
            throw TegraUEFIError.markGoodFailed("\(error)")
        }
        do {
            try prepareTarget(cur.other)
        } catch {
            throw TegraUEFIError.markGoodResetInactiveFailed("\(error)")
        }
        do {
            try fileStore.remove(bootAttemptedPath())
        } catch {
            throw TegraUEFIError.markGoodClearBootAttemptedFailed("\(error)")
        }
    }

    // MARK: - Shared efivar path helpers

    /// The efivarfs file for a slot's `RootfsStatusSlot` variable. Ports
    /// `tegrauefi.go`'s `statusVar`.
    func statusVarPath(_ s: Slot) -> String {
        efivarsDir + "/RootfsStatusSlot" + s.description + "-" + Self.vendorGUID
    }

    /// The efivarfs file for `RootfsRedundancyLevel`. Ports
    /// `tegrauefi.go`'s `redundancyLevelVar`.
    func redundancyLevelVarPath() -> String {
        efivarsDir + "/RootfsRedundancyLevel-" + Self.vendorGUID
    }

    /// The efivarfs file for `OsIndications`. Ports `swap-slot.go`'s
    /// inline path construction.
    func osIndicationsVarPath() -> String {
        efivarsDir + "/OsIndications-" + Self.efiGlobalGUID
    }

    /// This connector's private bookkeeping directory (docs/connector-
    /// architecture.md rule 2: engine state is off-limits). Ports
    /// `tegrauefi.go`'s `stateDir`.
    func stateDir() -> String {
        rootDir + "/data/wendyos-update/connector/tegrauefi"
    }

    /// Records which slot the last (uncommitted) boot attempt targeted.
    /// Ports `tegrauefi.go`'s `bootAttemptedPath`.
    func bootAttemptedPath() -> String {
        stateDir() + "/boot_attempted"
    }

    /// Pre-update bootloader version (transient, capsule updates only).
    /// Ports `swap-slot.go`'s `blVersionBeforePath`.
    func blVersionBeforePath() -> String {
        rootDir + "/data/wendyos-update/bl-version-before"
    }

    /// Reports whether `path` exists via a plain `access(2)` probe —
    /// efivarfs paths are real filesystem paths even under a test's
    /// temp-directory `efivarsDir`, so this deliberately does NOT go
    /// through the injectable `fileStore` seam (which models the
    /// `RootDir`-prefixed regular filesystem instead; see the type doc).
    func efivarExists(_ path: String) -> Bool {
        path.withCString { access($0, F_OK) == 0 }
    }

    /// Scans `PATH` for an executable named `name`, mirroring Go's
    /// `exec.LookPath` as used by `detect()`.
    private static func commandExistsOnPath(_ name: String) -> Bool {
        guard let pathEnv = getenv("PATH") else { return false }
        let pathVar = String(cString: pathEnv)
        for dir in pathVar.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if candidate.withCString({ access($0, X_OK) == 0 }) {
                return true
            }
        }
        return false
    }

    /// Trims ASCII whitespace from both ends without pulling in
    /// `Foundation` for a single `CharacterSet` trim.
    static func trimmed(_ s: String) -> String {
        var view = Substring(s)
        while let f = view.first, f == " " || f == "\n" || f == "\t" || f == "\r" {
            view.removeFirst()
        }
        while let l = view.last, l == " " || l == "\n" || l == "\t" || l == "\r" {
            view.removeLast()
        }
        return String(view)
    }

    /// Splits a line on runs of spaces/tabs, matching Go's
    /// `strings.Fields` as used to parse `lsblk`/`nv_boot_control.conf`
    /// output.
    static func whitespaceFields(_ line: Substring) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Decodes a command's stdout+stderr as one string for error
    /// messages, mirroring Go's `CombinedOutput()`.
    static func decodeCombined(_ result: CommandResult) -> String {
        String(decoding: result.stdout + result.stderr, as: UTF8.self)
    }
}
