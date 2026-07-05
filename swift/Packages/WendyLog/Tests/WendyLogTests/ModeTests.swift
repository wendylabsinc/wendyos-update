import Testing

@testable import WendyLog

/// Builds an env-lookup closure from a fixed dictionary, mirroring how the
/// executable will wire `ProcessInfo`/`getenv` in production.
private func env(_ vars: [String: String]) -> @Sendable (String) -> String? {
    { vars[$0] }
}

@Test func detectPrefersJournalWhenJournalStreamIsSet() {
    // JOURNAL_STREAM wins even if the stream also happens to be a TTY.
    let mode = WendyLog.detect(isTTY: true, env: env(["JOURNAL_STREAM": "9:1234"]))
    #expect(mode == .journal)
}

@Test func detectIsTTYWhenIsattyAndNoJournal() {
    let mode = WendyLog.detect(isTTY: true, env: env([:]))
    #expect(mode == .tty)
}

@Test func detectFallsBackToPlainOtherwise() {
    let mode = WendyLog.detect(isTTY: false, env: env([:]))
    #expect(mode == .plain)
}
