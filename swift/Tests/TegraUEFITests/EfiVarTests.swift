import Glibc
import LinuxSys
import Testing

@testable import TegraUEFI

// Ports the RootfsStatusSlot-primitive scenarios from
// `internal/connector/tegrauefi/efivar.go`: the validated 8-byte
// attrs+status layout, the single-write reset payload, and the
// immutable-inode-flag toggle that must precede it on real efivarfs.

/// Builds a unique path under /tmp for this test process. Tests use raw
/// `Glibc` calls (not `EfiVar`/`LinuxSys`) to create/remove/inspect
/// fixture files, mirroring `LinuxSysTests`' convention — `EfiVar`'s own
/// primitives deliberately never create a file (efivarfs semantics).
private func tempPath(_ tag: String) -> String {
    "/tmp/tegrauefi-efivar-test-\(getpid())-\(tag)-\(Int.random(in: 0..<1_000_000))"
}

@discardableResult
private func createFixtureFile(_ path: String, contents: [UInt8]) -> Int32 {
    let fd = Glibc.open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    #expect(fd >= 0, "failed to create fixture file \(path), errno \(errno)")
    contents.withUnsafeBytes { buf in
        let written = Glibc.write(fd, buf.baseAddress, buf.count)
        #expect(written == contents.count)
    }
    Glibc.close(fd)
    return fd
}

/// Reads back every byte of `path` via plain `Glibc` calls, independent of
/// anything under test in `EfiVar`.
private func readWholeFileRaw(_ path: String) -> [UInt8] {
    let fd = Glibc.open(path, O_RDONLY)
    #expect(fd >= 0, "failed to open fixture file \(path) for verification, errno \(errno)")
    defer { Glibc.close(fd) }

    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64)
    while true {
        let n = chunk.withUnsafeMutableBytes { buf in
            Glibc.read(fd, buf.baseAddress, buf.count)
        }
        if n <= 0 { break }
        out.append(contentsOf: chunk[0..<n])
    }
    return out
}

// MARK: - Pure byte-layout tests (no filesystem)

@Test func statusIsWellFormedAndNormalForAnEightByteNormalPayload() {
    let raw: [UInt8] = [0x07, 0, 0, 0, 0, 0, 0, 0]
    #expect(EfiVar.statusIsWellFormed(raw))
    #expect(EfiVar.statusIsNormal(raw))
}

@Test func statusIsWellFormedButNotNormalForAnUnbootablePayload() {
    let raw: [UInt8] = [0x07, 0, 0, 0, 0xFF, 0, 0, 0]
    #expect(EfiVar.statusIsWellFormed(raw))
    #expect(!EfiVar.statusIsNormal(raw))
}

@Test func statusIsNotWellFormedOrNormalForAWrongSizedPayload() {
    let raw: [UInt8] = [0x07, 0, 0, 0] // 4 bytes, not the validated 8-byte layout
    #expect(!EfiVar.statusIsWellFormed(raw))
    #expect(!EfiVar.statusIsNormal(raw))
}

// MARK: - Real-temp-file tests

@Test func readStatusReturnsTheSeededUnbootableBytes() throws {
    let path = tempPath("read-status")
    let seeded: [UInt8] = [0x07, 0, 0, 0, 0xFF, 0, 0, 0]
    createFixtureFile(path, contents: seeded)
    defer { unlink(path) }

    let raw = try EfiVar.readStatus(path)
    #expect(raw == seeded)
}

@Test func writeStatusNormalWritesTheExactEightByteResetPayload() throws {
    let path = tempPath("write-status-normal")
    // Seed as an unbootable slot — writeStatusNormal must rehabilitate it.
    createFixtureFile(path, contents: [0x07, 0, 0, 0, 0xFF, 0, 0, 0])
    defer { unlink(path) }

    try EfiVar.writeStatusNormal(path)

    let onDisk = readWholeFileRaw(path)
    #expect(onDisk == [0x07, 0, 0, 0, 0, 0, 0, 0])
    #expect(onDisk == EfiVar.statusNormal)

    let readBack = try EfiVar.readStatus(path)
    #expect(EfiVar.statusIsNormal(readBack))
}

@Test func clearImmutableDoesNotCrashOnTheTempFilesystem() throws {
    let path = tempPath("clear-immutable")
    createFixtureFile(path, contents: [0x07, 0, 0, 0, 0, 0, 0, 0])
    defer { unlink(path) }

    // The container's /tmp filesystem may or may not support the
    // immutable inode flag ioctl at all (or the capability required to
    // toggle it) — either a clean success or a typed EfiVarError is
    // acceptable; the point of this test is "does not crash/trap".
    do {
        try EfiVar.clearImmutable(path)
    } catch is EfiVarError {
        // Acceptable: filesystem/capability doesn't support it here.
    }
}

// MARK: - Immutable-clear tolerance (injectable seam, no filesystem)

/// The exact set of errnos `efivar.go`'s `clearImmutable` tolerates as
/// "this filesystem doesn't carry the immutable flag — nothing to clear".
private let toleratedClearErrnos: [Int32] = [ENOTTY, EOPNOTSUPP, ENOSYS]

@Test(arguments: toleratedClearErrnos)
func clearImmutableSwallowsUnsupportedFilesystemErrno(_ errno: Int32) throws {
    // A fake clearer standing in for LinuxSys.setImmutable on a filesystem
    // that has no immutable-flag support: the SysError must be treated as
    // a no-op, NOT propagated. This pins the tolerance that the real
    // temp-file test cannot exercise deterministically.
    let clearer: EfiVar.ImmutableClearer = { _ in
        throw SysError(errno: errno, op: "ioctl(FS_IOC_SETFLAGS)")
    }
    // Does not throw:
    try EfiVar.clearImmutable("/does/not/matter", using: clearer)
}

@Test func clearImmutablePropagatesAFatalErrno() {
    // EPERM (missing CAP_LINUX_IMMUTABLE for a real flag change) is NOT in
    // the tolerated set — it must surface as EfiVarError.clearImmutable,
    // never be swallowed. A regression that widened the tolerance to
    // "any SysError" would fail here.
    let clearer: EfiVar.ImmutableClearer = { _ in
        throw SysError(errno: EPERM, op: "ioctl(FS_IOC_SETFLAGS)")
    }
    #expect(throws: EfiVarError.self) {
        try EfiVar.clearImmutable("/does/not/matter", using: clearer)
    }
}

@Test func writeStatusNormalTreatsUnsupportedImmutableClearAsNoOp() throws {
    // The immutable-clear step failing with an unsupported-filesystem
    // errno must not abort the write: writeStatusNormal proceeds to write
    // the reset payload and its read-back succeeds.
    let path = tempPath("write-tolerant-clear")
    createFixtureFile(path, contents: [0x07, 0, 0, 0, 0xFF, 0, 0, 0])
    defer { unlink(path) }

    let clearer: EfiVar.ImmutableClearer = { _ in
        throw SysError(errno: ENOTTY, op: "ioctl(FS_IOC_SETFLAGS)")
    }
    try EfiVar.writeStatusNormal(path, clearImmutable: clearer)

    let onDisk = readWholeFileRaw(path)
    #expect(onDisk == [0x07, 0, 0, 0, 0, 0, 0, 0])
}

@Test func writeStatusNormalPropagatesAFatalImmutableClearError() {
    // A fatal (non-tolerated) immutable-clear error must abort the write
    // and surface — the reset payload is never written blindly over a
    // still-immutable variable.
    let path = tempPath("write-fatal-clear")
    createFixtureFile(path, contents: [0x07, 0, 0, 0, 0xFF, 0, 0, 0])
    defer { unlink(path) }

    let clearer: EfiVar.ImmutableClearer = { _ in
        throw SysError(errno: EPERM, op: "ioctl(FS_IOC_SETFLAGS)")
    }
    #expect(throws: EfiVarError.self) {
        try EfiVar.writeStatusNormal(path, clearImmutable: clearer)
    }
}
