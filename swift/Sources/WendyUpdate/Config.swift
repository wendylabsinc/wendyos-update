import CLIError
import Connector
import Engine
import Logging
import Model
import PlatformIO
import TegraUEFI
import UBootEnv

// Config load + engine assembly. Ports `cmd/wendyos-update/main.go`'s
// `Config`/`loadConfig`/`newEngine`.

/// `/etc/wendyos-update/config.json` — everything optional. Ports main.go's
/// `configPath`.
let configPath = "/etc/wendyos-update/config.json"

/// Loads the config file: absent = defaults, malformed = warn + defaults
/// (never throws — a broken config file must not brick every verb). Ports
/// main.go's `loadConfig`.
func loadConfig(path: String = configPath, fs: any FileStore) -> Model.Config {
    guard fs.exists(path) else { return Model.Config() }
    guard let bytes = try? fs.read(path) else { return Model.Config() }
    return decodeConfigOrDefault(bytes, path: path)
}

/// The pure decode step behind `loadConfig`, split out so it's testable
/// without a `FileStore`: valid JSON decodes normally, anything else
/// (malformed JSON, or valid JSON that isn't an object) swallows the error
/// after logging a warning and falls back to defaults — ports main.go's
/// swallowed `json.Unmarshal` error in `loadConfig`.
func decodeConfigOrDefault(_ bytes: [UInt8], path: String = configPath) -> Model.Config {
    do {
        return try JSONCodec.decodeConfig(bytes)
    } catch {
        Logger(label: "wendyos-update").warning(
            "ignoring malformed config", metadata: ["path": "\(path)", "err": "\(error)"]
        )
        return Model.Config()
    }
}

/// `ConnectorRegistry.select(explicit:from:)` treats `nil` as "unset, auto-
/// detect" but a non-nil (even empty) string as an explicit — and missing —
/// name. Config JSON can produce either a missing `connector` key (`nil`)
/// or an explicit empty/whitespace-only string (`""`, `"  "`); both mean
/// "not configured" to a human editing the file, so both must normalize to
/// `nil` here before the value ever reaches `select`.
func normalizedConnector(_ raw: String?) -> String? {
    guard let raw else { return nil }
    var start = raw.startIndex
    var end = raw.endIndex
    while start < end, raw[start].isWhitespace { start = raw.index(after: start) }
    while end > start, raw[raw.index(before: end)].isWhitespace { end = raw.index(before: end) }
    let trimmed = String(raw[start..<end])
    return trimmed.isEmpty ? nil : trimmed
}

/// `Engine.stateDir` has no built-in "unset" sentinel (unlike
/// `deviceTypePath`/`hooksDir`/`healthDir`, which treat `""` as "use the
/// default" internally) — the caller must resolve it. Ports main.go's
/// `if stateDir == "" { stateDir = engine.StateDir }`.
func effectiveStateDir(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return StateDir }
    return raw
}

/// Assembles the `Engine` a verb runs against: selects the connector (an
/// explicit `cfg.connector`, or auto-detect across the built-in factory
/// list), resolves the state directory, and wires the engine to the real
/// platform (`RealFileStore`/`RealCommandRunner`/`RealClock`/
/// `RealEnvReader`). Ports main.go's `newEngine`.
func newEngine(
    cfg: Model.Config,
    progress: (@Sendable (_ phase: String, _ percent: Int) -> Void)? = nil
) throws -> Engine {
    let conn = try ConnectorRegistry.select(
        explicit: normalizedConnector(cfg.connector),
        from: [TegraUEFI.factory, UBootEnv.factory]
    )
    return Engine(
        conn: conn,
        stateDir: effectiveStateDir(cfg.stateDir),
        deviceTypePath: cfg.deviceTypePath ?? "",
        hooksDir: cfg.hooksDir ?? "",
        healthDir: cfg.healthDir ?? "",
        toolVersion: WendyUpdate.version,
        fs: RealFileStore(),
        runner: RealCommandRunner(),
        clock: RealClock(),
        env: RealEnvReader(),
        progress: progress
    )
}

/// The one-liner every verb calls: load the real on-disk config, then
/// assemble the engine from it. Split from `newEngine(cfg:progress:)` only
/// so the config-driven assembly logic stays testable without touching the
/// real filesystem.
func makeEngine(progress: (@Sendable (_ phase: String, _ percent: Int) -> Void)? = nil) throws -> Engine {
    try newEngine(cfg: loadConfig(fs: RealFileStore()), progress: progress)
}
