import Connector
import Glibc
import PlatformIO
import Testing

@testable import UBootEnv

// Shared test doubles for UBootEnvTests: an in-memory `UBootEnvStore`
// (mirrors Go's `ubootenv_test.go` `fakeEnv`) and small filesystem helpers
// for building a `testController`-equivalent fixture. `RootDir` is always
// a REAL temp directory here (matching Go's `t.TempDir()`-based
// `testController`): symlink resolution (`canon`, the by-partlabel/
// by-label fallback) and the boot-mountpoint check in `assertEnvWritable`
// both do real `stat`/`realpath` syscalls, so they need real files to
// resolve against, not an in-memory `FakeFileStore`.

/// An in-memory U-Boot environment for tests. Ports
/// `ubootenv_test.go`'s `fakeEnv`.
final class FakeUBootEnvStore: UBootEnvStore, @unchecked Sendable {
    private(set) var vars: [String: String]
    private(set) var setCalls = 0
    /// Each `set(_:)` call's full argument, in call order — lets tests
    /// assert both "how many atomic writes happened" and "what exactly
    /// was in each one".
    private(set) var invocations: [[String: String]] = []

    init(_ initial: [String: String] = [:]) {
        self.vars = initial
    }

    func get(_ name: String) -> String {
        vars[name] ?? ""
    }

    func set(_ newVars: [String: String]) throws {
        setCalls += 1
        invocations.append(newVars)
        for (key, value) in newVars {
            vars[key] = value
        }
    }
}

func makeTempDir(_ tag: String) -> String {
    let path = "/tmp/ubootenv-test-\(getpid())-\(tag)-\(Int.random(in: 0..<1_000_000))"
    let rc = path.withCString { Glibc.mkdir($0, 0o755) }
    #expect(rc == 0, "failed to create temp dir \(path), errno \(errno)")
    return path
}

/// `mkdir -p`, ignoring already-existing components.
func makeDirAll(_ path: String) {
    var prefix = ""
    for component in path.split(separator: "/") {
        prefix += "/\(component)"
        _ = prefix.withCString { Glibc.mkdir($0, 0o755) }
    }
}

@discardableResult
func writeFixtureFile(_ path: String, _ contents: [UInt8] = []) -> Int32 {
    let fd = path.withCString { Glibc.open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
    #expect(fd >= 0, "failed to create fixture file \(path), errno \(errno)")
    if !contents.isEmpty {
        contents.withUnsafeBytes { buf in _ = Glibc.write(fd, buf.baseAddress, buf.count) }
    }
    Glibc.close(fd)
    return fd
}

func makeSymlink(_ target: String, at path: String) {
    let rc = path.withCString { p in target.withCString { t in Glibc.symlink(t, p) } }
    #expect(rc == 0, "failed to create symlink \(path) -> \(target), errno \(errno)")
}

/// Builds a `UBootEnv` wired to a fake env store and a REAL `RootDir`
/// tempdir, with the running root forced to the given slot's device.
/// Pass `running: nil` to leave `rootDeviceFn` returning an unmatched
/// device. When `makeSlots` is true, real files/symlinks are created so
/// `by-partlabel` symlink resolution and `lsblk`-equivalent partition
/// listing both succeed (single-disk fixture: both slots on `"mmcblk0"`).
/// Ports `ubootenv_test.go`'s `testController`.
func testController(
    env: FakeUBootEnvStore,
    running: Slot?,
    makeSlots: Bool
) -> (conn: UBootEnv, rootDir: String, devA: String, devB: String) {
    let rootDir = makeTempDir("ctrl")
    let devA = rootDir + "/dev/rootfsA"
    let devB = rootDir + "/dev/rootfsB"

    if makeSlots {
        makeDirAll(rootDir + "/dev")
        writeFixtureFile(devA)
        writeFixtureFile(devB)
        let linkDir = rootDir + "/dev/disk/by-partlabel"
        makeDirAll(linkDir)
        makeSymlink(devA, at: linkDir + "/rootfsA")
        makeSymlink(devB, at: linkDir + "/rootfsB")
    }

    let rootDeviceFn: @Sendable () throws -> String = {
        switch running {
        case .a: return devA
        case .b: return devB
        case nil: return rootDir + "/dev/unknown"
        }
    }
    let listPartsFn: @Sendable () throws -> [PartInfo] = {
        guard makeSlots else { return [] }
        return [
            PartInfo(path: devA, partlabel: "rootfsA", pkname: "mmcblk0"),
            PartInfo(path: devB, partlabel: "rootfsB", pkname: "mmcblk0"),
        ]
    }

    let conn = UBootEnv(
        rootDir: rootDir,
        fileStore: RealFileStore(),
        env: env,
        rootDeviceFn: rootDeviceFn,
        listPartsFn: listPartsFn
    )
    return (conn, rootDir, devA, devB)
}
