import LinuxSys
import Subprocess

#if canImport(System)
import System
#else
import SystemPackage
#endif

/// `CommandRunner` over `swift-subprocess`. Ports the `exec.Command` usage
/// in `engine/hooks.go`: `run` collects stdout/stderr for scripted/
/// one-shot callers, `runStreaming` line-buffers stdout for hooks whose
/// output is logged live as it arrives.
public struct RealCommandRunner: CommandRunner {
    /// Caps captured stdout/stderr at 16 MiB. `swift-subprocess`'s
    /// `.bytes(limit:)` requires an explicit bound (unlike Go's unbounded
    /// `bytes.Buffer`); no wendyos-update caller (hooks, `nvbootctrl`,
    /// `fw_printenv`, ...) produces output anywhere near this size.
    private static let outputLimit = 16 * 1024 * 1024

    public init() {}

    public func run(_ argv: [String], env: [String: String]?, stdin: [UInt8]?) async throws -> CommandResult {
        guard let head = argv.first else { throw CommandRunnerError.emptyArgv }
        let result = try await Subprocess.run(
            Self.executable(for: head),
            arguments: Arguments(Array(argv.dropFirst())),
            environment: Self.environment(for: env),
            input: .array(stdin ?? []),
            output: .bytes(limit: Self.outputLimit),
            error: .bytes(limit: Self.outputLimit)
        )
        return CommandResult(
            exitCode: Self.exitCode(from: result.terminationStatus),
            stdout: result.standardOutput,
            stderr: result.standardError
        )
    }

    public func runStreaming(
        _ argv: [String],
        env: [String: String],
        onLine: @Sendable (String) -> Void
    ) async throws -> Int32 {
        guard let head = argv.first else { throw CommandRunnerError.emptyArgv }
        let result = try await Subprocess.run(
            Self.executable(for: head),
            arguments: Arguments(Array(argv.dropFirst())),
            environment: Self.environment(for: env),
            input: .none,
            output: .sequence,
            error: .discarded
        ) { execution in
            for try await line in execution.standardOutput.strings() {
                onLine(line)
            }
        }
        return Self.exitCode(from: result.terminationStatus)
    }

    /// A `/`-containing command names an explicit path and is used
    /// directly, with no `PATH` search (matches `os/exec`'s handling of a
    /// name containing a path separator, and how `hooks.go` always passes
    /// a joined `<dir>/<name>` path). A bare name is resolved against
    /// `PATH` (matches bare `exec.Command("lsblk", ...)`/`"nvbootctrl"`
    /// calls elsewhere in the Go connectors, which rely on `LookPath`).
    private static func executable(for command: String) -> Executable {
        command.contains("/") ? .path(FilePath(command)) : .name(command)
    }

    /// `nil` inherits the parent process's environment unmodified;
    /// non-nil overlays `env` on top of it (matching `append(os.Environ(),
    /// hookEnv...)` in `hooks.go`, where later entries win on conflict).
    private static func environment(for env: [String: String]?) -> Environment {
        guard let env else { return .inherit }
        let overrides = Dictionary(
            uniqueKeysWithValues: env.map { (Environment.Key(rawValue: $0.key)!, Optional($0.value)) }
        )
        return Environment.inherit.updating(overrides)
    }

    private static func exitCode(from status: TerminationStatus) -> Int32 {
        switch status {
        case .exited(let code):
            return code
        default:
            // Signal-terminated: there is no exit code to report. Matches
            // Go's `os.ProcessState.ExitCode()`, which also returns -1
            // here (see `exitCodeOf` in hooks.go).
            return -1
        }
    }
}

/// Thrown when `argv` is empty — there is no executable to resolve.
public enum CommandRunnerError: Error, Equatable {
    case emptyArgv
}
