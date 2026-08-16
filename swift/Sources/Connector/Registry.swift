import CLIError

/// Creates a connector and detects whether its platform is present.
///
/// Ports `internal/connector/registry.go`'s `Factory` struct. Unlike Go,
/// where connector packages register themselves into a global map via a
/// side-effecting `init()`, registration here is explicit: the executable
/// builds the list of built-in factories (e.g. `[TegraUEFI.factory,
/// UBootEnv.factory]`) and passes it into `ConnectorRegistry.select` —
/// Swift has no package-level `init()` to hang global mutable state off
/// of, and an explicit list is easier to unit test besides.
public struct ConnectorFactory: Sendable {
    /// The connector's registered name (config key, `--connector`
    /// selection, error messages).
    public let name: String
    /// Creates a fresh instance of the connector.
    public let make: @Sendable () -> any Connector
    /// Reports whether this connector's platform is present. Must be
    /// cheap and must not mutate anything.
    public let detect: @Sendable () -> Bool

    public init(
        name: String,
        make: @escaping @Sendable () -> any Connector,
        detect: @escaping @Sendable () -> Bool
    ) {
        self.name = name
        self.make = make
        self.detect = detect
    }
}

/// Errors from `ConnectorRegistry.select`.
///
/// Ports the two `fmt.Errorf` failure paths in `registry.go`'s `Select`.
/// All three cases are equally fatal on the OTA path: never guess which
/// connector to drive.
public enum ConnectorError: Error, Equatable, ExitCoded {
    /// An explicitly named connector isn't in the candidate list. `have`
    /// is the sorted list of built-in names.
    case notBuiltIn(name: String, have: [String])
    /// Auto-detection found no match. `have` is the sorted list of
    /// built-in names.
    case noneDetected(have: [String])
    /// Auto-detection found more than one match. The associated array is
    /// the sorted list of matching names.
    case ambiguous([String])

    public var exitCode: Int32 { 1 }
}

extension ConnectorError: CustomStringConvertible {
    /// Matches `registry.go`'s `fmt.Errorf` messages verbatim, including
    /// Go's `%q` (double-quoted) and `%v` (space-separated, bracketed)
    /// slice formatting, so a caller that surfaces this text to a user or
    /// log sees the same wording either implementation produces.
    public var description: String {
        switch self {
        case .notBuiltIn(let name, let have):
            return "connector \"\(name)\" not built into this binary (have: \(Self.goSlice(have)))"
        case .noneDetected(let have):
            return
                "no connector detected this platform (have: \(Self.goSlice(have)))"
                + "; set one in /etc/wendyos-update/config.json"
        case .ambiguous(let matches):
            return
                "ambiguous platform: connectors \(Self.goSlice(matches)) all match"
                + "; set one in /etc/wendyos-update/config.json"
        }
    }

    private static func goSlice(_ values: [String]) -> String {
        "[\(values.joined(separator: " "))]"
    }
}

/// Resolves a `Connector` from a candidate list of built-in factories.
///
/// Ports `registry.go`'s `Select`.
public enum ConnectorRegistry {
    /// Resolution order (docs/connector-architecture.md):
    ///  1. `explicit` name (from `/etc/wendyos-update/config.json`) — must
    ///     exist among `factories`.
    ///  2. auto-detect across `factories` — exactly one must match.
    ///  3. otherwise a hard error: never guess on an OTA path.
    public static func select(explicit: String?, from factories: [ConnectorFactory]) throws -> any Connector {
        if let explicit {
            guard let factory = factories.first(where: { $0.name == explicit }) else {
                throw ConnectorError.notBuiltIn(name: explicit, have: sortedNames(factories))
            }
            return factory.make()
        }

        let matches = factories.filter { $0.detect() }
        switch matches.count {
        case 1:
            return matches[0].make()
        case 0:
            throw ConnectorError.noneDetected(have: sortedNames(factories))
        default:
            throw ConnectorError.ambiguous(matches.map(\.name).sorted())
        }
    }

    private static func sortedNames(_ factories: [ConnectorFactory]) -> [String] {
        factories.map(\.name).sorted()
    }
}
