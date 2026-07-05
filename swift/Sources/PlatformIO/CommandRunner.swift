/// The outcome of a completed, fully-collected subprocess run.
public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: [UInt8]
    public let stderr: [UInt8]

    public init(exitCode: Int32, stdout: [UInt8], stderr: [UInt8]) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs external processes. Ports `exec.Command` usage in
/// `engine/hooks.go`: lifecycle hooks run to completion with their output
/// line-logged live (`runStreaming`); other callers just need the
/// collected result (`run`).
public protocol CommandRunner: Sendable {
    /// Runs `argv` to completion, collecting stdout/stderr in full.
    /// `argv[0]` is the executable (a `/`-containing value is used
    /// directly; a bare name is resolved against `PATH`). `env`, when
    /// non-nil, is applied as overrides on top of the inherited
    /// environment; `nil` means "inherit only". `stdin`, when non-nil, is
    /// written to the child's standard input before closing it.
    func run(_ argv: [String], env: [String: String]?, stdin: [UInt8]?) async throws -> CommandResult

    /// Runs `argv` to completion, invoking `onLine` once per line of
    /// standard output as it arrives (standard error is discarded) —
    /// for hooks whose output is logged live rather than collected.
    /// `env` is always applied as overrides on top of the inherited
    /// environment. Returns the process's exit code.
    func runStreaming(_ argv: [String], env: [String: String], onLine: @Sendable (String) -> Void) async throws -> Int32
}
