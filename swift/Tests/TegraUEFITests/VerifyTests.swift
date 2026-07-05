import Connector
import Glibc
import PlatformIO
import PlatformIOTesting
import Testing

@testable import TegraUEFI

// Ports `internal/connector/tegrauefi/verify_test.go`'s
// `VerifyPlatformUpdate` cascade cases (`TestVerifyPlatformUpdate*`).
// `TestBootIsCompromised` was already ported into `TegraUEFITests.swift`
// (Task 8.2). `AbortPlatformUpdate` has no direct Go unit test — the cases
// below are new coverage, matching `verify.go`'s documented no-op/staged
// semantics.
//
// Unlike Go's `testController` (which points `RootDir` at a real temp
// directory), the marker/version/ESRT files here go through the injected
// `FakeFileStore` — `rootDir` is a plain string prefix, matching this
// suite's existing `makeConnector()` convention.

/// Seeds the marker file (source of truth for "a bootloader update was
/// part of this deployment") plus optional saved pre-update version and
/// ESRT status content. Ports `verify_test.go`'s `verifySetup`.
private func verifySetup(
    files: FakeFileStore,
    rootDir: String,
    savedVersion: String? = nil,
    esrtStatus: String? = nil
) throws {
    try files.writeAtomic(rootDir + TegraUEFI.markerPath, [], mode: 0o644)
    if let savedVersion {
        try files.writeAtomic(
            rootDir + "/data/wendyos-update/bl-version-before",
            Array((savedVersion + "\n").utf8),
            mode: 0o644
        )
    }
    if let esrtStatus {
        try files.writeAtomic(
            rootDir + TegraUEFI.esrtStatusPath,
            Array((esrtStatus + "\n").utf8),
            mode: 0o644
        )
    }
}

/// Scripts `nvbootctrl dump-slots-info` to report the given bootloader
/// version, matching `verify_test.go`'s `dumpSlotsInfoFake`.
private func scriptBootloaderVersion(_ cmd: FakeTegraCommandRunner, _ version: String) {
    cmd.script(containing: "dump-slots-info", stdout: "Current version: \(version)\nCapsule update status: 1\n")
}

// MARK: - VerifyPlatformUpdate (ports TestVerifyPlatformUpdate*)

@Test func verifyPlatformUpdateNoMarkerSkipsSilently() throws {
    let (conn, _, _, _) = makeConnector()
    try conn.verifyPlatformUpdate(bootloaderUpdate: false)  // must not throw
}

@Test func verifyPlatformUpdatePassesWhenVersionChanged() throws {
    let (conn, cmd, files, _) = makeConnector()
    scriptBootloaderVersion(cmd, "38.5.0")
    try verifySetup(files: files, rootDir: "/rootdir", savedVersion: "38.4.0")

    try conn.verifyPlatformUpdate(bootloaderUpdate: true)

    #expect(!files.exists("/rootdir/data/wendyos-update/bl-version-before"))
}

@Test func verifyPlatformUpdatePassesWhenSameVersionAndESRTSuccess() throws {
    let (conn, cmd, files, _) = makeConnector()
    scriptBootloaderVersion(cmd, "38.4.0")
    try verifySetup(files: files, rootDir: "/rootdir", savedVersion: "38.4.0", esrtStatus: "0")

    try conn.verifyPlatformUpdate(bootloaderUpdate: true)  // must not throw
}

@Test func verifyPlatformUpdateFailsOnESRTNvidiaCheckImageFail() throws {
    let (conn, cmd, files, _) = makeConnector()
    scriptBootloaderVersion(cmd, "38.4.0")
    try verifySetup(files: files, rootDir: "/rootdir", savedVersion: "38.4.0", esrtStatus: "6163")

    #expect(throws: TegraUEFIError.self) { try conn.verifyPlatformUpdate(bootloaderUpdate: true) }
    do {
        try conn.verifyPlatformUpdate(bootloaderUpdate: true)
        Issue.record("expected an error")
    } catch let error as TegraUEFIError {
        #expect("\(error)".contains("6163"))
    }
}

@Test func verifyPlatformUpdateFailsOnESRTSKUMismatch() throws {
    let (conn, cmd, files, _) = makeConnector()
    scriptBootloaderVersion(cmd, "38.4.0")
    try verifySetup(files: files, rootDir: "/rootdir", savedVersion: "38.4.0", esrtStatus: "6164")

    do {
        try conn.verifyPlatformUpdate(bootloaderUpdate: true)
        Issue.record("expected an error")
    } catch let error as TegraUEFIError {
        #expect("\(error)".contains("6164"))
    }
}

@Test func verifyPlatformUpdateFailsOnESRTStandardError() throws {
    let (conn, cmd, files, _) = makeConnector()
    scriptBootloaderVersion(cmd, "38.4.0")
    try verifySetup(files: files, rootDir: "/rootdir", savedVersion: "38.4.0", esrtStatus: "4")

    #expect(throws: TegraUEFIError.self) { try conn.verifyPlatformUpdate(bootloaderUpdate: true) }
}

@Test func verifyPlatformUpdateFailsOnESRTVendorRangeError() throws {
    let (conn, cmd, files, _) = makeConnector()
    scriptBootloaderVersion(cmd, "38.4.0")
    try verifySetup(files: files, rootDir: "/rootdir", savedVersion: "38.4.0", esrtStatus: "4096")  // 0x1000

    do {
        try conn.verifyPlatformUpdate(bootloaderUpdate: true)
        Issue.record("expected an error")
    } catch let error as TegraUEFIError {
        #expect("\(error)".contains("4096"))
        #expect("\(error)".contains("vendor"))
    }
}

/// New coverage: Go's own switch has an unparseable-ESRT branch
/// (`strconv.Atoi` failure) with no dedicated unit test.
@Test func verifyPlatformUpdateThrowsOnUnparseableESRTStatus() throws {
    let (conn, cmd, files, _) = makeConnector()
    scriptBootloaderVersion(cmd, "38.4.0")
    try verifySetup(files: files, rootDir: "/rootdir", savedVersion: "38.4.0", esrtStatus: "garbage")

    do {
        try conn.verifyPlatformUpdate(bootloaderUpdate: true)
        Issue.record("expected an error")
    } catch let error as TegraUEFIError {
        #expect("\(error)".contains("unparseable"))
        #expect("\(error)".contains("garbage"))
    }
}

@Test func verifyPlatformUpdateFallsBackToBootSuccessWhenNoVersionOrESRT() throws {
    let (conn, cmd, files, _) = makeConnector()
    scriptBootloaderVersion(cmd, "38.4.0")
    try verifySetup(files: files, rootDir: "/rootdir")  // no saved version, no ESRT

    try conn.verifyPlatformUpdate(bootloaderUpdate: true)  // must not throw
}

/// An unknown (not 0, not 1-6, not one of the NVIDIA codes/range) ESRT
/// status also falls back to boot-success, per `verify.go`'s `default:`
/// case.
@Test func verifyPlatformUpdateFallsBackToBootSuccessOnUnknownESRTStatus() throws {
    let (conn, cmd, files, _) = makeConnector()
    scriptBootloaderVersion(cmd, "38.4.0")
    try verifySetup(files: files, rootDir: "/rootdir", savedVersion: "38.4.0", esrtStatus: "99999")

    try conn.verifyPlatformUpdate(bootloaderUpdate: true)  // must not throw
}

// MARK: - AbortPlatformUpdate (new coverage: no direct Go unit test)

@Test func abortPlatformUpdateIsANoOpWhenNothingIsStaged() throws {
    let (conn, cmd, files, efivarsDir) = makeConnector(
        mountESP: { _ in fatalError("must not mount the ESP when nothing needs staging") }
    )
    // findmnt /boot/efi resolves so espMountpoint() doesn't try to mount.
    cmd.script(when: { $0.first == "findmnt" }, result: CommandResult(exitCode: 0, stdout: Array("/boot/efi\n".utf8), stderr: []))

    try conn.abortPlatformUpdate()  // must not throw

    _ = files
    let osIndicationsPath = "\(efivarsDir)/OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    #expect(osIndicationsPath.withCString { Glibc.access($0, F_OK) != 0 })
}

@Test func abortPlatformUpdateRemovesStagedCapsuleAndClearsOsIndications() throws {
    let (conn, cmd, files, efivarsDir) = makeConnector()
    cmd.script(when: { $0.first == "findmnt" }, result: CommandResult(exitCode: 0, stdout: Array("/mnt/esp\n".utf8), stderr: []))
    try files.writeAtomic("/mnt/esp/EFI/UpdateCapsule/TEGRA_BL.Cap", Array("capsule-bytes".utf8), mode: 0o644)
    try files.writeAtomic("/rootdir/data/wendyos-update/bl-version-before", Array("38.4.0\n".utf8), mode: 0o644)

    let osIndicationsPath = "\(efivarsDir)/OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    // Armed: attrs(0x07) + UINT64 with the capsule-processing bit (0x04) set.
    writeFile(osIndicationsPath, [0x07, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

    try conn.abortPlatformUpdate()

    #expect(!files.exists("/mnt/esp/EFI/UpdateCapsule/TEGRA_BL.Cap"))
    let osIndications = readEfivarBytes(osIndicationsPath)
    #expect(osIndications[4] & 0x04 == 0)
    // Staged: bl-version-before is also cleaned up.
    #expect(!files.exists("/rootdir/data/wendyos-update/bl-version-before"))
}

@Test func abortPlatformUpdateClearsOsIndicationsEvenWhenNoCapsuleStaged() throws {
    let (conn, cmd, _, efivarsDir) = makeConnector()
    cmd.script(when: { $0.first == "findmnt" }, result: CommandResult(exitCode: 0, stdout: Array("/mnt/esp\n".utf8), stderr: []))
    // No capsule file staged on the ESP.

    let osIndicationsPath = "\(efivarsDir)/OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    writeFile(osIndicationsPath, [0x07, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

    try conn.abortPlatformUpdate()

    let osIndications = readEfivarBytes(osIndicationsPath)
    #expect(osIndications[4] & 0x04 == 0)
}

@Test func abortPlatformUpdatePreservesOtherOsIndicationsBits() throws {
    let (conn, cmd, _, efivarsDir) = makeConnector()
    cmd.script(when: { $0.first == "findmnt" }, result: CommandResult(exitCode: 0, stdout: Array("/mnt/esp\n".utf8), stderr: []))

    let osIndicationsPath = "\(efivarsDir)/OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    // Bit 0 (0x01, "boot to firmware UI") set alongside the capsule bit.
    writeFile(osIndicationsPath, [0x07, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

    try conn.abortPlatformUpdate()

    let osIndications = readEfivarBytes(osIndicationsPath)
    #expect(osIndications[4] & 0x04 == 0)  // capsule bit cleared
    #expect(osIndications[4] & 0x01 != 0)  // other bit preserved
}
