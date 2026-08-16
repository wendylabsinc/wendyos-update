/// The current time, abstracted so tests can fix it. Ports the RFC3339
/// timestamps `engine/*.go` stamps into state/logs.
public protocol Clock: Sendable {
    /// The current UTC time as RFC3339 `"2006-01-02T15:04:05Z"` (no
    /// fractional seconds; always `Z`, never a numeric offset).
    func nowUTCISO8601() -> String
}
