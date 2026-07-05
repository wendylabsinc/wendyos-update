import CLIError
import Connector
import Logging
import PlatformIO

// Lifecycle hooks: product-defined executables run at fixed points in the
// update sequence (docs/cli-contract.md). Each phase P runs every regular,
// executable file in <HooksDir>/P.d in lexical order, with update context
// in the environment (WENDY_*). Gating phases (pre-install, post-install,
// health) abort the update on the first non-zero exit; advisory phases
// (post-commit, on-failure) only log. Ports internal/engine/hooks.go.

private let logger = Logger(label: "wendyos-update")

/// Hook phases. The directory for a phase is `<HooksDir>/<phase>.d`.
public let HookPreInstall = "pre-install" // before writing the slot; non-zero aborts install
public let HookPostInstall = "post-install" // after the swap, before reboot; non-zero aborts + unwinds
public let HookHealth = "health" // commit gate, after platform verify; non-zero -> exit 4 -> rollback
public let HookPostCommit = "post-commit" // after a successful commit; advisory (logged, never fatal)
public let HookOnFailure = "on-failure" // a deployment was marked failed; advisory

/// Reports a failing hook in a gating phase. `WendyUpdate`'s top-level
/// error handling maps it to a process exit code via `ExitCoded` (health ->
/// 4, other gating phases -> 1). Ports `engine.HookError`; `underlying` is
/// this error's `Error.Error()` string (Go's `*exec.ExitError` renders as
/// `"exit status N"`) rather than a wrapped `Error` value, since Swift's
/// `Equatable` conformance needs a comparable payload and callers only ever
/// display this, never unwrap it (mirrors `HookError.Unwrap` having no
/// dedicated Swift caller either).
public struct HookError: Error, Equatable, ExitCoded {
    public let phase: String
    public let hook: String
    public let underlying: String

    public init(phase: String, hook: String, underlying: String) {
        self.phase = phase
        self.hook = hook
        self.underlying = underlying
    }

    public var exitCode: Int32 { phase == HookHealth ? 4 : 1 }
}

extension Engine {
    /// Resolves a phase's hook directory. The health phase honors the
    /// legacy `healthDir` override; every phase otherwise lives under
    /// `effectiveHooksDir`. Ports `Engine.hookDir`.
    func hookDir(_ phase: String) -> String {
        if phase == HookHealth, !healthDir.isEmpty {
            return healthDir
        }
        return Self.join(effectiveHooksDir, "\(phase).d")
    }

    /// Executes the phase's regular, executable files in lexical order,
    /// exporting `WENDY_PHASE` plus `env` to each. The first non-zero exit
    /// throws a `HookError`. A missing or empty directory is a pass. Ports
    /// `Engine.runHooks`.
    public func runHooks(_ phase: String, _ env: [String: String]) async throws {
        let dir = hookDir(phase)
        let entries: [DirEntry]
        do {
            entries = try fs.listDir(dir)
        } catch {
            // Missing directory is a pass — mirrors Go's
            // `os.IsNotExist(err) -> return nil`.
            return
        }

        let names = entries
            .filter { !$0.isDir && $0.isExecutable }
            .map(\.name)
            .sorted()

        if names.isEmpty {
            logger.debug("no hooks", metadata: ["phase": "\(phase)", "dir": "\(dir)"])
            return
        }

        var hookEnvVars = env
        hookEnvVars["WENDY_PHASE"] = phase

        logger.debug(
            "hooks discovered",
            metadata: [
                "phase": "\(phase)", "dir": "\(dir)",
                "count": "\(names.count)", "hooks": "\(names.joined(separator: ","))",
            ]
        )
        logger.debug(
            "hook environment",
            metadata: [
                "phase": "\(phase)",
                "env": "\(hookEnvVars.keys.sorted().map { "\($0)=\(hookEnvVars[$0]!)" }.joined(separator: " "))",
            ]
        )

        for name in names {
            let path = Self.join(dir, name)
            logger.info("running hook", metadata: ["phase": "\(phase)", "hook": "\(name)"])
            let exitCode: Int32
            do {
                exitCode = try await runner.runStreaming([path], env: hookEnvVars) { line in
                    logger.info("hook[\(name)] \(line)")
                }
            } catch {
                logger.error(
                    "hook failed",
                    metadata: ["phase": "\(phase)", "hook": "\(name)", "err": "\(error)"]
                )
                throw HookError(phase: phase, hook: name, underlying: "\(error)")
            }
            if exitCode != 0 {
                logger.error(
                    "hook failed",
                    metadata: ["phase": "\(phase)", "hook": "\(name)", "exit_code": "\(exitCode)"]
                )
                throw HookError(phase: phase, hook: name, underlying: "exit status \(exitCode)")
            }
            logger.info("hook ok", metadata: ["phase": "\(phase)", "hook": "\(name)"])
        }
    }

    /// Runs a non-gating phase: a failure is logged, never thrown
    /// (post-commit, on-failure). Ports `Engine.runAdvisoryHooks`.
    public func runAdvisoryHooks(_ phase: String, _ env: [String: String]) async {
        do {
            try await runHooks(phase, env)
        } catch {
            logger.warning(
                "advisory hook phase reported an error (ignored)",
                metadata: ["phase": "\(phase)", "err": "\(error)"]
            )
        }
    }

    /// Builds the update-context environment exposed to every hook
    /// (`WENDY_PHASE` is added per-phase by `runHooks`). Ports
    /// `Engine.hookEnv`.
    public func hookEnv(name: String, version: String, target: Slot, cur: Slot, blUpdate: Bool) -> [String: String] {
        [
            "WENDY_ARTIFACT_NAME": name,
            "WENDY_ARTIFACT_VERSION": version,
            "WENDY_TARGET_SLOT": target.description,
            "WENDY_CURRENT_SLOT": cur.description,
            "WENDY_BOOTLOADER_UPDATE": blUpdate ? "true" : "false",
            "WENDY_STATE_DIR": stateDir,
        ]
    }

    private static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? "\(dir)\(name)" : "\(dir)/\(name)"
    }
}
