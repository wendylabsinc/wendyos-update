import Synchronization

/// Width, in characters, of the filled/unfilled block bar. Matches Go's
/// `barWidth`.
private let barWidth = 30

/// Renders a coarse install progress update, mirroring
/// `internal/log/log.go`'s `Logger.Progress`/`renderBarLocked`.
///
/// The in-place `\r` bar is an interactive nicety, so it is drawn ONLY in
/// `.tty` mode. Under `.journal` or `.plain`, per-percent updates are noise
/// (phase transitions are already logged elsewhere), so `update` is a no-op
/// there.
///
/// `ProgressReporter` serializes its own bar writes behind an internal lock
/// so concurrent `update` calls can't interleave a partially-written bar.
/// It does not share state with the `LogHandler` returned by
/// `WendyLog.handler` — the executable is responsible for wiring both to
/// the same underlying stream.
public final class ProgressReporter: Sendable {
    private let mode: LogMode
    private let out: @Sendable (String) -> Void
    private let barActive: Mutex<Bool> = Mutex(false)

    public init(mode: LogMode, out: @escaping @Sendable (String) -> Void) {
        self.mode = mode
        self.out = out
    }

    /// Renders one progress update. `percent < 0` means indeterminate
    /// ("phase…"). No-op outside `.tty`.
    public func update(phase: String, percent: Int) {
        guard mode == .tty else { return }

        let content: String
        if percent < 0 {
            content = "\(msgPrefix)\(phase)…"
        } else {
            let filled = min(percent * barWidth / 100, barWidth)
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)
            let paddedPhase = phase.count < 8 ? phase + String(repeating: " ", count: 8 - phase.count) : phase
            let percentDigits = String(percent)
            let percentField = String(repeating: " ", count: max(0, 3 - percentDigits.count)) + percentDigits
            content = "\(msgPrefix)\(paddedPhase) [\(bar)] \(percentField)%"
        }

        // \r to the line start, content, then \033[K to wipe any leftover of
        // a previously longer line.
        out("\r" + content + "\u{1b}[K")
        barActive.withLock { $0 = true }

        if percent >= 100 {
            out("\n")
            barActive.withLock { $0 = false }
        }
    }
}
