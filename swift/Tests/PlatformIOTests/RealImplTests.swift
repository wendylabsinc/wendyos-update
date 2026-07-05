import Foundation
import Glibc
import Testing

import PlatformIO

/// Builds a unique scratch directory path under /tmp for this test.
/// Nothing here uses `RealFileStore.mkdirp` for the *creation* of the
/// scratch root itself — tests want to start from a directory that does
/// NOT yet exist, so `writeAtomic`'s own parent-creation is what's under
/// test.
private func tempDir(_ tag: String) -> String {
    "/tmp/platformio-test-\(getpid())-\(tag)-\(Int.random(in: 0..<1_000_000))"
}

@Test func writeAtomicCreatesParentDirsAndLeavesNoTmpFile() throws {
    let store = RealFileStore()
    let dir = tempDir("writeatomic")
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let target = "\(dir)/nested/state.json"
    let payload = Array("hello atomic write".utf8)

    // The parent directory doesn't exist yet — writeAtomic must create it.
    #expect(!FileManager.default.fileExists(atPath: "\(dir)/nested"))
    try store.writeAtomic(target, payload, mode: 0o600)

    #expect(try store.read(target) == payload)

    let entries = try store.listDir("\(dir)/nested")
    #expect(entries.map(\.name) == ["state.json"])
    #expect(entries.allSatisfy { !$0.name.contains(".tmp") })
}

@Test func removeOfAbsentPathIsANoOp() throws {
    let store = RealFileStore()
    let path = tempDir("missing") + "/does-not-exist"

    try store.remove(path)  // must not throw
}

@Test func listDirReportsIsExecutableFromModeBits() throws {
    let store = RealFileStore()
    let dir = tempDir("listdir")
    defer { try? FileManager.default.removeItem(atPath: dir) }

    try store.writeAtomic("\(dir)/script.sh", Array("#!/bin/sh\n".utf8), mode: 0o755)
    try store.writeAtomic("\(dir)/notes.txt", Array("hi".utf8), mode: 0o644)

    let byName = Dictionary(uniqueKeysWithValues: try store.listDir(dir).map { ($0.name, $0) })
    #expect(byName.count == 2)
    #expect(byName["script.sh"]?.isExecutable == true)
    #expect(byName["notes.txt"]?.isExecutable == false)
    #expect(byName["script.sh"]?.isDir == false)
}

@Test func realCommandRunnerRunsEchoAndCollectsStdout() async throws {
    let runner = RealCommandRunner()

    let result = try await runner.run(["/bin/echo", "hi"], env: nil, stdin: nil)

    #expect(result.exitCode == 0)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "hi\n")
}

/// `state.json`'s `created` field is stamped with this string verbatim
/// and re-parsed by the Go binary as `time.RFC3339`
/// (`"2006-01-02T15:04:05Z"`). Pins the exact shape — no fractional
/// seconds, always a literal `Z` (never a `+00:00`/numeric offset) — so a
/// future switch to `ISO8601DateFormatter`/`Date.formatted` can't
/// silently drift the on-disk format.
@Test func realClockFormatsAsBareRFC3339UTCWithNoFractionalSeconds() {
    let timestamp = RealClock().nowUTCISO8601()

    #expect(timestamp.count == 20)
    #expect(timestamp.hasSuffix("Z"))

    let digitPositions = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
    let dashPositions = [4, 7]
    let chars = Array(timestamp)
    for i in digitPositions {
        #expect(chars[i].isASCII && chars[i].isNumber, "expected digit at index \(i), got \(chars[i]) in \(timestamp)")
    }
    for i in dashPositions {
        #expect(chars[i] == "-", "expected '-' at index \(i), got \(chars[i]) in \(timestamp)")
    }
    #expect(chars[10] == "T", "expected 'T' at index 10, got \(chars[10]) in \(timestamp)")
    #expect(chars[13] == ":", "expected ':' at index 13, got \(chars[13]) in \(timestamp)")
    #expect(chars[16] == ":", "expected ':' at index 16, got \(chars[16]) in \(timestamp)")
    #expect(chars[19] == "Z", "expected 'Z' at index 19, got \(chars[19]) in \(timestamp)")
}
