import CLIError

/// Errors surfaced by the `Engine`. Every case maps to one of the CLI's
/// documented exit codes (docs/cli-contract.md).
public enum EngineError: Error, Equatable, ExitCoded {
    /// Artifact-rejection condition: exit code 3. The slot was either
    /// untouched or only written — never swapped. Ports `engine.RejectError`
    /// in internal/engine/engine.go.
    case rejected(String)
    /// An update is already in flight; `install` refuses to start a second
    /// one. Ports the ad hoc `fmt.Errorf` at the top of `Engine.Install` in
    /// internal/engine/engine.go.
    case updateInFlight(phase: String, artifact: String)
    /// The device-type file is missing, unreadable, or has no `BOARD=`
    /// line. Ports `Engine.deviceType`'s error in internal/engine/engine.go.
    case deviceType(String)

    public var exitCode: Int32 {
        if case .rejected = self { return 3 }
        return 1
    }
}
