/// Selects how log records and progress updates are rendered.
///
/// Mirrors `internal/log/log.go`'s `Mode`:
///   - `.plain`: piped or redirected output — plain timestamped lines.
///   - `.tty`: an interactive terminal — colored lines and an in-place
///     progress bar updated with carriage returns.
///   - `.journal`: running under systemd — lines carry sd-daemon `<N>`
///     severity prefixes and progress is a no-op (a `\r` bar is meaningless
///     in the journal).
public enum LogMode: Sendable {
    case plain
    case tty
    case journal
}

/// Namespace for building a `WendyLog`-flavored `swift-log` handler.
///
/// `WendyLog` takes plain closures for environment lookup and output instead
/// of depending on the app's own `PlatformIO.EnvReader`, so this package
/// stays a self-contained, independently testable unit with no dependency
/// on the root package's internals.
public enum WendyLog {
    /// Picks a `LogMode`, mirroring Go's `Detect`: systemd's `$JOURNAL_STREAM`
    /// is the canonical "I am a service" signal and wins; then a TTY means
    /// interactive; otherwise plain.
    ///
    /// - Parameters:
    ///   - isTTY: whether the destination stream is a terminal.
    ///   - env: environment-variable lookup, injected for testability.
    public static func detect(isTTY: Bool, env: @escaping @Sendable (String) -> String?) -> LogMode {
        if env("JOURNAL_STREAM") != nil {
            return .journal
        }
        if isTTY {
            return .tty
        }
        return .plain
    }
}
