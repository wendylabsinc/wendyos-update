/// A minimal port of Go's `path.Clean` for forward-slash paths, used only
/// for tar member name normalization. It does not touch the filesystem.
///
/// Mirrors the classic lexical algorithm: iterate path elements separated
/// by `/`, drop empty and `.` elements, and pop the previous element on
/// `..` (unless there is nothing to pop and the path isn't rooted, in
/// which case `..` is kept literally).
enum TarPath {
    static func clean(_ path: String) -> String {
        if path.isEmpty { return "." }

        let rooted = path.hasPrefix("/")
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)

        var out: [Substring] = []
        for segment in segments {
            switch segment {
            case ".":
                continue
            case "..":
                if let last = out.last, last != ".." {
                    out.removeLast()
                } else if !rooted {
                    out.append(segment)
                }
                // If rooted, ".." at the root is dropped (nothing to pop above root).
            default:
                out.append(segment)
            }
        }

        var result = out.joined(separator: "/")
        if rooted {
            result = "/" + result
        }
        if result.isEmpty {
            result = "."
        }
        return result
    }
}
