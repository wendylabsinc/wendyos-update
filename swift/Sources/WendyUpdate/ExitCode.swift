import CLIError
import Engine

// Exit-code mapping (docs/cli-contract.md): 0 ok · 1 error · 2 nothing-to-
// commit · 3 artifact rejected · 4 platform verification failed. Ports
// `cmd/wendyos-update/main.go`'s `exitCode(err)`.

/// Maps a thrown domain error to the CLI's documented process exit code via
/// `ExitCoded` — every error type this tool throws from inside a verb's
/// `run()` (`CommitError`, `ArtifactError`, `EngineError`, `HookError`,
/// `ConnectorError`, `BlockDevError`, `RollbackError`, `SwitchError`, ...)
/// already conforms. An error that doesn't conform (including argument-
/// parser plumbing errors, which `WendyUpdate`'s subcommands never let
/// reach here — see `runVerb`) falls back to 1, matching Go's `exitCode`'s
/// unconditional `return exitError` at the end of its type-switch chain.
func mapExit(_ error: any Error) -> Int32 {
    (error as? any ExitCoded)?.exitCode ?? 1
}

/// True only for `commit`'s ordinary "nothing pending" outcome (exit 2) —
/// the normal result of the auto-commit unit running on every boot without
/// a trial update in flight. The CLI logs this at info, not error, so it
/// doesn't show up red/high-priority in the journal. Ports main.go's
/// `errors.Is(err, engine.ErrNothingToCommit)` special case in `main()`.
func isNothingToCommit(_ error: any Error) -> Bool {
    (error as? CommitError)?.kind == .nothingToCommit
}
