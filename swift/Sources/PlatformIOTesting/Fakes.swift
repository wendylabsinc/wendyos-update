import PlatformIO

// In-memory fakes for `PlatformIO`'s protocols, split into their own
// target so later test suites (Engine, connectors) can depend on the
// fakes without pulling in `PlatformIOTests`. None of these are
// thread-safe: tests use them from a single task, sequentially.

/// An in-memory `FileStore`. Paths are plain string keys — there's no
/// real filesystem underneath, so `mkdirp` just records that a directory
/// "exists" and `listDir` looks up entries whose recorded parent is the
/// requested path.
public final class FakeFileStore: FileStore, @unchecked Sendable {
    private var files: [String: [UInt8]] = [:]
    private var executableFiles: Set<String> = []
    private var directories: Set<String> = ["/"]

    public init() {}

    public func read(_ path: String) throws -> [UInt8] {
        guard let bytes = files[Self.normalize(path)] else {
            throw FakeFileStoreError.notFound(path)
        }
        return bytes
    }

    public func exists(_ path: String) -> Bool {
        let path = Self.normalize(path)
        return files[path] != nil || directories.contains(path)
    }

    public func writeAtomic(_ path: String, _ bytes: [UInt8], mode: UInt32) throws {
        let path = Self.normalize(path)
        let dir = Self.parentDirectory(of: path)
        if !dir.isEmpty {
            try mkdirp(dir, mode: 0o755)
        }
        files[path] = bytes
        if mode & 0o111 != 0 {
            executableFiles.insert(path)
        } else {
            executableFiles.remove(path)
        }
    }

    public func remove(_ path: String) throws {
        let path = Self.normalize(path)
        files.removeValue(forKey: path)
        executableFiles.remove(path)
    }

    public func mkdirp(_ path: String, mode: UInt32) throws {
        var prefix = ""
        for component in Self.normalize(path).split(separator: "/") {
            prefix += "/\(component)"
            directories.insert(prefix)
        }
    }

    public func listDir(_ path: String) throws -> [DirEntry] {
        let path = Self.normalize(path)
        guard directories.contains(path) else {
            throw FakeFileStoreError.notFound(path)
        }
        var entries: [String: DirEntry] = [:]
        for filePath in files.keys where Self.parentDirectory(of: filePath) == path {
            let name = String(filePath.split(separator: "/").last!)
            entries[name] = DirEntry(name: name, isDir: false, isExecutable: executableFiles.contains(filePath))
        }
        for dirPath in directories where dirPath != path && Self.parentDirectory(of: dirPath) == path {
            let name = String(dirPath.split(separator: "/").last!)
            entries[name] = DirEntry(name: name, isDir: true, isExecutable: false)
        }
        return entries.values.sorted { $0.name < $1.name }
    }

    private static func normalize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func parentDirectory(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "" }
        let parent = String(path[path.startIndex..<idx])
        return parent.isEmpty ? "/" : parent
    }
}

public enum FakeFileStoreError: Error, Equatable {
    case notFound(String)
}

/// A `CommandRunner` that records every `argv` it's asked to run and
/// returns a scripted `CommandResult` keyed by `argv[0]`. Unscripted
/// commands default to a clean exit with no output.
public final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    public private(set) var invocations: [[String]] = []
    private var scripts: [String: CommandResult] = [:]

    public init() {}

    /// Scripts the result `run`/`runStreaming` return the next (and every
    /// subsequent) time `argv[0] == command`.
    public func script(_ command: String, result: CommandResult) {
        scripts[command] = result
    }

    public func run(_ argv: [String], env: [String: String]?, stdin: [UInt8]?) async throws -> CommandResult {
        invocations.append(argv)
        guard let command = argv.first else {
            return CommandResult(exitCode: 0, stdout: [], stderr: [])
        }
        return scripts[command] ?? CommandResult(exitCode: 0, stdout: [], stderr: [])
    }

    public func runStreaming(
        _ argv: [String],
        env: [String: String],
        onLine: @Sendable (String) -> Void
    ) async throws -> Int32 {
        invocations.append(argv)
        guard let command = argv.first, let scripted = scripts[command] else {
            return 0
        }
        for line in Self.splitLines(scripted.stdout) {
            onLine(line)
        }
        return scripted.exitCode
    }

    private static func splitLines(_ bytes: [UInt8]) -> [String] {
        String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}

/// A fixed `Clock` for deterministic timestamp assertions.
public struct FixedClock: Clock {
    private let fixed: String

    public init(_ fixed: String) {
        self.fixed = fixed
    }

    public func nowUTCISO8601() -> String {
        fixed
    }
}

/// An `EnvReader` backed by a plain dictionary.
public struct MapEnv: EnvReader {
    private let values: [String: String]

    public init(_ values: [String: String]) {
        self.values = values
    }

    public func get(_ key: String) -> String? {
        values[key]
    }
}

/// A `WritableDevice` that records everything written to it in memory.
public final class FakeWritableDevice: WritableDevice {
    public private(set) var written: [UInt8] = []
    public private(set) var syncCount = 0
    public private(set) var closed = false

    public init() {}

    public func write(_ b: ArraySlice<UInt8>) throws {
        written.append(contentsOf: b)
    }

    public func sync() throws {
        syncCount += 1
    }

    public func close() {
        closed = true
    }
}

/// A `BlockTarget` backed by scripted per-path capacities and in-memory
/// `FakeWritableDevice`s (one per path, created lazily and reused across
/// repeated `openForWrite` calls on the same path).
public final class FakeBlockTarget: BlockTarget, @unchecked Sendable {
    public private(set) var openedPaths: [String] = []
    public var capacities: [String: Int64] = [:]
    public private(set) var devices: [String: FakeWritableDevice] = [:]

    public init() {}

    public func openForWrite(_ path: String) throws -> any WritableDevice {
        openedPaths.append(path)
        let device = devices[path] ?? FakeWritableDevice()
        devices[path] = device
        return device
    }

    public func capacity(_ path: String) throws -> Int64 {
        guard let cap = capacities[path] else {
            throw FakeBlockTargetError.unknownPath(path)
        }
        return cap
    }
}

public enum FakeBlockTargetError: Error, Equatable {
    case unknownPath(String)
}
