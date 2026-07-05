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

    /// Editor
    var editorText: String = ""
    // Managed by the model; views only read it.
    var openNoteURL: URL?
    @ObservationIgnored private var currentCursor: Int = 0

    // View triggers (incremented to signal the Cocoa editor)
    var scrollToBottomToken: Int = 0
    var restoreCursor: Int = 0
    var restoreToken: Int = 0
    var focusEditorToken: Int = 0

    // Signals the sidebar to start inline-renaming `renameTargetURL` (used when
    // a new note is created so its name is immediately editable).
    var beginRenameToken: Int = 0
    var renameTargetURL: URL?
    var focusPostFieldToken: Int = 0

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
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var dateFormatters: [String: DateFormatter] = [:]

    private func timestamp(format: String) -> String {
        let formatter: DateFormatter
        if let cached = dateFormatters[format] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            // Fixed formats need a stable locale/calendar, or a non-Gregorian
            // calendar / non-POSIX locale would skew the appended timestamp.
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = format
            dateFormatters[format] = formatter
        }
        return formatter.string(from: Date())
    }

    // MARK: Lifecycle

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminate() }
        })
    }

    /// Persist the buffer and release lifecycle resources on shutdown.
    private func terminate() {
        flush()
        watcher.stop()
        rootURL?.stopAccessingSecurityScopedResource()
    }

    func start() {
        // Idempotent: RootView.onAppear can fire again (e.g. window reopened),
        // and re-resolving the bookmark would unbalance security-scoped access
        // and restart the watcher.
        guard !didStart else { return }
        didStart = true
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
        // Persist a bookmark and resolve it so security-scoped access starts
        // the same way as on launch (balancing the later stop calls).
        guard let bookmark = RootDirectory.makeBookmark(for: url),
              let resolved = RootDirectory.resolve(from: bookmark) else { return }
        flush()
        watcher.stop()
        rootURL?.stopAccessingSecurityScopedResource()
        clearEditor()
        selection = nil
        settings.lastOpenNote = nil
        settings.rootBookmark = bookmark
        setRoot(resolved.url, persistBookmark: false)
    }

    private func setRoot(_ url: URL, persistBookmark: Bool) {
        rootURL = url
        // Only overwrite the persisted bookmark when regeneration succeeds, so a
        // failed makeBookmark can't wipe a still-valid rootBookmark (which would
        // lose the folder permission on the next launch).
        if persistBookmark, let bookmark = RootDirectory.makeBookmark(for: url) {
            settings.rootBookmark = bookmark
        }
        // Keep only expansion paths that live under this root (drop a previous
        // root's paths when switching folders).
        expanded = Set(settings.expandedFolders.map { URL(fileURLWithPath: $0) }
            .filter { $0.path.hasPrefix(url.path + "/") })
        settings.expandedFolders = expanded.map(\.path)
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
        // should keep keyboard focus there. New notes start an inline rename in
        // the sidebar via beginRenameToken instead.
    }

    func clearEditor() {
        openNoteURL = nil
        editorText = ""
    }

    /// The open note's filename (without extension), shown in the window title.
    /// Falls back to the app name when no note is open.
    var windowTitle: String {
        openNoteURL?.deletingPathExtension().lastPathComponent ?? "Slackpad"
    }

    // MARK: Autosave

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func updateCursor(_ offset: Int) {
        currentCursor = offset
    }

    /// Persist the editor buffer to the open note's file. The filename is now
    /// independent of the body (changed via the title bar or sidebar rename),
    /// so this only writes.
    func saveNow() {
        saveTask?.cancel()
        guard isEditorActive else { return }
        guard let current = openNoteURL else { return }
        let data = editorText.data(using: .utf8) ?? Data()
        Self.writePreservingCreationDate(data, to: current)
        settings.lastCursor = currentCursor
    }

    /// Atomic writes replace the file (new inode), which resets its creation
    /// date and would shuffle the created-date sort on every save. Preserve the
    /// original creation date across the write.
    static func writePreservingCreationDate(_ data: Data, to url: URL) {
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
        saveNow()
    }

    // MARK: Posting

    /// Post from the input field: send to Slack and append to the note body.
    func post(_ raw: String) {
        guard isEditorActive else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        appendToBody(text)
        sendToSlack(text)
    }

    /// Post the editor's selected text to Slack only (no body append).
    func postSelection(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        sendToSlack(text)
    }

    private func sendToSlack(_ text: String) {
        isSending = true
        postError = nil
        let webhook = settings.webhookURLValue
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let webhook else { throw SlackClient.PostError(message: "Webhook URL not set") }
                try await SlackClient().post(text: text, webhook: webhook)
            } catch {
                postError = "Failed to send: \(error.localizedDescription)"
                scheduleErrorClear()
            }
            isSending = false
        }
    }

    private func appendToBody(_ text: String) {
        let block: String
        if let format = settings.postTimestamp.format {
            let stamp = timestamp(format: format)
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
        sidebarVisible = visible
        settings.sidebarVisible = visible
    }
}
