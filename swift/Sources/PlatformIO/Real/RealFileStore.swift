import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
// The static-musl cross-compilation SDK exposes libc under the
// `Musl` overlay module instead of `Glibc` (see LinuxSys.swift for
// the fuller explanation); every symbol this file uses exists
// identically in both.
import Musl
#endif
import LinuxSys

/// `FileStore` over POSIX file APIs (`Glibc` + `LinuxSys.fsync`), plus
/// `Foundation.FileManager` for directory creation/listing/attributes.
/// Ports the file-IO scattered through `engine/*.go`: `os.ReadFile`, the
/// tmp+fsync+rename dance in `SaveState`, and `os.ReadDir` (used to
/// discover hook scripts).
public struct RealFileStore: FileStore {
    public init() {}

    public func read(_ path: String) throws -> [UInt8] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return [UInt8](data)
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Writes `bytes` to a sibling temp file, `fsync`s it, then
    /// `rename(2)`s it over `path`. `rename` is atomic on POSIX, so a
    /// concurrent reader of `path` never observes a partial write (ports
    /// `engine.SaveState`'s tmp+fsync+rename). On any failure the temp
    /// file is cleaned up and `path` is left untouched.
    public func writeAtomic(_ path: String, _ bytes: [UInt8], mode: UInt32) throws {
        let dir = Self.parentDirectory(of: path)
        if !dir.isEmpty {
            try mkdirp(dir, mode: 0o755)
        }

        let tmpPath = "\(path).tmp-\(ProcessInfo.processInfo.globallyUniqueString)"
        let fd = tmpPath.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, mode) }
        guard fd >= 0 else {
            throw SysError(errno: errno, op: "open(O_CREAT|O_WRONLY|O_TRUNC)")
        }

        do {
            var offset = 0
            try bytes.withUnsafeBytes { buf in
                while offset < buf.count {
                    let n = try LinuxSys.write(fd, UnsafeRawBufferPointer(rebasing: buf[offset...]))
                    if n == 0 { break }  // shouldn't happen for a regular file; avoid spinning forever
                    offset += n
                }
            }
            try LinuxSys.fsync(fd)
        } catch {
            LinuxSys.close(fd)
            try? remove(tmpPath)
            throw error
        }
        LinuxSys.close(fd)

        let renamed = tmpPath.withCString { tmp in
            path.withCString { dst in rename(tmp, dst) }
        }
        guard renamed == 0 else {
            let renameErrno = errno
            try? remove(tmpPath)
            throw SysError(errno: renameErrno, op: "rename")
        }
    }

    /// Unlinks `path`. A missing path is not an error (ports the
    /// `os.IsNotExist` swallow that wraps every `os.Remove` call site in
    /// the Go engine).
    public func remove(_ path: String) throws {
        guard unlink(path) == 0 else {
            if errno == ENOENT { return }
            throw SysError(errno: errno, op: "unlink")
        }
    }

    public func mkdirp(_ path: String, mode: UInt32) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: mode]
        )
    }

    public func listDir(_ path: String) throws -> [DirEntry] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: path)
        return try names.map { name in
            let full = (path as NSString).appendingPathComponent(name)
            let attrs = try fm.attributesOfItem(atPath: full)
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let posixMode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            // Any of owner/group/other execute bits, matching the Go
            // engine's `info.Mode()&0o111 == 0` hook-discovery filter.
            let isExecutable = (posixMode & 0o111) != 0
            return DirEntry(name: name, isDir: isDir, isExecutable: isExecutable)
        }
    }

    /// `realpath(3)`: resolves every symlink in `path` (including
    /// intermediate directory components) to an absolute, canonical path.
    /// Requires the final target to exist, exactly like Go's
    /// `filepath.EvalSymlinks`; returns `nil` on any failure (missing
    /// path, dangling symlink, ELOOP, ...) rather than throwing, since
    /// callers use this as a resolution *probe* across several candidate
    /// paths (see `TegraUEFI.partition(for:)`), not as a hard read.
    public func resolveSymlink(_ path: String) -> String? {
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = path.withCString({ cPath in
            realpath(cPath, &buf)
        }) else {
            return nil
        }
        return String(cString: resolved)
    }

    private static func parentDirectory(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
