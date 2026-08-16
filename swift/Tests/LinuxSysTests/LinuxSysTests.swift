import Glibc
import Testing

@testable import LinuxSys

/// Builds a unique path under /tmp for this test process. Tests use raw
/// `Glibc` calls (not `LinuxSys`) to create/remove fixture files, since
/// `LinuxSys` deliberately has no create-capable open.
private func tempPath(_ tag: String) -> String {
    "/tmp/linuxsys-test-\(getpid())-\(tag)-\(Int.random(in: 0..<1_000_000))"
}

@discardableResult
private func createFixtureFile(_ path: String) -> Int32 {
    let fd = Glibc.open(path, O_WRONLY | O_CREAT, 0o600)
    #expect(fd >= 0, "failed to create fixture file \(path), errno \(errno)")
    Glibc.close(fd)
    return fd
}

@Test func openWriteExistingOnMissingPathThrowsENOENT() {
    let path = tempPath("missing")

    #expect(throws: SysError.self) {
        _ = try LinuxSys.openWriteExisting(path)
    }
    do {
        _ = try LinuxSys.openWriteExisting(path)
        Issue.record("expected openWriteExisting to throw for a missing path")
    } catch let error as SysError {
        #expect(error.errno == ENOENT)
        #expect(error.op.contains("open"))
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func writeFsyncCloseReopenReadSeekEndRoundTrips() throws {
    let path = tempPath("roundtrip")
    createFixtureFile(path)
    defer { unlink(path) }

    let payload = Array("hello, wendyos update".utf8)

    let wfd = try LinuxSys.openWriteExisting(path)
    let written = try payload.withUnsafeBytes { buf in
        try LinuxSys.write(wfd, buf)
    }
    #expect(written == payload.count)
    try LinuxSys.fsync(wfd)
    LinuxSys.close(wfd)

    let rfd = try LinuxSys.openRead(path)
    defer { LinuxSys.close(rfd) }

    let size = try LinuxSys.seekEnd(rfd)
    #expect(size == Int64(payload.count))

    // seekEnd leaves the file offset at EOF; rewind before reading back.
    #expect(Glibc.lseek(rfd, 0, Int32(SEEK_SET)) == 0)

    var readBuf = [UInt8](repeating: 0, count: payload.count)
    let readCount = try readBuf.withUnsafeMutableBytes { buf in
        try LinuxSys.read(rfd, buf)
    }
    #expect(readCount == payload.count)
    #expect(readBuf == payload)
}

@Test func isattyIsFalseForRegularFile() throws {
    let path = tempPath("isatty-file")
    createFixtureFile(path)
    defer { unlink(path) }

    let fd = try LinuxSys.openRead(path)
    defer { LinuxSys.close(fd) }

    #expect(LinuxSys.isatty(fd) == false)
}

@Test func isattyIsFalseForPipe() {
    var fds: [Int32] = [0, 0]
    let rc = fds.withUnsafeMutableBufferPointer { ptr in
        pipe(ptr.baseAddress)
    }
    #expect(rc == 0)
    defer {
        Glibc.close(fds[0])
        Glibc.close(fds[1])
    }

    #expect(LinuxSys.isatty(fds[0]) == false)
    #expect(LinuxSys.isatty(fds[1]) == false)
}

// setImmutable's target filesystem may be overlayfs/tmpfs, which does not
// support FS_IOC_SETFLAGS (EOPNOTSUPP/ENOTTY). This test asserts only that
// the call does not crash/trap: it either succeeds or throws SysError,
// regardless of what the CI container's filesystem supports.
@Test func setImmutableEitherSucceedsOrThrowsCleanly() throws {
    let path = tempPath("immutable")
    createFixtureFile(path)
    defer { unlink(path) }

    do {
        try LinuxSys.setImmutable(path, true)
        // Supported: clear the flag again so the fixture can be unlinked.
        try LinuxSys.setImmutable(path, false)
    } catch is SysError {
        // Not supported on this filesystem — acceptable.
    }
}

@Test func openWriteCreateCreatesAMissingFileAndWritesToIt() throws {
    let path = tempPath("write-create")
    defer { unlink(path) }

    var st = stat()
    #expect(stat(path, &st) != 0, "fixture must not exist yet")

    let fd = try LinuxSys.openWriteCreate(path)
    let payload = Array("os-indications".utf8)
    let written = try payload.withUnsafeBytes { buf in try LinuxSys.write(fd, buf) }
    #expect(written == payload.count)
    LinuxSys.close(fd)

    #expect(stat(path, &st) == 0, "openWriteCreate must have created \(path)")
    #expect(readWholeFile(path) == payload)
}

@Test func openWriteCreateReusesAnExistingFile() throws {
    let path = tempPath("write-create-existing")
    createFixtureFile(path)
    defer { unlink(path) }

    let fd = try LinuxSys.openWriteCreate(path)
    let payload = Array("replaced".utf8)
    _ = try payload.withUnsafeBytes { buf in try LinuxSys.write(fd, buf) }
    LinuxSys.close(fd)

    #expect(readWholeFile(path) == payload)
}

private func readWholeFile(_ path: String) -> [UInt8] {
    let fd = Glibc.open(path, O_RDONLY)
    guard fd >= 0 else { return [] }
    defer { Glibc.close(fd) }
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64)
    while true {
        let n = chunk.withUnsafeMutableBytes { buf in Glibc.read(fd, buf.baseAddress, buf.count) }
        if n <= 0 { break }
        out.append(contentsOf: chunk[0..<n])
    }
    return out
}

@Test func openWriteExistingNeverCreatesAFile() {
    let path = tempPath("no-create")

    #expect(throws: SysError.self) {
        _ = try LinuxSys.openWriteExisting(path)
    }

    var st = stat()
    #expect(stat(path, &st) != 0, "openWriteExisting must not have created \(path)")
}
