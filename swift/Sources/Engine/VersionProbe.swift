import Foundation
import Glibc

// Per-slot distro/kernel version reads for the `status` verb. Ports
// internal/engine/slotinfo.go's `currentDistro`/`currentKernel`/
// `slotVersions` — distro/kernel are read live for the booted slot and via
// a best-effort read-only mount of the inactive slot's rootfs. All of it is
// display-only.

/// Reads a slot's distro/kernel version strings. A seam over slotinfo.go's
/// free functions so `Engine.status(verbose:)` is unit-testable without
/// root or a real mount: tests inject a scripted fake, production wires up
/// `RealVersionProbe`.
public protocol VersionProbe: Sendable {
    /// The booted slot's version info: `/etc/os-release`'s `VERSION`
    /// (falling back to `VERSION_ID`) and `uname -r`. Ports
    /// `currentDistro`/`currentKernel`.
    func liveVersions() -> (distro: String, kernel: String)

    /// The inactive slot's version info, read via a best-effort read-only
    /// mount of `partition`. Returns `("", "")` on ANY failure — not root,
    /// unmountable, unexpected layout, or an empty `partition` (mirroring
    /// an unresolvable `Connector.partition(for:)`). Ports `slotVersions`.
    func slotVersions(partition: String) -> (distro: String, kernel: String)
}

/// The real `VersionProbe`: `uname(2)` and a raw `mount(2)`/`umount2(2)`
/// pair (not shelling out to the `mount(8)` binary) — the same syscalls
/// `golang.org/x/sys/unix.Mount`/`Unmount` wrap in slotinfo.go. Exercising
/// the mount path needs root and a real ext4 partition, so it is not
/// covered by the unit-test suite; `slotVersions` mirrors Go's best-effort
/// contract closely enough (mount fails closed to `("", "")`) that this is
/// an acceptable, standard "needs real hardware" gap.
public struct RealVersionProbe: VersionProbe {
    public init() {}

    public func liveVersions() -> (distro: String, kernel: String) {
        (Self.osReleaseVersion("/etc/os-release"), Self.currentKernelRelease())
    }

    public func slotVersions(partition: String) -> (distro: String, kernel: String) {
        guard !partition.isEmpty else { return ("", "") }
        guard let dir = Self.makeTempDir() else { return ("", "") }
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let mounted = partition.withCString { src in
            dir.withCString { target in
                "ext4".withCString { fsType in
                    mount(src, target, fsType, UInt(MS_RDONLY | MS_NOATIME), nil)
                }
            }
        }
        guard mounted == 0 else { return ("", "") }
        defer { _ = umount2(dir, Int32(MNT_DETACH)) }

        return (
            Self.osReleaseVersion("\(dir)/etc/os-release"),
            Self.kernelFromModules("\(dir)/lib/modules")
        )
    }

    /// Ports `currentKernel`'s `unix.Uname` read of `Utsname.Release`.
    private static func currentKernelRelease() -> String {
        var u = utsname()
        guard uname(&u) == 0 else { return "" }
        return withUnsafeBytes(of: &u.release) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// Ports `osReleaseVersion`: `VERSION=` wins over `VERSION_ID=`; empty
    /// if the file or both keys are absent.
    private static func osReleaseVersion(_ path: String) -> String {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        var versionID = ""
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let v = Self.value(after: "VERSION=", in: line) { return v }
            if let v = Self.value(after: "VERSION_ID=", in: line) { versionID = v }
        }
        return versionID
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Ports `kernelFromModules`: the highest-sorted directory entry under
    /// `/lib/modules` (normally the only one). Empty if the directory is
    /// absent or has no subdirectories.
    private static func kernelFromModules(_ dir: String) -> String {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return "" }
        var best = ""
        for name in entries {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: "\(dir)/\(name)", isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if name > best { best = name }
        }
        return best
    }

    /// `mkdtemp(3)` — ports `os.MkdirTemp("", "wendyos-slot-")`.
    private static func makeTempDir() -> String? {
        var template = Array("/tmp/wendyos-slot-XXXXXX".utf8CString)
        guard let ptr = mkdtemp(&template) else { return nil }
        return String(cString: ptr)
    }
}
