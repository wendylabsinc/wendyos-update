import PlatformIO

@testable import TegraUEFI

// Shared test doubles for TegraUEFITests: a scriptable `TegraCommandRunner`
// (the sync `nvbootctrl`/`lsblk`/`findmnt` seam) and small helpers for
// building `TegraMount` fakes. `PlatformIOTesting.FakeFileStore` (extended
// with `symlink(_:to:)`/`resolveSymlink` in this task) covers the
// `RootDir`-prefixed regular-filesystem side (by-partlabel/by-partuuid
// symlinks, `nv_boot_control.conf`, marker/capsule files, ESP staging).

/// A `TegraCommandRunner` that records every `argv` it's asked to run and
/// answers with the first scripted result whose predicate matches, or a
/// clean `exit 0` with no output otherwise. Mirrors the Go test file's
/// `fakeNvbootctrl`/`recordingNvbootctrl` shell-stub idiom (fixed output
/// vs. per-subcommand output + an invocation log), but in-process.
final class FakeTegraCommandRunner: TegraCommandRunner, @unchecked Sendable {
    private(set) var invocations: [[String]] = []
    private var scripts: [(match: ([String]) -> Bool, result: CommandResult)] = []

    /// Scripts a result for the first invocation whose argv satisfies
    /// `match`, checked in registration order (first match wins).
    func script(when match: @escaping ([String]) -> Bool, result: CommandResult) {
        scripts.append((match, result))
    }

    /// Scripts a result whenever `argv` (joined with spaces) contains
    /// `substring` — e.g. a subcommand keyword like `"get-current-slot"`.
    /// Mirrors the Go fakes' `case "$*" in *substring*)`.
    func script(containing substring: String, stdout: String = "", exitCode: Int32 = 0) {
        script(
            when: { $0.joined(separator: " ").contains(substring) },
            result: CommandResult(exitCode: exitCode, stdout: Array(stdout.utf8), stderr: [])
        )
    }

    func run(_ argv: [String]) -> CommandResult {
        invocations.append(argv)
        return scripts.first(where: { $0.match(argv) })?.result
            ?? CommandResult(exitCode: 0, stdout: [], stderr: [])
    }

    /// Reports whether any invocation's argv contains `substring` when
    /// joined with spaces — the equivalent of the Go tests'
    /// `strings.Contains(string(calls), "...")` assertion against a log
    /// file.
    func ranCommand(containing substring: String) -> Bool {
        invocations.contains { $0.joined(separator: " ").contains(substring) }
    }
}

/// Builds a `RootfsMounter`/`EspMounter` that always returns `directory`
/// (as a fixed, already-populated fake mount point) and records whether it
/// was invoked — so a rollback-swap test can assert the mount seam was
/// NEVER called (swap-slot.go's rollback path must not mount).
final class FakeMounter: @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var lastDevicePath: String?
    var directory: String
    var error: Error?

    init(directory: String) {
        self.directory = directory
    }

    func mount(_ devicePath: String) throws -> TegraMount {
        callCount += 1
        lastDevicePath = devicePath
        if let error { throw error }
        return TegraMount(directory: directory, unmount: {})
    }
}
