import CLIError
import Glibc
import LinuxSys

// efivarfs access for the NVIDIA RootfsStatusSlot variables.
//
// Ports the RootfsStatusSlot-primitive half of
// `internal/connector/tegrauefi/efivar.go` (`readStatus`,
// `statusIsWellFormed`, `statusIsNormal`, `clearImmutable`,
// `writeStatusNormal`, `writeVar`). That file's OsIndications/capsule-bit
// helpers are ported by a later task, alongside the rest of the
// `Connector` conformance (Tasks 8.2-8.4).
//
// Validated variable format (t234/r36, t264/r38, and Orin Nano
// t234/r39.2 — the last read directly off the device for WDY-1742,
// identical 8-byte layout):
//   bytes 0..3  EFI attributes, 0x07 = NV+BS+RT (little-endian uint32)
//   bytes 4..7  status (little-endian uint32): 0 = normal, 0xFF = unbootable
//
// Writing attrs(0x07) + status(0) in a single 8-byte write resets a slot
// to normal AND re-seeds the firmware retry budget (observed on Thor:
// retry_count back to 3). efivarfs marks variables immutable by default,
// so the immutable inode flag must be cleared before writing — the
// `chattr -i` equivalent, via `LinuxSys.setImmutable`.

/// Errors from the `EfiVar` primitive. All are fatal to whatever
/// slot-status operation triggered them; there is no case where the
/// caller can usefully continue without the variable in a known state.
public enum EfiVarError: Error, Equatable, ExitCoded {
    /// Reading the variable's raw bytes failed.
    case readStatus(String)
    /// Clearing the immutable inode flag failed for a reason other than
    /// "this filesystem doesn't support the flag".
    case clearImmutable(String)
    /// The single `write(2)` of the variable's payload failed.
    case write(String)
    /// `writeStatusNormal` wrote the reset payload but the read-back
    /// afterward did not come back as a well-formed "normal" status.
    case readBackMismatch([UInt8])

    /// All `EfiVar` failures are fatal to the in-progress slot operation.
    public var exitCode: Int32 { 1 }
}

/// Free functions over the NVIDIA RootfsStatusSlot efivar layout. Every
/// function takes the variable's full path as a parameter (rather than
/// hard-coding `efivarsDir`), which is what makes them testable against a
/// plain temp file — production callers (the `Connector` conformance in a
/// later task) build the real path against `efivarsDir` themselves.
public enum EfiVar {
    /// Real efivarfs mountpoint the Tegra RootfsStatusSlot variables live
    /// under. Exposed as a default for production callers; every function
    /// below takes an explicit `path` instead of reading this directly, so
    /// tests can point at an arbitrary temp file.
    public static let efivarsDir = "/sys/firmware/efi/efivars"

    /// The full 8-byte payload that rehabilitates a slot: attrs `0x07`
    /// (NV+BS+RT) + status `0` (normal).
    public static let statusNormal: [UInt8] = [0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    /// `FS_IOC_GETFLAGS`/`FS_IOC_SETFLAGS` failures meaning "this
    /// filesystem doesn't support the immutable inode flag ioctl at
    /// all" — nothing to clear. Matches `efivar.go`'s `clearImmutable`
    /// errno allowlist exactly.
    private static let unsupportedImmutableErrnos: Set<Int32> = [ENOTTY, EOPNOTSUPP, ENOSYS]

    /// Returns the raw variable content via a whole-file read. A valid
    /// status var is exactly 8 bytes; callers check size themselves via
    /// `statusIsWellFormed`/`statusIsNormal` (the JP6 incident involved a
    /// wrong-sized variable).
    public static func readStatus(_ path: String) throws -> [UInt8] {
        let fd: Int32
        do {
            fd = try LinuxSys.openRead(path)
        } catch {
            throw EfiVarError.readStatus("open \(path): \(error)")
        }
        defer { LinuxSys.close(fd) }

        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n: Int
            do {
                n = try chunk.withUnsafeMutableBytes { buf in
                    try LinuxSys.read(fd, buf)
                }
            } catch {
                throw EfiVarError.readStatus("read \(path): \(error)")
            }
            if n == 0 { break }
            out.append(contentsOf: chunk[0..<n])
        }
        return out
    }

    /// Reports whether `raw` is the validated 8-byte attrs+status layout.
    /// Confirmed identical on t234/r36, t264/r38, and Orin Nano t234/r39.2
    /// (read off the device for WDY-1742). A different size is a layout we
    /// have NOT validated on this board: `bootIsCompromised` (a later
    /// task) treats it as inconclusive rather than compromised, so the
    /// documented JP6 wrong-sized variable cannot force a false rollback.
    public static func statusIsWellFormed(_ raw: [UInt8]) -> Bool {
        raw.count == 8
    }

    /// Reports whether `raw` is a well-formed "normal" status variable
    /// (size 8, all four status bytes zero).
    public static func statusIsNormal(_ raw: [UInt8]) -> Bool {
        guard statusIsWellFormed(raw) else { return false }
        return raw[4] == 0 && raw[5] == 0 && raw[6] == 0 && raw[7] == 0
    }

    /// Removes the immutable inode flag (efivarfs sets it by default) via
    /// `LinuxSys.setImmutable(path, false)`. Filesystems without flag
    /// support (e.g. tmpfs in tests) fail with `ENOTTY`/`EOPNOTSUPP`/
    /// `ENOSYS` — treated as "nothing to clear", matching `efivar.go`.
    /// Any other failure (e.g. missing `CAP_LINUX_IMMUTABLE` for an
    /// actual flag change) propagates as `EfiVarError.clearImmutable`.
    public static func clearImmutable(_ path: String) throws {
        do {
            try LinuxSys.setImmutable(path, false)
        } catch let error as SysError {
            if unsupportedImmutableErrnos.contains(error.errno) {
                return
            }
            throw EfiVarError.clearImmutable("\(path): \(error)")
        }
    }

    /// Writes a complete efivar payload (attrs + data) in a single
    /// `write(2)`, clearing the immutable flag first if the variable
    /// already exists. Ports `efivar.go`'s `writeVar` exactly, except it
    /// never creates the variable (`LinuxSys.openWriteExisting` — unlike
    /// Go's `os.O_CREATE` — deliberately fails loudly on a missing path
    /// rather than papering over it with a plain file; a missing
    /// firmware-owned efivar is a configuration error, not something to
    /// silently fix up).
    public static func writeVar(_ path: String, _ payload: [UInt8]) throws {
        if pathExists(path) {
            try clearImmutable(path)
        }

        let fd: Int32
        do {
            fd = try LinuxSys.openWriteExisting(path)
        } catch {
            throw EfiVarError.write("open \(path): \(error)")
        }

        do {
            try payload.withUnsafeBytes { buf in
                _ = try LinuxSys.write(fd, buf)
            }
        } catch {
            LinuxSys.close(fd)
            throw EfiVarError.write("write \(path): \(error)")
        }
        LinuxSys.close(fd)
    }

    /// Writes the 8-byte normal payload in a single `write(2)`, matching
    /// the validated `dd` pattern, then verifies the read-back.
    public static func writeStatusNormal(_ path: String) throws {
        do {
            try writeVar(path, statusNormal)
        } catch {
            throw EfiVarError.write("status var: \(error)")
        }

        let raw: [UInt8]
        do {
            raw = try readStatus(path)
        } catch {
            throw EfiVarError.readStatus("read-back: \(error)")
        }
        guard statusIsNormal(raw) else {
            throw EfiVarError.readBackMismatch(raw)
        }
    }

    /// Reports whether `path` exists, mirroring the `os.Stat(path); err
    /// == nil` guard in `efivar.go`'s `writeVar` — clearing the immutable
    /// flag is only attempted on a variable that's actually there.
    private static func pathExists(_ path: String) -> Bool {
        path.withCString { Glibc.access($0, F_OK) == 0 }
    }
}
