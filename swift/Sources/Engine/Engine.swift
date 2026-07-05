import Connector
import PlatformIO

/// The persistent state location (on the 'data' partition). Mirrors
/// `engine.StateDir` in internal/engine/state.go.
public let StateDir = "/data/wendyos-update"

/// Where WendyOS records the board identity (wendyos-identity recipe;
/// key=value lines, the `BOARD` key). Mirrors `engine.DefaultDeviceTypePath`
/// in internal/engine/engine.go.
public let DefaultDeviceTypePath = "/etc/wendyos/device-type"

/// The root holding the per-phase hook directories. Mirrors
/// `engine.DefaultHooksDir` in internal/engine/hooks.go. Hook execution
/// itself is a later task (6.x); this constant is defined here alongside
/// the other path defaults because `Engine.hooksDir`'s "" sentinel
/// resolves to it.
public let DefaultHooksDir = "/etc/wendyos-update"

/// Sequences updates over a connector. All paths and platform side effects
/// are fields so tests can fake the platform completely. Ports `engine.Engine`
/// in internal/engine/engine.go.
///
/// A handful of fields use an empty string as a "use the built-in default"
/// sentinel, resolved lazily at the point of use — mirroring how the Go
/// struct's zero-valued fields are resolved inside each method rather than
/// by a constructor (Go has none): `deviceTypePath` -> `DefaultDeviceTypePath`,
/// `hooksDir` -> `DefaultHooksDir`. `stateDir` has no such sentinel; its
/// default is applied directly by `init`, matching how every call site in
/// this codebase constructs an `Engine` with a concrete state directory.
public struct Engine: Sendable {
    public var conn: any Connector
    public var stateDir: String
    /// "" -> `DefaultDeviceTypePath`.
    public var deviceTypePath: String
    /// "" -> `DefaultHooksDir`; root for the per-phase hook dirs.
    public var hooksDir: String
    /// Legacy override for the health phase only (config `health_dir`).
    public var healthDir: String
    public var toolVersion: String
    public var fs: any FileStore
    public var runner: any CommandRunner
    public var clock: any Clock
    public var env: any EnvReader
    /// Reads a slot's distro/kernel version for the `status` verb (live for
    /// the booted slot, a best-effort mount for the inactive one). Defaults
    /// to `RealVersionProbe()` — a self-contained, dependency-free
    /// implementation — so every existing `Engine(...)` call site (fixed
    /// before this field existed) keeps compiling unchanged.
    public var versionProbe: any VersionProbe
    /// Receives coarse install progress for the CLI's JSON lines. `percent`
    /// is -1 when the total size is unknown. May be nil.
    public var progress: (@Sendable (_ phase: String, _ percent: Int) -> Void)?

    public init(
        conn: any Connector,
        stateDir: String = StateDir,
        deviceTypePath: String = "",
        hooksDir: String = "",
        healthDir: String = "",
        toolVersion: String = "",
        fs: any FileStore,
        runner: any CommandRunner,
        clock: any Clock,
        env: any EnvReader,
        versionProbe: any VersionProbe = RealVersionProbe(),
        progress: (@Sendable (_ phase: String, _ percent: Int) -> Void)? = nil
    ) {
        self.conn = conn
        self.stateDir = stateDir
        self.deviceTypePath = deviceTypePath
        self.hooksDir = hooksDir
        self.healthDir = healthDir
        self.toolVersion = toolVersion
        self.fs = fs
        self.runner = runner
        self.clock = clock
        self.env = env
        self.versionProbe = versionProbe
        self.progress = progress
    }

    /// Invokes `progress` if one is set; a no-op otherwise. Ports
    /// `engine.Engine.progress` (the lower-case helper wrapping the
    /// exported `Progress` field).
    func reportProgress(_ phase: String, _ percent: Int) {
        progress?(phase, percent)
    }

    var effectiveDeviceTypePath: String {
        deviceTypePath.isEmpty ? DefaultDeviceTypePath : deviceTypePath
    }

    var effectiveHooksDir: String {
        hooksDir.isEmpty ? DefaultHooksDir : hooksDir
    }
}
