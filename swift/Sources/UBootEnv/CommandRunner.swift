#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
// The static-musl cross-compilation SDK exposes libc under the
// `Musl` overlay module instead of `Glibc` (see LinuxSys.swift for
// the fuller explanation); every symbol this file uses exists
// identically in both.
import Musl
#endif
import PlatformIO

// A synchronous command-execution seam for `fw_printenv`/`fw_setenv`/
// `findmnt`/`lsblk`.
//
// `Connector` protocol methods (`currentSlot`, `partition(for:)`,
// `swapSlot`, ...) are plain `throws`, not `async throws` — the Engine
// calls them without `await` even from `async throws` functions, matching
// how Go's `Controller` methods block the calling goroutine on
// `exec.Command(...)`. `PlatformIO.CommandRunner` cannot serve this seam:
// its `run`/`runStreaming` are `async` over `swift-subprocess`, and a sync
// protocol requirement cannot be satisfied by an async implementation.
//
// This is the same seam TegraUEFI defines as `TegraCommandRunner`. It is
// intentionally duplicated here rather than shared: `UBootEnv`'s declared
// dependencies (root `Package.swift`) are `Connector`, `PlatformIO`,
// `CLIError` — adding a dependency on the `TegraUEFI` target just to reuse
// a ~30-line protocol + `popen` shim would couple two otherwise-unrelated
// board connectors for no real benefit (over-engineering for a seam this
// small). If a third connector needs the same seam, promoting it to a
// shared target (e.g. under `PlatformIO`) becomes worth it; until then,
// duplication is the simpler choice.
public protocol UBootCommandRunner: Sendable {
    /// Runs `argv` to completion, returning its exit code and captured
    /// output. Never throws: a failure to even start the process (e.g.
    /// `argv[0]` not found) is reported as a non-zero `exitCode`, exactly
    /// as callers already have to check the Go call sites' `err` /
    /// exit-status — there is no separate "couldn't launch" case to
    /// model.
    func run(_ argv: [String]) -> CommandResult
}

/// `UBootCommandRunner` over `popen(3)`. Every element of `argv` is
/// single-quote shell-escaped before being joined into the command line
/// `popen` executes via `/bin/sh -c`; every caller in this module passes
/// argv built entirely from internal constants (subcommand keywords) and
/// values already validated as slot ordinals (`0`/`1`), file paths
/// resolved by this connector, or well-known env-var names — never raw
/// external/user input — so shell-escaping (rather than a full
/// `posix_spawn` argv-array exec) is a deliberately simple, adequately
/// safe choice here. Standard error is merged into standard output
/// (`2>&1`), matching Go's `CombinedOutput()` used by the real call
/// sites this connector ports.
public struct RealUBootCommandRunner: UBootCommandRunner {
    public init() {}

    public func run(_ argv: [String]) -> CommandResult {
        guard !argv.isEmpty else {
            return CommandResult(exitCode: 127, stdout: [], stderr: Array("empty argv".utf8))
        }
        let shellCommand = argv.map(Self.shellQuote).joined(separator: " ") + " 2>&1"

        guard let pipe = popen(shellCommand, "r") else {
            return CommandResult(exitCode: 127, stdout: [], stderr: Array("popen failed: errno \(errno)".utf8))
        }

        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return fread(base, 1, buf.count, pipe)
            }
            if n <= 0 { break }
            output.append(contentsOf: chunk[0..<n])
        }

        let status = pclose(pipe)
        let exitCode = Self.exitCode(fromWaitStatus: status)
        return CommandResult(exitCode: exitCode, stdout: output, stderr: [])
    }

    /// Decodes a `wait(2)`-style status word (as returned by `pclose`)
    /// into a process exit code, mirroring Go's
    /// `os.ProcessState.ExitCode()`: a signal-terminated child (or a
    /// `pclose` failure) has no exit code, reported as `-1`.
    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        guard status != -1 else { return -1 }
        let exitedNormally = (status & 0x7f) == 0
        guard exitedNormally else { return -1 }
        return (status >> 8) & 0xff
    }

    /// Single-quotes `s` for safe inclusion in a `/bin/sh -c` command
    /// line, escaping any embedded single quote as `'\''`.
    private static func shellQuote(_ s: String) -> String {
        var quoted = "'"
        for ch in s {
            if ch == "'" {
                quoted += "'\\''"
            } else {
                quoted.append(ch)
            }
        }
        quoted += "'"
        return quoted
    }
}
