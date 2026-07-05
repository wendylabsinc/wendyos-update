import Model

// State persistence (schema: docs/state-schema.md). Ports the
// `LoadState`/`SaveState`/`ClearState` trio in internal/engine/engine.go —
// one JSON file, atomic replace, no database.

extension Engine {
    func statePath() -> String {
        stateDir.hasSuffix("/") ? "\(stateDir)state.json" : "\(stateDir)/state.json"
    }

    /// Returns `nil` when no update is in flight (the state file doesn't
    /// exist) rather than throwing — ports `Engine.LoadState`'s
    /// `os.IsNotExist` -> `nil, nil` short-circuit.
    public func loadState() throws -> State? {
        let path = statePath()
        guard fs.exists(path) else { return nil }
        let bytes = try fs.read(path)
        return try JSONCodec.decodeState(bytes)
    }

    /// Persists atomically: `fs.writeAtomic` does the tmp+fsync+rename
    /// dance (`RealFileStore.writeAtomic`). The bytes are 2-space-indented
    /// JSON with a trailing newline — `JSONCodec.encodePretty`, verified
    /// byte-for-byte against Go's `json.MarshalIndent` output in Task 2.2 —
    /// never hand-rolled here.
    public func saveState(_ s: State) throws {
        let bytes = JSONCodec.encodePretty(s.makeJSONObject())
        try fs.writeAtomic(statePath(), bytes, mode: 0o644)
    }

    /// Removes the state file. A path that doesn't exist is not an error —
    /// ports `Engine.ClearState`'s `os.IsNotExist` swallow.
    public func clearState() throws {
        try fs.remove(statePath())
    }
}
