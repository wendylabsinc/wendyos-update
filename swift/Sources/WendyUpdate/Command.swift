import ArgumentParser
import Artifact
import BlockDev
import CLIError
import Connector
import Engine
import Foundation
import Logging
import LinuxSys
import Model
import PlatformIO
import Tar

// Verb dispatch for the `wendyos-update` executable. Ports
// `cmd/wendyos-update/main.go`'s `switch os.Args[1]` and each `cmd*`
// function end to end.
//
// stdout stays the machine-readable JSON channel (docs/cli-contract.md);
// every human-facing line — including the plain-text `status` view — goes
// to stderr via `Logger`/`FileHandle.standardError`, matching main.go.

@main
struct WendyUpdate: AsyncParsableCommand {
    static let version = "0.1.0-dev"

    static let configuration = CommandConfiguration(
        commandName: "wendyos-update",
        abstract: "generic A/B OTA tool for WendyOS",
        version: version,
        subcommands: [
            Install.self, Commit.self, Rollback.self, Status.self, Switch.self,
            MarkGood.self, Pack.self, VerifyBoot.self, Version.self,
        ]
    )

    /// Invoked when no verb is given at all — ports main.go's
    /// `if len(os.Args) < 2 { usage(); os.Exit(1) }`. (Every OTHER
    /// unrecognized-invocation shape — an unknown verb, a missing/extra
    /// positional argument — is caught by `ArgumentParser`'s own parser
    /// before `run()` is ever reached, and exits through its usual
    /// validation-failure path rather than this one.)
    mutating func run() async throws {
        FileHandle.standardError.write(Data(usageText.utf8))
        throw ExitCode(1)
    }
}

/// Ports main.go's `usage()` text verbatim (module-scope so it can embed
/// `WendyUpdate.version`).
let usageText = """
wendyos-update \(WendyUpdate.version)
usage:
  wendyos-update install <url|path>   install a .wendy artifact (no reboot)
  wendyos-update commit               finalize after reboot (exit 2 = nothing to commit)
  wendyos-update rollback             swap back an uncommitted update
  wendyos-update status [--json] [--verbose]
                                      per-slot state (rootfs/distro/kernel) + pending update
                                      (--verbose adds a raw slot/EFI-var snapshot)
  wendyos-update switch <other|a|b>   boot the other slot next, no update (reboot to apply)
  wendyos-update mark-good            reset slot health, clear pending state
  wendyos-update pack <flags>         build a .wendy artifact from a rootfs image (host-side)

"""

/// Runs `body`, funneling any thrown domain error through the shared
/// log-then-map-exit-code tail every verb needs — ports the common part of
/// main.go's `main()`: `if err != nil { ...; os.Exit(exitCode(err)) }`.
/// Logs at info for the ordinary "nothing to commit" outcome (so it
/// doesn't show up red/high-priority in the journal), error otherwise,
/// then re-throws as an `ArgumentParser.ExitCode` — which the framework's
/// default top-level `exit(withError:)` recognizes as "exit with this code,
/// print nothing else" (we've already printed the log line ourselves).
func runVerb(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch {
        let logger = Logger(label: "wendyos-update")
        if isNothingToCommit(error) {
            logger.info("\(error)")
        } else {
            logger.error("\(error)")
        }
        throw ExitCode(mapExit(error))
    }
}

// MARK: - install

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "install a .wendy artifact (no reboot)"
    )

    @Argument(help: "a local .wendy artifact path, or - for stdin (an http(s) url is not yet supported by this build)")
    var source: String

    mutating func run() async throws {
        bootstrapRuntime()
        try await runVerb {
            if source.hasPrefix("http://") || source.hasPrefix("https://") {
                throw InstallSourceError(
                    message: "install: http(s) sources are not yet supported by this build (task 10.2); " +
                        "pass a local file path or - for stdin"
                )
            }

            let logger = Logger(label: "wendyos-update")
            let engine = try makeEngine(progress: makeProgressCallback())

            let fd: Int32 = source == "-" ? 0 : try LinuxSys.openRead(source)
            defer { if fd != 0 { LinuxSys.close(fd) } }

            let tar = TarReader { into, max in
                var chunk = [UInt8](repeating: 0, count: max)
                let n = try chunk.withUnsafeMutableBytes { ptr in try LinuxSys.read(fd, ptr) }
                into = n == max ? chunk : Array(chunk[0..<n])
                return n
            }
            let reader = try ArtifactReader.open(tar)

            let result = try await engine.install(reader, blockTarget: RealBlockTarget())

            emitEvent(makeInstallDoneJSON(result), stdoutIsTTY: stdoutIsTTY)
            logger.info(
                "install complete — reboot to activate",
                metadata: [
                    "artifact": "\(result.artifactName)", "version": "\(result.artifactVersion)",
                    "target_slot": "\(result.targetSlot)", "bootloader_update": "\(result.bootloaderUpdate)",
                    "reboot_required": "true",
                ]
            )
        }
    }
}

/// Thrown by `install` for an `http://`/`https://` source: streaming a
/// download is Task 10.2's scope, not this one's. Maps to exit 1, like any
/// other generic CLI error.
struct InstallSourceError: Error, Equatable, ExitCoded {
    let message: String
    var exitCode: Int32 { 1 }
}

extension InstallSourceError: CustomStringConvertible {
    var description: String { message }
}

// MARK: - commit

struct Commit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "commit",
        abstract: "finalize after reboot (exit 2 = nothing to commit)"
    )

    mutating func run() async throws {
        bootstrapRuntime()
        try await runVerb {
            let engine = try makeEngine()
            try await engine.commit()
            Logger(label: "wendyos-update").info("committed")
        }
    }
}

// MARK: - rollback

struct Rollback: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "swap back an uncommitted update"
    )

    mutating func run() async throws {
        bootstrapRuntime()
        try await runVerb {
            let engine = try makeEngine()
            let result = try engine.rollback()
            emitEvent(makeRollbackJSON(result), stdoutIsTTY: stdoutIsTTY)
        }
    }
}

// MARK: - switch

struct Switch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "boot the other slot next, no update (reboot to apply)"
    )

    @Argument(help: "other|a|b")
    var target: String

    mutating func run() async throws {
        bootstrapRuntime()
        try await runVerb {
            let engine = try makeEngine()
            let cur = try engine.conn.currentSlot()
            let resolved: Slot
            switch target.lowercased() {
            case "other": resolved = cur.other
            case "a": resolved = .a
            case "b": resolved = .b
            default:
                throw SwitchError(message: "switch: unknown target \"\(target)\" (use other|a|b)")
            }
            try engine.`switch`(to: resolved)
            emitEvent(makeSwitchJSON(target: resolved), stdoutIsTTY: stdoutIsTTY)
        }
    }
}

// MARK: - status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "per-slot state (rootfs/distro/kernel) + pending update"
    )

    @Flag(name: .long, help: "machine-readable JSON output")
    var json = false

    @Flag(name: [.long, .short], help: "raw slot/EFI-var snapshot")
    var verbose = false

    mutating func run() async throws {
        bootstrapRuntime()
        try await runVerb {
            let engine = try makeEngine()
            let info = try engine.status(verbose: verbose)
            if json {
                writeStdoutRaw(JSONCodec.encodePretty(makeStatusJSON(info)))
            } else {
                FileHandle.standardError.write(Data(renderHumanStatus(info, verbose: verbose).utf8))
            }
        }
    }
}

// MARK: - mark-good

struct MarkGood: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mark-good",
        abstract: "reset slot health, clear pending state"
    )

    mutating func run() async throws {
        bootstrapRuntime()
        try await runVerb {
            let engine = try makeEngine()
            try engine.markGood()
        }
    }
}

// MARK: - pack (Task 10.3)

struct Pack: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pack",
        abstract: "build a .wendy artifact from a rootfs image (host-side)"
    )

    mutating func run() async throws {
        FileHandle.standardError.write(Data("wendyos-update: pack: not yet implemented (task 10.3)\n".utf8))
        throw ExitCode(1)
    }
}

// MARK: - verify-boot (internal; not part of the public CLI contract)

struct VerifyBoot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-boot",
        shouldDisplay: false
    )

    /// Best-effort, always exits 0: `wendyos-update-verify.service` must
    /// never fail the boot over a userspace bookkeeping problem. Ports
    /// main.go's `cmdVerifyBoot`.
    mutating func run() async throws {
        bootstrapRuntime()
        let logger = Logger(label: "wendyos-update")

        let engine: Engine
        do {
            engine = try makeEngine()
        } catch {
            logger.warning("verify-boot: skipped", metadata: ["err": "\(error)"])
            return
        }
        do {
            try await engine.verifyBoot()
        } catch {
            logger.warning("verify-boot", metadata: ["err": "\(error)"])
        }
    }
}

// MARK: - version

struct Version: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "print the tool version"
    )

    mutating func run() async throws {
        print(WendyUpdate.version)
    }
}
