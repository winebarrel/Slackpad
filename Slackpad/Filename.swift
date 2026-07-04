import Foundation

/// Helpers for turning a note's first line into a safe `.txt` filename.
enum Filename {
    static let maxLength = 64
    static let fallback = "Untitled"

    /// Derive a base filename (without extension) from the note body's first line.
    static func base(fromBody body: String) -> String {
        let firstLine = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return sanitize(firstLine)
    }

    /// Replace characters that are illegal in a filename and clamp the length.
    static func sanitize(_ raw: String) -> String {
        var s = raw
        // "/" and ":" are unusable in macOS filenames; drop control characters too.
        let bad = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        s = String(s.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) })
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > maxLength {
            s = String(s.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? fallback : s
    }

    /// Return a `.txt` URL in `dir` for `base`, appending " 2", " 3"... on collision.
    /// `excluding` (the note's own current URL) is not treated as a collision.
    static func uniqueURL(dir: URL, base: String, excluding: URL? = nil) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(base).appendingPathExtension("txt")
        var n = 2
        while fm.fileExists(atPath: candidate.path), candidate != excluding {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension("txt")
            n += 1
        }
        return candidate
    }
}
