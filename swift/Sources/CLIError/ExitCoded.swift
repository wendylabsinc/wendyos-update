// Shared error protocol for `wendyos-update`'s CLI-facing error types.
//
// Every layer that can fail terminally (artifact validation, the
// connector, the engine, the CLI itself) defines its own `Error` enum, but
// they all need to answer the same question at the top of `main`: "what
// process exit code does this failure map to?" `ExitCoded` is that single
// shared answer, declared once here so downstream targets (Artifact,
// Connector, Engine, WendyUpdate) conform their own error types to it
// instead of each redeclaring the protocol.
public protocol ExitCoded: Error {
    var exitCode: Int32 { get }
}
