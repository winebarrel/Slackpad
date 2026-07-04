import SwiftUI
import AppKit
import Observation

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
    private(set) var openNoteURL: URL?
    @ObservationIgnored private var currentCursor: Int = 0

    // View triggers (incremented to signal the Cocoa editor)
    var focusToken: Int = 0
    var scrollToBottomToken: Int = 0
    var restoreCursor: Int = 0
    var restoreToken: Int = 0
    var selectFirstLineToken: Int = 0

    // Posting
    var isSending: Bool = false
    var postError: String?

    var isEditorActive: Bool { openNoteURL != nil }

    static let untitled = "Untitled"

    @ObservationIgnored private let watcher = FolderWatcher()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var errorClearTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

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
        if let root = RootDirectory.resolve(from: settings.rootBookmark) {
            setRoot(root, persistBookmark: false)
        }
    }

    var needsRoot: Bool { rootURL == nil }

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

    private func openNote(_ url: URL) {
        editorText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        openNoteURL = url
        currentCursor = 0
        settings.lastOpenNote = url.path
        focusToken += 1
    }

    private func clearEditor() {
        openNoteURL = nil
        editorText = ""
    }

    private func targetFolder() -> URL {
        if let sel = selection {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: sel.path, isDirectory: &isDir)
            return isDir.boolValue ? sel : sel.deletingLastPathComponent()
        }
        return rootURL ?? FileManager.default.temporaryDirectory
    }

    // MARK: CRUD

    /// Create an "Untitled" note file immediately and open it, with the first
    /// line ("Untitled") selected so typing replaces it (Finder-style).
    /// `folder` overrides the target (e.g. the root from the empty-area menu).
    func newNote(in folder: URL? = nil) {
        guard rootURL != nil else { return }
        flush()
        let url = Filename.uniqueURL(dir: folder ?? targetFolder(), base: Self.untitled)
        try? Self.untitled.data(using: .utf8)?.write(to: url, options: .atomic)
        reloadTree()
        selection = url
        openNote(url)
        selectFirstLineToken += 1
    }

    func newFolder(in folder: URL? = nil) {
        let dir = folder ?? targetFolder()
        var name = "新規フォルダ"
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            name = "新規フォルダ \(n)"
            candidate = dir.appendingPathComponent(name)
            n += 1
        }
        try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        reloadTree()
    }

    func delete(_ url: URL) {
        if url == openNoteURL { clearEditor(); selection = nil }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reloadTree()
    }

    func deleteSelection() {
        guard let url = selection else { return }
        delete(url)
    }

    /// Move a file or folder into `folder`. No-op for invalid moves.
    func move(_ src: URL, into folder: URL) {
        guard src.deletingLastPathComponent() != folder else { return }
        guard !folder.path.hasPrefix(src.path + "/") , folder != src else { return }
        let dest = folder.appendingPathComponent(src.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        let wasOpen = src == openNoteURL
        try? FileManager.default.moveItem(at: src, to: dest)
        if wasOpen {
            openNoteURL = dest
            selection = dest
            settings.lastOpenNote = dest.path
        }
        reloadTree()
    }

    // MARK: Rename

    /// Rename a sidebar item. Folders rename in place; for a note, renaming
    /// rewrites its first line (which is the source of truth for its filename).
    func rename(_ url: URL, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            renameFolder(url, to: name)
        } else {
            renameNote(url, to: name)
        }
    }

    private func renameFolder(_ url: URL, to newName: String) {
        let base = Filename.sanitize(newName)
        let parent = url.deletingLastPathComponent()
        var dest = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path), dest != url {
            dest = parent.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        guard dest != url else { return }
        guard (try? FileManager.default.moveItem(at: url, to: dest)) != nil else { return }
        remapPaths(from: url, to: dest)
        selection = dest
        reloadTree()
    }

    private func renameNote(_ url: URL, to newName: String) {
        if url == openNoteURL {
            editorText = Self.replacingFirstLine(editorText, with: newName)
            saveNow() // renames the file to match the new first line
            return
        }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let newContent = Self.replacingFirstLine(content, with: newName)
        let dir = url.deletingLastPathComponent()
        let dest = Filename.uniqueURL(dir: dir, base: Filename.base(fromBody: newContent), excluding: url)
        try? newContent.data(using: .utf8)?.write(to: url, options: .atomic)
        if dest != url {
            try? FileManager.default.moveItem(at: url, to: dest)
        }
        if settings.lastOpenNote == url.path { settings.lastOpenNote = dest.path }
        selection = dest
        reloadTree()
    }

    /// Replace the first line of `content`, keeping the rest of the body intact.
    private static func replacingFirstLine(_ content: String, with first: String) -> String {
        if let nl = content.firstIndex(of: "\n") {
            return first + String(content[nl...])
        }
        return first
    }

    /// After moving `oldDir` to `newDir`, fix up any state that pointed inside it.
    private func remapPaths(from oldDir: URL, to newDir: URL) {
        func remap(_ u: URL) -> URL? {
            if u == oldDir { return newDir }
            let prefix = oldDir.path + "/"
            guard u.path.hasPrefix(prefix) else { return nil }
            let suffix = String(u.path.dropFirst(prefix.count))
            return newDir.appendingPathComponent(suffix)
        }
        if let open = openNoteURL, let moved = remap(open) {
            openNoteURL = moved
            settings.lastOpenNote = moved.path
        }
        if let sel = selection, let moved = remap(sel) { selection = moved }
        expanded = Set(expanded.map { remap($0) ?? $0 })
        settings.expandedFolders = expanded.map(\.path)
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

    func updateCursor(_ offset: Int) { currentCursor = offset }

    /// `reselect` updates the sidebar selection to follow a created/renamed
    /// file. It must be false when called from `flush()` during a selection
    /// change, otherwise re-writing `selection` re-enters the change handler
    /// and loops ("Publishing changes from within view updates").
    private func saveNow(reselect: Bool = true) {
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
        try? data.write(to: writeURL, options: .atomic)
        settings.lastCursor = currentCursor
    }

    /// Persist the current buffer. Called on note switch, resign active and
    /// terminate. Empty notes are kept as-is (no cleanup).
    private func flush() {
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
                guard let webhook else { throw SlackClient.PostError(message: "Webhook URL 未設定") }
                try await SlackClient().post(text: text, webhook: webhook)
            } catch {
                self.postError = "送信に失敗しました"
                self.scheduleErrorClear()
            }
            self.isSending = false
        }
    }

    private func appendToBody(_ text: String) {
        let time = Self.timeFormatter.string(from: Date())
        let lines = text.components(separatedBy: "\n")
        let first = "\(time) \(lines[0])"
        let block = ([first] + lines.dropFirst()).joined(separator: "\n")
        if !editorText.isEmpty && !editorText.hasSuffix("\n") { editorText += "\n" }
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
