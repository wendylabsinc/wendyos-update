import Connector
import Glibc
import PlatformIO
import PlatformIOTesting
import Testing

@testable import TegraUEFI

// Ports `internal/connector/tegrauefi/swap-slot_test.go`: the
// `capsuleUpdateEffective` SoC allowlist, and the install-swap routing
// tests (`TestSwapSlotSwitchesSlotWhenCapsuleIneffective` /
// `TestSwapSlotDoesNotSwitchSlotWhenCapsuleEffective`). Adds new coverage
// the Go suite doesn't have: a full successful capsule-staging happy path
// (Go's own test can't complete it without a real ESP; the in-memory
// `FakeFileStore` + a fake `EspMounter` can), and a rollback-never-mounts
// test.

// MARK: - capsuleUpdateEffective (ports TestCapsuleUpdateEffective)

struct CapsuleEffectiveCase: Sendable {
    let name: String
    let entries: [String]
    let writeVar: Bool
    let want: Bool
}

private let capsuleEffectiveCases: [CapsuleEffectiveCase] = [
    .init(name: "thor tegra264 is effective", entries: ["nvidia,p3834-0008", "nvidia,tegra264"], writeVar: true, want: true),
    .init(name: "orin tegra234 is not effective", entries: ["nvidia,p3701-0000", "nvidia,tegra234"], writeVar: true, want: false),
    .init(name: "orin nano tegra234 is not effective", entries: ["nvidia,p3767-0000", "nvidia,tegra234"], writeVar: true, want: false),
    .init(name: "missing compatible defaults to not effective", entries: [], writeVar: false, want: false),
    .init(name: "unknown soc defaults to not effective", entries: ["nvidia,someboard", "nvidia,tegra999"], writeVar: true, want: false),
]

@Test(arguments: capsuleEffectiveCases)
func capsuleUpdateEffectiveMatchesThorAllowlist(_ tc: CapsuleEffectiveCase) throws {
    let (conn, _, files, _) = makeConnector()
    if tc.writeVar {
        let body = tc.entries.joined(separator: "\0") + "\0"
        try files.writeAtomic("/rootdir/proc/device-tree/compatible", Array(body.utf8), mode: 0o644)
    }
    #expect(conn.capsuleUpdateEffective() == tc.want, "case: \(tc.name)")
}

// MARK: - install-swap routing (ports the two TestSwapSlot* cases)

/// Wires a `FakeFileStore` + `FakeMounter` so `swapSlot(target, true)` can
/// reach the marker-inspection branch: `partition(for:)` resolves via a
/// by-partlabel symlink, and `mountRootfs` returns a fake rootfs mount
/// whose marker presence the test controls. Mirrors
/// `swap-slot_test.go`'s `installSwapSetup`.
private func installSwapSetup(
    files: FakeFileStore,
    rootDir: String,
    target: Slot,
    hasMarker: Bool,
    hasCapsule: Bool = false
) -> String {
    let label = TegraUEFI.partlabel(for: target)
    let devPath = "/dev/fake-\(label)"
    files.symlink("\(rootDir)/dev/disk/by-partlabel/\(label)", to: devPath)

    let mountDir = "/mnt/fake-rootfs-\(label)"
    if hasMarker {
        try? files.writeAtomic(mountDir + TegraUEFI.markerPath, [], mode: 0o644)
    }
    if hasCapsule {
        try? files.writeAtomic(mountDir + TegraUEFI.capsuleSrcPath, Array("fake-capsule-bytes".utf8), mode: 0o644)
    }
    return mountDir
}

/// On a platform where capsule-on-disk is NOT effective (Orin), an
/// install swap for an image that carries the bootloader marker must
/// still switch the active slot via `nvbootctrl` — otherwise the update
/// silently no-ops. It must NOT stage a capsule or arm `OsIndications`.
///
/// This fixture is Orin (tegra234), so the slot switch must go to the
/// BOOT CHAIN layer (no `-t rootfs`) per `nvbootctrlSlotArgs`/
/// `bootChainSlotAB` — Go's `TestSwapSlotSwitchesSlotWhenCapsuleIneffective`
/// still asserts a literal `-t rootfs set-active-boot-slot 1`, which is
/// stale against the current `main` source and fails there too (verified
/// by running it); this port asserts the actual current behavior instead.
@Test func swapSlotSwitchesSlotWhenCapsuleIneffective() throws {
    let files = FakeFileStore()
    let rootDir = "/rootdir"
    let mountDir = installSwapSetup(files: files, rootDir: rootDir, target: .b, hasMarker: true)
    try files.writeAtomic(
        rootDir + "/proc/device-tree/compatible",
        Array(("nvidia,p3701-0000\0nvidia,tegra234\0").utf8),
        mode: 0o644
    )
    let mounter = FakeMounter(directory: mountDir)
    let cmd = FakeTegraCommandRunner()
    cmd.script(containing: "get-current-slot", stdout: "0\n")
    let efivarsDir = makeTempDir("swap-ineffective")

    let conn = TegraUEFI(
        efivarsDir: efivarsDir,
        rootDir: rootDir,
        commandRunner: cmd,
        fileStore: files,
        mountRootfs: mounter.mount,
        mountESP: { _ in fatalError("must not mount ESP on an ineffective-capsule platform") }
    )

    try conn.swapSlot(.b, stagePlatformUpdate: true)

    #expect(cmd.ranCommand(containing: "set-active-boot-slot 1"))
    #expect(!cmd.ranCommand(containing: "-t rootfs"))
    #expect(mounter.callCount == 1)

    // OsIndications must not be armed (no capsule to process) — the
    // variable must not even have been created.
    let osIndicationsPath = "\(efivarsDir)/OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    #expect(osIndicationsPath.withCString { Glibc.access($0, F_OK) != 0 })
}

/// On a platform where capsule-on-disk IS effective (Thor), an install
/// swap for a bootloader-carrying image must take the full capsule path:
/// stage the capsule onto the (fake) ESP, arm `OsIndications`, and NEVER
/// call `nvbootctrl set-active-boot-slot` (the documented BC_NEXT
/// conflict). Unlike the Go test (which can't complete staging without a
/// real ESP), the in-memory fakes let this exercise the full happy path.
@Test func swapSlotStagesCapsuleAndArmsOsIndicationsWhenCapsuleEffective() throws {
    let files = FakeFileStore()
    let rootDir = "/rootdir"
    let mountDir = installSwapSetup(files: files, rootDir: rootDir, target: .b, hasMarker: true, hasCapsule: true)
    try files.writeAtomic(
        rootDir + "/proc/device-tree/compatible",
        Array(("nvidia,p3834-0008\0nvidia,tegra264\0").utf8),
        mode: 0o644
    )
    let rootfsMounter = FakeMounter(directory: mountDir)
    let espDir = "/mnt/fake-esp"
    let espMounter = FakeMounter(directory: espDir)
    let cmd = FakeTegraCommandRunner()
    cmd.script(containing: "get-current-slot", stdout: "0\n")
    cmd.script(containing: "dump-slots-info", stdout: "Current version: 1.2.3\n")
    // findmnt /boot/efi finds nothing -> falls back to by-partlabel + mountESP.
    cmd.script(when: { $0.first == "findmnt" }, result: CommandResult(exitCode: 1, stdout: [], stderr: []))
    files.symlink("\(rootDir)/dev/disk/by-partlabel/esp", to: "/dev/fake-esp-part")

    let efivarsDir = makeTempDir("swap-effective")
    let conn = TegraUEFI(
        efivarsDir: efivarsDir,
        rootDir: rootDir,
        commandRunner: cmd,
        fileStore: files,
        mountRootfs: rootfsMounter.mount,
        mountESP: espMounter.mount
    )

    try conn.swapSlot(.b, stagePlatformUpdate: true)

    // Capsule staged onto the ESP.
    #expect(try files.read(espDir + "/EFI/UpdateCapsule/TEGRA_BL.Cap") == Array("fake-capsule-bytes".utf8))
    // OsIndications capsule bit armed.
    let osIndications = try #require(try? EfiVar.readStatus("\(efivarsDir)/OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c"))
    #expect(osIndications.count >= 5)
    #expect(osIndications[4] & 0x04 != 0)
    // nvbootctrl slot switch must NOT have been called (BC_NEXT conflict).
    #expect(!cmd.ranCommand(containing: "set-active-boot-slot"))
    // Bootloader version-before recorded for post-reboot verification.
    #expect(try files.read(rootDir + "/data/wendyos-update/bl-version-before") == Array("1.2.3\n".utf8))
}

/// An install swap for an image with NO bootloader marker must switch the
/// slot via `nvbootctrl` (the ordinary rootfs-only path) even on a
/// capsule-effective platform.
@Test func swapSlotSwitchesSlotWhenNoMarkerPresent() throws {
    let files = FakeFileStore()
    let rootDir = "/rootdir"
    let mountDir = installSwapSetup(files: files, rootDir: rootDir, target: .a, hasMarker: false)
    let mounter = FakeMounter(directory: mountDir)
    let cmd = FakeTegraCommandRunner()
    cmd.script(containing: "get-current-slot", stdout: "1\n")

    let conn = TegraUEFI(
        efivarsDir: makeTempDir("swap-no-marker"),
        rootDir: rootDir,
        commandRunner: cmd,
        fileStore: files,
        mountRootfs: mounter.mount,
        mountESP: { _ in fatalError("must not mount ESP with no marker") }
    )

    try conn.swapSlot(.a, stagePlatformUpdate: true)

    #expect(cmd.ranCommand(containing: "-t rootfs set-active-boot-slot 0"))
}

// MARK: - rollback swap (new coverage: "never mounts")

/// Rollback (`stagePlatformUpdate: false`) must be a pure `nvbootctrl`
/// re-point: it must NEVER mount or inspect the target rootfs (the target
/// may be the running, unmountable slot), and must never call
/// `partition(for:)`.
@Test func rollbackSwapOnlyCallsSetActiveBootSlotAndNeverMounts() throws {
    let (conn, cmd, _, _) = makeConnector(
        mountRootfs: { _ in fatalError("rollback must never mount the rootfs") },
        mountESP: { _ in fatalError("rollback must never mount the ESP") }
    )

    try conn.swapSlot(.a, stagePlatformUpdate: false)

    #expect(cmd.invocations == [["nvbootctrl", "-t", "rootfs", "set-active-boot-slot", "0"]])
}

@Test func rollbackSwapThrowsOnNonZeroNvbootctrlExit() {
    let (conn, cmd, _, _) = makeConnector()
    cmd.script(containing: "set-active-boot-slot", stdout: "denied", exitCode: 1)

    #expect(throws: TegraUEFIError.self) { try conn.swapSlot(.b, stagePlatformUpdate: false) }
}

// MARK: - Orin boot-chain A/B rollback routing (ports
// TestSwapSlotRollbackTargetsCorrectNvbootctrlLayer)

struct RollbackLayerCase: Sendable {
    let name: String
    let soc: String
    let wantRootfs: Bool
}

private let rollbackLayerCases: [RollbackLayerCase] = [
    .init(name: "orin uses boot chain", soc: "tegra234", wantRootfs: false),
    .init(name: "thor uses rootfs redundancy", soc: "tegra264", wantRootfs: true),
]

/// The fix for the original Orin failure: a slot switch on Orin must go to
/// the boot chain (no `-t rootfs`), which flips the coupled rootfs slot
/// without the unarmable `RootfsRedundancyLevel` var. Thor keeps
/// `-t rootfs`. Ports `TestSwapSlotRollbackTargetsCorrectNvbootctrlLayer`.
@Test(arguments: rollbackLayerCases)
func rollbackSwapTargetsCorrectNvbootctrlLayer(_ tc: RollbackLayerCase) throws {
    let files = FakeFileStore()
    let rootDir = "/rootdir"
    try files.writeAtomic(
        rootDir + "/proc/device-tree/compatible",
        Array("nvidia,board\0nvidia,\(tc.soc)\0".utf8),
        mode: 0o644
    )
    let cmd = FakeTegraCommandRunner()
    cmd.script(containing: "get-current-slot", stdout: "0\n")
    let conn = TegraUEFI(
        efivarsDir: makeTempDir("rollback-layer"),
        rootDir: rootDir,
        commandRunner: cmd,
        fileStore: files,
        mountRootfs: { _ in fatalError("rollback must never mount the rootfs") },
        mountESP: { _ in fatalError("rollback must never mount the ESP") }
    )

    try conn.swapSlot(.b, stagePlatformUpdate: false)

    #expect(cmd.ranCommand(containing: "set-active-boot-slot 1"), "case: \(tc.name)")
    #expect(cmd.ranCommand(containing: "-t rootfs") == tc.wantRootfs, "case: \(tc.name)")
}
