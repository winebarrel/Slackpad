import SwiftUI
import AppKit
import Combine

/// Central coordinator: owns settings, the root directory, the note tree, the
/// open note / editor buffer, autosave, external-change watching and posting.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()

    // Tree / sidebar
    @Published var rootURL: URL?
    @Published var tree: [NoteNode] = []
    @Published var expanded: Set<URL> = []
    @Published var selection: URL?
    @Published var sidebarVisible: Bool = true

    // Editor
    @Published var editorText: String = ""
    @Published private(set) var openNoteURL: URL?
    @Published private(set) var isNewUnsaved: Bool = false
    private var newNoteParent: URL?
    private var currentCursor: Int = 0

    // View triggers (incremented to signal the Cocoa editor)
    @Published var focusToken: Int = 0
    @Published var scrollToBottomToken: Int = 0
    @Published var restoreCursor: Int = 0
    @Published var restoreToken: Int = 0

    // Posting
    @Published var isSending: Bool = false
    @Published var postError: String?

    var isEditorActive: Bool { openNoteURL != nil || isNewUnsaved }

    private let watcher = FolderWatcher()
    private var saveWork: DispatchWorkItem?
    private var rebuildWork: DispatchWorkItem?
    private var errorClearToken = 0
    private var observers: [NSObjectProtocol] = []

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
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadTree() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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

    func onSelectionChange(_ url: URL?) {
        if let url, url == openNoteURL { return } // already open (or set programmatically)
        flush()
        guard let url else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            clearEditor()
            newNoteParent = url
        } else {
            openNote(url)
        }
    }

    private func openNote(_ url: URL) {
        editorText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        openNoteURL = url
        isNewUnsaved = false
        newNoteParent = url.deletingLastPathComponent()
        currentCursor = 0
        settings.lastOpenNote = url.path
        focusToken += 1
    }

    private func clearEditor() {
        openNoteURL = nil
        isNewUnsaved = false
        editorText = ""
        newNoteParent = nil
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

    func newNote() {
        guard rootURL != nil else { return }
        flush()
        newNoteParent = targetFolder()
        editorText = ""
        openNoteURL = nil
        isNewUnsaved = true
        currentCursor = 0
        focusToken += 1
    }

    func newFolder() {
        let dir = targetFolder()
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

    // MARK: Autosave

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func updateCursor(_ offset: Int) { currentCursor = offset }

    private func saveNow() {
        saveWork?.cancel()
        guard isEditorActive else { return }
        let text = editorText
        let isBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isBlank {
            // Keep disk in sync but do not delete yet; empty notes are removed on transitions.
            if let url = openNoteURL { try? Data().write(to: url, options: .atomic) }
            return
        }
        let base = Filename.base(fromBody: text)
        let data = text.data(using: .utf8) ?? Data()
        if isNewUnsaved {
            let url = Filename.uniqueURL(dir: newNoteParent ?? rootURL!, base: base)
            try? data.write(to: url, options: .atomic)
            openNoteURL = url
            isNewUnsaved = false
            selection = url
            settings.lastOpenNote = url.path
        } else if let current = openNoteURL {
            let dir = current.deletingLastPathComponent()
            let desired = base + ".txt"
            var writeURL = current
            if current.lastPathComponent != desired {
                let target = Filename.uniqueURL(dir: dir, base: base, excluding: current)
                try? FileManager.default.moveItem(at: current, to: target)
                openNoteURL = target
                selection = target
                settings.lastOpenNote = target.path
                writeURL = target
            }
            try? data.write(to: writeURL, options: .atomic)
        }
        settings.lastCursor = currentCursor
    }

    /// Persist or discard the current buffer. Called on note switch, resign
    /// active and terminate. Empty notes are removed without a trace.
    private func flush() {
        saveWork?.cancel()
        guard isEditorActive else { return }
        let isBlank = editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isBlank {
            if let url = openNoteURL { try? FileManager.default.removeItem(at: url) }
            clearEditor()
        } else {
            saveNow()
        }
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
        errorClearToken += 1
        let token = errorClearToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.errorClearToken == token else { return }
            self.postError = nil
        }
    }

    // MARK: Sidebar visibility persistence

    func persistSidebarVisible(_ visible: Bool) {
        settings.sidebarVisible = visible
    }
}
