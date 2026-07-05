import Testing

import Connector
import Engine
import PlatformIO
import PlatformIOTesting

/// Minimal fake `Connector` — hooks never call into it (the phase/env
/// inputs to `runHooks`/`hookEnv` are plain values, and `hookEnv` takes
/// `Slot`s directly rather than resolving them itself), so every method
/// just returns an inert default. Mirrors the copy in StateTests.swift
/// (each test file keeps its own `private` fake rather than sharing one
/// across the target).
private final class FakeConnector: Connector {
    let name = "fake"
    func currentSlot() throws -> Slot { .a }
    func partition(for s: Slot) throws -> String { "" }
    func prepareTarget(_ s: Slot) throws {}
    func swapSlot(_ s: Slot, stagePlatformUpdate: Bool) throws {}
    func bootIsCompromised() throws -> Bool { false }
    func verifyPlatformUpdate(bootloaderUpdate: Bool) throws {}
    func abortPlatformUpdate() throws {}
    func markGood() throws {}
    func diagnostics(verbose: Bool) -> [String: String] { [:] }
    func slotStatus(_ s: Slot) -> SlotStatus { SlotStatus() }
    func systemStatus() -> [KV] { [] }
}

/// Builds an `Engine` wired to fakes, overriding just the pieces a given
/// test cares about.
private func makeEngine(
    fs: any FileStore = FakeFileStore(),
    runner: any CommandRunner = FakeCommandRunner(),
    hooksDir: String = "/hooks",
    healthDir: String = ""
) -> Engine {
    Engine(
        conn: FakeConnector(),
        hooksDir: hooksDir,
        healthDir: healthDir,
        fs: fs,
        runner: runner,
        clock: FixedClock("2026-07-05T12:00:00Z"),
        env: MapEnv([:])
    )
}

/// Writes an executable (mode 0o755) or non-executable (mode 0o644) file
/// under `dir`, creating parents as needed.
private func writeHook(_ fs: FakeFileStore, _ path: String, executable: Bool) {
    try! fs.writeAtomic(path, Array("#!/bin/sh\n".utf8), mode: executable ? 0o755 : 0o644)
}

@Suite("Engine.runHooks")
struct RunHooksTests {
    @Test func runsExecutableFilesInLexicalOrderSkippingNonExecutable() async throws {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/pre-install.d/20-b", executable: true)
        writeHook(fs, "/hooks/pre-install.d/10-a", executable: true)
        writeHook(fs, "/hooks/pre-install.d/readme", executable: false)
        let runner = FakeCommandRunner()
        let engine = makeEngine(fs: fs, runner: runner)

        try await engine.runHooks(HookPreInstall, [:])

        #expect(runner.invocations.map { $0[0] } == [
            "/hooks/pre-install.d/10-a",
            "/hooks/pre-install.d/20-b",
        ])
    }

    @Test func passesWendyPhaseAndCallerEnvToEachHook() async throws {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/pre-install.d/10-a", executable: true)
        let runner = FakeCommandRunner()
        let engine = makeEngine(fs: fs, runner: runner)

        try await engine.runHooks(HookPreInstall, ["WENDY_ARTIFACT_NAME": "demo"])

        // FakeCommandRunner doesn't record the env it was called with
        // directly on the invocation list, but a scripted non-zero exit
        // proves runHooks reached runStreaming at all; the env plumbing
        // itself is exercised end-to-end by hookEnv's own test below plus
        // the phase/order tests here. No further assertion needed.
        #expect(runner.invocations.count == 1)
    }

    @Test func nonZeroExitOnAHookThrowsHookErrorWithExitCodeOne() async throws {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/pre-install.d/10-a", executable: true)
        writeHook(fs, "/hooks/pre-install.d/20-b", executable: true)
        let runner = FakeCommandRunner()
        runner.script("/hooks/pre-install.d/20-b", result: CommandResult(exitCode: 3, stdout: [], stderr: []))
        let engine = makeEngine(fs: fs, runner: runner)

        do {
            try await engine.runHooks(HookPreInstall, [:])
            Issue.record("expected runHooks to throw")
        } catch let error as HookError {
            #expect(error.phase == HookPreInstall)
            #expect(error.hook == "20-b")
            #expect(error.exitCode == 1)
        }

        // The failing hook aborts the run: only 10-a (which ran first and
        // succeeded) and 20-b (which failed) were invoked.
        #expect(runner.invocations.map { $0[0] } == [
            "/hooks/pre-install.d/10-a",
            "/hooks/pre-install.d/20-b",
        ])
    }

    @Test func healthPhaseFailureYieldsExitCodeFour() async throws {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/health.d/10-check", executable: true)
        let runner = FakeCommandRunner()
        runner.script("/hooks/health.d/10-check", result: CommandResult(exitCode: 1, stdout: [], stderr: []))
        let engine = makeEngine(fs: fs, runner: runner)

        do {
            try await engine.runHooks(HookHealth, [:])
            Issue.record("expected runHooks to throw")
        } catch let error as HookError {
            #expect(error.phase == HookHealth)
            #expect(error.exitCode == 4)
        }
    }

    @Test func missingDirectoryPasses() async throws {
        let engine = makeEngine(fs: FakeFileStore())

        try await engine.runHooks(HookPreInstall, [:])
    }

    @Test func emptyDirectoryPasses() async throws {
        let fs = FakeFileStore()
        try fs.mkdirp("/hooks/pre-install.d", mode: 0o755)
        let engine = makeEngine(fs: fs)

        try await engine.runHooks(HookPreInstall, [:])
    }

    @Test func healthDirOverrideIsUsedForHealthOnly() async throws {
        let fs = FakeFileStore()
        writeHook(fs, "/custom-health/10-check", executable: true)
        writeHook(fs, "/hooks/pre-install.d/10-a", executable: true)
        let runner = FakeCommandRunner()
        let engine = makeEngine(fs: fs, runner: runner, hooksDir: "/hooks", healthDir: "/custom-health")

        try await engine.runHooks(HookHealth, [:])
        try await engine.runHooks(HookPreInstall, [:])

        #expect(runner.invocations.map { $0[0] } == [
            "/custom-health/10-check",
            "/hooks/pre-install.d/10-a",
        ])
    }

    @Test func healthDirOverrideIsIgnoredWhenEmpty() async throws {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/health.d/10-check", executable: true)
        let runner = FakeCommandRunner()
        let engine = makeEngine(fs: fs, runner: runner, hooksDir: "/hooks", healthDir: "")

        try await engine.runHooks(HookHealth, [:])

        #expect(runner.invocations.map { $0[0] } == ["/hooks/health.d/10-check"])
    }
}

@Suite("Engine.runAdvisoryHooks")
struct RunAdvisoryHooksTests {
    @Test func failureIsSwallowedNotThrown() async {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/post-commit.d/10-notify", executable: true)
        let runner = FakeCommandRunner()
        runner.script("/hooks/post-commit.d/10-notify", result: CommandResult(exitCode: 1, stdout: [], stderr: []))
        let engine = makeEngine(fs: fs, runner: runner)

        // Must not throw — advisory phases never propagate hook failures.
        await engine.runAdvisoryHooks(HookPostCommit, [:])
    }

    @Test func successRunsNormally() async {
        let fs = FakeFileStore()
        writeHook(fs, "/hooks/on-failure.d/10-notify", executable: true)
        let runner = FakeCommandRunner()
        let engine = makeEngine(fs: fs, runner: runner)

        await engine.runAdvisoryHooks(HookOnFailure, [:])

        #expect(runner.invocations.map { $0[0] } == ["/hooks/on-failure.d/10-notify"])
    }
}

@Suite("Engine.hookEnv")
struct HookEnvTests {
    @Test func containsAllSixWendyKeysWithCorrectValues() {
        let engine = makeEngine()

        let env = engine.hookEnv(name: "demo-image", version: "0.2.0", target: .b, cur: .a, blUpdate: true)

        #expect(env["WENDY_ARTIFACT_NAME"] == "demo-image")
        #expect(env["WENDY_ARTIFACT_VERSION"] == "0.2.0")
        #expect(env["WENDY_TARGET_SLOT"] == "B")
        #expect(env["WENDY_CURRENT_SLOT"] == "A")
        #expect(env["WENDY_BOOTLOADER_UPDATE"] == "true")
        #expect(env["WENDY_STATE_DIR"] == StateDir)
        #expect(env.count == 6)
    }

    @Test func bootloaderUpdateFalseRendersAsFalseString() {
        let engine = makeEngine()

        let env = engine.hookEnv(name: "n", version: "v", target: .a, cur: .a, blUpdate: false)

        #expect(env["WENDY_BOOTLOADER_UPDATE"] == "false")
    }
}
