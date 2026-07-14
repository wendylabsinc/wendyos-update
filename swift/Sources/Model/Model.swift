// Model types for the on-disk/on-wire JSON documents `wendyos-update` reads
// and writes: the `.wendy` artifact manifest (docs/manifest-schema.md), the
// on-device update state and installed history (docs/state-schema.md), and
// the optional config file (cmd/wendyos-update/main.go's `Config`).
//
// These structs port the Go structs field-for-field, including JSON key
// names (see the `json:"..."` tags in internal/artifact/manifest.go,
// internal/engine/state.go, and cmd/wendyos-update/main.go) — anything that
// reads/writes these files across the Go and Swift implementations (or
// across a version upgrade) must agree byte-for-byte on shape and key
// order, so field order here mirrors Go struct declaration order and MUST
// NOT be reordered casually.
//
// JSON path: decode AND encode go through IkigaJSON's `JSONObject`
// (swift/Sources/Model/Decode.swift, swift/Sources/Model/Encode.swift) —
// never Foundation's Codable/JSONDecoder/JSONEncoder. See the task-2.1
// report for why (Int64 payload sizes and Sendable conformance aren't
// expressible through the wendylabsinc/swift-json-schema generator, which
// is Codable-shaped and Int-only).

/// The parsed `manifest.json` (format v1) — first member of a `.wendy`
/// artifact tar. Mirrors `artifact.Manifest` in internal/artifact/manifest.go.
public struct Manifest: Sendable, Equatable {
    public var formatVersion: Int
    public var artifactName: String
    public var artifactVersion: String
    public var compatibleDevices: [String]
    public var payload: Payload
    public var bootloaderUpdate: Bool
    public var minToolVersion: String

    public init(
        formatVersion: Int,
        artifactName: String,
        artifactVersion: String,
        compatibleDevices: [String],
        payload: Payload,
        bootloaderUpdate: Bool,
        minToolVersion: String
    ) {
        self.formatVersion = formatVersion
        self.artifactName = artifactName
        self.artifactVersion = artifactVersion
        self.compatibleDevices = compatibleDevices
        self.payload = payload
        self.bootloaderUpdate = bootloaderUpdate
        self.minToolVersion = minToolVersion
    }
}

/// Describes the rootfs image member of a `.wendy` artifact. Mirrors
/// `artifact.Payload` in internal/artifact/manifest.go.
public struct Payload: Sendable, Equatable {
    public var name: String
    /// Size in bytes. `Int64` (not `Int`) to match Go's `int64` exactly —
    /// this is compared against on-device block sizes that can legitimately
    /// exceed 32-bit range on 32-bit-`Int` platforms.
    public var size: Int64
    /// SHA-256 of the uncompressed image.
    public var sha256: String
    /// SHA-256 of the tar member as stored (i.e. of the compressed bytes).
    public var compressedSHA256: String
    /// "zstd" | "gzip" | "none".
    public var compression: String

    public init(
        name: String,
        size: Int64,
        sha256: String,
        compressedSHA256: String,
        compression: String
    ) {
        self.name = name
        self.size = size
        self.sha256 = sha256
        self.compressedSHA256 = compressedSHA256
        self.compression = compression
    }
}

/// `state.json` — present only while an update is in flight. Mirrors
/// `engine.State` in internal/engine/state.go.
///
/// `created` is carried as a raw `String`, never parsed into a `Date`: the
/// Go side treats it as an opaque RFC 3339 timestamp it only ever
/// round-trips, and re-parsing + re-formatting it here would risk losing
/// precision or a trailing-zero difference that isn't ours to normalize.
public struct State: Sendable, Equatable {
    public var schema: Int
    public var phase: String
    public var targetSlot: Int
    public var artifactName: String
    public var artifactVersion: String
    public var payloadSHA256: String
    public var bootloaderUpdate: Bool
    public var created: String

    public init(
        schema: Int,
        phase: String,
        targetSlot: Int,
        artifactName: String,
        artifactVersion: String,
        payloadSHA256: String,
        bootloaderUpdate: Bool,
        created: String
    ) {
        self.schema = schema
        self.phase = phase
        self.targetSlot = targetSlot
        self.artifactName = artifactName
        self.artifactVersion = artifactVersion
        self.payloadSHA256 = payloadSHA256
        self.bootloaderUpdate = bootloaderUpdate
        self.created = created
    }
}

/// One committed entry in `installed.json`. Mirrors `engine.InstalledEntry`
/// in internal/engine/state.go. `committed` is a raw string for the same
/// reason `State.created` is — see its doc comment.
public struct InstalledEntry: Sendable, Equatable {
    public var artifactName: String
    public var artifactVersion: String
    public var committed: String
    public var slot: Int

    public init(
        artifactName: String,
        artifactVersion: String,
        committed: String,
        slot: Int
    ) {
        self.artifactName = artifactName
        self.artifactVersion = artifactVersion
        self.committed = committed
        self.slot = slot
    }
}

/// `installed.json` — committed artifact history, capped at 10 entries by
/// the engine. Mirrors `engine.InstalledHistory` in internal/engine/state.go.
public struct InstalledHistory: Sendable, Equatable {
    public var history: [InstalledEntry]

    public init(history: [InstalledEntry]) {
        self.history = history
    }
}

/// `/etc/wendyos-update/config.json` — everything optional (a missing file,
/// or missing keys, mean "use the built-in default" at every call site).
/// Mirrors `main.Config` in cmd/wendyos-update/main.go.
public struct Config: Sendable, Equatable {
    /// Override auto-detect.
    public var connector: String?
    /// Override /etc/wendyos/device-type.
    public var deviceTypePath: String?
    /// Override /data/wendyos-update.
    public var stateDir: String?
    /// Override /etc/wendyos-update (root of <phase>.d dirs).
    public var hooksDir: String?
    /// Legacy: override the health phase dir only.
    public var healthDir: String?

    public init(
        connector: String? = nil,
        deviceTypePath: String? = nil,
        stateDir: String? = nil,
        hooksDir: String? = nil,
        healthDir: String? = nil
    ) {
        self.connector = connector
        self.deviceTypePath = deviceTypePath
        self.stateDir = stateDir
        self.hooksDir = hooksDir
        self.healthDir = healthDir
    }
}

/// Errors surfaced by `JSONCodec` decode entry points. Wraps both outright
/// parse failures (not valid JSON, or not a JSON object at the top level)
/// and shape failures (valid JSON, but missing/mistyped a field this tool
/// treats as load-bearing).
public enum JSONError: Error, Equatable {
    case malformed(String)
}
