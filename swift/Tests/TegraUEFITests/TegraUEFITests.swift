import Connector
import Glibc
import PlatformIO
import PlatformIOTesting
import Testing

@testable import TegraUEFI

// Ports the `Controller`-level scenarios from
// `internal/connector/tegrauefi/tegrauefi_test.go` and
// `internal/connector/tegrauefi/verify_test.go`'s `TestBootIsCompromised`.
//
// `efivarsDir` is a REAL temp directory (matching `EfiVarTests`' own
// convention and Go's `testController`, which does the same via
// `t.TempDir()`) — `prepareTarget`/`bootIsCompromised`/`preflightInstall`/
// `confirmBoot`'s efivar reads go through `EfiVar`'s real-path primitives,
// not the injectable `FileStore` seam. `rootDir` is a plain (non-existent)
// string prefix: everything under it is resolved through the injected
// `FakeFileStore`, which needs no real filesystem at all.

func makeTempDir(_ tag: String) -> String {
    let path = "/tmp/tegrauefi-test-\(getpid())-\(tag)-\(Int.random(in: 0..<1_000_000))"
    let rc = path.withCString { Glibc.mkdir($0, 0o755) }
    #expect(rc == 0, "failed to create temp dir \(path), errno \(errno)")
    return path
}

@discardableResult
func writeFile(_ path: String, _ contents: [UInt8]) -> Int32 {
    let fd = path.withCString { Glibc.open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
    #expect(fd >= 0, "failed to create fixture file \(path), errno \(errno)")
    contents.withUnsafeBytes { buf in
        let written = Glibc.write(fd, buf.baseAddress, buf.count)
        #expect(written == contents.count)
    }
    Glibc.close(fd)
    return fd
}

func readEfivarBytes(_ path: String) -> [UInt8] {
    let fd = Glibc.open(path, O_RDONLY)
    #expect(fd >= 0, "failed to open \(path) for verification, errno \(errno)")
    defer { Glibc.close(fd) }
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64)
    while true {
        let n = chunk.withUnsafeMutableBytes { buf in Glibc.read(fd, buf.baseAddress, buf.count) }
        if n <= 0 { break }
        out.append(contentsOf: chunk[0..<n])
    }
    return out
}

/// Builds a `TegraUEFI` wired to a real temp `efivarsDir`, a fake
/// `commandRunner`, and a fake `fileStore`. Mounters default to
/// `fatalError` traps: none of the `TegraUEFITests` scenarios (current
/// slot, partition resolution, prepare-target, boot-health, preflight,
/// confirm-boot, detect) should ever mount anything — only `SwapSlot`
/// (tested separately in `SwapSlotTests.swift`) does.
func makeConnector(
    rootDir: String = "/rootdir",
    mountRootfs: @escaping RootfsMounter = { _ in fatalError("mountRootfs must not be called by this test") },
    mountESP: @escaping EspMounter = { _ in fatalError("mountESP must not be called by this test") }
) -> (conn: TegraUEFI, cmd: FakeTegraCommandRunner, files: FakeFileStore, efivarsDir: String) {
    let efivarsDir = makeTempDir("efivars")
    let cmd = FakeTegraCommandRunner()
    let files = FakeFileStore()
    let conn = TegraUEFI(
        nvbootctrl: "nvbootctrl",
        efivarsDir: efivarsDir,
        rootDir: rootDir,
        commandRunner: cmd,
        fileStore: files,
        mountRootfs: mountRootfs,
        mountESP: mountESP
    )
    return (conn, cmd, files, efivarsDir)
}

// MARK: - CurrentSlot (ports TestCurrentSlot)

struct CurrentSlotCase: Sendable {
    let out: String
    let want: Slot
    let wantsError: Bool
}

private let currentSlotCases: [CurrentSlotCase] = [
    .init(out: "0\n", want: .a, wantsError: false),
    .init(out: "1\n", want: .b, wantsError: false),
    .init(out: "2\n", want: .a, wantsError: true),
    .init(out: "garbage", want: .a, wantsError: true),
]

@Test(arguments: currentSlotCases)
func currentSlotParsesTrailingDigitOrThrows(_ tc: CurrentSlotCase) throws {
    let (conn, cmd, _, _) = makeConnector()
    cmd.script(containing: "get-current-slot", stdout: tc.out)

    if tc.wantsError {
        #expect(throws: TegraUEFIError.self) { try conn.currentSlot() }
    } else {
        #expect(try conn.currentSlot() == tc.want)
    }
}

// MARK: - PartitionFor (new coverage: Go has no direct unit test for this)

@Test func partitionForResolvesViaByPartlabelSymlink() throws {
    let (conn, _, files, _) = makeConnector()
    files.symlink("/rootdir/dev/disk/by-partlabel/APP", to: "/dev/nvme0n1p1")
    files.symlink("/rootdir/dev/disk/by-partlabel/APP_b", to: "/dev/nvme0n1p2")

    #expect(try conn.partition(for: .a) == "/dev/nvme0n1p1")
    #expect(try conn.partition(for: .b) == "/dev/nvme0n1p2")
}

@Test func partitionForFallsBackToLsblkScanWhenNoSymlink() throws {
    let (conn, cmd, _, _) = makeConnector()
    cmd.script(
        when: { $0.first == "lsblk" },
        result: CommandResult(
            exitCode: 0,
            stdout: Array("/dev/nvme0n1p1 APP\n/dev/nvme0n1p2 APP_b\n".utf8),
            stderr: []
        )
    )

    #expect(try conn.partition(for: .a) == "/dev/nvme0n1p1")
    #expect(try conn.partition(for: .b) == "/dev/nvme0n1p2")
}

@Test func partitionForFallsBackToPartuuidFromNvBootControlConf() throws {
    let (conn, _, files, _) = makeConnector()
    try files.writeAtomic(
        "/rootdir/etc/nv_boot_control.conf",
        Array("ROOTFS_PARTUUID_A abc-123\nROOTFS_PARTUUID_B def-456\n".utf8),
        mode: 0o644
    )
    files.symlink("/rootdir/dev/disk/by-partuuid/abc-123", to: "/dev/nvme0n1p1")
    files.symlink("/rootdir/dev/disk/by-partuuid/def-456", to: "/dev/nvme0n1p2")

    #expect(try conn.partition(for: .a) == "/dev/nvme0n1p1")
    #expect(try conn.partition(for: .b) == "/dev/nvme0n1p2")
}

@Test func partitionForThrowsWhenAllTiersFail() {
    let (conn, _, _, _) = makeConnector()
    #expect(throws: TegraUEFIError.self) { try conn.partition(for: .a) }
}

@Test func partitionForPrefersByPartlabelOverLsblkAndPartuuid() throws {
    // Tier ordering: a working by-partlabel symlink must win even if
    // lsblk/nv_boot_control.conf are also (differently) populated.
    let (conn, cmd, files, _) = makeConnector()
    files.symlink("/rootdir/dev/disk/by-partlabel/APP", to: "/dev/tier1")
    cmd.script(
        when: { $0.first == "lsblk" },
        result: CommandResult(exitCode: 0, stdout: Array("/dev/tier2 APP\n".utf8), stderr: [])
    )

    #expect(try conn.partition(for: .a) == "/dev/tier1")
}

// MARK: - PrepareTarget (ports TestPrepareTarget*)

@Test func prepareTargetToleratesMissingVar() throws {
    let (conn, _, _, _) = makeConnector()
    try conn.prepareTarget(.b)  // must not throw
}

@Test func prepareTargetLeavesAnAlreadyNormalVarUnchanged() throws {
    let (conn, _, _, efivarsDir) = makeConnector()
    let path = "\(efivarsDir)/RootfsStatusSlotB-781e084c-a330-417c-b678-38e696380cb9"
    let seeded: [UInt8] = [0x07, 0, 0, 0, 0, 0, 0, 0]
    writeFile(path, seeded)

    try conn.prepareTarget(.b)

    #expect(readEfivarBytes(path) == seeded)
}

@Test func prepareTargetResetsAnUnbootableVarToNormal() throws {
    let (conn, _, _, efivarsDir) = makeConnector()
    let path = "\(efivarsDir)/RootfsStatusSlotB-781e084c-a330-417c-b678-38e696380cb9"
    writeFile(path, [0x07, 0, 0, 0, 0xFF, 0, 0, 0])

    try conn.prepareTarget(.b)

    #expect(EfiVar.statusIsNormal(readEfivarBytes(path)))
}

@Test func prepareTargetFixesAWrongSizedVar() throws {
    let (conn, _, _, efivarsDir) = makeConnector()
    let path = "\(efivarsDir)/RootfsStatusSlotA-781e084c-a330-417c-b678-38e696380cb9"
    writeFile(path, [0x07, 0, 0, 0, 0])  // 5 bytes: the JP6 wrong-sized incident

    try conn.prepareTarget(.a)

    #expect(EfiVar.statusIsNormal(readEfivarBytes(path)))
}

// MARK: - BootIsCompromised (ports verify_test.go's TestBootIsCompromised)

private let bootHealthNormal: [UInt8] = [0x07, 0, 0, 0, 0, 0, 0, 0]
private let bootHealthUnbootable: [UInt8] = [0x07, 0, 0, 0, 0xFF, 0, 0, 0]

@Test func bootIsCompromisedFalseWhenNoStatusVarForBootedSlot() throws {
    let (conn, cmd, _, _) = makeConnector()
    cmd.script(containing: "get-current-slot", stdout: "0\n")

    #expect(try conn.bootIsCompromised() == false)
}

@Test func bootIsCompromisedFalseWhenBootedSlotNormal() throws {
    let (conn, cmd, _, efivarsDir) = makeConnector()
    cmd.script(containing: "get-current-slot", stdout: "0\n")
    writeFile("\(efivarsDir)/RootfsStatusSlotA-781e084c-a330-417c-b678-38e696380cb9", bootHealthNormal)
    writeFile("\(efivarsDir)/RootfsStatusSlotB-781e084c-a330-417c-b678-38e696380cb9", bootHealthNormal)

    #expect(try conn.bootIsCompromised() == false)
}

/// WDY-1742 regression: a stale 0xFF left on the INACTIVE slot must not
/// flag a healthy boot of the active slot.
@Test func bootIsCompromisedIgnoresStaleUnbootableOnInactiveSlot() throws {
    let (conn, cmd, _, efivarsDir) = makeConnector()
    cmd.script(containing: "get-current-slot", stdout: "0\n")  // booted A
    writeFile("\(efivarsDir)/RootfsStatusSlotA-781e084c-a330-417c-b678-38e696380cb9", bootHealthNormal)
    writeFile("\(efivarsDir)/RootfsStatusSlotB-781e084c-a330-417c-b678-38e696380cb9", bootHealthUnbootable)

    #expect(try conn.bootIsCompromised() == false)
}

@Test func bootIsCompromisedTrueWhenBootedSlotUnbootable() throws {
    let (conn, cmd, _, efivarsDir) = makeConnector()
    cmd.script(containing: "get-current-slot", stdout: "1\n")  // booted B
    writeFile("\(efivarsDir)/RootfsStatusSlotB-781e084c-a330-417c-b678-38e696380cb9", bootHealthUnbootable)

    #expect(try conn.bootIsCompromised() == true)
}

/// WDY-1742: an unvalidated size is inconclusive, not compromised.
@Test func bootIsCompromisedInconclusiveForWrongSizedVar() throws {
    let (conn, cmd, _, efivarsDir) = makeConnector()
    cmd.script(containing: "get-current-slot", stdout: "1\n")  // booted B
    writeFile("\(efivarsDir)/RootfsStatusSlotB-781e084c-a330-417c-b678-38e696380cb9", [0x07, 0, 0, 0])

    #expect(try conn.bootIsCompromised() == false)
}

// MARK: - PreflightInstall (ports TestPreflightInstallRefuses/Passes)

private let redundancyArmed: [UInt8] = [0x07, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]
private let redundancyZeroLevel: [UInt8] = [0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

@Test func preflightInstallRefusesWhenRedundancyVarMissing() throws {
    let (conn, _, _, _) = makeConnector()

    #expect(throws: TegraUEFIError.self) { try conn.preflightInstall() }
    do {
        try conn.preflightInstall()
    } catch let error as TegraUEFIError {
        #expect("\(error)".contains("RootfsRedundancyLevel"))
    }
}

@Test func preflightInstallRefusesWhenRedundancyLevelIsZero() throws {
    let (conn, _, _, efivarsDir) = makeConnector()
    writeFile("\(efivarsDir)/RootfsRedundancyLevel-781e084c-a330-417c-b678-38e696380cb9", redundancyZeroLevel)

    #expect(throws: TegraUEFIError.self) { try conn.preflightInstall() }
}

@Test func preflightInstallPassesWhenRedundancyArmed() throws {
    let (conn, _, _, efivarsDir) = makeConnector()
    writeFile("\(efivarsDir)/RootfsRedundancyLevel-781e084c-a330-417c-b678-38e696380cb9", redundancyArmed)

    try conn.preflightInstall()  // must not throw
}

// MARK: - ConfirmBoot (ports TestConfirmBootRunsMarkBootSuccessful)

@Test func confirmBootRunsMarkBootSuccessful() throws {
    let (conn, cmd, _, _) = makeConnector()

    try conn.confirmBoot()

    #expect(cmd.ranCommand(containing: "-t rootfs mark-boot-successful"))
}

@Test func confirmBootThrowsOnNonZeroExit() {
    let (conn, cmd, _, _) = makeConnector()
    cmd.script(containing: "mark-boot-successful", stdout: "nope", exitCode: 1)

    #expect(throws: TegraUEFIError.self) { try conn.confirmBoot() }
}

// MARK: - detect (factory)

@Test func factoryNameIsTegrauefi() {
    #expect(TegraUEFI.factory.name == "tegrauefi")
}

@Test func detectFalseWhenNvbootctrlNotOnPath() {
    // The sandboxed test environment has no `nvbootctrl` on PATH, so the
    // real `detect()` (which does a real `PATH` scan) must report false —
    // pinning that a hardware-only tool never appears "detected" while
    // running in CI/dev.
    #expect(TegraUEFI.factory.detect() == false)
}
