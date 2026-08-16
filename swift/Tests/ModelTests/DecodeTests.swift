import Foundation
import Testing

import Model

/// Loads a fixture file under `Fixtures/` as raw bytes, the same shape
/// `JSONCodec`'s decode entry points consume (e.g. what a file read off
/// `/data/wendyos-update/state.json` would produce).
private func fixture(_ name: String) throws -> [UInt8] {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    guard let url else {
        throw TestFixtureError.missing(name)
    }
    return [UInt8](try Data(contentsOf: url))
}

private enum TestFixtureError: Error {
    case missing(String)
}

@Test func decodeManifestReadsEveryField() throws {
    let manifest = try JSONCodec.decodeManifest(try fixture("manifest.json"))

    #expect(manifest.formatVersion == 1)
    #expect(manifest.artifactName == "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0")
    #expect(manifest.artifactVersion == "0.16.0")
    #expect(manifest.compatibleDevices == ["jetson-agx-thor"])
    #expect(manifest.bootloaderUpdate == false)
    #expect(manifest.minToolVersion == "0.1.0")

    #expect(manifest.payload.name == "wendyos-image.ext4.zst")
    #expect(manifest.payload.size == 0)
    #expect(manifest.payload.sha256 == "<hex digest of the UNCOMPRESSED image>")
    #expect(manifest.payload.compressedSHA256 == "<hex digest of the tar member as stored>")
    #expect(manifest.payload.compression == "zstd")
}

@Test func decodeStateReadsPhaseSlotAndCreatedVerbatim() throws {
    let state = try JSONCodec.decodeState(try fixture("state.json"))

    #expect(state.schema == 1)
    #expect(state.phase == "swapped")
    #expect(state.targetSlot == 1)
    #expect(state.artifactName == "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0")
    #expect(state.artifactVersion == "0.16.0")
    #expect(state.payloadSHA256 == "<hex>")
    #expect(state.bootloaderUpdate == false)
    // `created` must round-trip exactly as written — it's a raw string,
    // never parsed/reformatted as a Date.
    #expect(state.created == "2026-06-07T12:00:00Z")
}

@Test func decodeInstalledReadsHistoryEntries() throws {
    let installed = try JSONCodec.decodeInstalled(try fixture("installed.json"))

    #expect(installed.history.count == 1)
    let entry = installed.history[0]
    #expect(entry.artifactName == "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.15.0")
    #expect(entry.artifactVersion == "0.15.0")
    #expect(entry.committed == "2026-06-01T09:30:00Z")
    #expect(entry.slot == 0)
}

@Test func decodeConfigReadsAllOptionalFields() throws {
    let config = try JSONCodec.decodeConfig(try fixture("config.json"))

    #expect(config.connector == "manual")
    #expect(config.deviceTypePath == "/etc/wendyos/device-type")
    #expect(config.stateDir == "/data/wendyos-update")
    #expect(config.hooksDir == "/etc/wendyos-update")
    #expect(config.healthDir == "/etc/wendyos-update/health.d")
}

@Test func decodeConfigDefaultsMissingFieldsToNil() throws {
    let config = try JSONCodec.decodeConfig(Array("{}".utf8))

    #expect(config.connector == nil)
    #expect(config.deviceTypePath == nil)
    #expect(config.stateDir == nil)
    #expect(config.hooksDir == nil)
    #expect(config.healthDir == nil)
}

@Test func decodeManifestThrowsOnMalformedJSON() throws {
    #expect(throws: JSONError.self) {
        _ = try JSONCodec.decodeManifest(Array("{ not json".utf8))
    }
}

@Test func decodeManifestThrowsOnMissingRequiredField() throws {
    // Valid JSON, but missing `payload` — every field is load-bearing for
    // downstream install logic, so a missing key must fail loudly rather
    // than silently defaulting.
    let bytes = Array(
        """
        {
          "format_version": 1,
          "artifact_name": "x",
          "artifact_version": "1.0.0",
          "compatible_devices": ["jetson-agx-thor"],
          "bootloader_update": false,
          "min_tool_version": "0.1.0"
        }
        """.utf8)

    #expect(throws: JSONError.self) {
        _ = try JSONCodec.decodeManifest(bytes)
    }
}
