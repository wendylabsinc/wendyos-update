import Connector
import PlatformIO
import Testing

@testable import UBootEnv

// Ports the WDY-1775 MBR-partition-number / boot-disk-scoping slot
// resolution scenarios from `ubootenv_test.go` that Task 9.1 shipped code
// for (`currentSlot`/`partition(for:)`'s MBR fallback and boot-disk
// scoping) but never covered with a direct test:
// `TestSlotResolutionMBRByPartitionNumber`,
// `TestCurrentSlotMBRCommittedSlotLabelStripped`,
// `TestSlotResolutionMBRScopedToBootDisk`,
// `TestSlotResolutionPartlabelWinsOverFSLabel`,
// `TestSlotResolutionScopedToBootDisk`, `TestPartNum`,
// `TestBootDiskHasPartlabel`, and `TestMarkGoodMBRLabelStripped`.
//
// Unlike `testController` (which builds real symlinked fixture files for
// the by-partlabel fallback), these fixtures never touch the fallback
// path — `listPartsFn` always resolves the running root directly — so a
// bare `UBootEnv` wired to fabricated (non-existent) `/dev/...` paths is
// enough; `canon` passes an unresolvable path through unchanged, exactly
// like Go's `filepath.EvalSymlinks` failure branch.

private func makeConnector(
    rootDevice: String,
    parts: [PartInfo],
    env: any UBootEnvStore = FakeUBootEnvStore()
) -> UBootEnv {
    UBootEnv(
        fileStore: RealFileStore(),
        env: env,
        rootDeviceFn: { rootDevice },
        listPartsFn: { parts }
    )
}

// MARK: - MBR partition-number resolution (rpi3: no GPT partlabel)

struct MBRLabelCase: Sendable {
    let name: String
    let labelA: String
    let labelB: String
}

private let mbrLabelCases: [MBRLabelCase] = [
    .init(name: "labels absent (post-OTA)", labelA: "", labelB: ""),
    .init(
        name: "labels swapped (fs label must be ignored on MBR)",
        labelA: UBootEnv.partlabelB,
        labelB: UBootEnv.partlabelA
    ),
    .init(name: "factory labels present", labelA: UBootEnv.partlabelA, labelB: UBootEnv.partlabelB),
]

@Test(arguments: mbrLabelCases)
func slotResolutionOnMBRIsByPartitionNumberRegardlessOfFSLabel(_ tc: MBRLabelCase) throws {
    let a = "/dev/mmcblk0p2"
    let b = "/dev/mmcblk0p3"
    let conn = makeConnector(
        rootDevice: a,  // booted slot A (p2)
        parts: [
            PartInfo(path: a, partlabel: "", label: tc.labelA, pkname: "mmcblk0"),
            PartInfo(path: b, partlabel: "", label: tc.labelB, pkname: "mmcblk0"),
        ]
    )

    #expect(try conn.currentSlot() == .a, "case: \(tc.name)")
    #expect(try conn.partition(for: .a) == a, "case: \(tc.name)")
    #expect(try conn.partition(for: .b) == b, "case: \(tc.name)")
}

/// The exact post-OTA failure this fixes: after committing an OTA to slot
/// B on rpi3, the running root is p3 whose fs label was wiped by the
/// rootfs write. `currentSlot` must still report B (by partition number),
/// or Commit/VerifyBoot would see a false "firmware fallback"
/// (running-slot != target-slot) and mark it failed.
@Test func currentSlotMBRResolvesCommittedSlotEvenWithLabelStripped() throws {
    let a = "/dev/mmcblk0p2"
    let b = "/dev/mmcblk0p3"
    let conn = makeConnector(
        rootDevice: b,  // running the committed slot B
        parts: [
            PartInfo(path: a, partlabel: "", label: UBootEnv.partlabelA, pkname: "mmcblk0"),  // A keeps its factory label
            PartInfo(path: b, partlabel: "", label: "", pkname: "mmcblk0"),  // B: label wiped by the OTA write
        ]
    )

    #expect(try conn.currentSlot() == .b)
}

/// MBR analogue of `slotResolutionScopedToBootDiskGPT` with NO labels at
/// all: a second (USB) disk carrying its own p2/p3 must never shadow the
/// booted SD.
@Test func slotResolutionMBRScopedToBootDisk() throws {
    let sdA = "/dev/mmcblk0p2"
    let sdB = "/dev/mmcblk0p3"
    let usbA = "/dev/sda2"
    let usbB = "/dev/sda3"
    let conn = makeConnector(
        rootDevice: sdA,  // booted from SD
        parts: [
            PartInfo(path: sdA, partlabel: "", label: "", pkname: "mmcblk0"),
            PartInfo(path: sdB, partlabel: "", label: "", pkname: "mmcblk0"),
            PartInfo(path: usbA, partlabel: "", label: "", pkname: "sda"),
            PartInfo(path: usbB, partlabel: "", label: "", pkname: "sda"),
        ]
    )

    #expect(try conn.currentSlot() == .a)
    #expect(try conn.partition(for: .a) == sdA, "want the SD partition, not the USB one")
    #expect(try conn.partition(for: .b) == sdB, "want the SD partition, not the USB one")
}

// MARK: - GPT resolution is unaffected by the MBR fallback

/// The GPT partlabel is authoritative and takes precedence over the fs
/// label, so adding the MBR fs-label fallback cannot change resolution on
/// GPT boards (rpi4/rpi5): even a deliberately wrong fs label is ignored
/// when a partlabel is present. Guards that the fallback is purely
/// additive.
@Test func slotResolutionPartlabelWinsOverFSLabelOnGPT() throws {
    let a = "/dev/mmcblk0p3"
    let b = "/dev/mmcblk0p4"
    let conn = makeConnector(
        rootDevice: a,
        parts: [
            PartInfo(path: a, partlabel: UBootEnv.partlabelA, label: "bogusA", pkname: "mmcblk0"),
            PartInfo(path: b, partlabel: UBootEnv.partlabelB, label: "bogusB", pkname: "mmcblk0"),
        ]
    )

    #expect(try conn.currentSlot() == .a)
    #expect(try conn.partition(for: .b) == b)
}

/// Reproduces the SD+NVMe collision on a GPT board: two flashed disks,
/// both carrying rootfsA/rootfsB. Slot resolution must stay on the disk
/// the running root is on (the SD here) and never resolve to the NVMe's
/// same-labelled partitions — otherwise `currentSlot` fails ("matches
/// neither") and install would write the inactive slot to the wrong disk.
@Test func slotResolutionScopedToBootDiskGPT() throws {
    let sdA = "/dev/mmcblk0p3"
    let sdB = "/dev/mmcblk0p4"
    let nvA = "/dev/nvme0n1p3"
    let nvB = "/dev/nvme0n1p4"
    let conn = makeConnector(
        rootDevice: sdA,  // booted from SD
        parts: [
            PartInfo(path: sdA, partlabel: UBootEnv.partlabelA, pkname: "mmcblk0"),
            PartInfo(path: sdB, partlabel: UBootEnv.partlabelB, pkname: "mmcblk0"),
            PartInfo(path: nvA, partlabel: UBootEnv.partlabelA, pkname: "nvme0n1"),
            PartInfo(path: nvB, partlabel: UBootEnv.partlabelB, pkname: "nvme0n1"),
        ]
    )

    #expect(try conn.currentSlot() == .a)
    #expect(try conn.partition(for: .a) == sdA, "want the SD partition, not the NVMe one")
    #expect(try conn.partition(for: .b) == sdB, "want the SD partition, not the NVMe one")
}

// MARK: - MarkGood on MBR (label stripped by the OTA it is finalizing)

/// `markGood` calls `currentSlot` internally to pin `boot_slot` to the
/// running slot. On rpi3 the just-committed slot's fs label is wiped, so
/// this must resolve by partition number — otherwise the finalize step of
/// Commit would fail on MBR.
@Test func markGoodResolvesMBRCommittedSlotWithLabelStripped() throws {
    let env = FakeUBootEnvStore([
        UBootEnv.envBootSlot: "0", UBootEnv.envUpgradeAvailable: "1", UBootEnv.envBootCount: "1",
    ])
    let a = "/dev/mmcblk0p2"
    let b = "/dev/mmcblk0p3"
    let conn = makeConnector(
        rootDevice: b,  // running the committed slot B
        parts: [
            PartInfo(path: a, partlabel: "", label: UBootEnv.partlabelA, pkname: "mmcblk0"),
            PartInfo(path: b, partlabel: "", label: "", pkname: "mmcblk0"),  // wiped by OTA
        ],
        env: env
    )

    try conn.markGood()

    #expect(env.vars[UBootEnv.envBootSlot] == "1", "boot_slot pinned to running slot B by partition number")
    #expect(env.vars[UBootEnv.envUpgradeAvailable] == "0")
    #expect(env.vars[UBootEnv.envBootCount] == "0")
}

// MARK: - partNum / bootDiskHasPartlabel (pure helpers)

struct PartNumCase: Sendable {
    let path: String
    let pkname: String
    let want: Int?
}

private let partNumCases: [PartNumCase] = [
    .init(path: "/dev/mmcblk0p2", pkname: "mmcblk0", want: 2),
    .init(path: "/dev/mmcblk0p3", pkname: "mmcblk0", want: 3),
    .init(path: "/dev/sda3", pkname: "sda", want: 3),
    .init(path: "/dev/nvme0n1p3", pkname: "nvme0n1", want: 3),
    .init(path: "/dev/mmcblk0", pkname: "mmcblk0", want: nil),  // whole disk: no partition number
    .init(path: "/dev/sda", pkname: "sda", want: nil),
    .init(path: "/dev/mmcblk0p3", pkname: "", want: nil),  // no parent disk known
]

@Test(arguments: partNumCases)
func partNumParsesThePartitionNumberFromADevicePath(_ tc: PartNumCase) {
    #expect(UBootEnv.partNum(tc.path, pkname: tc.pkname) == tc.want)
}

/// `bootDiskHasPartlabel` must decide MBR-vs-GPT PER DISK: a GPT USB
/// drive beside an MBR SD boot disk must NOT flip the boot disk onto the
/// partlabel path.
@Test func bootDiskHasPartlabelDecidesPerDiskNotGlobally() {
    let gpt = [PartInfo(path: "/dev/mmcblk0p3", partlabel: UBootEnv.partlabelA, pkname: "mmcblk0")]
    #expect(UBootEnv.bootDiskHasPartlabel(gpt, disk: "mmcblk0"), "GPT boot disk (partlabel present)")

    let mbr = [PartInfo(path: "/dev/mmcblk0p2", partlabel: "", label: UBootEnv.partlabelA, pkname: "mmcblk0")]
    #expect(!UBootEnv.bootDiskHasPartlabel(mbr, disk: "mmcblk0"), "MBR boot disk (no partlabel)")

    let mixed = [
        PartInfo(path: "/dev/sda1", partlabel: "ESP", pkname: "sda"),  // GPT USB drive
        PartInfo(path: "/dev/mmcblk0p2", partlabel: "", label: UBootEnv.partlabelA, pkname: "mmcblk0"),  // MBR SD boot disk
    ]
    #expect(
        !UBootEnv.bootDiskHasPartlabel(mixed, disk: "mmcblk0"),
        "a partlabel on a DIFFERENT disk must not make the MBR boot disk report true"
    )
}
