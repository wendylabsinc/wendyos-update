/// Filesystem side effects the engine needs: reading a whole file, an
/// atomic (tmp+fsync+rename) write, directory creation/listing, and
/// removal. Ports the file-IO scattered through `engine/*.go` —
/// `os.ReadFile`, the tmp+fsync+rename dance in `SaveState`, and
/// `os.ReadDir` (used to discover hook scripts).
public protocol FileStore: Sendable {
    /// Reads the whole file at `path`, throwing if it doesn't exist or
    /// can't be read.
    func read(_ path: String) throws -> [UInt8]

    /// Reports whether `path` exists (file or directory).
    func exists(_ path: String) -> Bool

    /// Writes `bytes` to `path` such that a concurrent reader never
    /// observes a partial write: the implementation writes to a sibling
    /// temp file, flushes it to stable storage, then atomically renames
    /// it over `path`. Creates any missing parent directories first.
    func writeAtomic(_ path: String, _ bytes: [UInt8], mode: UInt32) throws

    /// Removes `path`. A path that doesn't exist is not an error.
    func remove(_ path: String) throws

    /// Creates `path` and any missing parent directories (`mkdir -p`).
    /// Already-existing directories are not an error.
    func mkdirp(_ path: String, mode: UInt32) throws

    /// Lists the immediate children of the directory at `path`.
    func listDir(_ path: String) throws -> [DirEntry]
}

/// One entry returned by `FileStore.listDir`.
public struct DirEntry: Sendable {
    public let name: String
    public let isDir: Bool
    public let isExecutable: Bool

    public init(name: String, isDir: Bool, isExecutable: Bool) {
        self.name = name
        self.isDir = isDir
        self.isExecutable = isExecutable
    }
}
