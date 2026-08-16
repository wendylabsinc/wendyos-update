/// Reads process environment variables. Ports `os.Getenv` usage in
/// `log.go`/`main.go`.
public protocol EnvReader: Sendable {
    /// Returns the value of `key`, or `nil` if it's unset.
    func get(_ key: String) -> String?
}
