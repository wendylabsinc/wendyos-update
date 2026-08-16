import CLIError

/// Everything that can go wrong while validating or reading a `.wendy`
/// artifact. Every case maps to the same process exit code (3) — the Go
/// CLI (`cmd/wendyos-update/main.go`) treats "the artifact is bad" as a
/// single reject outcome regardless of which specific check tripped.
///
/// Only `.invalidManifest` is produced by this task (manifest structural
/// validation, `Manifest+Validate.swift`). The remaining cases exist now
/// because a later task (3.2, the artifact reader) needs the type to
/// already be shaped for tar/payload verification — declaring them here
/// keeps `ArtifactError` a single, ports-`internal/artifact` type instead
/// of splitting artifact errors across two enums as the reader lands.
public enum ArtifactError: Error, Equatable, ExitCoded {
    /// The parsed manifest failed a structural check. The associated
    /// string matches Go's `Validate()` error message verbatim (see
    /// `internal/artifact/manifest.go`).
    case invalidManifest(String)
    /// The artifact file is not a valid tar stream.
    case notTar(String)
    /// The tar stream ended without producing the payload member named in
    /// the manifest.
    case payloadNotFound(String)
    /// The payload tar member was already consumed (single-pass stream
    /// invariant violated).
    case payloadAlreadyTaken
    /// The payload's actual size didn't match `Payload.size` from the
    /// manifest.
    case sizeMismatch(got: Int64, want: Int64)
    /// The payload's actual SHA-256 didn't match the manifest's digest.
    case sha256Mismatch(String)

    /// All artifact problems are a reject: exit 3.
    public var exitCode: Int32 { 3 }
}
