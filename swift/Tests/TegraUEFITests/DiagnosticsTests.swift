import Connector
import Glibc
import PlatformIO
import PlatformIOTesting
import Testing

@testable import TegraUEFI

// Ports the shape of `internal/connector/tegrauefi/diagnostics.go`'s
// `Diagnostics`/`SlotStatus`/`SystemStatus`. Go has no `diagnostics_test.go`
// — this is new coverage designed directly against the source, pinning the
// exact key names, the verbose/non-verbose boundary, best-effort omission
// of unreadable items, and `systemStatus`'s KV order.
//
// Reuses `makeConnector`/`writeFile`/`makeTempDir`/`readEfivarBytes` from
// `TegraUEFITests.swift` and the vendor/global GUID constants inline
// (matching that file's convention of spelling efivar filenames out in
// full rather than referencing `TegraUEFI.vendorGUID` from the test body).

private let vendorGUID = "781e084c-a330-417c-b678-38e696380cb9"
private let efiGlobalGUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"

/// Scripts the BOOTLOADER view (`nvbootctrl dump-slots-info`, no `-t
/// rootfs`) — distinct argv from the rootfs view so both can be scripted
/// independently in the same test.
private func scriptBootloaderDumpSlotsInfo(_ cmd: FakeTegraCommandRunner, _ stdout: String) {
    cmd.script(when: { $0 == ["nvbootctrl", "dump-slots-info"] }, result: CommandResult(exitCode: 0, stdout: Array(stdout.utf8), stderr: []))
}

/// Scripts the ROOTFS view (`nvbootctrl -t rootfs dump-slots-info`),
/// which carries `retry_count` (the bootloader view does not).
private func scriptRootfsDumpSlotsInfo(_ cmd: FakeTegraCommandRunner, _ stdout: String, exitCode: Int32 = 0) {
    cmd.script(
        when: { $0 == ["nvbootctrl", "-t", "rootfs", "dump-slots-info"] },
        result: CommandResult(exitCode: exitCode, stdout: Array(stdout.utf8), stderr: [])
    )
}

private let bootloaderDumpFixture = """
    Current version: 1.2.3
    Current bootloader slot: A
    num of slots: 2
    slot: 0,\tstatus: normal
    slot: 1,\tstatus: normal
    """

private let rootfsDumpFixture = """
    Current rootfs slot: A
    num of slots: 2
    slot: 0, retry_count: 3, status: normal
    slot: 1, retry_count: 1, status: unbootable
    """

// MARK: - diagnostics (non-verbose)

@Test func diagnosticsReportsSlotBootloaderESRTAndPerSlotHealth() throws {
    let (conn, cmd, files, efivarsDir) = makeConnector()
    cmd.script(containing: "get-current-slot", stdout: "0\n")
    scriptBootloaderDumpSlotsInfo(cmd, bootloaderDumpFixture)

    try files.writeAtomic("/rootdir/sys/firmware/efi/esrt/entries/entry0/last_attempt_status", Array("0\n".utf8), mode: 0o644)
    try files.writeAtomic("/rootdir/sys/firmware/efi/esrt/entries/entry0/fw_version", Array("10\n".utf8), mode: 0o644)
    try files.writeAtomic("/rootdir/sys/firmware/efi/esrt/entries/entry0/lowest_supported_fw_version", Array("5\n".utf8), mode: 0o644)

    writeFile("\(efivarsDir)/RootfsStatusSlotA-\(vendorGUID)", [0x07, 0, 0, 0, 0, 0, 0, 0])
    writeFile("\(efivarsDir)/RootfsStatusSlotB-\(vendorGUID)", [0x07, 0, 0, 0, 0xFF, 0, 0, 0])
    writeFile("\(efivarsDir)/RootfsRedundancyLevel-\(vendorGUID)", [0x07, 0, 0, 0, 0x01, 0, 0, 0])

    let d = conn.diagnostics(verbose: false)

    #expect(
        d == [
            "rootfs_slot": "A",
            "bootloader_version": "1.2.3",
            "bootloader_slot": "A",
            "esrt_last_attempt_status": "0",
            "esrt_fw_version": "10",
            "esrt_lowest_supported_version": "5",
            "rootfs_status_A": "normal",
            "rootfs_status_B": "unbootable",
            "rootfs_redundancy": "armed",
        ]
    )
}

@Test func diagnosticsOmitsUnreadableItemsButReportsRedundancyNotArmed() {
    // No scripted commands, no efivars, no ESRT files: every probe fails
    // to read something, yet `diagnostics` never errors — it just leaves
    // the corresponding key out. `rootfs_redundancy` is the one
    // exception: a MISSING RootfsRedundancyLevel var is itself the
    // definitive "not armed" answer (not a read failure), so it is always
    // present.
    let (conn, _, _, _) = makeConnector()

    let d = conn.diagnostics(verbose: false)

    #expect(d == ["rootfs_redundancy": "NOT ARMED (RootfsRedundancyLevel missing/zero — slot switch is a no-op)"])
}

@Test func diagnosticsRedundancyZeroLevelReportsNotArmed() throws {
    let (conn, _, _, efivarsDir) = makeConnector()
    writeFile("\(efivarsDir)/RootfsRedundancyLevel-\(vendorGUID)", [0x07, 0, 0, 0, 0, 0, 0, 0])

    let d = conn.diagnostics(verbose: false)

    #expect(d["rootfs_redundancy"] == "NOT ARMED (RootfsRedundancyLevel missing/zero — slot switch is a no-op)")
}

// MARK: - diagnostics (verbose)

@Test func diagnosticsVerboseAddsRawSlotEfiSnapshot() throws {
    let (conn, cmd, _, efivarsDir) = makeConnector()
    cmd.script(containing: "get-current-slot", stdout: "0\n")
    scriptBootloaderDumpSlotsInfo(cmd, bootloaderDumpFixture)

    writeFile("\(efivarsDir)/RootfsStatusSlotA-\(vendorGUID)", [0x07, 0, 0, 0, 0, 0, 0, 0])
    writeFile("\(efivarsDir)/RootfsStatusSlotB-\(vendorGUID)", [0x07, 0, 0, 0, 0xFF, 0, 0, 0])
    writeFile("\(efivarsDir)/BootChainFwCurrent-\(vendorGUID)", [0x07, 0, 0, 0, 0x01, 0, 0, 0])
    writeFile("\(efivarsDir)/BootChainFwNext-\(vendorGUID)", [0x07, 0, 0, 0, 0x02, 0, 0, 0])
    writeFile("\(efivarsDir)/OsIndications-\(efiGlobalGUID)", [0x07, 0, 0, 0, 0x04, 0, 0, 0, 0, 0, 0, 0])

    let d = conn.diagnostics(verbose: true)

    #expect(d["rootfs_status_A_raw"] == "07 00 00 00 00 00 00 00")
    #expect(d["rootfs_status_B_raw"] == "07 00 00 00 ff 00 00 00")
    #expect(d["bootloader_slot_0"] == "status: normal")
    #expect(d["bootloader_slot_1"] == "status: normal")
    #expect(d["bootchainfwcurrent"] == "01 00 00 00")
    #expect(d["bootchainfwnext"] == "02 00 00 00")
    #expect(d["osindications"] == "07 00 00 00 04 00 00 00 00 00 00 00 (capsule_armed=true)")
}

@Test func diagnosticsVerboseOmitsCapsuleArmedWhenBitClear() throws {
    let (conn, _, _, efivarsDir) = makeConnector()
    writeFile("\(efivarsDir)/OsIndications-\(efiGlobalGUID)", [0x07, 0, 0, 0, 0x00, 0, 0, 0, 0, 0, 0, 0])

    let d = conn.diagnostics(verbose: true)

    #expect(d["osindications"] == "07 00 00 00 00 00 00 00 00 00 00 00 (capsule_armed=false)")
}

@Test func diagnosticsNonVerboseOmitsRawSnapshotKeys() throws {
    let (conn, cmd, _, efivarsDir) = makeConnector()
    cmd.script(containing: "get-current-slot", stdout: "0\n")
    scriptBootloaderDumpSlotsInfo(cmd, bootloaderDumpFixture)
    writeFile("\(efivarsDir)/RootfsStatusSlotA-\(vendorGUID)", [0x07, 0, 0, 0, 0, 0, 0, 0])
    writeFile("\(efivarsDir)/BootChainFwCurrent-\(vendorGUID)", [0x07, 0, 0, 0, 0x01, 0, 0, 0])
    writeFile("\(efivarsDir)/OsIndications-\(efiGlobalGUID)", [0x07, 0, 0, 0, 0x04, 0, 0, 0, 0, 0, 0, 0])

    let d = conn.diagnostics(verbose: false)

    #expect(d["rootfs_status_A_raw"] == nil)
    #expect(d["bootloader_slot_0"] == nil)
    #expect(d["bootchainfwcurrent"] == nil)
    #expect(d["osindications"] == nil)
}

@Test func diagnosticsVerboseOmitsBootChainFwAndOsIndicationsWhenMissing() {
    // No BootChainFw*/OsIndications efivars seeded: verbose must not
    // crash and must simply omit those keys.
    let (conn, _, _, _) = makeConnector()

    let d = conn.diagnostics(verbose: true)

    #expect(d["osindications"] == nil)
    #expect(d.keys.contains { $0.hasPrefix("bootchainfw") } == false)
}

// MARK: - slotStatus

@Test func slotStatusReportsNormalFromEfivarWithNoRetryInfo() {
    let (conn, _, _, efivarsDir) = makeConnector()
    writeFile("\(efivarsDir)/RootfsStatusSlotA-\(vendorGUID)", [0x07, 0, 0, 0, 0, 0, 0, 0])

    let st = conn.slotStatus(.a)

    #expect(st.rootfsHealth == "normal")
    #expect(st.retries == "")
    #expect(st.note == "")
}

@Test func slotStatusReportsUnbootableFromEfivar() {
    let (conn, _, _, efivarsDir) = makeConnector()
    writeFile("\(efivarsDir)/RootfsStatusSlotB-\(vendorGUID)", [0x07, 0, 0, 0, 0xFF, 0, 0, 0])

    let st = conn.slotStatus(.b)

    #expect(st.rootfsHealth == "unbootable")
}

@Test func slotStatusAddsRetriesFromNvbootctrlAlongsideEfivarHealth() {
    let (conn, cmd, _, efivarsDir) = makeConnector()
    writeFile("\(efivarsDir)/RootfsStatusSlotA-\(vendorGUID)", [0x07, 0, 0, 0, 0, 0, 0, 0])
    scriptRootfsDumpSlotsInfo(cmd, rootfsDumpFixture)

    let st = conn.slotStatus(.a)

    // efivar wins for health ("normal"); nvbootctrl supplies retries.
    #expect(st.rootfsHealth == "normal")
    #expect(st.retries == "3")
}

@Test func slotStatusFallsBackToNvbootctrlStatusWhenEfivarUnreadable() {
    let (conn, cmd, _, _) = makeConnector()
    // No RootfsStatusSlotB efivar written at all.
    scriptRootfsDumpSlotsInfo(cmd, rootfsDumpFixture)

    let st = conn.slotStatus(.b)

    #expect(st.rootfsHealth == "unbootable")  // from nvbootctrl, since efivar is unreadable
    #expect(st.retries == "1")
}

@Test func slotStatusEmptyWhenNothingIsReadable() {
    let (conn, cmd, _, _) = makeConnector()
    scriptRootfsDumpSlotsInfo(cmd, "", exitCode: 1)  // command failure: rootfsSlotInfo returns nil

    let st = conn.slotStatus(.a)

    #expect(st.rootfsHealth == "")
    #expect(st.retries == "")
    #expect(st.note == "")
}

// MARK: - systemStatus

@Test func systemStatusOrdersBootloaderVersionThenCapsuleStatus() throws {
    let (conn, cmd, files, _) = makeConnector()
    scriptBootloaderDumpSlotsInfo(cmd, bootloaderDumpFixture)
    try files.writeAtomic("/rootdir/sys/firmware/efi/esrt/entries/entry0/last_attempt_status", Array("0\n".utf8), mode: 0o644)

    let kv = conn.systemStatus()

    #expect(kv.count == 2)
    #expect(kv[0].key == "bootloader version")
    #expect(kv[0].value == "1.2.3")
    #expect(kv[1].key == "last capsule status")
    #expect(kv[1].value == "0 (success)")
}

@Test func systemStatusReportsRawNonZeroCapsuleStatusWithoutSuccessSuffix() throws {
    let (conn, cmd, files, _) = makeConnector()
    scriptBootloaderDumpSlotsInfo(cmd, bootloaderDumpFixture)
    try files.writeAtomic("/rootdir/sys/firmware/efi/esrt/entries/entry0/last_attempt_status", Array("6163\n".utf8), mode: 0o644)

    let kv = conn.systemStatus()

    #expect(kv.last?.key == "last capsule status")
    #expect(kv.last?.value == "6163")
}

@Test func systemStatusOmitsBootloaderVersionWhenDumpHasNoCurrentVersionLine() throws {
    let (conn, cmd, files, _) = makeConnector()
    scriptBootloaderDumpSlotsInfo(cmd, "num of slots: 2\n")
    try files.writeAtomic("/rootdir/sys/firmware/efi/esrt/entries/entry0/last_attempt_status", Array("0\n".utf8), mode: 0o644)

    let kv = conn.systemStatus()

    #expect(kv.count == 1)
    #expect(kv[0].key == "last capsule status")
}

@Test func systemStatusOmitsCapsuleStatusWhenESRTUnreadable() {
    let (conn, cmd, _, _) = makeConnector()
    scriptBootloaderDumpSlotsInfo(cmd, bootloaderDumpFixture)

    let kv = conn.systemStatus()

    #expect(kv.count == 1)
    #expect(kv[0].key == "bootloader version")
}

@Test func systemStatusEmptyWhenNothingReadable() {
    let (conn, _, _, _) = makeConnector()

    let kv = conn.systemStatus()

    #expect(kv.isEmpty)
}
