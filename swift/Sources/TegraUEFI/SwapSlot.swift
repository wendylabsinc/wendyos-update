import Connector
import PlatformIO

// Port of `internal/connector/tegrauefi/swap-slot.go`'s `SwapSlot` — the
// switch-rootfs state script's main flow.
//
// NVIDIA couples bootloader chain and rootfs slot (chain A <-> slot 0,
// chain B <-> slot 1). Two paths:
//
//   ROOTFS-ONLY:    nvbootctrl -t rootfs set-active-boot-slot N
//   CAPSULE UPDATE: stage TEGRA_BL.Cap on the ESP + set OsIndications
//                   bit 2 — the firmware switches the chain itself,
//                   atomically, and nvbootctrl must NOT also be called
//                   (BC_NEXT conflict).
//
// The decision between the two is made by the MARKER INSIDE the freshly
// written rootfs (`/var/lib/wendyos/update-bootloader` + the capsule it
// ships), not by artifact metadata — the new image owns the decision.
extension TegraUEFI {
    /// Capsule staging (platform updates). The capsule ships INSIDE each
    /// rootfs; the marker in the freshly written rootfs decides staging.
    static let markerPath = "/var/lib/wendyos/update-bootloader"
    static let capsuleSrcPath = "/opt/nvidia/UpdateCapsule/tegra-bl.cap"
    static let espCapsuleRel = "EFI/UpdateCapsule/TEGRA_BL.Cap"

    /// ESP partition labels seen across generations: "esp" on t264/r38
    /// (validated), "UEFI-ESP" on t234/r36 layouts.
    static let espPartlabels = ["esp", "UEFI-ESP"]

    /// The device-tree `compatible` token for the only platform where
    /// UEFI capsule-on-disk bootloader updates are validated to be
    /// processed by firmware: NVIDIA Jetson AGX Thor (t264).
    static let capsuleEffectiveSoC = "tegra264"

    /// Bit 2 of the `OsIndications` UINT64: "process capsule(s) on next
    /// boot". Validated on Thor: armed variable reads
    /// `07 00 00 00 04 00 00 00 00 00 00 00` (4-byte attrs + UINT64).
    static let osIndicationsProcessCapsule: UInt64 = 0x04

    /// Makes slot `s` the next-boot slot.
    ///
    /// `stagePlatformUpdate` distinguishes the two callers:
    ///  - install (`true`): `s` is the freshly-written INACTIVE slot.
    ///    Inspect its rootfs marker; if a bootloader update is requested
    ///    AND capsule-on-disk is effective on this platform, stage the
    ///    capsule (the firmware switches the chain) — otherwise
    ///    `nvbootctrl` flips it.
    ///  - rollback (`false`): pure re-point via `nvbootctrl`. Never mount,
    ///    never stage. The target may be the running slot (pre-reboot
    ///    rollback — unmountable) or an old slot whose marker is
    ///    irrelevant, so the install inspection must be skipped entirely.
    public func swapSlot(_ s: Slot, stagePlatformUpdate: Bool) throws {
        if !stagePlatformUpdate {
            // Rollback: just re-point the active boot slot. NEVER mount
            // or inspect the target rootfs.
            try recordBootAttempt(s)
            try runSetActiveBootSlot(s)
            return
        }

        let dev = try partition(for: s)

        // Mount the freshly written rootfs read-only to inspect the
        // marker (and stage the capsule from it if present).
        let mount: TegraMount
        do {
            mount = try mountRootfs(dev)
        } catch {
            throw TegraUEFIError.mountFailed("swap to slot \(s): mount \(dev): \(error)")
        }
        defer { mount.unmount() }

        let marker = mount.directory + Self.markerPath
        let capsule = mount.directory + Self.capsuleSrcPath
        let hasMarker = fileStore.exists(marker)

        // The capsule path delegates the ENTIRE slot switch to UEFI
        // processing the capsule at reboot — no nvbootctrl call. That
        // only works where capsule-on-disk is actually honored (Thor).
        // On Orin and unknown SoCs the firmware silently ignores a
        // correctly-staged capsule, so the slot never moves and the
        // update no-ops. Fall back to the reliable nvbootctrl slot
        // switch there.
        if !hasMarker || !capsuleUpdateEffective() {
            try recordBootAttempt(s)
            try runSetActiveBootSlot(s)
            return
        }

        // CAPSULE UPDATE.
        guard fileStore.exists(capsule) else {
            throw TegraUEFIError.capsuleMissing(Self.capsuleSrcPath)
        }

        // Save the current bootloader version for post-reboot
        // verification (verify-bootloader-update's primary check). A
        // failure to determine it is only a warning; a failure to WRITE
        // it (once determined) is fatal.
        if let version = try? bootloaderVersion() {
            do {
                try fileStore.writeAtomic(blVersionBeforePath(), Array((version + "\n").utf8), mode: 0o644)
            } catch {
                throw TegraUEFIError.saveBootloaderVersionFailed(s, "\(error)")
            }
        }

        let espDir = try espMountpoint()
        let dst = espDir + "/" + Self.espCapsuleRel
        do {
            let capsuleBytes = try fileStore.read(capsule)
            try fileStore.writeAtomic(dst, capsuleBytes, mode: 0o644)
        } catch {
            throw TegraUEFIError.stageCapsuleFailed(s, "\(error)")
        }

        try recordBootAttempt(s)
        try setOsIndicationsCapsuleBit()
        // Deliberately NO nvbootctrl call: the firmware switches the
        // chain when the capsule is processed.
    }

    /// Reports whether staging a UEFI capsule-on-disk update (capsule on
    /// the ESP + `OsIndications` bit, no `nvbootctrl` call) will actually
    /// be honored by this platform's firmware. An allowlist, not a
    /// capability probe: `OsIndicationsSupported` advertises
    /// `FILE_CAPSULE_DELIVERY` on Orin (tegra234) too, yet firmware never
    /// processes a correctly-staged capsule there. Only Thor (tegra264)
    /// is validated to process it; everything else (including an
    /// unreadable `compatible`) is treated as ineffective.
    func capsuleUpdateEffective() -> Bool {
        socCompatibleContains(Self.capsuleEffectiveSoC)
    }

    /// The device-tree `compatible` token for Orin (t234), the platform
    /// that drives A/B by switching the BOOT CHAIN rather than the
    /// rootfs-redundancy slot. See `bootChainSlotAB`.
    static let bootChainSlotABSoC = "tegra234"

    /// Reports whether this SoC does OS-driven rootfs A/B by switching the
    /// BOOT CHAIN (`nvbootctrl` WITHOUT `-t rootfs`) instead of the
    /// rootfs-redundancy slot (`nvbootctrl -t rootfs`).
    ///
    /// NVIDIA couples the two layers — boot chain N <-> rootfs slot N —
    /// but the rootfs-redundancy layer is gated by the
    /// `RootfsRedundancyLevel` UEFI variable, which is UNARMABLE from the
    /// OS on Orin (t234): it is a flash-time device-tree setting, and
    /// every efivarfs write returns `EINVAL`. With it unarmed, `nvbootctrl
    /// -t rootfs set-active-boot-slot` is a silent no-op and every OTA
    /// rolls back. The boot-chain layer needs no such variable: a
    /// capsule-on-disk update on Orin (which switches the chain and makes
    /// NO `nvbootctrl` call) was observed to flip the coupled rootfs slot,
    /// proving the chain switch moves the rootfs. So on Orin we drive the
    /// chain directly with `nvbootctrl` and skip the redundancy machinery
    /// entirely.
    ///
    /// Only Orin (tegra234) opts in. Thor (tegra264) keeps the
    /// rootfs-redundancy path (redundancy is armed at flash there and its
    /// flow is hardware-validated), and an unknown/unreadable SoC keeps
    /// that conservative default too. Ports `swap-slot.go`'s
    /// `bootChainSlotAB`.
    func bootChainSlotAB() -> Bool {
        socCompatibleContains(Self.bootChainSlotABSoC)
    }

    /// Returns the `nvbootctrl` target-type selector for slot operations
    /// (`get-current-slot`/`set-active-boot-slot`/`mark-boot-successful`):
    /// none for the boot-chain layer (Orin), `["-t", "rootfs"]` for the
    /// rootfs-redundancy layer (Thor and the conservative default).
    /// Returns a fresh array each call so callers can append safely. Ports
    /// `swap-slot.go`'s `nvbootctrlSlotArgs`.
    func nvbootctrlSlotArgs() -> [String] {
        bootChainSlotAB() ? [] : ["-t", "rootfs"]
    }

    /// Reports whether the device-tree `compatible` property contains
    /// `token` (e.g. "tegra234", "tegra264"). `compatible` is a
    /// NUL-separated list of "vendor,soc" strings. Returns `false` when it
    /// cannot be read, so callers treat an unknown SoC conservatively.
    /// Ports `swap-slot.go`'s `socCompatibleContains`.
    func socCompatibleContains(_ token: String) -> Bool {
        guard let raw = try? fileStore.read(rootDir + "/proc/device-tree/compatible") else {
            return false
        }
        let text = String(decoding: raw, as: UTF8.self)
        let nul: Character = "\0"
        return text.split(separator: nul, omittingEmptySubsequences: true)
            .contains { $0.contains(token) }
    }

    /// Records which slot the next boot targets — input for the
    /// double-boot detector (`bootIsCompromised`, Task 8.3+). Ports
    /// `recordBootAttempt`.
    func recordBootAttempt(_ s: Slot) throws {
        do {
            try fileStore.writeAtomic(bootAttemptedPath(), Array("\(s.rawValue)\n".utf8), mode: 0o644)
        } catch {
            throw TegraUEFIError.recordBootAttemptFailed(s, "\(error)")
        }
    }

    /// `nvbootctrl [-t rootfs] set-active-boot-slot <n>` — the boot-chain
    /// layer on Orin, the rootfs-redundancy layer elsewhere (see
    /// `nvbootctrlSlotArgs`).
    func runSetActiveBootSlot(_ s: Slot) throws {
        let result = commandRunner.run([nvbootctrl] + nvbootctrlSlotArgs() + ["set-active-boot-slot", String(s.rawValue)])
        guard result.exitCode == 0 else {
            throw TegraUEFIError.swapCommandFailed(s, Self.decodeCombined(result))
        }
    }

    /// Parses "Current version: X" from the BOOTLOADER view of
    /// `dump-slots-info` (no `-t rootfs`; validated format on r36+r38).
    /// Ports `bootloaderVersion`.
    func bootloaderVersion() throws -> String {
        let result = commandRunner.run([nvbootctrl, "dump-slots-info"])
        guard result.exitCode == 0 else {
            throw TegraUEFIError.bootloaderVersionUnavailable(
                "nvbootctrl dump-slots-info: exit \(result.exitCode) (\(Self.decodeCombined(result)))"
            )
        }
        let prefix = "Current version:"
        for line in Self.decodeCombined(result).split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = Self.trimmed(String(line))
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = Self.trimmed(String(trimmed.dropFirst(prefix.count)))
            if !value.isEmpty { return value }
        }
        throw TegraUEFIError.bootloaderVersionUnavailable("no 'Current version:' line")
    }

    /// Returns where the ESP is mounted, mounting it at
    /// `/run/wendyos-update/esp` if necessary: `findmnt /boot/efi` first,
    /// else by-partlabel (`esp`/`UEFI-ESP`) + `mountESP`. Ports
    /// `espMountpoint`.
    func espMountpoint() throws -> String {
        let findmntResult = commandRunner.run(["findmnt", "-no", "TARGET", "/boot/efi"])
        if findmntResult.exitCode == 0 {
            let target = Self.trimmed(String(decoding: findmntResult.stdout, as: UTF8.self))
            if !target.isEmpty { return target }
        }

        for label in Self.espPartlabels {
            let link = rootDir + "/dev/disk/by-partlabel/" + label
            guard let dev = fileStore.resolveSymlink(link) else { continue }
            do {
                // Left mounted on purpose: the staged capsule must be on
                // disk at reboot; the mount dies with the system anyway.
                return try mountESP(dev).directory
            } catch {
                throw TegraUEFIError.mountFailed("mount ESP \(dev): \(error)")
            }
        }
        throw TegraUEFIError.espUnavailable(Self.espPartlabels.joined(separator: ", "))
    }

    /// Sets bit 2 of `OsIndications`, preserving any other bits the
    /// variable already carries, then verifies the bit reads back.
    /// Creates the variable if it doesn't pre-exist (see
    /// `EfiVar.writeVarCreating`). Ports
    /// `oe4t-set-uefi-OSIndications`/`switch-rootfs`'s
    /// `verify_osindications` via `setOsIndicationsCapsuleBit`.
    func setOsIndicationsCapsuleBit() throws {
        let path = osIndicationsVarPath()

        var value: UInt64 = 0
        if let raw = try? EfiVar.readStatus(path), raw.count >= 5 {
            for i in 0..<min(8, raw.count - 4) {
                value |= UInt64(raw[4 + i]) << (8 * i)
            }
        } // absent or malformed: start from 0, the write creates it.
        value |= Self.osIndicationsProcessCapsule

        var payload = [UInt8](repeating: 0, count: 12)
        payload[0] = 0x07 // NV+BS+RT
        for i in 0..<8 {
            payload[4 + i] = UInt8((value >> (8 * i)) & 0xFF)
        }

        do {
            try EfiVar.writeVarCreating(path, payload)
        } catch {
            throw TegraUEFIError.osIndicationsFailed("\(error)")
        }

        guard let raw = try? EfiVar.readStatus(path),
            raw.count >= 5,
            (UInt64(raw[4]) & Self.osIndicationsProcessCapsule) != 0
        else {
            throw TegraUEFIError.osIndicationsFailed("read-back: capsule bit not set")
        }
    }
}
