import Glibc

/// `EnvReader` over `getenv(3)`. Ports `os.Getenv` usage in
/// `log.go`/`main.go`.
public struct RealEnvReader: EnvReader {
    public init() {}

    public func get(_ key: String) -> String? {
        guard let value = getenv(key) else { return nil }
        return String(cString: value)
    }
}
