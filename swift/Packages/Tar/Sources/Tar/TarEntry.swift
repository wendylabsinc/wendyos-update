/// A single member of a tar archive, as reported by `TarReader.next()`.
public struct TarEntry: Sendable {
    /// The normalized member name (`./foo` and `foo` are equivalent; see
    /// `TarReader`'s name-normalization, which mirrors Go's
    /// `internal/artifact/reader.go` `memberName` helper).
    public let name: String

    /// The size, in bytes, of the member's body.
    public let size: Int64
}
