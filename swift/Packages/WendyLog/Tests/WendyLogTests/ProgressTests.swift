import Testing

@testable import WendyLog

private final class Sink: @unchecked Sendable {
    private(set) var writes: [String] = []

    var sink: @Sendable (String) -> Void {
        { self.writes.append($0) }
    }
}

@Test func progressIsNoOpInPlainMode() {
    let sink = Sink()
    let progress = ProgressReporter(mode: .plain, out: sink.sink)
    progress.update(phase: "downloading", percent: 42)
    #expect(sink.writes.isEmpty)
}

@Test func progressIsNoOpInJournalMode() {
    let sink = Sink()
    let progress = ProgressReporter(mode: .journal, out: sink.sink)
    progress.update(phase: "downloading", percent: 42)
    #expect(sink.writes.isEmpty)
}

@Test func ttyProgressEmitsCarriageReturnPrefixedBar() {
    let sink = Sink()
    let progress = ProgressReporter(mode: .tty, out: sink.sink)
    progress.update(phase: "writing", percent: 50)
    #expect(sink.writes.count == 1)
    let line = sink.writes[0]
    #expect(line.hasPrefix("\r"))
    #expect(line.contains("wendyos-update: "))
    #expect(line.contains(" 50%"))
    #expect(line.contains("█"))
    #expect(line.contains("░"))
    // Not complete yet, so no trailing newline write.
    #expect(!line.hasSuffix("\n"))
}

@Test func ttyProgressEmitsIndeterminatePhaseWhenPercentNegative() {
    let sink = Sink()
    let progress = ProgressReporter(mode: .tty, out: sink.sink)
    progress.update(phase: "verifying", percent: -1)
    #expect(sink.writes.count == 1)
    #expect(sink.writes[0].contains("verifying…"))
}

@Test func ttyProgressEmitsTrailingNewlineAtCompletion() {
    let sink = Sink()
    let progress = ProgressReporter(mode: .tty, out: sink.sink)
    progress.update(phase: "writing", percent: 100)
    // One write for the bar line, one for the trailing newline that
    // terminates the in-place bar once the operation completes.
    #expect(sink.writes.count == 2)
    #expect(sink.writes[0].hasPrefix("\r"))
    #expect(sink.writes[1] == "\n")
}
