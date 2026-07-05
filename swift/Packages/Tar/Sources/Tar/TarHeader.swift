/// Parsed fields of a single 512-byte ustar header block, plus the
/// low-level helpers `TarReader` needs to validate and decode one.
///
/// Field offsets follow the standard (POSIX ustar) tar header layout:
/// name(0,100) mode(100,8) uid(108,8) gid(116,8) size(124,12) mtime(136,12)
/// chksum(148,8) typeflag(156,1) linkname(157,100) magic(257,6) version(263,2)
/// uname(265,32) gname(297,32) devmajor(329,8) devminor(337,8) prefix(345,155).
enum TarHeader {
    static let blockSize = 512

    /// True if every byte in the block is zero — tar marks end-of-archive
    /// with (conventionally) two such blocks in a row.
    static func isZeroBlock(_ block: [UInt8]) -> Bool {
        block.allSatisfy { $0 == 0 }
    }

    /// Parses `name` and `size` out of a raw header block.
    ///
    /// - Parameter isFirstMember: when true, a checksum failure is reported
    ///   as `.notTar` (the stream likely isn't a tar archive at all);
    ///   otherwise it's reported as `.badHeader` (corruption mid-stream).
    static func parse(_ block: [UInt8], isFirstMember: Bool) throws -> (name: String, size: Int64) {
        precondition(block.count == blockSize)

        guard try validChecksum(block) else {
            throw isFirstMember ? TarError.notTar : TarError.badHeader
        }

        let name = decodeField(block, 0, 100)
        let size = try parseOctal(block[124..<136])

        // POSIX ustar (and GNU, which also stamps "ustar" but leaves the
        // prefix field unused) store a long-name prefix at offset 345.
        let magic = decodeField(block, 257, 6)
        var fullName = name
        if magic.hasPrefix("ustar") {
            let prefix = decodeField(block, 345, 155)
            if !prefix.isEmpty {
                fullName = prefix + "/" + name
            }
        }

        return (name: memberName(fullName), size: size)
    }

    /// Mirrors Go's `memberName` (internal/artifact/reader.go:110):
    /// path-clean the raw header name, then strip a leading "./".
    static func memberName(_ rawName: String) -> String {
        var cleaned = TarPath.clean(rawName)
        if cleaned.hasPrefix("./") {
            cleaned.removeFirst(2)
        }
        return cleaned
    }

    /// Decodes a fixed-width header field as a NUL-terminated ASCII string
    /// (trailing NULs/spaces are dropped; tar pads unused field bytes with
    /// either).
    private static func decodeField(_ block: [UInt8], _ offset: Int, _ length: Int) -> String {
        var end = offset
        let limit = offset + length
        while end < limit, block[end] != 0 {
            end += 1
        }
        var bytes = block[offset..<end]
        while let last = bytes.last, last == 0x20 {
            bytes = bytes.dropLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Parses a NUL/space-terminated octal field (used for size, mode, etc).
    /// Tolerates leading padding of either spaces or zeros.
    private static func parseOctal(_ field: ArraySlice<UInt8>) throws -> Int64 {
        var value: Int64 = 0
        var sawDigit = false
        for byte in field {
            if byte == 0 || byte == 0x20 {
                if sawDigit { break }
                continue
            }
            guard byte >= 0x30, byte <= 0x37 else {
                throw TarError.badHeader
            }
            value = value * 8 + Int64(byte - 0x30)
            sawDigit = true
        }
        return value
    }

    /// Validates the header checksum the way Go's `archive/tar` does:
    /// compute the sum of all 512 bytes (with the checksum field itself
    /// treated as eight ASCII spaces) both as unsigned and as signed
    /// bytes, and accept either — some old implementations wrote a
    /// signed-byte checksum.
    private static func validChecksum(_ block: [UInt8]) throws -> Bool {
        let want = try parseOctal(block[148..<156])

        var unsigned: Int64 = 0
        var signed: Int64 = 0
        for i in 0..<blockSize {
            let byte: UInt8 = (i >= 148 && i < 156) ? 0x20 : block[i]
            unsigned += Int64(byte)
            signed += Int64(Int8(bitPattern: byte))
        }

        return want == unsigned || want == signed
    }
}
