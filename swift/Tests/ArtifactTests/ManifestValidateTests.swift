import Testing

import Artifact
import Model

/// A structurally valid v1 manifest, matching the shape `manifest.go`'s
/// `Validate()` accepts. Individual tests mutate one field at a time to
/// exercise the parity table below.
private func validManifest() -> Manifest {
    Manifest(
        formatVersion: 1,
        artifactName: "wendyos-image-jetson-agx-thor-devkit-nvme-wendyos-0.16.0",
        artifactVersion: "0.16.0",
        compatibleDevices: ["jetson-agx-thor"],
        payload: Payload(
            name: "wendyos-image.ext4.zst",
            size: 1024,
            sha256: String(repeating: "a", count: 64),
            compressedSHA256: String(repeating: "b", count: 64),
            compression: "zstd"
        ),
        bootloaderUpdate: false,
        minToolVersion: "0.1.0"
    )
}

// MARK: - Parity table (internal/artifact/manifest.go Validate())

@Test func validateAcceptsAWellFormedManifest() throws {
    try validManifest().validate()
}

@Test func validateRejectsUnsupportedFormatVersion() {
    var manifest = validManifest()
    manifest.formatVersion = 2

    #expect(throws: ArtifactError.invalidManifest("unsupported format_version 2 (tool supports 1)")) {
        try manifest.validate()
    }
}

@Test func validateRejectsEmptyArtifactName() {
    var manifest = validManifest()
    manifest.artifactName = ""

    #expect(throws: ArtifactError.invalidManifest("artifact_name and artifact_version are required")) {
        try manifest.validate()
    }
}

@Test func validateRejectsEmptyArtifactVersion() {
    var manifest = validManifest()
    manifest.artifactVersion = ""

    #expect(throws: ArtifactError.invalidManifest("artifact_name and artifact_version are required")) {
        try manifest.validate()
    }
}

@Test func validateRejectsEmptyCompatibleDevices() {
    var manifest = validManifest()
    manifest.compatibleDevices = []

    #expect(throws: ArtifactError.invalidManifest("compatible_devices must not be empty")) {
        try manifest.validate()
    }
}

@Test func validateRejectsEmptyPayloadName() {
    var manifest = validManifest()
    manifest.payload.name = ""

    #expect(throws: ArtifactError.invalidManifest("payload.name is required")) {
        try manifest.validate()
    }
}

@Test func validateRejectsShortSHA256() {
    var manifest = validManifest()
    manifest.payload.sha256 = "deadbeef"

    #expect(throws: ArtifactError.invalidManifest("payload.sha256 must be a hex sha256 digest")) {
        try manifest.validate()
    }
}

@Test func validateRejectsLongSHA256() {
    var manifest = validManifest()
    manifest.payload.sha256 = String(repeating: "a", count: 65)

    #expect(throws: ArtifactError.invalidManifest("payload.sha256 must be a hex sha256 digest")) {
        try manifest.validate()
    }
}

@Test func validateRejectsUnsupportedCompression() {
    var manifest = validManifest()
    manifest.payload.compression = "lz4"

    #expect(throws: ArtifactError.invalidManifest("unsupported payload.compression \"lz4\"")) {
        try manifest.validate()
    }
}

// MARK: - compatible(with:)

@Test func compatibleWithReturnsTrueForListedDeviceType() {
    let manifest = validManifest()

    #expect(manifest.compatible(with: "jetson-agx-thor"))
}

@Test func compatibleWithReturnsFalseForUnlistedDeviceType() {
    let manifest = validManifest()

    #expect(!manifest.compatible(with: "raspberry-pi-5"))
}

@Test func compatibleWithReturnsFalseWhenCompatibleDevicesIsEmpty() {
    var manifest = validManifest()
    manifest.compatibleDevices = []

    #expect(!manifest.compatible(with: "jetson-agx-thor"))
}
