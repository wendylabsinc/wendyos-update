import PlatformIO
import Testing

@testable import UBootEnv

// Ports the fixed-path-to-unique-temp-file fix noted in Task 9.2: Go's
// `fwEnv.set` (ubootenv.go) uses `os.CreateTemp("", "wendyos-fwenv-*.txt")`
// — a fresh, uniquely-named script file per invocation — so two
// overlapping `fw_setenv` writes (a retry racing a fresh call, or two
// connector instances) can never clobber each other's in-flight script.
// The prior Swift port wrote to one FIXED path
// (`.../run/wendyos-update/.fwenv-script`), which is exactly the
// corruption hazard Go's implementation avoids. These tests pin the fix:
// each `set` call gets its own path, and the file is written and cleaned
// up correctly regardless.

@Test func fwEnvSetUsesADistinctScriptPathPerInvocation() throws {
    let cmd = FakeUBootCommandRunner()
    var seenPaths: [String] = []
    cmd.onRun = { argv in
        guard argv.first == "fw_setenv", argv.count == 3, argv[1] == "-s" else { return }
        seenPaths.append(argv[2])
    }
    let rootDir = makeTempDir("fwenv-unique")
    let fwEnv = FwEnv(commandRunner: cmd, fileStore: RealFileStore(), rootDir: rootDir)

    try fwEnv.set(["wendyos_boot_slot": "1"])
    try fwEnv.set(["wendyos_boot_slot": "0"])

    #expect(seenPaths.count == 2)
    #expect(
        seenPaths[0] != seenPaths[1],
        "each fw_setenv invocation must use a distinct script path (concurrent-invocation safety)"
    )
}

@Test func fwEnvSetWritesTheEnvScriptToTheGeneratedPathBeforeRunningFwSetenv() throws {
    let cmd = FakeUBootCommandRunner()
    var capturedContents = ""
    cmd.onRun = { argv in
        guard argv.first == "fw_setenv", argv.count == 3, argv[1] == "-s" else { return }
        // Read the script file DURING the (fake) fw_setenv invocation —
        // the same moment the real binary would read it, and before
        // `set`'s `defer`-cleanup removes it.
        if let data = try? RealFileStore().read(argv[2]) {
            capturedContents = String(decoding: data, as: UTF8.self)
        }
    }
    let rootDir = makeTempDir("fwenv-contents")
    let fwEnv = FwEnv(commandRunner: cmd, fileStore: RealFileStore(), rootDir: rootDir)

    try fwEnv.set(["wendyos_boot_slot": "1", "bootcount": "0"])

    #expect(capturedContents.contains("wendyos_boot_slot=1\n"))
    #expect(capturedContents.contains("bootcount=0\n"))
}

@Test func fwEnvSetRemovesTheScriptFileAfterFwSetenvReturns() throws {
    let cmd = FakeUBootCommandRunner()
    var capturedPath = ""
    cmd.onRun = { argv in capturedPath = argv[2] }
    let rootDir = makeTempDir("fwenv-cleanup")
    let fwEnv = FwEnv(commandRunner: cmd, fileStore: RealFileStore(), rootDir: rootDir)

    try fwEnv.set(["bootcount": "0"])

    #expect(!capturedPath.isEmpty)
    #expect(!RealFileStore().exists(capturedPath), "the scratch script must be removed once fw_setenv has run")
}

@Test func fwEnvSetPropagatesAFwSetenvFailure() {
    let cmd = FakeUBootCommandRunner()
    cmd.result = CommandResult(exitCode: 1, stdout: Array("boom".utf8), stderr: [])
    let rootDir = makeTempDir("fwenv-fail")
    let fwEnv = FwEnv(commandRunner: cmd, fileStore: RealFileStore(), rootDir: rootDir)

    #expect(throws: (any Error).self) { try fwEnv.set(["bootcount": "0"]) }
}
