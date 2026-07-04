import Foundation
import AppKit

/// Resolves and persists the root notes directory using a security-scoped
/// app-scope bookmark, so the sandboxed app can reach the user-chosen folder
/// across launches.
enum RootDirectory {
    /// Resolve the saved bookmark and begin security-scoped access. Returns the
    /// folder and whether the bookmark was stale (the caller should regenerate
    /// and persist a fresh bookmark in that case). Nil if it can't be resolved.
    static func resolve(from bookmark: Data?) -> (url: URL, isStale: Bool)? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        return (url, stale)
    }

    /// Create bookmark data for a folder the user just picked.
    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Show a folder-selection panel starting at ~/Documents.
    /// Returns the chosen folder (already security-scope accessible), or nil if cancelled.
    @MainActor
    static func pick() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose a folder to store your notes"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }
}
