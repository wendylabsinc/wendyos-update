import Testing

import Engine
import Model
import PlatformIO
import PlatformIOTesting

@testable import WendyUpdate

// Ports the config-loading half of `cmd/wendyos-update/main.go`'s
// `loadConfig`/`newEngine`: an absent file is fine (all defaults), a
// malformed one is a warning (not a failure) that still yields defaults,
// and `ConnectorRegistry.select`'s nil-vs-explicit-empty-string
// distinction is bridged at the config boundary, not left to the caller.

private let path = "/etc/wendyos-update/config.json"

@Suite("Config")
struct ConfigTests {
    @Test func absentFileYieldsDefaults() {
        let fs = FakeFileStore()

        let cfg = loadConfig(path: path, fs: fs)

        #expect(cfg == Model.Config())
    }

    @Test func malformedJSONYieldsDefaultsWithoutThrowing() {
        let fs = FakeFileStore()
        try! fs.writeAtomic(path, Array("{not json".utf8), mode: 0o644)

        let cfg = loadConfig(path: path, fs: fs)

        #expect(cfg == Model.Config())
    }

    @Test func malformedBytesDecodeToDefaults() {
        // The pure decode step, exercised directly (no FileStore at all).
        let cfg = decodeConfigOrDefault(Array("not json at all".utf8))

        #expect(cfg == Model.Config())
    }

    @Test func validJSONDecodesEveryField() {
        let fs = FakeFileStore()
        let json = """
        {"connector":"tegrauefi","device_type_path":"/etc/x","state_dir":"/data/x",\
        "hooks_dir":"/etc/hooks","health_dir":"/etc/health"}
        """
        try! fs.writeAtomic(path, Array(json.utf8), mode: 0o644)

        let cfg = loadConfig(path: path, fs: fs)

        #expect(cfg.connector == "tegrauefi")
        #expect(cfg.deviceTypePath == "/etc/x")
        #expect(cfg.stateDir == "/data/x")
        #expect(cfg.hooksDir == "/etc/hooks")
        #expect(cfg.healthDir == "/etc/health")
    }

    @Test func unreadablePathYieldsDefaults() {
        // Exists (a directory, say) but `read` fails — must not throw out
        // of `loadConfig`.
        let fs = FakeFileStore()
        try! fs.mkdirp(path, mode: 0o755)

        let cfg = loadConfig(path: path, fs: fs)

        #expect(cfg == Model.Config())
    }
}

@Suite("normalizedConnector")
struct NormalizedConnectorTests {
    @Test func nilStaysNil() {
        #expect(normalizedConnector(nil) == nil)
    }

    @Test func emptyStringBecomesNil() {
        #expect(normalizedConnector("") == nil)
    }

    @Test func whitespaceOnlyBecomesNil() {
        #expect(normalizedConnector("   \t") == nil)
    }

    @Test func nonEmptyNameIsTrimmedAndKept() {
        #expect(normalizedConnector("tegrauefi") == "tegrauefi")
        #expect(normalizedConnector("  ubootenv  ") == "ubootenv")
    }
}

@Suite("effectiveStateDir")
struct EffectiveStateDirTests {
    @Test func nilFallsBackToDefault() {
        #expect(effectiveStateDir(nil) == StateDir)
    }

    @Test func emptyStringFallsBackToDefault() {
        #expect(effectiveStateDir("") == StateDir)
    }

    @Test func explicitValueWins() {
        #expect(effectiveStateDir("/data/custom") == "/data/custom")
    }
}
