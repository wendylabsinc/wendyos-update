import Logging
import Testing

@testable import WendyLog

/// Collects every line the handler writes to `out`, thread-safely enough
/// for these single-threaded tests.
private final class Sink: @unchecked Sendable {
    private(set) var lines: [String] = []

    var sink: @Sendable (String) -> Void {
        { self.lines.append($0) }
    }
}

private func env(_ vars: [String: String]) -> @Sendable (String) -> String? {
    { vars[$0] }
}

private func log(
    _ handler: any LogHandler,
    level: Logger.Level,
    _ message: Logger.Message
) {
    handler.log(
        event: LogEvent(
            level: level,
            message: message,
            metadata: nil,
            source: "test",
            file: #fileID,
            function: #function,
            line: #line
        )
    )
}

// MARK: - Journal mode: sd-daemon severity prefixes + tag

@Test func journalHandlerRendersErrorWithSevPrefix3() {
    let sink = Sink()
    let handler = WendyLog.handler(.journal, out: sink.sink, env: env([:]))
    log(handler, level: .error, "boom")
    #expect(sink.lines == ["<3>wendyos-update: boom\n"])
}

@Test func journalHandlerRendersWarningWithSevPrefix4() {
    let sink = Sink()
    let handler = WendyLog.handler(.journal, out: sink.sink, env: env([:]))
    log(handler, level: .warning, "careful")
    #expect(sink.lines == ["<4>wendyos-update: careful\n"])
}

@Test func journalHandlerRendersInfoWithSevPrefix6() {
    let sink = Sink()
    let handler = WendyLog.handler(.journal, out: sink.sink, env: env([:]))
    log(handler, level: .info, "hello")
    #expect(sink.lines == ["<6>wendyos-update: hello\n"])
}

// MARK: - Plain mode: RFC3339 timestamp + level text + tag

@Test func plainHandlerRendersErrorWithTimestampLevelAndTag() {
    let sink = Sink()
    let handler = WendyLog.handler(.plain, out: sink.sink, env: env([:]))
    log(handler, level: .error, "boom")
    #expect(sink.lines.count == 1)
    let line = sink.lines[0]
    #expect(line.hasSuffix(" ERROR wendyos-update: boom\n"))
    // The timestamp prefix should look like an RFC3339 stamp, e.g.
    // 2026-07-05T21:17:02Z or with a numeric offset; just check shape.
    let prefix = line.split(separator: " ", maxSplits: 1)[0]
    #expect(prefix.contains("T"))
    #expect(prefix.count >= "2026-07-05T00:00:00Z".count - 1)
}

// MARK: - TTY mode: NO_COLOR gating

@Test func ttyHandlerColorsErrorRedWithoutNoColor() {
    let sink = Sink()
    let handler = WendyLog.handler(.tty, out: sink.sink, env: env([:]))
    log(handler, level: .error, "boom")
    #expect(sink.lines.count == 1)
    #expect(sink.lines[0].contains("\u{1b}[31m"))
    #expect(sink.lines[0].contains("wendyos-update: boom"))
}

@Test func ttyHandlerSuppressesColorWhenNoColorSet() {
    let sink = Sink()
    let handler = WendyLog.handler(.tty, out: sink.sink, env: env(["NO_COLOR": "1"]))
    log(handler, level: .error, "boom")
    #expect(sink.lines.count == 1)
    #expect(!sink.lines[0].contains("\u{1b}["))
    #expect(sink.lines[0].contains("wendyos-update: boom"))
}

// MARK: - WENDY_DEBUG gating

@Test func debugRecordSuppressedByDefault() {
    let sink = Sink()
    let handler = WendyLog.handler(.plain, out: sink.sink, env: env([:]))
    log(handler, level: .debug, "verbose detail")
    #expect(sink.lines.isEmpty)
}

@Test func debugRecordEmittedWhenWendyDebugSet() {
    let sink = Sink()
    let handler = WendyLog.handler(.plain, out: sink.sink, env: env(["WENDY_DEBUG": "1"]))
    log(handler, level: .debug, "verbose detail")
    #expect(sink.lines.count == 1)
    #expect(sink.lines[0].hasSuffix(" DEBUG wendyos-update: verbose detail\n"))
}
