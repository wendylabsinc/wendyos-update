import Connector
import Engine
import Foundation
import IkigaJSON
import Model

// stdout is the machine-readable JSON channel ONLY (docs/cli-contract.md);
// every human-facing line goes to stderr via `WendyLog`/`Logger`. This file
// builds the JSON event objects `install`/`switch`/`rollback`/`status
// --json` emit, plus the plain-text `status` view, and the two small
// helpers that write to the two streams.
//
// The ad hoc events (`install`'s "done", `switch`, `rollback`, the
// progress line) port Go `map[string]any` literals passed to
// `json.Marshal` in main.go — Go's `encoding/json` sorts a map's keys
// ALPHABETICALLY when encoding, regardless of the literal's source order,
// so each `make*JSON` builder below inserts keys in alphabetical (not
// call-site-obvious) order to match that byte-for-byte. `status --json`,
// by contrast, marshals a *struct* (`*engine.StatusInfo`), which Go
// encodes in DECLARED FIELD order — so its builder mirrors the Go struct's
// field order instead, exactly like `Model/Encode.swift`'s builders do for
// `Manifest`/`State`/etc.

// MARK: - Ad hoc event objects (map-shaped in Go; alphabetical key order)

/// The `install` verb's `"done"` event. Ports the `map[string]any` built in
/// main.go's `cmdInstall`.
func makeInstallDoneJSON(_ result: InstallResult) -> JSONObject {
    var object = JSONObject()
    object["artifact_name"] = result.artifactName
    object["artifact_version"] = result.artifactVersion
    object["bootloader_update"] = result.bootloaderUpdate
    object["percent"] = 100
    object["phase"] = "done"
    object["reboot_required"] = true
    object["target_slot"] = result.targetSlot.description
    return object
}

/// The `switch` verb's event. Ports the `map[string]any` built in
/// main.go's `cmdSwitch`.
func makeSwitchJSON(target: Slot) -> JSONObject {
    var object = JSONObject()
    object["phase"] = "switch"
    object["reboot_required"] = true
    object["target_slot"] = target.description
    return object
}

/// The `rollback` verb's event. Ports the `map[string]any` built in
/// main.go's `cmdRollback`.
func makeRollbackJSON(_ result: RollbackResult) -> JSONObject {
    var object = JSONObject()
    object["origin_slot"] = result.originSlot.description
    object["phase"] = "rollback"
    object["reboot_required"] = result.rebootRequired
    return object
}

/// The coarse install-progress line. `percent < 0` means indeterminate
/// ("phase…", e.g. `download`). Ports the `map[string]any` built in
/// main.go's `emitProgress`.
func makeProgressJSON(phase: String, percent: Int) -> JSONObject {
    var object = JSONObject()
    object["percent"] = percent
    object["phase"] = phase
    return object
}

// MARK: - status --json (struct-shaped in Go; declared field order)

func makeSlotStateJSON(_ slot: SlotState) -> JSONObject {
    var object = JSONObject()
    object["slot"] = slot.slot
    object["booted"] = slot.booted
    if !slot.partition.isEmpty { object["partition"] = slot.partition }
    if !slot.distro.isEmpty { object["distro"] = slot.distro }
    if !slot.kernel.isEmpty { object["kernel"] = slot.kernel }
    if !slot.rootfsHealth.isEmpty { object["rootfs_health"] = slot.rootfsHealth }
    if !slot.retries.isEmpty { object["retries"] = slot.retries }
    if !slot.note.isEmpty { object["note"] = slot.note }
    return object
}

func makeKVJSON(_ kv: KV) -> JSONObject {
    var object = JSONObject()
    object["key"] = kv.key
    object["value"] = kv.value
    return object
}

/// Ports main.go's `json.MarshalIndent(info, "", "  ")` for the `status
/// --json` verb, field-for-field against `engine.StatusInfo`'s declared
/// order and `omitempty` tags: `slots`/`system`/`diagnostics` are omitted
/// entirely when empty, `pending` is omitted when `nil`.
func makeStatusJSON(_ info: StatusInfo) -> JSONObject {
    var object = JSONObject()
    object["connector"] = info.connector
    object["current_slot"] = info.currentSlot
    if !info.slots.isEmpty {
        var slots = JSONArray()
        for slot in info.slots { slots.append(makeSlotStateJSON(slot)) }
        object["slots"] = slots
    }
    if !info.system.isEmpty {
        var system = JSONArray()
        for kv in info.system { system.append(makeKVJSON(kv)) }
        object["system"] = system
    }
    if let pending = info.pending {
        object["pending"] = pending.makeJSONObject()
    }
    if !info.diagnostics.isEmpty {
        var diagnostics = JSONObject()
        // Go's map[string]string marshals with keys sorted ascending.
        for key in info.diagnostics.keys.sorted() {
            diagnostics[key] = info.diagnostics[key]
        }
        object["diagnostics"] = diagnostics
    }
    return object
}

// MARK: - stdout/stderr writers

/// Writes `bytes` to stdout followed by a newline — mirrors Go's
/// `fmt.Println(string(line))` around a compact `json.Marshal` result.
func writeStdoutLine(_ bytes: [UInt8]) {
    var data = Data(bytes)
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

/// Writes `bytes` to stdout verbatim — for `JSONCodec.encodePretty`
/// output, which already carries its own trailing newline.
func writeStdoutRaw(_ bytes: [UInt8]) {
    FileHandle.standardOutput.write(Data(bytes))
}

/// Emits a compact JSON event line to stdout, unless stdout is a TTY (a
/// human is watching the terminal directly, not a machine caller piping
/// it) — ports the `if !stdoutIsTTY { ... }` guard wrapped around every
/// `fmt.Println` in main.go's `cmdInstall`/`cmdSwitch`/`cmdRollback`.
/// `write` is injected so this stays testable without touching real stdout.
func emitEvent(_ object: JSONObject, stdoutIsTTY: Bool, write: ([UInt8]) -> Void = writeStdoutLine) {
    guard !stdoutIsTTY else { return }
    write(JSONCodec.encodeCompact(object))
}

/// Emits one progress line, subject to the same TTY suppression as
/// `emitEvent`. Ports main.go's `emitProgress`'s stdout half (the stderr
/// bar half is `ProgressReporter.update`, driven separately).
func emitProgressJSON(phase: String, percent: Int, stdoutIsTTY: Bool, write: ([UInt8]) -> Void = writeStdoutLine) {
    emitEvent(makeProgressJSON(phase: phase, percent: percent), stdoutIsTTY: stdoutIsTTY, write: write)
}

// MARK: - Human-readable `status` view (stderr)

/// Renders the plain-text `status` view (no `--json`) exactly like
/// main.go's `cmdStatus` — including that it writes to STDERR, not stdout:
/// `status`'s only stdout output is the `--json` form.
func renderHumanStatus(_ info: StatusInfo, verbose: Bool) -> String {
    var lines: [String] = []
    lines.append("wendyos-update \(WendyUpdate.version)   ·   connector: \(info.connector)")

    lines.append("")
    lines.append("System")
    lines.append("  \(leftPad("booted slot:", 20)) \(info.currentSlot)")
    for kv in info.system {
        lines.append("  \(leftPad("\(kv.key):", 20)) \(kv.value)")
    }

    lines.append("")
    lines.append("Slots")
    for slot in info.slots {
        let marker = slot.booted ? "● " : "○ "
        let label = slot.booted ? "booted" : "inactive"
        lines.append("  \(marker)\(slot.slot)   \(label)")
        let rootfs = rootfsLine(slot)
        if !rootfs.isEmpty {
            lines.append("        \(leftPad("rootfs:", 12)) \(rootfs)")
        }
        lines.append("        \(leftPad("distro:", 12)) \(orUnknown(slot.distro))")
        lines.append("        \(leftPad("kernel:", 12)) \(orUnknown(slot.kernel))")
        if !slot.retries.isEmpty {
            lines.append("        \(leftPad("retries:", 12)) \(slot.retries)")
        }
        if !slot.note.isEmpty {
            lines.append("        \(leftPad("note:", 12)) \(slot.note)")
        }
    }

    lines.append("")
    lines.append("Pending update")
    if let pending = info.pending {
        lines.append("  \(leftPad("artifact:", 12)) \(pending.artifactName)")
        lines.append("  \(leftPad("version:", 12)) \(pending.artifactVersion)")
        lines.append("  \(leftPad("phase:", 12)) \(pending.phase)")
        let target = Slot(rawValue: pending.targetSlot)?.description ?? "\(pending.targetSlot)"
        lines.append("  \(leftPad("target:", 12)) \(target)")
    } else {
        lines.append("  none")
    }

    if verbose, !info.diagnostics.isEmpty {
        lines.append("")
        lines.append("Raw diagnostics")
        for key in info.diagnostics.keys.sorted() {
            lines.append("  \(leftPad(key, 30)) \(info.diagnostics[key]!)")
        }
    }

    return lines.joined(separator: "\n") + "\n"
}

/// Left-justifies `s` to `width` characters, matching Go's `%-Ns` (no
/// truncation when `s` is already wider than `width`).
private func leftPad(_ s: String, _ width: Int) -> String {
    s.count < width ? s + String(repeating: " ", count: width - s.count) : s
}

/// Renders a slot's device + health on one line, rauc-style (e.g.
/// "/dev/nvme0n1p1, normal"); either part may be absent. Ports main.go's
/// `rootfsLine`.
private func rootfsLine(_ slot: SlotState) -> String {
    var parts: [String] = []
    if !slot.partition.isEmpty { parts.append(slot.partition) }
    if !slot.rootfsHealth.isEmpty { parts.append(slot.rootfsHealth) }
    return parts.joined(separator: ", ")
}

private func orUnknown(_ s: String) -> String {
    s.isEmpty ? "unknown" : s
}
