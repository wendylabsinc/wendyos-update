import Testing

@testable import Tar

/// Builds a single 512-byte ustar header block for a regular file member.
///
/// Mirrors the subset of fields Go's `archive/tar` writer populates and
/// that `TarReader` needs to parse: name, size (octal, NUL-terminated),
/// typeflag, magic/version, and a checksum computed the same way `archive/tar`
/// computes it (sum of all header bytes with the checksum field treated as
/// eight ASCII spaces).
private func makeUstarHeader(name: String, size: Int) -> [UInt8] {
    var block = [UInt8](repeating: 0, count: 512)

    func write(_ string: String, at offset: Int, length: Int) {
        let bytes = Array(string.utf8)
        precondition(bytes.count <= length, "field value too long for ustar header")
        for i in 0..<bytes.count {
            block[offset + i] = bytes[i]
        }
    }

    // name: offset 0, length 100
    write(name, at: 0, length: 100)
    // mode: offset 100, length 8 (octal, NUL-terminated) — not exercised by TarReader, but keep it well-formed.
    write("0000644\0", at: 100, length: 8)
    // uid: offset 108, length 8
    write("0000000\0", at: 108, length: 8)
    // gid: offset 116, length 8
    write("0000000\0", at: 116, length: 8)
    // size: offset 124, length 12 (octal, NUL-terminated)
    let octalSize = String(size, radix: 8)
    write(String(repeating: "0", count: 11 - octalSize.count) + octalSize + "\0", at: 124, length: 12)
    // mtime: offset 136, length 12
    write("00000000000\0", at: 136, length: 12)
    // chksum: offset 148, length 8 — filled below with spaces first.
    write("        ", at: 148, length: 8)
    // typeflag: offset 156, length 1 — '0' = regular file
    write("0", at: 156, length: 1)
    // magic: offset 257, length 6
    write("ustar\0", at: 257, length: 6)
    // version: offset 263, length 2
    write("00", at: 263, length: 2)

    // Checksum: unsigned sum of all 512 bytes with the checksum field
    // treated as eight ASCII spaces, formatted as a 6-digit zero-padded
    // octal number followed by a NUL and a space (as archive/tar writes it).
    let sum = block.reduce(0) { $0 + Int($1) }
    let octalChecksum = String(sum, radix: 8)
    let padded = String(repeating: "0", count: 6 - octalChecksum.count) + octalChecksum
    write(padded + "\0 ", at: 148, length: 8)

    return block
}

/// Pads `bytes` up to the next 512-byte boundary with zero bytes, matching
/// tar's block alignment for member bodies.
private func padToBlock(_ bytes: [UInt8]) -> [UInt8] {
    var result = bytes
    let remainder = result.count % 512
    if remainder != 0 {
        result.append(contentsOf: [UInt8](repeating: 0, count: 512 - remainder))
    }
    return result
}

/// Wraps a fixed byte buffer in the pull-source closure shape `TarReader` expects.
private func makeSource(_ bytes: [UInt8]) -> (inout [UInt8], Int) throws -> Int {
    var offset = 0
    return { buf, max in
        guard offset < bytes.count else { return 0 }
        let n = min(max, bytes.count - offset)
        buf = Array(bytes[offset..<(offset + n)])
        offset += n
        return n
    }
}

@Test func readsSingleMemberWithBodyAndTrailer() throws {
    var archive = makeUstarHeader(name: "manifest.json", size: 5)
    archive += padToBlock(Array("hello".utf8))
    // Two zero blocks mark end-of-archive.
    archive += [UInt8](repeating: 0, count: 1024)

    let reader = TarReader(makeSource(archive))

    let entry = try reader.next()
    #expect(entry?.name == "manifest.json")
    #expect(entry?.size == 5)

    var buf = [UInt8](repeating: 0, count: 16)
    let n = try reader.read(into: &buf)
    #expect(n == 5)
    #expect(Array(buf[0..<n]) == Array("hello".utf8))

    // Body is fully consumed.
    let n2 = try reader.read(into: &buf)
    #expect(n2 == 0)

    // No further members.
    let next = try reader.next()
    #expect(next == nil)
}

@Test func normalizesLeadingDotSlashInMemberName() throws {
    var archive = makeUstarHeader(name: "./manifest.json", size: 5)
    archive += padToBlock(Array("hello".utf8))
    archive += [UInt8](repeating: 0, count: 1024)

    let reader = TarReader(makeSource(archive))

    let entry = try reader.next()
    #expect(entry?.name == "manifest.json")
    #expect(entry?.size == 5)
}

@Test func emptyArchiveReturnsNilImmediately() throws {
    let reader = TarReader(makeSource([]))
    let entry = try reader.next()
    #expect(entry == nil)
}

@Test func truncatedHeaderThrows() throws {
    // Fewer than 512 bytes and not a clean EOF at a block boundary.
    let archive = [UInt8](repeating: 0x41, count: 100)
    let reader = TarReader(makeSource(archive))
    #expect(throws: TarError.self) {
        try reader.next()
    }
}
