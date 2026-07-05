import Foundation
import Logging

/// Tags every line so wendyos-update's output is greppable when interleaved
/// with other services in the journal. Mirrors Go's `msgPrefix`.
let msgPrefix = "wendyos-update: "

let colorReset = "\u{1b}[0m"

extension WendyLog {
    /// Builds a `swift-log` `LogHandler` that renders records the way
    /// `internal/log/log.go`'s `handler` does: sd-daemon `<N>` severity
    /// prefixes under `.journal`, colored lines under `.tty` (unless
    /// `NO_COLOR` is set), and RFC3339-timestamped plain lines otherwise.
    ///
    /// - Parameters:
    ///   - mode: the rendering mode (see `detect(isTTY:env:)`).
    ///   - out: sink that receives each fully-formed line (including the
    ///     trailing newline). The caller wires this to stderr.
    ///   - env: environment-variable lookup, injected for testability;
    ///     consulted for `NO_COLOR` (tty) and `WENDY_DEBUG` (debug gate).
    public static func handler(
        _ mode: LogMode,
        out: @escaping @Sendable (String) -> Void,
        env: @escaping @Sendable (String) -> String?
    ) -> any LogHandler {
        WendyLogHandler(mode: mode, out: out, env: env)
    }
}

/// The `LogHandler` conformance backing `WendyLog.handler`.
///
/// Per `swift-log`'s implementation requirements this is a `struct` — its
/// `logLevel` is left maximally permissive (`.trace`) so every record
/// reaches `log(event:)`, where the debug gate (`WENDY_DEBUG`) is applied
/// the same way Go's `handler.Enabled` did.
struct WendyLogHandler: LogHandler {
    private let mode: LogMode
    private let out: @Sendable (String) -> Void
    private let env: @Sendable (String) -> String?

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    init(
        mode: LogMode,
        out: @escaping @Sendable (String) -> Void,
        env: @escaping @Sendable (String) -> String?
    ) {
        self.mode = mode
        self.out = out
        self.env = env
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        // Go's handler.Enabled: below Info requires WENDY_DEBUG.
        if event.level < .info, env("WENDY_DEBUG") == nil {
            return
        }

        var text = event.message.description
        var combined = self.metadata
        if let eventMetadata = event.metadata {
            combined.merge(eventMetadata) { _, new in new }
        }
        for key in combined.keys.sorted() {
            text += " \(key)=\(combined[key]!)"
        }

        out(render(level: event.level, msg: text))
    }

    private func render(level: Logger.Level, msg: String) -> String {
        switch mode {
        case .journal:
            return sevPrefix(level) + msgPrefix + msg + "\n"
        case .tty:
            if let color = colorFor(level), env("NO_COLOR") == nil {
                return color + msgPrefix + msg + colorReset + "\n"
            }
            return msgPrefix + msg + "\n"
        case .plain:
            return rfc3339Now() + " " + levelText(level) + " " + msgPrefix + msg + "\n"
        }
    }
}

/// Maps a swift-log level to an sd-daemon severity prefix. journald (and the
/// kmsg/syslog console) parse a leading `<N>` into PRIORITY. Trace/Debug
/// share Go's "default" (`<7>`, debug) bucket; Notice/Critical fold into the
/// adjacent Info/Error buckets since Go's four-level `slog` has no
/// equivalent of its own.
func sevPrefix(_ level: Logger.Level) -> String {
    switch level {
    case .critical, .error:
        return "<3>" // err
    case .warning:
        return "<4>" // warning
    case .notice, .info:
        return "<6>" // info
    case .debug, .trace:
        return "<7>" // debug
    }
}

func levelText(_ level: Logger.Level) -> String {
    switch level {
    case .critical, .error:
        return "ERROR"
    case .warning:
        return "WARN"
    case .notice, .info:
        return "INFO"
    case .debug, .trace:
        return "DEBUG"
    }
}

/// - Returns: the ANSI color-start code for `level`, or `nil` when the level
///   keeps the terminal default (info/debug), matching Go's `colorFor`.
func colorFor(_ level: Logger.Level) -> String? {
    switch level {
    case .critical, .error:
        return "\u{1b}[31m" // red
    case .warning:
        return "\u{1b}[33m" // yellow
    default:
        return nil
    }
}

/// RFC3339 timestamp for plain-mode lines, matching Go's
/// `time.Now().Format(time.RFC3339)`.
func rfc3339Now() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}
