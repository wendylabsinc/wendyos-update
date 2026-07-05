import Foundation
import IkigaJSON

/// Decodes the on-disk JSON documents `wendyos-update` reads
/// (`manifest.json`, `state.json`, `installed.json`,
/// `/etc/wendyos-update/config.json`) into the `Model` structs, and encodes
/// them back (see Encode.swift). Every entry point runs on `[UInt8]` — the
/// shape a file read (or an HTTP body) naturally produces — and every
/// decode goes through IkigaJSON's `JSONObject`, never Foundation's
/// `JSONDecoder`.
public enum JSONCodec {
    public static func decodeManifest(_ bytes: [UInt8]) throws -> Manifest {
        try Manifest.decode(try parseObject(bytes))
    }

    public static func decodeState(_ bytes: [UInt8]) throws -> State {
        try State.decode(try parseObject(bytes))
    }

    public static func decodeInstalled(_ bytes: [UInt8]) throws -> InstalledHistory {
        try InstalledHistory.decode(try parseObject(bytes))
    }

    public static func decodeConfig(_ bytes: [UInt8]) throws -> Config {
        Config.decode(try parseObject(bytes))
    }
}

/// Parses `bytes` as a top-level JSON object, collapsing IkigaJSON's own
/// `JSONObjectError` into `JSONError` so every decode entry point above
/// throws exactly one error type.
private func parseObject(_ bytes: [UInt8]) throws -> JSONObject {
    do {
        return try JSONObject(data: Data(bytes))
    } catch {
        throw JSONError.malformed("\(error)")
    }
}

extension Payload {
    static func decode(_ object: JSONObject) throws -> Payload {
        guard let name = object["name"].string else {
            throw JSONError.malformed("payload.name missing or not a string")
        }
        guard let size = object["size"].int else {
            throw JSONError.malformed("payload.size missing or not an integer")
        }
        guard let sha256 = object["sha256"].string else {
            throw JSONError.malformed("payload.sha256 missing or not a string")
        }
        guard let compressedSHA256 = object["compressed_sha256"].string else {
            throw JSONError.malformed("payload.compressed_sha256 missing or not a string")
        }
        guard let compression = object["compression"].string else {
            throw JSONError.malformed("payload.compression missing or not a string")
        }
        return Payload(
            name: name,
            size: Int64(size),
            sha256: sha256,
            compressedSHA256: compressedSHA256,
            compression: compression
        )
    }
}

extension Manifest {
    static func decode(_ object: JSONObject) throws -> Manifest {
        guard let formatVersion = object["format_version"].int else {
            throw JSONError.malformed("format_version missing or not an integer")
        }
        guard let artifactName = object["artifact_name"].string else {
            throw JSONError.malformed("artifact_name missing or not a string")
        }
        guard let artifactVersion = object["artifact_version"].string else {
            throw JSONError.malformed("artifact_version missing or not a string")
        }
        guard let devices = object["compatible_devices"].array else {
            throw JSONError.malformed("compatible_devices missing or not an array")
        }
        var compatibleDevices: [String] = []
        compatibleDevices.reserveCapacity(devices.count)
        for element in devices {
            guard let device = element.string else {
                throw JSONError.malformed("compatible_devices contains a non-string element")
            }
            compatibleDevices.append(device)
        }
        guard let payloadObject = object["payload"].object else {
            throw JSONError.malformed("payload missing or not an object")
        }
        let payload = try Payload.decode(payloadObject)
        guard let bootloaderUpdate = object["bootloader_update"].bool else {
            throw JSONError.malformed("bootloader_update missing or not a boolean")
        }
        guard let minToolVersion = object["min_tool_version"].string else {
            throw JSONError.malformed("min_tool_version missing or not a string")
        }
        return Manifest(
            formatVersion: formatVersion,
            artifactName: artifactName,
            artifactVersion: artifactVersion,
            compatibleDevices: compatibleDevices,
            payload: payload,
            bootloaderUpdate: bootloaderUpdate,
            minToolVersion: minToolVersion
        )
    }
}

extension State {
    static func decode(_ object: JSONObject) throws -> State {
        guard let schema = object["schema"].int else {
            throw JSONError.malformed("schema missing or not an integer")
        }
        guard let phase = object["phase"].string else {
            throw JSONError.malformed("phase missing or not a string")
        }
        guard let targetSlot = object["target_slot"].int else {
            throw JSONError.malformed("target_slot missing or not an integer")
        }
        guard let artifactName = object["artifact_name"].string else {
            throw JSONError.malformed("artifact_name missing or not a string")
        }
        guard let artifactVersion = object["artifact_version"].string else {
            throw JSONError.malformed("artifact_version missing or not a string")
        }
        guard let payloadSHA256 = object["payload_sha256"].string else {
            throw JSONError.malformed("payload_sha256 missing or not a string")
        }
        guard let bootloaderUpdate = object["bootloader_update"].bool else {
            throw JSONError.malformed("bootloader_update missing or not a boolean")
        }
        guard let created = object["created"].string else {
            throw JSONError.malformed("created missing or not a string")
        }
        return State(
            schema: schema,
            phase: phase,
            targetSlot: targetSlot,
            artifactName: artifactName,
            artifactVersion: artifactVersion,
            payloadSHA256: payloadSHA256,
            bootloaderUpdate: bootloaderUpdate,
            created: created
        )
    }
}

extension InstalledEntry {
    static func decode(_ object: JSONObject) throws -> InstalledEntry {
        guard let artifactName = object["artifact_name"].string else {
            throw JSONError.malformed("artifact_name missing or not a string")
        }
        guard let artifactVersion = object["artifact_version"].string else {
            throw JSONError.malformed("artifact_version missing or not a string")
        }
        guard let committed = object["committed"].string else {
            throw JSONError.malformed("committed missing or not a string")
        }
        guard let slot = object["slot"].int else {
            throw JSONError.malformed("slot missing or not an integer")
        }
        return InstalledEntry(
            artifactName: artifactName,
            artifactVersion: artifactVersion,
            committed: committed,
            slot: slot
        )
    }
}

extension InstalledHistory {
    static func decode(_ object: JSONObject) throws -> InstalledHistory {
        guard let entries = object["history"].array else {
            throw JSONError.malformed("history missing or not an array")
        }
        var history: [InstalledEntry] = []
        history.reserveCapacity(entries.count)
        for element in entries {
            guard let entryObject = element.object else {
                throw JSONError.malformed("history contains a non-object element")
            }
            history.append(try InstalledEntry.decode(entryObject))
        }
        return InstalledHistory(history: history)
    }
}

extension Config {
    /// Every field is optional, so — unlike the other decoders — a missing
    /// key is not an error; it just means "use the built-in default",
    /// matching Go's zero-value-on-missing-field `encoding/json` behavior.
    static func decode(_ object: JSONObject) -> Config {
        Config(
            connector: object["connector"].string,
            deviceTypePath: object["device_type_path"].string,
            stateDir: object["state_dir"].string,
            hooksDir: object["hooks_dir"].string,
            healthDir: object["health_dir"].string
        )
    }
}
