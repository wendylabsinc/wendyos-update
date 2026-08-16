import Foundation
import Logging
import LinuxSys
import PlatformIO
import Synchronization
import WendyLog

// Process-wide runtime wiring: log-mode detection, `LoggingSystem`
// bootstrap, the progress reporter, and the stdout-is-a-TTY flag every
// verb consults before emitting a JSON event. Ports the package-level
// `var ui *wlog.Logger` / `var stdoutIsTTY bool` plus their one-time setup
// in main.go's `main()`.
//
// Exactly one subcommand's `run()` executes per process invocation (an
// `ArgumentParser` command tree dispatches to a single leaf), so calling
// `bootstrapRuntime()` unconditionally at the top of each verb's `run()`
// bootstraps `LoggingSystem` exactly once per process — `LoggingSystem
// .bootstrap` may only be called once; a second call is undefined
// behavior. These globals are written exactly once, before any concurrent
// work starts, and only read afterward — the same single-assignment
// lifecycle Go's package-level `var`s have.

/// Whether stdout is a terminal — suppresses the high-frequency progress
/// JSON (and every other stdout event) when a human is watching it
/// directly, since machine callers always pipe stdout. Set once by
/// `bootstrapRuntime()`.
nonisolated(unsafe) var stdoutIsTTY = false

/// The stderr progress bar (`.tty` mode only; a no-op elsewhere). Set once
/// by `bootstrapRuntime()`.
nonisolated(unsafe) var sharedProgressReporter: ProgressReporter?

/// Coordinates writes to stderr between `WendyLog`'s structured log lines
/// and `ProgressReporter`'s interactive bar, so a log line landing mid-bar
/// clears the bar first instead of visually interleaving with it — the
/// known no-shared-lock gap from Task 7.1 (`WendyLog.handler` and
/// `ProgressReporter` each take their own `out` closure with no
/// coordination between them). Both `WendyUpdate.main()`'s log handler and
/// its `ProgressReporter` are wired through the SAME `StderrSink`
/// instance, so this is the one place that actually needs the lock —
/// neither `WendyLog` type needs to change.
final class StderrSink: Sendable {
    /// `true` while a bar is the last thing written to stderr (i.e. the
    /// cursor sits mid-line on a `\r...\u{1b}[K`-terminated bar, not at the
    /// start of a fresh line).
    private let barActive = Mutex(false)

    /// Called by the `WendyLog` handler for each fully-rendered, already
    /// newline-terminated log line.
    func writeLog(_ line: String) {
        let hadBar = barActive.withLock { active -> Bool in
            defer { active = false }
            return active
        }
        if hadBar {
            // Blank the half-drawn bar before the log line lands, so the
            // two never visually interleave.
            Self.rawWrite("\r\u{1b}[K")
        }
        Self.rawWrite(line)
    }

    /// Called by `ProgressReporter` for each bar update. Its `content` is
    /// either a `\r...\u{1b}[K`-terminated bar (leaves the bar active) or
    /// exactly `"\n"` (the 100%-complete newline that ends the bar).
    func writeProgress(_ content: String) {
        barActive.withLock { $0 = content != "\n" }
        Self.rawWrite(content)
    }

    private static func rawWrite(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }
}

/// One-time process setup: detects the stderr log mode and stdout TTY-ness,
/// bootstraps `swift-log`'s `LoggingSystem` with `WendyLog`'s handler, and
/// builds the shared `ProgressReporter` — all routed through one
/// `StderrSink` (see its doc comment). Ports main.go's `main()` preamble:
/// `ui = wlog.New(...)`, `slog.SetDefault(...)`, `stdoutIsTTY = ...`.
func bootstrapRuntime() {
    let sink = StderrSink()
    let env: @Sendable (String) -> String? = { RealEnvReader().get($0) }
    let mode = WendyLog.detect(isTTY: LinuxSys.isatty(2), env: env)

    LoggingSystem.bootstrap { _ in WendyLog.handler(mode, out: sink.writeLog, env: env) }
    sharedProgressReporter = ProgressReporter(mode: mode, out: sink.writeProgress)
    stdoutIsTTY = LinuxSys.isatty(1)
}

/// Builds the `Engine.progress` callback for `install`: drives both
/// channels exactly like main.go's `emitProgress` — the contract's
/// compact JSON line on stdout (suppressed on a TTY) and the human bar on
/// stderr via the shared `ProgressReporter`.
func makeProgressCallback() -> @Sendable (_ phase: String, _ percent: Int) -> Void {
    { phase, percent in
        emitProgressJSON(phase: phase, percent: percent, stdoutIsTTY: stdoutIsTTY)
        sharedProgressReporter?.update(phase: phase, percent: percent)
    }
}
