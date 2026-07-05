import Testing

import Model

private let sampleManifest = Manifest(
    formatVersion: 1,
    artifactName: "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0",
    artifactVersion: "0.16.0",
    compatibleDevices: ["jetson-agx-thor"],
    payload: Payload(
        name: "wendyos-image.ext4.zst",
        size: 12345,
        sha256: "abc123",
        compressedSHA256: "def456",
        compression: "zstd"
    ),
    bootloaderUpdate: false,
    minToolVersion: "0.1.0"
)

/// Hand-written expected output: no Swift code produced this, it's what
/// `encoding/json` on the Go side would write for the same values, key for
/// key, in Go struct field order. If `JSONCodec.encodeCompact`/`encodePretty`
/// ever stop matching this exactly, something changed the emitted key
/// order or formatting — both are cross-implementation contracts, not
/// internal details.
private let expectedCompactManifest = """
    {"format_version":1,"artifact_name":"wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0","artifact_version":"0.16.0","compatible_devices":["jetson-agx-thor"],"payload":{"name":"wendyos-image.ext4.zst","size":12345,"sha256":"abc123","compressed_sha256":"def456","compression":"zstd"},"bootloader_update":false,"min_tool_version":"0.1.0"}
    """

private let expectedPrettyManifest = """
    {
      "format_version": 1,
      "artifact_name": "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0",
      "artifact_version": "0.16.0",
      "compatible_devices": [
        "jetson-agx-thor"
      ],
      "payload": {
        "name": "wendyos-image.ext4.zst",
        "size": 12345,
        "sha256": "abc123",
        "compressed_sha256": "def456",
        "compression": "zstd"
      },
      "bootloader_update": false,
      "min_tool_version": "0.1.0"
    }

    """

@Test func encodeCompactMatchesGoFieldOrderExactly() {
    let bytes = JSONCodec.encodeCompact(sampleManifest.makeJSONObject())
    #expect(String(decoding: bytes, as: UTF8.self) == expectedCompactManifest)
}

@Test func encodePrettyMatchesGoMarshalIndentFormatExactly() {
    let bytes = JSONCodec.encodePretty(sampleManifest.makeJSONObject())
    #expect(String(decoding: bytes, as: UTF8.self) == expectedPrettyManifest)
}

@Test func encodePrettyEndsWithExactlyOneTrailingNewline() {
    let bytes = JSONCodec.encodePretty(sampleManifest.makeJSONObject())
    #expect(bytes.last == UInt8(ascii: "\n"))
    #expect(bytes.dropLast().last != UInt8(ascii: "\n"))
}

@Test func encodeCompactRoundTripsThroughDecode() throws {
    let bytes = JSONCodec.encodeCompact(sampleManifest.makeJSONObject())
    let decoded = try JSONCodec.decodeManifest(bytes)
    #expect(decoded == sampleManifest)
}

@Test func encodePrettyRoundTripsThroughDecode() throws {
    let bytes = JSONCodec.encodePretty(sampleManifest.makeJSONObject())
    let decoded = try JSONCodec.decodeManifest(bytes)
    #expect(decoded == sampleManifest)
}

@Test func encodeStateKeyOrderMatchesGoStructOrder() {
    let state = State(
        schema: 1,
        phase: "swapped",
        targetSlot: 1,
        artifactName: "artifact",
        artifactVersion: "0.16.0",
        payloadSHA256: "sha",
        bootloaderUpdate: true,
        created: "2026-06-07T12:00:00Z"
    )
    let expected = """
        {"schema":1,"phase":"swapped","target_slot":1,"artifact_name":"artifact","artifact_version":"0.16.0","payload_sha256":"sha","bootloader_update":true,"created":"2026-06-07T12:00:00Z"}
        """
    let bytes = JSONCodec.encodeCompact(state.makeJSONObject())
    #expect(String(decoding: bytes, as: UTF8.self) == expected)
}

@Test func encodeInstalledHistoryPreservesEntryOrderAndFieldOrder() {
    let history = InstalledHistory(history: [
        InstalledEntry(artifactName: "a", artifactVersion: "1.0.0", committed: "t1", slot: 0),
        InstalledEntry(artifactName: "b", artifactVersion: "2.0.0", committed: "t2", slot: 1),
    ])
    let expected = """
        {"history":[{"artifact_name":"a","artifact_version":"1.0.0","committed":"t1","slot":0},{"artifact_name":"b","artifact_version":"2.0.0","committed":"t2","slot":1}]}
        """
    let bytes = JSONCodec.encodeCompact(history.makeJSONObject())
    #expect(String(decoding: bytes, as: UTF8.self) == expected)
}

/// Pretty-printing an array-of-objects (`array → object → scalar`) is the
/// deepest nesting `encodePretty`'s re-parse-before-walk workaround has to
/// survive — and the exact shape upcoming status/state encoding
/// (`slots[]`, `system[]`) will use. `InstalledHistory.history` is that
/// shape, so drive it through `encodePretty` (not just `encodeCompact`)
/// with two entries and check the full layout against a hand-typed
/// expected string (2-space indent, Go field order, trailing newline —
/// what `json.MarshalIndent(_, "", "  ")` + a written `\n` produces).
@Test func encodePrettyHandlesArrayOfObjects() {
    let history = InstalledHistory(history: [
        InstalledEntry(artifactName: "a", artifactVersion: "1.0.0", committed: "t1", slot: 0),
        InstalledEntry(artifactName: "b", artifactVersion: "2.0.0", committed: "t2", slot: 1),
    ])
    let expected = """
        {
          "history": [
            {
              "artifact_name": "a",
              "artifact_version": "1.0.0",
              "committed": "t1",
              "slot": 0
            },
            {
              "artifact_name": "b",
              "artifact_version": "2.0.0",
              "committed": "t2",
              "slot": 1
            }
          ]
        }

        """
    let bytes = JSONCodec.encodePretty(history.makeJSONObject())
    #expect(String(decoding: bytes, as: UTF8.self) == expected)
}

@Test func encodeConfigOmitsAbsentFields() {
    let config = Config(connector: "manual", stateDir: "/data/wendyos-update")
    let expected = """
        {"connector":"manual","state_dir":"/data/wendyos-update"}
        """
    let bytes = JSONCodec.encodeCompact(config.makeJSONObject())
    #expect(String(decoding: bytes, as: UTF8.self) == expected)
}
