import Connector
import Glibc
import PlatformIO

// Direct port of `internal/connector/ubootenv/ubootenv.go`'s `Controller`
// (Task 9.1 slice: `Name`, `CurrentSlot`, `PartitionFor`, `PrepareTarget`,
// `BootIsCompromised`, plus `detect`; `SwapSlot` lives in `SwapSlot.swift`
// (ports `swap-slot.go`); `BootIsCompromised`/`VerifyPlatformUpdate`/
// `AbortPlatformUpdate` live in `Verify.swift`).
//
// Where TegraUEFI leans on NVIDIA's boot-control framework (nvbootctrl +
// efivars + UEFI capsules), this connector drives the much simpler U-Boot
// "trial boot" pattern through libubootenv (`fw_printenv`/`fw_setenv`):
// the boot script picks the rootfs slot from `wendyos_boot_slot`; when
// `wendyos_upgrade_available=1` the boot is a TRIAL — U-Boot's native
// bootcount/bootlimit/altbootcmd machinery falls back to the other slot
// if the trial slot fails to reach a healthy userspace; committing clears
// `wendyos_upgrade_available` so the slot becomes the permanent default.
//
// Unlike TegraUEFI, this connector does NOT implement `BootConfirmer`:
// U-Boot's bootcount stays armed until an explicit commit (`markGood`)
// clears it — there is no per-boot watchdog to satisfy.
//
// `markGood` (swap-slot.go) and `diagnostics`/`slotStatus`/`systemStatus`
// (diagnostics.go) are left as TODO-tagged stubs here, matching the same
// incremental-slice pattern TegraUEFI's Task 8.2 used (its own
// `markGood`/`diagnostics`/`slotStatus`/`systemStatus` were stubbed in
// the slot/partition/swap task and completed in later tasks) — they
// exist only so `UBootEnv` satisfies `Connector`.
public final class UBootEnv: Connector, @unchecked Sendable {
    public let name = "ubootenv"

    /// Prefix for `/dev`, `/etc`, `/run` lookups (tests); `""` in
    /// production. Matches `TegraUEFI.rootDir`/Go's `Controller.RootDir`.
    public let rootDir: String

    let commandRunner: any UBootCommandRunner
    let fileStore: any FileStore
    let env: any UBootEnvStore
    let rootDeviceFn: @Sendable () throws -> String
    let listPartsFn: @Sendable () throws -> [PartInfo]

    /// Environment variable names (our names; documented contract). The
    /// boot script in meta-edgeos selects the slot and arms the trial
    /// boot off exactly these. Ports `ubootenv.go`'s `envBootSlot`/
    /// `envUpgradeAvailable`/`envBootCount`.
    static let envBootSlot = "wendyos_boot_slot"
    static let envUpgradeAvailable = "wendyos_upgrade_available"
    static let envBootCount = "bootcount"  // U-Boot's native counter

    /// Slot labels for the two rootfs slots: GPT PARTLABELs on rpi4/rpi5,
    /// or the ext4 filesystem label on an MBR table (rpi3). Ports
    /// `ubootenv.go`'s `partlabelA`/`partlabelB`.
    static let partlabelA = "rootfsA"
    static let partlabelB = "rootfsB"

    /// MBR (rpi3) has no GPT partlabel, so slots resolve by the fixed
    /// rootfs partition number instead (the only slot identity an OTA
    /// rootfs write can't wipe). Ports `ubootenv.go`'s `mbrRootfsPartA`/
    /// `mbrRootfsPartB`.
    static let mbrRootfsPartA = 2
    static let mbrRootfsPartB = 3

    /// libubootenv's config (read by `fw_setenv`); parsed only to sanity-
    /// check that a slot swap will actually be written. Ports
    /// `ubootenv.go`'s `fwEnvConfigPath`.
    static let fwEnvConfigPath = "/etc/fw_env.config"

    public init(
        rootDir: String = "",
        commandRunner: any UBootCommandRunner = RealUBootCommandRunner(),
        fileStore: any FileStore = RealFileStore(),
        env: (any UBootEnvStore)? = nil,
        rootDeviceFn: (@Sendable () throws -> String)? = nil,
        listPartsFn: (@Sendable () throws -> [PartInfo])? = nil
    ) {
        self.rootDir = rootDir
        self.commandRunner = commandRunner
        self.fileStore = fileStore
        self.env = env ?? FwEnv(commandRunner: commandRunner, fileStore: fileStore, rootDir: rootDir)
        self.rootDeviceFn = rootDeviceFn ?? Self.defaultRootDevice(commandRunner: commandRunner)
        self.listPartsFn = listPartsFn ?? Self.defaultListParts(commandRunner: commandRunner)
    }

    /// `detect`: `fw_printenv` present on `PATH` AND our env layout is
    /// already seeded (`wendyos_boot_slot` is defined). On a Tegra board
    /// `fw_printenv` is absent, so this never collides with `tegrauefi`.
    /// Ports `ubootenv.go`'s package-level `detect()`.
    public static let factory = ConnectorFactory(
        name: "ubootenv",
        make: { UBootEnv() },
        detect: {
            guard UBootEnv.commandExistsOnPath("fw_printenv") else { return false }
            let probe = UBootEnv()
            return !probe.env.get(UBootEnv.envBootSlot).isEmpty
        }
    )

    // MARK: - CurrentSlot

    /// Returns the slot actually running, derived from the block device
    /// mounted at `/`. Deliberately ground-truth (what booted) rather
    /// than reading `wendyos_boot_slot` (what we *asked* to boot): after
    /// a failed trial U-Boot falls back to the other slot without
    /// rewriting the env. Ports `ubootenv.go`'s `CurrentSlot`.
    public func currentSlot() throws -> Slot {
        let root: String
        do {
            root = try rootDeviceFn()
        } catch {
            throw UBootEnvError.currentSlotRootDeviceUnknown("\(error)")
        }
        let canonicalRoot = canon(root)

        // Identify the running root partition by its OWN device
        // (unambiguous even when a second disk carries the same
        // rootfsA/rootfsB). GPT: by partlabel. MBR: by partition number
        // (the OTA rootfs write wipes the just-committed slot's fs
        // label).
        if let parts = try? listPartsFn() {
            for p in parts where canon(p.path) == canonicalRoot {
                if Self.bootDiskHasPartlabel(parts, disk: p.pkname) {
                    switch Self.effectiveLabel(p) {
                    case Self.partlabelA: return .a
                    case Self.partlabelB: return .b
                    default: break
                    }
                } else if let n = Self.partNum(p.path, pkname: p.pkname) {
                    switch n {
                    case Self.mbrRootfsPartA: return .a
                    case Self.mbrRootfsPartB: return .b
                    default: break
                    }
                }
                break  // running root found; its identity didn't resolve — fall through
            }
        }

        // Fallback (running root not listed by lsblk, e.g. unit tests):
        // compare the running root against each slot's resolved device.
        for s: Slot in [.a, .b] {
            guard let dev = try? partition(for: s) else { continue }
            if canon(dev) == canonicalRoot { return s }
        }
        throw UBootEnvError.currentSlotNoMatch(root: canonicalRoot)
    }

    // MARK: - PartitionFor

    /// Resolves a slot's rootfs block device, scoped to the disk we
    /// booted from:
    ///   - GPT (rpi4/5): by GPT partlabel (`rootfsA`/`rootfsB`) — stable
    ///     across OTA.
    ///   - MBR (rpi3): by partition number (`rootfsA`=p2, `rootfsB`=p3),
    ///     because an OTA rootfs write wipes the target's ext4 label and
    ///     MBR has no partlabel.
    ///
    /// Falls back to the `/dev/disk/by-partlabel` then `by-label`
    /// symlinks only when the running root is not listed (early boot /
    /// unit tests). Ports `ubootenv.go`'s `PartitionFor`.
    public func partition(for s: Slot) throws -> String {
        let label = Self.rootfsSlotLabel(s)

        if let parts = try? listPartsFn(), let disk = try? bootDisk(parts), !disk.isEmpty {
            if Self.bootDiskHasPartlabel(parts, disk: disk) {
                // GPT: resolve by partlabel. On a miss, fall through to
                // the symlink fallback below (unchanged behavior).
                for p in parts where Self.effectiveLabel(p) == label && p.pkname == disk {
                    return p.path
                }
            } else {
                // MBR: resolve by partition number, scoped to the boot disk.
                let want = Self.mbrPartForSlot(s)
                for p in parts where p.pkname == disk {
                    if let n = Self.partNum(p.path, pkname: p.pkname), n == want {
                        return p.path
                    }
                }
                throw UBootEnvError.partitionNoMBRPartition(s, want: want, disk: disk)
            }
        }

        for base in ["/dev/disk/by-partlabel/", "/dev/disk/by-label/"] {
            if let dev = fileStore.resolveSymlink(rootDir + base + label) {
                return dev
            }
        }

        throw UBootEnvError.partitionNoLabelledPartition(s, label: label)
    }

    /// Returns the parent whole-disk kernel name (PKNAME) of the running
    /// root, e.g. `"mmcblk0"` for `/dev/mmcblk0p3`. Ports `ubootenv.go`'s
    /// `bootDisk`.
    func bootDisk(_ parts: [PartInfo]) throws -> String {
        let root = try rootDeviceFn()
        let canonicalRoot = canon(root)
        for p in parts where canon(p.path) == canonicalRoot {
            return p.pkname
        }
        throw UBootEnvInternalError(detail: "running root \"\(canonicalRoot)\" not found among partitions")
    }

    // MARK: - PrepareTarget

    /// Clears any stale trial state before a fresh slot is armed. A
    /// previous cycle that was aborted (power cut between write and
    /// swap, a failed install) could leave `wendyos_upgrade_available=1`
    /// or a non-zero `bootcount` lingering; arming a new trial on top of
    /// that would mis-count the retry budget. The actual arming happens
    /// in `swapSlot`. Ports `swap-slot.go`'s `PrepareTarget`.
    public func prepareTarget(_ s: Slot) throws {
        do {
            try env.set([Self.envUpgradeAvailable: "0", Self.envBootCount: "0"])
        } catch {
            throw UBootEnvError.prepareTargetFailed(s, "\(error)")
        }
    }

    // MARK: - Deferred to a later task (protocol-conformance stubs only)

    // TODO(future task): port `MarkGood` (swap-slot.go): clears the
    // trial flag, pins `wendyos_boot_slot` to the running slot, and
    // zeros `bootcount` — one atomic env write.
    public func markGood() throws {}

    // TODO(future task): port board-specific diagnostics/status detail
    // (diagnostics.go).
    public func diagnostics(verbose: Bool) -> [String: String] { [:] }
    public func slotStatus(_ s: Slot) -> SlotStatus { SlotStatus() }
    public func systemStatus() -> [KV] { [] }

    // MARK: - Slot ↔ partition resolution helpers

    /// Ports `ubootenv.go`'s `rootfsSlotLabel`.
    static func rootfsSlotLabel(_ s: Slot) -> String {
        s == .a ? partlabelA : partlabelB
    }

    /// Maps a slot to the `wendyos_boot_slot` string the boot script
    /// expects (`"0"`/`"1"`, same encoding as `Slot`'s raw value). Ports
    /// `ubootenv.go`'s `slotEnvValue`.
    static func slotEnvValue(_ s: Slot) -> String {
        String(s.rawValue)
    }

    /// Maps a slot to its MBR rootfs partition number. Ports
    /// `ubootenv.go`'s `mbrPartForSlot`.
    static func mbrPartForSlot(_ s: Slot) -> Int {
        s == .b ? mbrRootfsPartB : mbrRootfsPartA
    }

    /// A partition's slot identity: the GPT partlabel when present, else
    /// the filesystem label. Ports `ubootenv.go`'s `effectiveLabel`.
    static func effectiveLabel(_ p: PartInfo) -> String {
        p.partlabel.isEmpty ? p.label : p.partlabel
    }

    /// Reports whether ANY partition on `disk` carries a GPT PARTLABEL
    /// (decided once per disk so a mixed-signal partition can never be
    /// partially resolved by number). Ports `ubootenv.go`'s
    /// `bootDiskHasPartlabel`.
    static func bootDiskHasPartlabel(_ parts: [PartInfo], disk: String) -> Bool {
        parts.contains { $0.pkname == disk && !$0.partlabel.isEmpty }
    }

    /// Extracts a partition's number from its device path given the
    /// parent disk kernel name: `("/dev/mmcblk0p3","mmcblk0")` -> `3`,
    /// `("/dev/sda3","sda")` -> `3`. `nil` if it cannot be parsed. Ports
    /// `ubootenv.go`'s `partNum`.
    static func partNum(_ path: String, pkname: String) -> Int? {
        guard !pkname.isEmpty else { return nil }
        var suffix = Substring(path)
        if suffix.hasPrefix("/dev/") { suffix.removeFirst("/dev/".count) }
        if suffix.hasPrefix(pkname) { suffix.removeFirst(pkname.count) }
        if suffix.hasPrefix("p") { suffix.removeFirst() }
        return Int(suffix)
    }

    /// Canonicalizes a device path via `resolveSymlink`, returning the
    /// input unchanged when it doesn't (transitively) resolve — e.g. the
    /// path is not a real node, as in unit tests. Ports `ubootenv.go`'s
    /// `canon` (`filepath.EvalSymlinks`, same failure-passthrough
    /// behavior).
    func canon(_ dev: String) -> String {
        fileStore.resolveSymlink(dev) ?? dev
    }

    // MARK: - Real (production) rootDeviceFn / listPartsFn

    /// Returns the block device mounted at `/` via `findmnt -no SOURCE
    /// /`. Ports `ubootenv.go`'s `currentRootDevice`.
    static func defaultRootDevice(commandRunner: any UBootCommandRunner) -> @Sendable () throws -> String {
        {
            let result = commandRunner.run(["findmnt", "-no", "SOURCE", "/"])
            guard result.exitCode == 0 else {
                throw UBootEnvInternalError(detail: "findmnt /: exit \(result.exitCode)")
            }
            let dev = trimmed(String(decoding: result.stdout, as: UTF8.self))
            guard !dev.isEmpty else {
                throw UBootEnvInternalError(detail: "findmnt /: empty source")
            }
            return dev
        }
    }

    /// Lists block partitions with their partlabel, fs label and parent
    /// disk via `lsblk -P` (`KEY="value"` — robust to empty columns,
    /// e.g. partitions with no partlabel on an MBR table). Ports
    /// `ubootenv.go`'s `lsblkParts`.
    static func defaultListParts(commandRunner: any UBootCommandRunner) -> @Sendable () throws -> [PartInfo] {
        {
            let result = commandRunner.run(["lsblk", "-Pno", "PATH,PARTLABEL,LABEL,PKNAME"])
            guard result.exitCode == 0 else {
                throw UBootEnvInternalError(detail: "lsblk: exit \(result.exitCode)")
            }
            let out = String(decoding: result.stdout, as: UTF8.self)
            var parts: [PartInfo] = []
            for line in out.split(separator: "\n") {
                guard !trimmed(String(line)).isEmpty else { continue }
                parts.append(
                    PartInfo(
                        path: lsblkField(line, key: "PATH"),
                        partlabel: lsblkField(line, key: "PARTLABEL"),
                        label: lsblkField(line, key: "LABEL"),
                        pkname: lsblkField(line, key: "PKNAME")
                    )
                )
            }
            return parts
        }
    }

    /// Extracts `key`'s value from an `lsblk -P` line (`KEY="value"
    /// ...`). Ports `ubootenv.go`'s `lsblkField`.
    static func lsblkField(_ line: Substring, key: String) -> String {
        let prefix = key + "=\""
        guard let range = firstRange(of: prefix, in: line) else { return "" }
        let afterPrefix = line[range.upperBound...]
        guard let endQuote = afterPrefix.firstIndex(of: "\"") else { return "" }
        return String(afterPrefix[afterPrefix.startIndex..<endQuote])
    }

    /// A dependency-free (no `Foundation`) substring search, since
    /// `String.range(of:)` requires `Foundation` on Linux.
    static func firstRange(of needle: String, in haystack: Substring) -> Range<Substring.Index>? {
        guard !needle.isEmpty else { return nil }
        var start = haystack.startIndex
        while start < haystack.endIndex {
            if let end = haystack.index(start, offsetBy: needle.count, limitedBy: haystack.endIndex),
                haystack[start..<end] == needle
            {
                return start..<end
            }
            start = haystack.index(after: start)
        }
        return nil
    }

    /// Trims ASCII whitespace from both ends without pulling in
    /// `Foundation` for a single trim. Ports Go's implicit
    /// `strings.TrimSpace` usage.
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
    /// `strings.Fields`.
    static func whitespaceFields(_ line: Substring) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Scans `PATH` for an executable named `name`, mirroring Go's
    /// `exec.LookPath` as used by `detect()`.
    static func commandExistsOnPath(_ name: String) -> Bool {
        guard let pathEnv = Glibc.getenv("PATH") else { return false }
        let pathVar = String(cString: pathEnv)
        for dir in pathVar.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if candidate.withCString({ Glibc.access($0, X_OK) == 0 }) {
                return true
            }
        }
        return false
    }
}

/// One block partition as reported by `lsblk`: device path, GPT
/// partlabel, filesystem label, and parent whole-disk kernel name
/// (PKNAME). Ports `ubootenv.go`'s `partInfo`.
public struct PartInfo: Sendable {
    public let path: String
    public var partlabel: String = ""
    public var label: String = ""
    public var pkname: String = ""

    public init(path: String, partlabel: String = "", label: String = "", pkname: String = "") {
        self.path = path
        self.partlabel = partlabel
        self.label = label
        self.pkname = pkname
    }
}

/// A lightweight, description-only error for internal plumbing
/// (`bootDisk`, the default `findmnt`/`lsblk` seams, `assertEnvWritable`)
/// whose failures are always caught and re-wrapped into a
/// `UBootEnvError` by their caller, or discarded via `try?` — mirrors how
/// Go wraps a plain `fmt.Errorf` at each of these call sites.
struct UBootEnvInternalError: Error, CustomStringConvertible {
    let detail: String
    var description: String { detail }
}

/// The U-Boot environment access seam. The real implementation shells
/// out to libubootenv; tests substitute an in-memory store. `set` is a
/// single atomic batch (libubootenv writes the whole script
/// transactionally), which matters when arming a trial: slot + flag +
/// counter must land together. Ports `ubootenv.go`'s `envStore`.
public protocol UBootEnvStore: Sendable {
    /// Reads one variable. An unset or unreadable variable reads as the
    /// empty string — a missing trial flag means "no trial", a missing
    /// slot means "unknown", both safe defaults the callers already
    /// handle. Ports `fwEnv.get`, which never actually returns a non-nil
    /// error (an `fw_printenv` failure is swallowed to `""`).
    func get(_ name: String) -> String

    /// Writes `vars` atomically.
    func set(_ vars: [String: String]) throws
}

/// `UBootEnvStore` backed by `fw_printenv`/`fw_setenv`. Ports
/// `ubootenv.go`'s `fwEnv`.
struct FwEnv: UBootEnvStore {
    let commandRunner: any UBootCommandRunner
    let fileStore: any FileStore
    let rootDir: String
    var printenv = "fw_printenv"
    var setenv = "fw_setenv"

    func get(_ name: String) -> String {
        let result = commandRunner.run([printenv, "-n", name])
        guard result.exitCode == 0 else { return "" }
        return UBootEnv.trimmed(String(decoding: result.stdout, as: UTF8.self))
    }

    /// Writes `vars` as a libubootenv `-s` script to a scratch file, runs
    /// `fw_setenv -s <file>`, then syncs. Two libubootenv specifics
    /// learned bringing up RPi OTA (see `envScript`): the script MUST use
    /// `"key=value"` (a bare space is silently ignored), and `-s` opens a
    /// real file (it does NOT treat `"-"` as stdin). Ports `fwEnv.set`.
    func set(_ vars: [String: String]) throws {
        let scriptPath = rootDir + "/run/wendyos-update/.fwenv-script"
        do {
            try fileStore.writeAtomic(scriptPath, Array(Self.envScript(vars).utf8), mode: 0o600)
        } catch {
            throw UBootEnvInternalError(detail: "fw_setenv: write script: \(error)")
        }
        defer { try? fileStore.remove(scriptPath) }

        let result = commandRunner.run([setenv, "-s", scriptPath])
        guard result.exitCode == 0 else {
            let combined = String(decoding: result.stdout + result.stderr, as: UTF8.self)
            throw UBootEnvInternalError(detail: "fw_setenv: exit \(result.exitCode) (\(combined))")
        }
        // Flush before returning: callers arm a trial then reboot almost
        // immediately, and on RPi the env is a file on the FAT
        // (CONFIG_ENV_IS_IN_FAT). A global sync gets the env write onto
        // disk before the reboot.
        Glibc.sync()
    }

    /// Renders `vars` as a libubootenv `-s` script — one `key=value` per
    /// line. The `=` is REQUIRED: libubootenv silently ignores lines
    /// without it. Ports `ubootenv.go`'s `envScript`.
    static func envScript(_ vars: [String: String]) -> String {
        var script = ""
        for (key, value) in vars {
            script += "\(key)=\(value)\n"
        }
        return script
    }
}
