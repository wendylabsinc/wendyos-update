// Slot identifies one of the two A/B rootfs slots.
//
// Ports `internal/connector/connector.go`'s `Slot` type — same ordinal
// values (`SlotA` == 0, `SlotB` == 1) so any wire/JSON representation that
// leaks a raw ordinal stays compatible with the Go implementation.
public enum Slot: Int, Sendable, CustomStringConvertible {
    case a = 0
    case b = 1

    /// The other slot: `.a.other == .b` and vice versa.
    public var other: Slot {
        self == .a ? .b : .a
    }

    public var description: String {
        self == .a ? "A" : "B"
    }
}

/// Display-only per-slot health from the connector. Empty fields are
/// omitted by the `status` formatter.
///
/// Ports `connector.go`'s `SlotStatus` struct.
public struct SlotStatus: Sendable {
    /// "normal" | "unbootable" | "" (n/a)
    public var rootfsHealth: String = ""
    /// Remaining trial attempts; "" if n/a.
    public var retries: String = ""
    /// Free-form per-slot note (e.g. trial state).
    public var note: String = ""

    public init() {}
}

/// An ordered display key/value pair (system-wide status lines).
///
/// Ports `connector.go`'s `KV` struct.
public struct KV: Sendable {
    public let key: String
    public let value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}
