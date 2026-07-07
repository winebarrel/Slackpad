import Foundation

/// Browser-style back/forward navigation through the notes the user has opened.
extension AppModel {
    var canGoBack: Bool {
        historyIndex > 0
    }

    var canGoForward: Bool {
        historyIndex >= 0 && historyIndex < history.count - 1
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
