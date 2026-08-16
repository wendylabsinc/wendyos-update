import Foundation
import IkigaJSON

// MARK: - Ordered JSONObject builders
//
// Each `makeJSONObject()` below assigns keys to a `JSONObject` in the exact
// order the corresponding Go struct declares its fields. IkigaJSON's
// `JSONObject` subscript setter appends new keys at the end of its
// underlying buffer (it only rewrites in place for a key that already
// exists), so insertion order here IS the emitted key order — this is what
// guarantees `JSONCodec.encodePretty`/`encodeCompact` output matches Go's
// `json.Marshal`/`MarshalIndent` byte-for-byte in field order, independent
// of however Swift happens to lay out the struct's stored properties.

extension Payload {
    public func makeJSONObject() -> JSONObject {
        var object = JSONObject()
        object["name"] = name
        // `Int64` -> `Int`: safe on every platform this tool targets
        // (64-bit Linux/macOS), and `JSONObject` only knows how to store a
        // plain `Int`.
        object["size"] = Int(size)
        object["sha256"] = sha256
        object["compressed_sha256"] = compressedSHA256
        object["compression"] = compression
        return object
    }
}

extension Manifest {
    public func makeJSONObject() -> JSONObject {
        var object = JSONObject()
        object["format_version"] = formatVersion
        object["artifact_name"] = artifactName
        object["artifact_version"] = artifactVersion
        var devices = JSONArray()
        for device in compatibleDevices {
            devices.append(device)
        }
        object["compatible_devices"] = devices
        object["payload"] = payload.makeJSONObject()
        object["bootloader_update"] = bootloaderUpdate
        object["min_tool_version"] = minToolVersion
        return object
    }
}

extension State {
    public func makeJSONObject() -> JSONObject {
        var object = JSONObject()
        object["schema"] = schema
        object["phase"] = phase
        object["target_slot"] = targetSlot
        object["artifact_name"] = artifactName
        object["artifact_version"] = artifactVersion
        object["payload_sha256"] = payloadSHA256
        object["bootloader_update"] = bootloaderUpdate
        object["created"] = created
        return object
    }
}

extension InstalledEntry {
    public func makeJSONObject() -> JSONObject {
        var object = JSONObject()
        object["artifact_name"] = artifactName
        object["artifact_version"] = artifactVersion
        object["committed"] = committed
        object["slot"] = slot
        return object
    }
}

extension InstalledHistory {
    public func makeJSONObject() -> JSONObject {
        var object = JSONObject()
        var entries = JSONArray()
        for entry in history {
            entries.append(entry.makeJSONObject())
        }
        object["history"] = entries
        return object
    }
}

extension Config {
    /// Omits keys for `nil` fields entirely (rather than writing `null`),
    /// matching how this config file is actually produced/consumed:
    /// downstream readers treat "absent" and "null" identically (both mean
    /// "use the default"), and Go never marshals this struct back out —
    /// it's read-only — so there's no wire format to match key-for-key.
    public func makeJSONObject() -> JSONObject {
        var object = JSONObject()
        if let connector { object["connector"] = connector }
        if let deviceTypePath { object["device_type_path"] = deviceTypePath }
        if let stateDir { object["state_dir"] = stateDir }
        if let hooksDir { object["hooks_dir"] = hooksDir }
        if let healthDir { object["health_dir"] = healthDir }
        return object
    }
}

// MARK: - JSONCodec encode entry points

extension JSONCodec {
    /// Single-line JSON — the bytes IkigaJSON already built while
    /// `JSONObject`'s subscript setters ran, with no reformatting.
    public static func encodeCompact(_ obj: JSONObject) -> [UInt8] {
        [UInt8](obj.data)
    }

    /// 2-space-indented JSON + a trailing newline, matching
    /// `json.MarshalIndent(v, "", "  ")` followed by a written `\n` on the
    /// Go side. IkigaJSON has no pretty-printer of its own, so this walks
    /// the already-built `JSONObject`/`JSONArray` tree (reusing IkigaJSON's
    /// parsed key order and value typing) and lays out the indentation by
    /// hand.
    public static func encodePretty(_ obj: JSONObject) -> [UInt8] {
        // Re-parse `obj`'s own compact bytes before walking it: IkigaJSON's
        // nested-container read path (`JSONObject`/`JSONArray` subscript
        // get, which slices the parent's description) assumes the
        // description was built by its tokenizer, not by the
        // mutate-in-place subscript-set path `makeJSONObject()` uses to
        // control key order. Reading a nested array straight out of a
        // freshly *built* (never re-parsed) object crashes inside
        // IkigaJSON — round-tripping through the tokenizer once here
        // sidesteps that and is cheap next to the pretty-printing walk
        // itself.
        let reparsed = (try? JSONObject(data: obj.data)) ?? obj
        var out: [UInt8] = []
        writePretty(reparsed, indent: 0, into: &out)
        out.append(UInt8(ascii: "\n"))
        return out
    }
}

private func writePretty(_ value: JSONValue, indent: Int, into out: inout [UInt8]) {
    switch value {
    case let object as JSONObject:
        writePrettyObject(object, indent: indent, into: &out)
    case let array as JSONArray:
        writePrettyArray(array, indent: indent, into: &out)
    case let string as String:
        writeJSONString(string, into: &out)
    case let int as Int:
        out.append(contentsOf: Array(String(int).utf8))
    case let double as Double:
        out.append(contentsOf: Array(String(double).utf8))
    case let bool as Bool:
        out.append(contentsOf: Array((bool ? "true" : "false").utf8))
    default:
        // `NSNull`, or anything else `JSONValue` might in principle admit.
        out.append(contentsOf: Array("null".utf8))
    }
}

private func writePrettyObject(_ object: JSONObject, indent: Int, into out: inout [UInt8]) {
    let keys = object.keys
    guard !keys.isEmpty else {
        out.append(contentsOf: Array("{}".utf8))
        return
    }

    let childIndent = indent + 2
    out.append(UInt8(ascii: "{"))
    out.append(UInt8(ascii: "\n"))
    for (index, key) in keys.enumerated() {
        out.append(contentsOf: repeatElement(UInt8(ascii: " "), count: childIndent))
        writeJSONString(key, into: &out)
        out.append(contentsOf: Array(": ".utf8))
        writePretty(object[key] ?? NSNull(), indent: childIndent, into: &out)
        if index < keys.count - 1 {
            out.append(UInt8(ascii: ","))
        }
        out.append(UInt8(ascii: "\n"))
    }
    out.append(contentsOf: repeatElement(UInt8(ascii: " "), count: indent))
    out.append(UInt8(ascii: "}"))
}

private func writePrettyArray(_ array: JSONArray, indent: Int, into out: inout [UInt8]) {
    guard array.count > 0 else {
        out.append(contentsOf: Array("[]".utf8))
        return
    }

    let childIndent = indent + 2
    out.append(UInt8(ascii: "["))
    out.append(UInt8(ascii: "\n"))
    for index in 0..<array.count {
        out.append(contentsOf: repeatElement(UInt8(ascii: " "), count: childIndent))
        writePretty(array[index], indent: childIndent, into: &out)
        if index < array.count - 1 {
            out.append(UInt8(ascii: ","))
        }
        out.append(UInt8(ascii: "\n"))
    }
    out.append(contentsOf: repeatElement(UInt8(ascii: " "), count: indent))
    out.append(UInt8(ascii: "]"))
}

/// Minimal JSON string escaper: quotes, backslashes, and C0 control
/// characters. Deliberately does NOT replicate Go's default HTML-safe
/// escaping of `<`, `>`, `&` — every string this codebase actually encodes
/// (hex digests, semver strings, filesystem paths, RFC 3339 timestamps,
/// device-type identifiers) is drawn from a character set that never
/// contains those bytes, so the two encoders agree on every value this
/// tool produces even though this escaper is not a general-purpose match
/// for `encoding/json`.
private func writeJSONString(_ string: String, into out: inout [UInt8]) {
    out.append(UInt8(ascii: "\""))
    for scalar in string.unicodeScalars {
        switch scalar {
        case "\"":
            out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
        case "\\":
            out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
        case "\n":
            out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
        case "\r":
            out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
        case "\t":
            out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
        case let scalar where scalar.value < 0x20:
            out.append(contentsOf: Array("\\u00".utf8))
            let byte = UInt8(scalar.value)
            out.append(hexDigit(byte >> 4))
            out.append(hexDigit(byte & 0x0F))
        default:
            out.append(contentsOf: Array(String(scalar).utf8))
        }
    }
    out.append(UInt8(ascii: "\""))
}

private func hexDigit(_ nibble: UInt8) -> UInt8 {
    nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "a") + (nibble - 10)
}
