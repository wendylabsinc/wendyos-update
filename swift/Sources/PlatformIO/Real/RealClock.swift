#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
// The static-musl cross-compilation SDK exposes libc under the
// `Musl` overlay module instead of `Glibc` (see LinuxSys.swift for
// the fuller explanation); every symbol this file uses exists
// identically in both.
import Musl
#endif

/// `Clock` over `gmtime_r`. Formats manually rather than through a
/// `DateFormatter`/`ISO8601DateFormatter` so the output is pinned exactly
/// to Go's `time.RFC3339` shape (`"2006-01-02T15:04:05Z"`, no fractional
/// seconds, always `Z`) regardless of locale or formatter defaults.
public struct RealClock: Clock {
    public init() {}

    public func nowUTCISO8601() -> String {
        var t = time_t(time(nil))
        var tmValue = tm()
        gmtime_r(&t, &tmValue)
        return "\(Self.pad4(tmValue.tm_year + 1900))-\(Self.pad2(tmValue.tm_mon + 1))-\(Self.pad2(tmValue.tm_mday))"
            + "T\(Self.pad2(tmValue.tm_hour)):\(Self.pad2(tmValue.tm_min)):\(Self.pad2(tmValue.tm_sec))Z"
    }

    private static func pad2(_ n: Int32) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }

    private static func pad4(_ n: Int32) -> String {
        let s = "\(n)"
        return String(repeating: "0", count: max(0, 4 - s.count)) + s
    }
}
