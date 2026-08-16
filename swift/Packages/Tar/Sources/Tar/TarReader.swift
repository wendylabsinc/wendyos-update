/// Streaming reader over a ustar-format tar archive, pulling bytes from a
/// caller-supplied read closure rather than owning any I/O itself.
///
/// Usage: call `next()` to advance to each member's header, then `read(into:)`
/// repeatedly (returns 0 once the member body is fully consumed) before
/// calling `next()` again. `next()` automatically skips any unread bytes
/// (and block padding) left over from the previous member.
///
/// `@unchecked Sendable`: a `TarReader` is never accessed concurrently —
/// every method call happens strictly in sequence — but ownership can
/// legitimately move between execution contexts (e.g. `wendyos-update`'s
/// `install <url>` bridges a `TarReader` fed by an async HTTP body task
/// over to a dedicated `Thread` that drives `ArtifactReader`/`Engine
/// .install`'s synchronous pull loop). The pull closure itself is a plain
/// `(inout [UInt8], Int) throws -> Int`, not `@Sendable`, precisely
/// because callers construct it inline with mutable local captures (an fd,
/// a byte offset) that are likewise only ever touched from the single
/// logical owner at a time.
public final class TarReader: @unchecked Sendable {
    /// Pull source: fills `into` with up to `max` bytes and returns the
    /// count actually read; 0 means the source is exhausted.
    private let pull: (_ into: inout [UInt8], _ max: Int) throws -> Int

    /// Bytes of the current member's body not yet returned by `read(into:)`.
    private var remaining: Int64 = 0
    /// Padding bytes after the current member's body, up to the next
    /// 512-byte boundary, not yet skipped.
    private var pad: Int = 0
    /// Set once the end-of-archive marker (or a clean EOF) has been seen;
    /// short-circuits further `next()` calls.
    private var finished = false
    /// Whether any member header has been successfully parsed yet — used
    /// to decide between `.notTar` and `.badHeader` on a checksum failure.
    private var sawAnyMember = false

    public init(_ read: @escaping (_ into: inout [UInt8], _ max: Int) throws -> Int) {
        self.pull = read
    }

    /// Advances to the next member's header. Returns `nil` at the end of
    /// the archive (a standard two-zero-block trailer, or a clean EOF in
    /// its place).
    public func next() throws -> TarEntry? {
        if finished { return nil }

        try skipToNextHeader()

        guard let block = try readFull(TarHeader.blockSize) else {
            finished = true
            return nil
        }

        if TarHeader.isZeroBlock(block) {
            // Standard trailer is two zero blocks; tolerate a truncated
            // archive that ends right after the first one too.
            if let block2 = try readFull(TarHeader.blockSize), !TarHeader.isZeroBlock(block2) {
                throw TarError.badHeader
            }
            finished = true
            return nil
        }

        let header = try TarHeader.parse(block, isFirstMember: !sawAnyMember)
        sawAnyMember = true
        remaining = header.size
        pad = header.size > 0 ? Int((512 - (header.size % 512)) % 512) : 0

        return TarEntry(name: header.name, size: header.size)
    }

    /// Reads up to `buf.count` bytes of the current member's body into
    /// `buf` (filling from index 0), returning the number of bytes read.
    /// Returns 0 once the member's body has been fully consumed.
    public func read(into buf: inout [UInt8]) throws -> Int {
        guard remaining > 0, !buf.isEmpty else { return 0 }

        let want = Int(min(remaining, Int64(buf.count)))
        var chunk: [UInt8] = []
        let got = try pull(&chunk, want)
        if got == 0 {
            throw TarError.truncated
        }
        precondition(got <= want, "read closure returned more bytes than requested")

        for i in 0..<got {
            buf[i] = chunk[i]
        }
        remaining -= Int64(got)
        return got
    }

    /// Drains any unread body bytes and block padding left over from the
    /// previously-returned member, so the next read lands on a header
    /// boundary.
    private func skipToNextHeader() throws {
        while remaining > 0 {
            let want = Int(min(remaining, 64 * 1024))
            var chunk: [UInt8] = []
            let got = try pull(&chunk, want)
            if got == 0 { throw TarError.truncated }
            remaining -= Int64(got)
        }

        var toSkip = pad
        while toSkip > 0 {
            var chunk: [UInt8] = []
            let got = try pull(&chunk, toSkip)
            if got == 0 { throw TarError.truncated }
            toSkip -= got
        }
        pad = 0
    }

    /// Reads exactly `n` bytes from the pull source, looping over partial
    /// reads. Returns `nil` only for a clean EOF with zero bytes read so
    /// far (i.e. the source had nothing left at all); a partial read
    /// followed by EOF is a `.truncated` error.
    private func readFull(_ n: Int) throws -> [UInt8]? {
        var result = [UInt8]()
        result.reserveCapacity(n)
        while result.count < n {
            let want = n - result.count
            var chunk: [UInt8] = []
            let got = try pull(&chunk, want)
            if got == 0 {
                if result.isEmpty { return nil }
                throw TarError.truncated
            }
            precondition(got <= want, "read closure returned more bytes than requested")
            result.append(contentsOf: chunk.prefix(got))
        }
        return result
    }
}
