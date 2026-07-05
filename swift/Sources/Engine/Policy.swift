// Policy gates evaluated before an install is allowed to proceed. Ports
// `deviceType`/`versionAtLeast`/`parseVersion` in internal/engine/engine.go.

extension Engine {
    /// Parses the `BOARD` key from `deviceTypePath` (or `DefaultDeviceTypePath`
    /// when unset) — key=value lines, wendyos-identity recipe. The first
    /// line whose trimmed value starts with `BOARD=` AND has a non-empty
    /// value after the prefix wins; a missing file or a file with no
    /// matching line is an error. Ports `Engine.deviceType` verbatim.
    public func deviceType() throws -> String {
        let path = effectiveDeviceTypePath
        let data: [UInt8]
        do {
            data = try fs.read(path)
        } catch {
            throw EngineError.deviceType("device type: \(error)")
        }
        let text = String(decoding: data, as: UTF8.self)
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = trimASCIIWhitespace(rawLine)
            guard line.hasPrefix("BOARD=") else { continue }
            let value = line.dropFirst("BOARD=".count)
            if !value.isEmpty {
                return String(value)
            }
        }
        throw EngineError.deviceType("device type: no BOARD= line in \(path)")
    }
}

/// Trims leading/trailing ASCII whitespace (space, tab, CR, LF, VT, FF) —
/// the same character class `strings.TrimSpace` covers for the plain-ASCII
/// `key=value` lines this file actually contains.
private func trimASCIIWhitespace(_ s: Substring) -> Substring {
    func isSpace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\r" || c == "\n" || c == "\u{0B}" || c == "\u{0C}"
    }
    var s = s
    while let first = s.first, isSpace(first) {
        s.removeFirst()
    }
    while let last = s.last, isSpace(last) {
        s.removeLast()
    }
    return s
}

/// `parseVersion` failed to parse a dotted `x.y.z` version.
public struct VersionParseError: Error, Equatable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

/// Parses a dotted `x.y.z` numeric version, ignoring any pre-release
/// suffix after the first `-` (e.g. `"1.2.3-rc1"` -> `(1, 2, 3)`). Ports
/// `parseVersion` in internal/engine/engine.go.
public func parseVersion(_ v: String) throws -> (Int, Int, Int) {
    let core = v.firstIndex(of: "-").map { v[v.startIndex..<$0] } ?? v[...]
    let parts = core.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else {
        throw VersionParseError(v)
    }
    var numbers: [Int] = []
    numbers.reserveCapacity(3)
    for part in parts {
        guard let n = Int(part) else {
            throw VersionParseError(v)
        }
        numbers.append(n)
    }
    return (numbers[0], numbers[1], numbers[2])
}

/// Compares dotted numeric versions (pre-release suffixes after `-` are
/// ignored). An empty or unparseable minimum gates nothing — a malformed
/// policy config must not brick updates. Ports `versionAtLeast` in
/// internal/engine/engine.go.
public func versionAtLeast(_ have: String, _ min: String) -> Bool {
    if min.isEmpty { return true }
    guard let m = try? parseVersion(min) else { return true }
    guard let h = try? parseVersion(have) else { return false }
    if h.0 != m.0 { return h.0 > m.0 }
    if h.1 != m.1 { return h.1 > m.1 }
    if h.2 != m.2 { return h.2 > m.2 }
    return true
}
