import Connector
import Glibc

// The slot-flip half of the U-Boot connector. All state lives in the
// U-Boot environment (libubootenv); this connector keeps no files of its
// own. Ports `internal/connector/ubootenv/swap-slot.go`'s `SwapSlot`.
extension UBootEnv {
    /// Makes slot `s` the next-boot slot.
    ///
    ///   - install (`stagePlatformUpdate == true`): `s` is the freshly
    ///     written inactive slot. Arms a TRIAL boot — points the boot
    ///     script at `s`, sets the trial flag, zeros the counter — all
    ///     in one atomic env write. If the trial slot never reaches a
    ///     healthy userspace, U-Boot's bootcount/bootlimit/altbootcmd
    ///     falls back to the old slot on its own.
    ///   - rollback (`stagePlatformUpdate == false`): a pure re-point.
    ///     Sets the boot slot to `s` and DISARMS the trial
    ///     (`upgrade_available=0`) so the next boot is permanent, not a
    ///     trial. Never a trial — rollback returns to a known-good slot.
    ///
    /// Ports `swap-slot.go`'s `SwapSlot`.
    public func swapSlot(_ s: Slot, stagePlatformUpdate: Bool) throws {
        // Refuse if the U-Boot env is not actually on the mounted boot
        // partition: otherwise `fw_setenv` writes a shadow copy U-Boot
        // never reads and the slot change silently no-ops.
        do {
            try assertEnvWritable()
        } catch {
            throw UBootEnvError.swapEnvNotWritable(s, "\(error)")
        }

        if stagePlatformUpdate {
            do {
                try env.set([
                    Self.envBootSlot: Self.slotEnvValue(s),
                    Self.envUpgradeAvailable: "1",
                    Self.envBootCount: "0",
                ])
            } catch {
                throw UBootEnvError.swapArmTrialFailed(s, "\(error)")
            }
            return
        }

        do {
            try env.set([
                Self.envBootSlot: Self.slotEnvValue(s),
                Self.envUpgradeAvailable: "0",
                Self.envBootCount: "0",
            ])
        } catch {
            throw UBootEnvError.swapRepointFailed(s, "\(error)")
        }
    }

    /// Finalizes a healthy, committed boot: clears the trial flag so the
    /// current slot becomes the permanent default, pins
    /// `wendyos_boot_slot` to the running slot, and zeros the counter for
    /// the next cycle — one atomic write. The engine's `commit()` calls
    /// this; leaving it a no-op would mean a committed update never
    /// clears its U-Boot trial and could roll back on the next reboot.
    /// Ports `swap-slot.go`'s `MarkGood`.
    public func markGood() throws {
        let cur: Slot
        do {
            cur = try currentSlot()
        } catch {
            throw UBootEnvError.markGoodFailed("\(error)")
        }
        do {
            try env.set([
                Self.envBootSlot: Self.slotEnvValue(cur),
                Self.envUpgradeAvailable: "0",
                Self.envBootCount: "0",
            ])
        } catch {
            throw UBootEnvError.markGoodFailed("\(error)")
        }
    }

    /// Guards against a silently-ineffective env write. On RPi the
    /// U-Boot env is a file on the FAT boot partition
    /// (`fw_env.config` -> `/boot/uboot.env`), and the GPT fstab mounts
    /// `/boot` with `nofail`. If `/boot` fails to mount, `fw_setenv`
    /// happily writes a *copy* of `uboot.env` into the empty `/boot`
    /// directory on the rootfs and exits 0 — but U-Boot reads the real
    /// FAT, so a trial is never armed and the device just reboots the
    /// current slot (a silent no-op OTA, indistinguishable from success
    /// to the caller).
    ///
    /// So: if the configured env is a regular file, refuse unless its
    /// parent directory is a real mountpoint. Fails OPEN on anything it
    /// cannot determine (unreadable config, raw block-device env,
    /// unstattable path) — `fw_setenv` surfaces genuine errors itself;
    /// this only closes the specific shadow-file trap. Ports
    /// `ubootenv.go`'s `assertEnvWritable`.
    func assertEnvWritable() throws {
        guard let data = try? fileStore.read(rootDir + Self.fwEnvConfigPath) else {
            return  // no/unreadable config: don't block (tests, non-RPi boards, ...)
        }
        let dev = Self.firstEnvField(String(decoding: data, as: UTF8.self))
        guard !dev.isEmpty, !dev.hasPrefix("/dev/") else {
            return  // unparseable, or a raw block device (no mount semantics)
        }
        let dir = Self.parentDirectory(of: dev)
        guard let isMountpoint = Self.isMountpoint(rootDir + dir) else {
            return  // cannot stat (e.g. /boot absent): let fw_setenv decide
        }
        guard isMountpoint else {
            throw UBootEnvInternalError(
                detail: "u-boot env \(dev) is not on a mounted boot partition "
                    + "(is \(dir) mounted?): refusing — fw_setenv would write a copy the bootloader never reads"
            )
        }
    }

    /// Returns the first whitespace-separated token of the first
    /// non-blank, non-comment line of an `fw_env.config` (the
    /// device-or-file path). Ports `ubootenv.go`'s `firstEnvField`.
    static func firstEnvField(_ cfg: String) -> String {
        for line in cfg.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = trimmed(String(line))
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }
            return whitespaceFields(Substring(trimmedLine)).first ?? ""
        }
        return ""
    }

    /// `filepath.Dir`, without `Foundation`: the portion of `path` before
    /// its last `/` (or `"/"`/`"."` for the degenerate cases).
    static func parentDirectory(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "." }
        if idx == path.startIndex { return "/" }
        return String(path[path.startIndex..<idx])
    }

    /// Reports whether `path` is a filesystem mountpoint, by the
    /// standard test: its `st_dev` differs from its parent's. `nil` when
    /// either cannot be `stat`'d. Ports `ubootenv.go`'s `isMountpoint`.
    static func isMountpoint(_ path: String) -> Bool? {
        guard let st = statOrNil(path) else { return nil }
        guard let parentSt = statOrNil(parentDirectory(of: path)) else { return nil }
        return st.st_dev != parentSt.st_dev
    }

    /// `stat(2)`, returning `nil` on failure. Broken out as its own
    /// function (rather than inlined at each call site) because `stat`
    /// names both the C struct and the syscall function: the
    /// module-qualified `Glibc.stat(...)` call resolves only to the
    /// struct's initializer on this toolchain, so the syscall must be
    /// called unqualified (plain `stat(...)`, relying on `import Glibc`
    /// bringing the free function into scope) for overload resolution
    /// to pick it.
    private static func statOrNil(_ path: String) -> stat? {
        var buf = stat()
        let rc: Int32 = path.withCString { cPath -> Int32 in
            stat(cPath, &buf)
        }
        return rc == 0 ? buf : nil
    }
}
