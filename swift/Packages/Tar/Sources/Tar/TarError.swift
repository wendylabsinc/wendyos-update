/// Errors surfaced while parsing a ustar-format tar stream.
public enum TarError: Error, Equatable {
    /// The stream ended in the middle of a header or member body.
    case truncated
    /// A header block failed validation (bad magic/checksum/octal field).
    case badHeader
    /// The stream is not recognized as a tar stream at all.
    case notTar
}
