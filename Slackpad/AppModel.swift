// import Foundation
import Observation
import SwiftUI

/// Central coordinator: owns settings, the root directory, the note tree, the
/// open note / editor buffer, autosave, external-change watching and posting.
@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()

    // Tree / sidebar
    var rootURL: URL?
    var tree: [NoteNode] = []
    var expanded: Set<URL> = []
    var selection: URL?
    var sidebarVisible: Bool = true

    // Editor
    var editorText: String = ""
    // Managed by the model; views only read it.
    var openNoteURL: URL?
    @ObservationIgnored private var currentCursor: Int = 0

    // View triggers (incremented to signal the Cocoa editor)
    var scrollToBottomToken: Int = 0
    var restoreCursor: Int = 0
    var restoreToken: Int = 0
    var selectFirstLineToken: Int = 0

    // Posting
    var isSending: Bool = false
    var postError: String?

    var isEditorActive: Bool {
        openNoteURL != nil
    }

    static let untitled = "Untitled"

    @ObservationIgnored private let watcher = FolderWatcher()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var errorClearTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static func timestamp(format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: Date())
    }

    // MARK: Lifecycle

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        })
    }

    func start() {
        settings.load()
        sidebarVisible = settings.sidebarVisible
        if let resolved = RootDirectory.resolve(from: settings.rootBookmark) {
            // Regenerate and persist the bookmark when it has gone stale.
            setRoot(resolved.url, persistBookmark: resolved.isStale)
        }
    }

    var needsRoot: Bool {
        rootURL == nil
    }

    // MARK: Root directory

    /// Prompt for a folder. Used by onboarding and the "change folder" setting.
    func chooseRoot() {
        guard let url = RootDirectory.pick() else { return } // cancelled: keep prompting
        flush()
        watcher.stop()
        rootURL?.stopAccessingSecurityScopedResource()
        clearEditor()
        selection = nil
        settings.lastOpenNote = nil
        setRoot(url, persistBookmark: true)
    }

    private func setRoot(_ url: URL, persistBookmark: Bool) {
        rootURL = url
        if persistBookmark { settings.rootBookmark = RootDirectory.makeBookmark(for: url) }
        expanded = Set(settings.expandedFolders.map { URL(fileURLWithPath: $0) })
        reloadTree()
        watcher.onChange = { [weak self] in self?.scheduleRebuild() }
        watcher.start(url: url)
        restoreOpenNote()
    }

    private func restoreOpenNote() {
        guard let path = settings.lastOpenNote,
              FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        selection = url
        openNote(url)
        restoreCursor = settings.lastCursor
        restoreToken += 1
    }

    // MARK: Tree

    func reloadTree() {
        guard let root = rootURL else { return }
        tree = NoteTree.scan(root, sortKey: settings.sortKey, ascending: settings.sortAscending)
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            self?.reloadTree()
        }
    }

    func expansionBinding(_ url: URL) -> Binding<Bool> {
        Binding(
            get: { self.expanded.contains(url) },
            set: { open in
                if open { self.expanded.insert(url) } else { self.expanded.remove(url) }
                self.settings.expandedFolders = self.expanded.map(\.path)
            }
        )
    }

    // MARK: Selection

    /// Called by the sidebar when the user picks a row. Keeps `selection` in
    /// sync (for new-note/folder context) and opens/closes the editor.
    func userSelected(_ url: URL?) {
        selection = url
        onSelectionChange(url)
    }

    private func onSelectionChange(_ url: URL?) {
        if let url, url == openNoteURL { return } // already open (or set programmatically)
        flush()
        guard let url else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            clearEditor()
        } else {
            openNote(url)
        }
    }

    func openNote(_ url: URL) {
        editorText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        openNoteURL = url
        currentCursor = 0
        settings.lastOpenNote = url.path
        // Don't move focus to the editor: selecting a note in the sidebar
        // should keep keyboard focus there. New notes focus the editor via
        // selectFirstLineToken instead.
    }

    func clearEditor() {
        openNoteURL = nil
        editorText = ""
    }

    // MARK: Autosave

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            // Don't re-select while the user is typing: renaming to follow the
            // title would move the sidebar selection and steal keyboard focus
            // from the editor.
            self?.saveNow(reselect: false)
        }
    }

    func updateCursor(_ offset: Int) {
        currentCursor = offset
    }

    /// `reselect` updates the sidebar selection to follow a created/renamed
    /// file. It must be false when called from `flush()` during a selection
    /// change, otherwise re-writing `selection` re-enters the change handler
    /// and loops ("Publishing changes from within view updates").
    func saveNow(reselect: Bool = true) {
        saveTask?.cancel()
        guard isEditorActive else { return }
        let text = editorText
        guard let current = openNoteURL else { return }
        let data = text.data(using: .utf8) ?? Data()
        let dir = current.deletingLastPathComponent()
        var writeURL = current
        // Rename to follow the first line, but only when it is non-blank;
        // an empty note keeps its current filename (no cleanup).
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let desired = Filename.base(fromBody: text) + ".txt"
            if current.lastPathComponent != desired {
                let target = Filename.uniqueURL(dir: dir, base: Filename.base(fromBody: text), excluding: current)
                try? FileManager.default.moveItem(at: current, to: target)
                openNoteURL = target
                settings.lastOpenNote = target.path
                writeURL = target
                if reselect, selection != target { selection = target }
            }
        }
        Self.writePreservingCreationDate(data, to: writeURL)
        settings.lastCursor = currentCursor
    }

    /// Atomic writes replace the file (new inode), which resets its creation
    /// date and would shuffle the created-date sort on every save. Preserve the
    /// original creation date across the write.
    private static func writePreservingCreationDate(_ data: Data, to url: URL) {
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        try? data.write(to: url, options: .atomic)
        if let created {
            try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        }
    }

    /// Persist the current buffer. Called on note switch, resign active and
    /// terminate. Empty notes are kept as-is (no cleanup).
    func flush() {
        saveTask?.cancel()
        guard isEditorActive else { return }
        saveNow(reselect: false)
    }

    // MARK: Posting

    func post(_ raw: String) {
        guard isEditorActive else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        postError = nil
        appendToBody(text)
        let webhook = settings.webhookURLValue
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let webhook else { throw SlackClient.PostError(message: "Webhook URL not set") }
                try await SlackClient().post(text: text, webhook: webhook)
            } catch {
                self.postError = "Failed to send"
                self.scheduleErrorClear()
            }
            self.isSending = false
        }
    }

    private func appendToBody(_ text: String) {
        let block: String
        if let format = settings.postTimestamp.format {
            let stamp = Self.timestamp(format: format)
            let lines = text.components(separatedBy: "\n")
            let first = "\(stamp) \(lines[0])"
            block = ([first] + lines.dropFirst()).joined(separator: "\n")
        } else {
            block = text
        }
        if !editorText.isEmpty, !editorText.hasSuffix("\n") { editorText += "\n" }
        editorText += block
        saveNow()
        scrollToBottomToken += 1
    }

    private func scheduleErrorClear() {
        errorClearTask?.cancel()
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.postError = nil
        }
    }

    // MARK: Sidebar visibility persistence

    func persistSidebarVisible(_ visible: Bool) {
        settings.sidebarVisible = visible
    }
}
