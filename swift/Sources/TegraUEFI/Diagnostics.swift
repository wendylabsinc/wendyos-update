import Connector
import Glibc
import PlatformIO

// Port of `internal/connector/tegrauefi/diagnostics.go`: `Diagnostics`,
// `SlotStatus`, `SystemStatus`. Display-only, best-effort for the
// `status` verb: every probe swallows its own failure so `status` never
// errors on a quirky platform state, and an unreadable item is simply
// omitted from the result. With `verbose` set, `diagnostics` adds a
// fuller raw slot/EFI-variable snapshot for debugging.
extension TegraUEFI {
    // MARK: - diagnostics

    /// Best-effort map of board-specific debug detail: rootfs/bootloader
    /// slots, the ESRT (capsule) outcome, per-slot rootfs health, and
    /// whether rootfs A/B redundancy is armed. With `verbose`, adds the
    /// raw slot/EFI-variable snapshot from `verboseDiagnostics`. Ports
    /// `diagnostics.go`'s `Diagnostics`.
    public func diagnostics(verbose: Bool) -> [String: String] {
        var d: [String: String] = [:]

        if let s = try? currentSlot() {
            d["rootfs_slot"] = s.description
        }

        // Bootloader slot + version — the BOOTLOADER view of
        // dump-slots-info (no `-t rootfs`). Captured once; the verbose
        // pass re-parses it for the per-slot detail lines.
        let blInfo = Self.decodeCombined(commandRunner.run([nvbootctrl, "dump-slots-info"]))
        for line in blInfo.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = Self.trimmed(String(line))
            if l.hasPrefix("Current version:") {
                d["bootloader_version"] = Self.trimmed(String(l.dropFirst("Current version:".count)))
            }
            if l.hasPrefix("Current bootloader slot:") {
                d["bootloader_slot"] = Self.trimmed(String(l.dropFirst("Current bootloader slot:".count)))
            }
        }

        // ESRT entry0 — outcome of the last capsule (bootloader) update.
        let esrtDir = Self.dirname(rootDir + Self.esrtStatusPath)
        let esrtFiles: [(key: String, file: String)] = [
            ("esrt_last_attempt_status", "last_attempt_status"),
            ("esrt_fw_version", "fw_version"),
            ("esrt_lowest_supported_version", "lowest_supported_fw_version"),
        ]
        for (key, file) in esrtFiles {
            if let b = try? fileStore.read(esrtDir + "/" + file) {
                d[key] = Self.trimmed(String(decoding: b, as: UTF8.self))
            }
        }

        // Per-slot rootfs health efivar (normal vs unbootable).
        for s in [Slot.a, Slot.b] {
            if let raw = try? EfiVar.readStatus(statusVarPath(s)) {
                d["rootfs_status_" + s.description] = EfiVar.statusIsNormal(raw) ? "normal" : "unbootable"
            }
        }

        // Rootfs A/B redundancy: when not armed, a slot switch is a
        // firmware no-op and every OTA rolls back — the single most
        // important field for diagnosing a device that installs but
        // never commits.
        if let armed = rootfsRedundancyArmed() {
            d["rootfs_redundancy"] = armed
                ? "armed"
                : "NOT ARMED (RootfsRedundancyLevel missing/zero — slot switch is a no-op)"
        }

        if verbose {
            verboseDiagnostics(&d, blInfo: blInfo)
        }
        return d
    }

    /// Adds the raw slot/EFI-variable snapshot used for debugging
    /// (`status --verbose`). Every probe is best-effort. Ports
    /// `diagnostics.go`'s `verboseDiagnostics`.
    private func verboseDiagnostics(_ d: inout [String: String], blInfo: String) {
        // Raw RootfsStatusSlot bytes so a 0xFF (byte 4) is directly
        // visible alongside the normal|unbootable label.
        for s in [Slot.a, Slot.b] {
            if let raw = try? EfiVar.readStatus(statusVarPath(s)) {
                d["rootfs_status_" + s.description + "_raw"] = Self.hexSpaced(raw)
            }
        }

        // Per-slot bootloader state (status / retry_count / priority),
        // parsed from the `slot: N, …` lines of dump-slots-info.
        for line in blInfo.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = Self.trimmed(String(line))
            guard l.hasPrefix("slot:") else { continue }
            let rest = Self.trimmed(String(l.dropFirst("slot:".count)))
            let parts = rest.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init)
            let num = Self.trimmed(parts[0])
            var detail = ""
            if parts.count > 1 {
                detail = Self.whitespaceFields(Substring(parts[1])).joined(separator: " ")
            }
            d["bootloader_slot_" + num] = detail
        }

        // BootChainFw* variables (Current/Next/Status) drive the
        // firmware A/B bootloader-chain transitions a capsule triggers.
        // Globbed (via a raw directory scan) so no GUID is hardcoded.
        for name in Self.directoryEntries(efivarsDir) where name.hasPrefix("BootChainFw") {
            let path = efivarsDir + "/" + name
            guard let raw = try? EfiVar.readStatus(path) else { continue }
            let val = raw.count >= 4 ? Array(raw[4...]) : raw  // skip the 4 attribute bytes
            d[Self.varStem(name).lowercased()] = Self.hexSpaced(val)
        }

        // OsIndications: capsule-process bit (0x04) armed = "process
        // capsule on next boot". Shows the raw bytes plus the decoded
        // arm state.
        if let raw = try? EfiVar.readStatus(osIndicationsVarPath()) {
            let armed = raw.count >= 5 && (raw[4] & UInt8(TegraUEFI.osIndicationsProcessCapsule) != 0)
            d["osindications"] = "\(Self.hexSpaced(raw)) (capsule_armed=\(armed))"
        }
    }

    // MARK: - slotStatus

    /// A slot's rootfs health (the `RootfsStatusSlot` efivar) and
    /// remaining trial attempts (`nvbootctrl rootfs retry_count`).
    /// Display-only. Ports `diagnostics.go`'s `SlotStatus`.
    public func slotStatus(_ s: Slot) -> SlotStatus {
        var st = SlotStatus()
        if let raw = try? EfiVar.readStatus(statusVarPath(s)) {
            st.rootfsHealth = EfiVar.statusIsNormal(raw) ? "normal" : "unbootable"
        }
        if let info = rootfsSlotInfo(), let d = info[s.rawValue] {
            st.retries = d.retry
            if st.rootfsHealth.isEmpty && !d.status.isEmpty {
                st.rootfsHealth = d.status  // efivar unreadable: fall back to nvbootctrl
            }
        }
        return st
    }

    /// Per-slot `retry_count`/`status` parsed from `nvbootctrl -t rootfs
    /// dump-slots-info` (the rootfs A/B view, which carries
    /// `retry_count`; the bootloader view does not). Ports
    /// `diagnostics.go`'s `rootfsSlot`/`rootfsSlotInfo`.
    private struct RootfsSlotInfo {
        var retry = ""
        var status = ""
    }

    private func rootfsSlotInfo() -> [Int: RootfsSlotInfo]? {
        let result = commandRunner.run([nvbootctrl, "-t", "rootfs", "dump-slots-info"])
        guard result.exitCode == 0 else { return nil }

        var m: [Int: RootfsSlotInfo] = [:]
        for line in Self.decodeCombined(result).split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = Self.trimmed(String(line))
            guard trimmedLine.hasPrefix("slot:") else { continue }
            let rest = String(trimmedLine.dropFirst("slot:".count))
            let fields = rest.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let num = Int(Self.trimmed(fields[0])) else { continue }

            var info = RootfsSlotInfo()
            for f in fields.dropFirst() {
                let trimmedF = Self.trimmed(f)
                if trimmedF.hasPrefix("retry_count:") {
                    info.retry = Self.trimmed(String(trimmedF.dropFirst("retry_count:".count)))
                }
                if trimmedF.hasPrefix("status:") {
                    info.status = Self.trimmed(String(trimmedF.dropFirst("status:".count)))
                }
            }
            m[num] = info
        }
        return m
    }

    // MARK: - systemStatus

    /// Ordered, system-wide (not per-slot) status lines: the bootloader
    /// version and the last capsule (ESRT) outcome. Ports
    /// `diagnostics.go`'s `SystemStatus`.
    public func systemStatus() -> [KV] {
        var kv: [KV] = []

        let blInfo = Self.decodeCombined(commandRunner.run([nvbootctrl, "dump-slots-info"]))
        for line in blInfo.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = Self.trimmed(String(line))
            if l.hasPrefix("Current version:") {
                kv.append(KV("bootloader version", Self.trimmed(String(l.dropFirst("Current version:".count)))))
                break
            }
        }

        let esrtDir = Self.dirname(rootDir + Self.esrtStatusPath)
        if let b = try? fileStore.read(esrtDir + "/last_attempt_status") {
            var s = Self.trimmed(String(decoding: b, as: UTF8.self))
            if s == "0" { s = "0 (success)" }
            kv.append(KV("last capsule status", s))
        }

        return kv
    }

    // MARK: - Shared helpers

    /// Reports whether rootfs A/B redundancy is armed in firmware: the
    /// `RootfsRedundancyLevel` efivar exists with a non-zero level.
    /// Returns `nil` on an unexpected read failure (the diagnostics field
    /// is skipped entirely, matching Go's `err == nil` gate); a missing
    /// variable or a present-but-short/zero one report `false`. Ports
    /// `tegrauefi.go`'s `rootfsRedundancyArmed`.
    private func rootfsRedundancyArmed() -> Bool? {
        let path = redundancyLevelVarPath()
        guard efivarExists(path) else { return false }
        guard let raw = try? EfiVar.readStatus(path) else { return nil }
        guard raw.count >= 8 else { return false }
        return raw[4] != 0 || raw[5] != 0 || raw[6] != 0 || raw[7] != 0
    }

    /// Strips the last `/segment` from a path, mirroring `filepath.Dir`
    /// for the single always-absolute-path use here (the ESRT
    /// `.../entry0/last_attempt_status` path).
    private static func dirname(_ path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "." }
        if idx == path.startIndex { return "/" }
        return String(path[path.startIndex..<idx])
    }

    /// Strips the trailing `-<GUID>` from an efivarfs filename (e.g.
    /// `BootChainFwCurrent-<guid>` -> `BootChainFwCurrent`). Ports
    /// `diagnostics.go`'s `varStem`.
    private static func varStem(_ filename: String) -> String {
        if let idx = filename.firstIndex(of: "-"), idx != filename.startIndex {
            return String(filename[filename.startIndex..<idx])
        }
        return filename
    }

    /// Formats `bytes` as lowercase, space-separated hex pairs (e.g. `07
    /// 00 ff 00`), matching Go's `fmt.Sprintf("% x", raw)`.
    private static func hexSpaced(_ bytes: [UInt8]) -> String {
        let hexDigits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
        return bytes.map { byte -> String in
            String([hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]])
        }.joined(separator: " ")
    }

    /// Lists the immediate entries of `dir` (excluding `.`/`..`) via a raw
    /// `opendir`/`readdir` scan. `efivarsDir` is a real filesystem path in
    /// both production and tests, bypassing `fileStore` — matching
    /// `efivarExists`'s direct `Glibc.access` use — since `fileStore`
    /// models the `rootDir`-prefixed regular filesystem instead. Returns
    /// an empty array if `dir` can't be opened, mirroring
    /// `filepath.Glob`'s best-effort "no matches" on a lookup failure.
    private static func directoryEntries(_ dir: String) -> [String] {
        guard let dp = Glibc.opendir(dir) else { return [] }
        defer { Glibc.closedir(dp) }

        var names: [String] = []
        while let entry = Glibc.readdir(dp) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: ptr)
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names
    }
}
