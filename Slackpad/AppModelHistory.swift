import Foundation

/// Browser-style back/forward navigation through the notes the user has opened.
extension AppModel {
    var canGoBack: Bool {
        hasReachableEntry(step: -1)
    }

    var canGoForward: Bool {
        hasReachableEntry(step: 1)
    }

    /// Whether history holds a still-existing note in the given direction, so
    /// the Back/Forward controls aren't enabled when every entry that way has
    /// been deleted and navigation would do nothing.
    private func hasReachableEntry(step: Int) -> Bool {
        var index = historyIndex + step
        while history.indices.contains(index) {
            if FileManager.default.fileExists(atPath: history[index].path) { return true }
            index += step
        }
        return false
    }

    /// Drop the forward entries and append the newly opened note, unless it is
    /// already the current one.
    func recordHistory(_ url: URL) {
        if historyIndex >= 0, history[historyIndex] == url { return }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(url)
        historyIndex = history.count - 1
    }

    func goBack() {
        navigateHistory(step: -1)
    }

    func goForward() {
        navigateHistory(step: 1)
    }

    /// Move through history in the given direction, skipping entries whose file
    /// no longer exists (deleted or renamed).
    private func navigateHistory(step: Int) {
        var index = historyIndex + step
        while history.indices.contains(index) {
            let url = history[index]
            if FileManager.default.fileExists(atPath: url.path) {
                flush()
                navigatingHistory = true
                selection = url
                openNote(url)
                navigatingHistory = false
                historyIndex = index
                return
            }
            index += step
        }
    }
}
