/// Streaming writer for a ustar-format tar archive, pushing bytes to a
/// caller-supplied write closure rather than owning any I/O itself.
///
/// Usage: call `writeHeader(name:size:mode:)` to start a member, then
/// `write(_:)` one or more times with exactly `size` bytes total, repeating
/// for each subsequent member, then `finish()` once at the end. Mirrors the
/// write side of Go's `archive/tar` as used by `internal/artifact/writer.go`:
/// a fixed member order (caller-controlled), ustar headers, and a
/// two-zero-block trailer.
public final class TarWriter {
    /// Push sink: hands a chunk of archive bytes to the caller (e.g. a file
    /// handle or in-memory buffer).
    private let push: (_ chunk: [UInt8]) throws -> Void

    /// Declared size of the member currently being written.
    private var currentSize: Int64 = 0
    /// Bytes written so far for the current member's body.
    private var currentWritten: Int64 = 0
    /// Whether a header has been written without a matching `finish()`'s
    /// padding yet — used to pad/validate the previous member before
    /// starting the next one.
    private var hasOpenMember = false

    public init(_ write: @escaping (_ chunk: [UInt8]) throws -> Void) {
        self.push = write
    }

    /// Starts a new member: pads the previous member's body to the next
    /// 512-byte boundary (if any), then writes this member's ustar header
    /// block. `size` bytes must follow via `write(_:)` before the next call
    /// to `writeHeader` or `finish`.
    public func writeHeader(name: String, size: Int64, mode: UInt32) throws {
        try closeCurrentMember()

        let nameBytes = Array(name.utf8)
        guard nameBytes.count <= 100 else { throw TarError.badHeader }

        var block = [UInt8](repeating: 0, count: TarHeader.blockSize)
        for i in 0..<nameBytes.count { block[i] = nameBytes[i] }

        Self.writeOctal(UInt64(mode), into: &block, at: 100, length: 8)
        Self.writeOctal(0, into: &block, at: 108, length: 8) // uid
        Self.writeOctal(0, into: &block, at: 116, length: 8) // gid
        Self.writeOctal(UInt64(size), into: &block, at: 124, length: 12) // size
        Self.writeOctal(0, into: &block, at: 136, length: 12) // mtime
        // chksum (148, 8): filled below, treated as spaces while summing.
        block[156] = UInt8(ascii: "0") // typeflag: regular file
        let magic = Array("ustar\0".utf8)
        for i in 0..<magic.count { block[257 + i] = magic[i] }
        block[263] = UInt8(ascii: "0") // version
        block[264] = UInt8(ascii: "0")

        for i in 148..<156 { block[i] = 0x20 } // spaces, per checksum convention
        let sum = block.reduce(0) { $0 + UInt64($1) }
        Self.writeOctalChecksum(sum, into: &block)

        try push(block)

        currentSize = size
        currentWritten = 0
        hasOpenMember = true
    }

    /// Writes body bytes for the current member. The total across all calls
    /// since the last `writeHeader` must equal that call's `size`.
    public func write(_ bytes: ArraySlice<UInt8>) throws {
        guard hasOpenMember else { throw TarError.badHeader }
        currentWritten += Int64(bytes.count)
        guard currentWritten <= currentSize else { throw TarError.badHeader }
        try push(Array(bytes))
    }

    /// Pads the final member's body (if any) to a 512-byte boundary, then
    /// writes the standard two-zero-block end-of-archive trailer.
    public func finish() throws {
        try closeCurrentMember()
        try push([UInt8](repeating: 0, count: TarHeader.blockSize))
        try push([UInt8](repeating: 0, count: TarHeader.blockSize))
    }

    /// Pads the currently-open member's body to the next 512-byte boundary
    /// and clears the open-member state. No-op if no member is open.
    private func closeCurrentMember() throws {
        guard hasOpenMember else { return }
        guard currentWritten == currentSize else { throw TarError.badHeader }

        let remainder = Int(currentSize % 512)
        if remainder != 0 {
            try push([UInt8](repeating: 0, count: 512 - remainder))
        }
        hasOpenMember = false
    }

    /// Writes an octal-encoded, NUL-terminated numeric field: `length - 1`
    /// zero-padded octal digits followed by a NUL, matching the layout
    /// `TarHeader.parse` expects.
    private static func writeOctal(_ value: UInt64, into block: inout [UInt8], at offset: Int, length: Int) {
        let digitCount = length - 1
        var digits = String(value, radix: 8)
        precondition(digits.count <= digitCount, "value too large for ustar octal field")
        digits = String(repeating: "0", count: digitCount - digits.count) + digits

        let bytes = Array(digits.utf8)
        for i in 0..<bytes.count { block[offset + i] = bytes[i] }
        block[offset + digitCount] = 0
    }

    /// Writes the checksum field (offset 148, length 8) as a 6-digit
    /// zero-padded octal number followed by a NUL and a space, matching the
    /// format Go's `archive/tar` writes.
    private static func writeOctalChecksum(_ sum: UInt64, into block: inout [UInt8]) {
        var digits = String(sum, radix: 8)
        precondition(digits.count <= 6, "checksum overflowed ustar checksum field")
        digits = String(repeating: "0", count: 6 - digits.count) + digits

        let bytes = Array(digits.utf8) + [0, 0x20]
        for i in 0..<bytes.count { block[148 + i] = bytes[i] }
    }
}
