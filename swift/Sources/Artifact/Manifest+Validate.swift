import Model

/// SHA-256 digest length in lowercase hex. Mirrors `sha256HexLen` in
/// `internal/artifact/manifest.go`.
private let sha256HexLen = 64

public extension Manifest {
    /// Checks structural validity of a parsed manifest (format v1). Device
    /// compatibility and tool-version gating are policy checks the engine
    /// performs separately — this only asks "is the manifest well-formed".
    ///
    /// Ports `(*artifact.Manifest).Validate()` in
    /// `internal/artifact/manifest.go`, including its error messages
    /// verbatim and the order in which checks run.
    func validate() throws {
        if formatVersion != 1 {
            throw ArtifactError.invalidManifest(
                "unsupported format_version \(formatVersion) (tool supports 1)"
            )
        }
        if artifactName.isEmpty || artifactVersion.isEmpty {
            throw ArtifactError.invalidManifest("artifact_name and artifact_version are required")
        }
        if compatibleDevices.isEmpty {
            throw ArtifactError.invalidManifest("compatible_devices must not be empty")
        }
        if payload.name.isEmpty {
            throw ArtifactError.invalidManifest("payload.name is required")
        }
        if payload.sha256.count != sha256HexLen {
            throw ArtifactError.invalidManifest("payload.sha256 must be a hex sha256 digest")
        }
        switch payload.compression {
        case "zstd", "gzip", "none":
            break
        default:
            throw ArtifactError.invalidManifest("unsupported payload.compression \"\(payload.compression)\"")
        }
    }

    /// Reports whether the artifact targets the given device type (from
    /// `/etc/wendyos/device-type`). Ports
    /// `(*artifact.Manifest).CompatibleWith()`.
    func compatible(with deviceType: String) -> Bool {
        compatibleDevices.contains(deviceType)
    }
}
