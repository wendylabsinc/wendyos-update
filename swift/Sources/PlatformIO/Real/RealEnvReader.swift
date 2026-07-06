#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
// The static-musl cross-compilation SDK exposes libc under the
// `Musl` overlay module instead of `Glibc` (see LinuxSys.swift for
// the fuller explanation); every symbol this file uses exists
// identically in both.
import Musl
#endif

/// `EnvReader` over `getenv(3)`. Ports `os.Getenv` usage in
/// `log.go`/`main.go`.
public struct RealEnvReader: EnvReader {
    public init() {}

    public func get(_ key: String) -> String? {
        guard let value = getenv(key) else { return nil }
        return String(cString: value)
    }
}
