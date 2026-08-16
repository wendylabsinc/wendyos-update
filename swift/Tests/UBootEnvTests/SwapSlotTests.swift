import Connector
import PlatformIO
import Testing

@testable import UBootEnv

// Ports `internal/connector/ubootenv/ubootenv_test.go`'s `SwapSlot`-
// related scenarios: install arms a trial, rollback re-points and
// disarms, and the boot-not-mounted refusal guard
// (`assertEnvWritable`).

// MARK: - Install arms a trial (ports TestSwapSlotInstallArmsTrial)

@Test func swapSlotInstallArmsTrial() throws {
    let env = FakeUBootEnvStore([
        UBootEnv.envBootSlot: "0",
        UBootEnv.envUpgradeAvailable: "0",
        UBootEnv.envBootCount: "5",
    ])
    let (conn, _, _, _) = testController(env: env, running: .a, makeSlots: true)

    try conn.swapSlot(.b, stagePlatformUpdate: true)

    #expect(env.vars[UBootEnv.envBootSlot] == "1")
    #expect(env.vars[UBootEnv.envUpgradeAvailable] == "1", "trial must be armed")
    #expect(env.vars[UBootEnv.envBootCount] == "0")
    #expect(env.setCalls == 1, "the slot + flag + counter must land in a single atomic write")
    #expect(
        env.invocations == [[
            UBootEnv.envBootSlot: "1",
            UBootEnv.envUpgradeAvailable: "1",
            UBootEnv.envBootCount: "0",
        ]]
    )
}

// MARK: - Rollback re-points and disarms (ports TestSwapSlotRollbackDisarms)

@Test func swapSlotRollbackDisarms() throws {
    let env = FakeUBootEnvStore([
        UBootEnv.envBootSlot: "1",
        UBootEnv.envUpgradeAvailable: "1",
        UBootEnv.envBootCount: "2",
    ])
    let (conn, _, _, _) = testController(env: env, running: .b, makeSlots: true)

    try conn.swapSlot(.a, stagePlatformUpdate: false)

    #expect(env.vars[UBootEnv.envBootSlot] == "0")
    #expect(env.vars[UBootEnv.envUpgradeAvailable] == "0", "rollback is permanent, not a trial")
    #expect(env.vars[UBootEnv.envBootCount] == "0")
    #expect(env.setCalls == 1)
    #expect(
        env.invocations == [[
            UBootEnv.envBootSlot: "0",
            UBootEnv.envUpgradeAvailable: "0",
            UBootEnv.envBootCount: "0",
        ]]
    )
}

// MARK: - assertEnvWritable (ports TestSwapSlotRefusesWhenBootNotMounted / TestAssertEnvWritableFailsOpen)

/// `SwapSlot` must refuse to write the env when the U-Boot env file is
/// not on a mounted boot partition — `fw_setenv` would write a shadow
/// copy on the rootfs that the bootloader never reads, silently
/// no-op'ing the slot change. A plain subdir of `RootDir` shares its
/// `st_dev` with its parent, so it is not a mountpoint.
@Test func swapSlotRefusesWhenBootNotMounted() throws {
    let env = FakeUBootEnvStore([
        UBootEnv.envBootSlot: "0",
        UBootEnv.envUpgradeAvailable: "0",
        UBootEnv.envBootCount: "0",
    ])
    let (conn, rootDir, _, _) = testController(env: env, running: .a, makeSlots: true)

    makeDirAll(rootDir + "/etc")
    writeFixtureFile(
        rootDir + "/etc/fw_env.config",
        Array("# comment\n/boot/uboot.env   0x0000   0x4000\n".utf8)
    )
    makeDirAll(rootDir + "/boot")

    #expect(throws: UBootEnvError.self) { try conn.swapSlot(.b, stagePlatformUpdate: true) }
    #expect(env.setCalls == 0, "env written despite the guard")
}

/// `assertEnvWritable` fails OPEN: a missing config or a raw
/// block-device env has no mount semantics to check, so it must not
/// block.
@Test func assertEnvWritableFailsOpen() throws {
    let (conn, rootDir, _, _) = testController(env: FakeUBootEnvStore(), running: .a, makeSlots: false)

    #expect(throws: Never.self) { try conn.assertEnvWritable() }

    makeDirAll(rootDir + "/etc")
    writeFixtureFile(rootDir + "/etc/fw_env.config", Array("/dev/mmcblk0p1 0x0000 0x4000\n".utf8))

    #expect(throws: Never.self) { try conn.assertEnvWritable() }
}
