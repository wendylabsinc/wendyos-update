import Connector
import PlatformIO

// Port of `internal/connector/tegrauefi/verify.go`'s `VerifyPlatformUpdate`
// (the bootloader-version + ESRT cascade) and `AbortPlatformUpdate`
// (unstage a not-yet-processed capsule + disarm `OsIndications`).
// `BootIsCompromised` is ported in `TegraUEFI.swift` (Task 8.2); `MarkGood`
// lives there too (Task 8.3, alongside `tegrauefi.go`'s own layout).
extension TegraUEFI {
    /// ESRT verdict of the last capsule attempt (`entry0` on both t234 and
    /// t264). Ports `tegrauefi.go`'s `ESRTStatusPath`.
    static let esrtStatusPath = "/sys/firmware/efi/esrt/entries/entry0/last_attempt_status"

    /// ESRT entry0 `last_attempt_status` codes (validated: t234 incident
    /// analysis + t264 Phase 1). 0 = success; 1-6 = standard UEFI capsule
    /// errors; the NVIDIA-specific codes and vendor range are documented
    /// per NVIDIA L4T. Ports `verify.go`'s constants.
    static let esrtSuccess = 0
    static let esrtUEFIErrLo = 1
    static let esrtUEFIErrHi = 6
    /// 6163: NVIDIA "CheckTheImage failed" — the capsule was rejected. NOT
    /// a cert/auth failure (test-cert capsules verify fine on a clean
    /// device); observed to be boot-chain-state dependent.
    static let esrtNvidiaCheckImageFail = 6163
    /// 6164: device SKU not in the capsule's BUP.
    static let esrtNvidiaSKUMismatch = 6164
    static let esrtNvidiaVendorLo = 0x1000
    static let esrtNvidiaVendorHi = 0x4000

    /// The `VerifyPlatformUpdate` cascade. The running rootfs's marker
    /// file is the source of truth for whether a bootloader update was
    /// part of this deployment (same rule as staging); `bootloaderUpdate`
    /// from the manifest is informational only and does not change the
    /// cascade.
    ///
    ///  1. PRIMARY:   bootloader version changed vs the value saved at swap
    ///  2. SECONDARY: ESRT `last_attempt_status == 0`
    ///  3. FALLBACK:  we booted, assume success
    ///
    /// Validated ESRT codes (t234 incident analysis + t264 Phase 1): 0
    /// success; 1-6 standard UEFI capsule errors; 6163 NVIDIA "CheckTheImage
    /// failed" / capsule rejected (boot-chain-state dependent, NOT a
    /// cert/auth failure); 6164 NVIDIA SKU mismatch; 0x1000-0x4000 NVIDIA
    /// vendor range. `nvbootctrl`'s own capsule status is NOT consulted —
    /// NVIDIA documents it as unreliable. Ports `verify.go`'s
    /// `VerifyPlatformUpdate`.
    public func verifyPlatformUpdate(bootloaderUpdate: Bool) throws {
        guard fileStore.exists(rootDir + Self.markerPath) else { return }

        // 1) version comparison.
        if let before = try? fileStore.read(blVersionBeforePath()) {
            let beforeVersion = Self.trimmed(String(decoding: before, as: UTF8.self))
            if let after = try? bootloaderVersion() {
                if beforeVersion != after {
                    try? fileStore.remove(blVersionBeforePath())
                    return  // version changed: capsule applied
                }
                // unchanged: fall through to the ESRT check.
            }
            // version unreadable: fall through to the ESRT check.
        }
        // no recorded pre-update version: fall through to the ESRT check.

        // 2) ESRT verdict.
        if let raw = try? fileStore.read(rootDir + Self.esrtStatusPath) {
            let text = Self.trimmed(String(decoding: raw, as: UTF8.self))
            guard let status = Int(text) else {
                throw TegraUEFIError.platformVerifyESRTUnparseable(text)
            }
            switch status {
            case Self.esrtSuccess:
                try? fileStore.remove(blVersionBeforePath())
                return
            case Self.esrtUEFIErrLo...Self.esrtUEFIErrHi:
                throw TegraUEFIError.platformVerifyESRTStandardError(status)
            case Self.esrtNvidiaCheckImageFail:
                throw TegraUEFIError.platformVerifyESRTCapsuleRejected
            case Self.esrtNvidiaSKUMismatch:
                throw TegraUEFIError.platformVerifyESRTSKUMismatch
            case Self.esrtNvidiaVendorLo...Self.esrtNvidiaVendorHi:
                throw TegraUEFIError.platformVerifyESRTVendorError(status)
            default:
                break  // unknown status: fall through to the boot-success fallback.
            }
        }
        // ESRT not readable: fall through to the boot-success fallback.

        // 3) fallback: the system booted to this point.
        try? fileStore.remove(blVersionBeforePath())
    }

    /// Unstages a capsule that has not been processed: removes
    /// `TEGRA_BL.Cap` from the ESP and disarms the `OsIndications` capsule
    /// bit so firmware will not look for one. No-op when nothing is
    /// staged. Ports `verify.go`'s `AbortPlatformUpdate`.
    public func abortPlatformUpdate() throws {
        var staged = false

        if let espDir = try? espMountpoint() {
            let cap = espDir + "/" + Self.espCapsuleRel
            if fileStore.exists(cap) {
                staged = true
                do {
                    try fileStore.remove(cap)
                } catch {
                    throw TegraUEFIError.abortPlatformUpdateFailed("\(error)")
                }
            }
        }

        do {
            try clearOsIndicationsCapsuleBit(osIndicationsVarPath())
        } catch {
            throw TegraUEFIError.abortPlatformUpdateFailed("\(error)")
        }

        if staged {
            try? fileStore.remove(blVersionBeforePath())
        }
    }

    /// Disarms capsule processing (rollback before reboot): clears bit 2
    /// of `OsIndications`, preserving any other bits; a missing variable
    /// is a no-op. Ports `efivar.go`'s `clearOsIndicationsCapsuleBit`.
    func clearOsIndicationsCapsuleBit(_ path: String) throws {
        guard efivarExists(path) else { return }

        let raw: [UInt8]
        do {
            raw = try EfiVar.readStatus(path)
        } catch {
            throw TegraUEFIError.osIndicationsFailed("\(error)")
        }
        guard raw.count >= 5, raw[4] & UInt8(Self.osIndicationsProcessCapsule) != 0 else {
            return  // bit not set
        }

        var value: UInt64 = 0
        for i in 0..<min(8, raw.count - 4) {
            value |= UInt64(raw[4 + i]) << (8 * i)
        }
        value &= ~Self.osIndicationsProcessCapsule

        var payload = [UInt8](repeating: 0, count: 12)
        payload[0] = 0x07
        for i in 0..<8 {
            payload[4 + i] = UInt8((value >> (8 * i)) & 0xFF)
        }
        do {
            try EfiVar.writeVar(path, payload)
        } catch {
            throw TegraUEFIError.osIndicationsFailed("\(error)")
        }
    }
}
