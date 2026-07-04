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
        // Rebuild via the scalar view so grapheme clusters (emoji ZWJ
        // sequences, combining marks) survive and the length clamp counts
        // user-perceived characters. Replace only "/" / ":" (unusable in macOS
        // filenames) and genuine control characters — not format scalars like
        // the zero-width joiner, which hold emoji sequences together.
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let illegal = scalar == "/" || scalar == ":" || scalar.properties.generalCategory == .control
            scalars.append(illegal ? "-" : scalar)
        }
        var name = String(scalars).trimmingCharacters(in: .whitespaces)
        // A leading dot would make a hidden file that the tree scan skips.
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.count > maxLength {
            name = String(name.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? fallback : name
    }

    /// Return a `.txt` URL in `dir` for `base`, appending " 2", " 3"... on collision.
    /// `excluding` (the note's own current URL) is not treated as a collision.
    static func uniqueURL(dir: URL, base: String, excluding: URL? = nil) -> URL {
        let manager = FileManager.default
        var candidate = dir.appendingPathComponent(base).appendingPathExtension("txt")
        var suffix = 2
        while manager.fileExists(atPath: candidate.path), candidate != excluding {
            // Keep the whole name within maxLength once the " N" suffix is added.
            let tail = " \(suffix)"
            let trimmed = String(base.prefix(maxLength - tail.count)).trimmingCharacters(in: .whitespaces)
            candidate = dir.appendingPathComponent(trimmed + tail).appendingPathExtension("txt")
            suffix += 1
        }
        return candidate
    }
}
