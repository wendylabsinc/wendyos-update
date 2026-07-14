import ArgumentParser
import Artifact
import AsyncHTTPClient
import BlockDev
import CLIError
import Connector
import Engine
import Foundation
import Logging
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

    @Argument(help: "a local .wendy artifact path, an http(s) url, or - for stdin")
    var source: String

    mutating func run() async throws {
        bootstrapRuntime()
        try await runVerb {
            let logger = Logger(label: "wendyos-update")
            let engine = try makeEngine(progress: makeProgressCallback())

            let httpClient = HTTPClient(eventLoopGroupProvider: .singleton, configuration: installHTTPClientConfiguration)
            defer { sharedInstallCancellation.disarm() }

            let artifactSource = try await openArtifactSource(source, httpClient: httpClient)
            // Tear down the background HTTP producer the moment the
            // consumer pipeline below stops — success, rejection, or
            // thrown error alike. Without this, a routine early rejection
            // (wrong device/version/digest, read only from the manifest)
            // would leave the producer `push`-ing a multi-GB body into a
            // queue no one drains, hanging forever. No-op for a local
            // source. (Runs before `disarm()` — declared later, so LIFO.)
            defer { artifactSource.teardown() }

            // `ArtifactReader.open`/`engine.install` pull bytes through
            // the source's synchronous closure, which — for an http(s)
            // source — blocks a real OS thread waiting on the streamed
            // download (see Download.swift's doc comment). Running that on
            // a dedicated `Thread` rather than inline here keeps that
            // blocking wait off Swift Concurrency's cooperative pool,
            // uniformly for both source kinds (local reads settle
            // instantly, so the extra thread hop costs them nothing
            // observable).
            let result = try await runOnDedicatedThread {
                let reader = try ArtifactReader.open(artifactSource.tar)
                return try blockingRun { try await engine.install(reader, blockTarget: RealBlockTarget()) }
            }

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

/// Ports pack.go's `cmdPack` flag surface verbatim. Every flag here is
/// declared optional (no `ArgumentParser`-level `required` — required-ness
/// is instead checked, all at once, by `runPack(_:)`) so a missing flag
/// produces the same exit-1 `PackError` pack.go's own manual check does,
/// rather than `ArgumentParser`'s unrelated validation-failure exit code.
/// This command itself does nothing but gather flags into a
/// `PackCLIOptions` and hand off to `runPack(_:)` — see `Pack.swift` for
/// the actual logic (and what a test drives directly, with no argument
/// parsing involved).
struct Pack: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pack",
        abstract: "build a .wendy artifact from a rootfs image (host-side)"
    )

    @Option(name: .long, help: "rootfs image to package (e.g. the deployed .ext4)")
    var image = ""

    @Option(name: .long, help: "artifact name (e.g. wendyos-image-<machine>-<version>)")
    var name = ""

    @Option(name: .long, help: "artifact version (e.g. 0.16.0)")
    var version = ""

    @Option(name: .long, help: "payload compression: zstd|gzip|none")
    var compression = "zstd"

    @Flag(name: .long, help: "informational flag (the rootfs marker decides at install time)")
    var bootloaderUpdate = false

    @Option(name: .long, help: "minimum wendyos-update version able to install this artifact")
    var minToolVersion = ""

    @Option(name: .customShort("o"), help: "output .wendy path")
    var output = ""

    @Flag(name: .long, help: "skip the read-back verification pass")
    var noVerify = false

    @Option(name: .customLong("device"), help: "compatible device type (WENDYOS_BOARD_ID); repeatable")
    var devices: [String] = []

    mutating func run() async throws {
        bootstrapRuntime()
        try await runVerb {
            let summary = try runPack(
                PackCLIOptions(
                    image: image, name: name, version: version, compression: compression,
                    bootloaderUpdate: bootloaderUpdate, minToolVersion: minToolVersion,
                    output: output, noVerify: noVerify, devices: devices
                )
            )
            FileHandle.standardError.write(Data(summary.utf8))
        }
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
