import Foundation

/// Sidebar file/folder operations: create, delete, move and rename.
extension AppModel {
    private func targetFolder() -> URL {
        if let sel = selection {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: sel.path, isDirectory: &isDir)
            return isDir.boolValue ? sel : sel.deletingLastPathComponent()
        }
        return rootURL ?? FileManager.default.temporaryDirectory
    }

    // MARK: Create

    /// Expand `dir` (and its ancestors) so a newly created item inside it is
    /// visible in the sidebar.
    private func revealFolder(_ dir: URL) {
        guard let root = rootURL else { return }
        var current = dir
        while current != root, current.path.hasPrefix(root.path + "/") {
            expanded.insert(current)
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        settings.expandedFolders = expanded.map(\.path)
    }

    /// Create an "Untitled" note file immediately and open it, with the first
    /// line ("Untitled") selected so typing replaces it (Finder-style).
    /// `folder` overrides the target (e.g. the root from the empty-area menu).
    func newNote(in folder: URL? = nil) {
        guard rootURL != nil else { return }
        flush()
        let dir = folder ?? targetFolder()
        let url = Filename.uniqueURL(dir: dir, base: Self.untitled)
        try? Self.untitled.data(using: .utf8)?.write(to: url, options: .atomic)
        revealFolder(dir)
        reloadTree()
        selection = url
        openNote(url)
        selectFirstLineToken += 1
    }

    func newFolder(in folder: URL? = nil) {
        guard rootURL != nil else { return }
        let dir = folder ?? targetFolder()
        var name = "New Folder"
        var candidate = dir.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            name = "New Folder \(suffix)"
            candidate = dir.appendingPathComponent(name)
            suffix += 1
        }
        try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        revealFolder(dir)
        reloadTree()
        // Select the new folder so the List renders it immediately (and it's
        // ready to rename).
        selection = candidate
    }

    // MARK: Delete / move

    func delete(_ url: URL) {
        deleteAll([url])
    }

    /// Move one or more files/folders to the Trash.
    func deleteAll(_ urls: some Collection<URL>) {
        guard !urls.isEmpty else { return }
        for url in urls {
            // Close the editor / drop the restore path if the deleted item is
            // the open note or a folder that contains it.
            if isSelfOrAncestor(url, of: openNoteURL) { clearEditor() }
            if let last = settings.lastOpenNote, isSelfOrAncestor(url, of: URL(fileURLWithPath: last)) {
                settings.lastOpenNote = nil
            }
            // Drop expansion state for the deleted folder and its descendants.
            expanded = expanded.filter { !isSelfOrAncestor(url, of: $0) }
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        settings.expandedFolders = expanded.map(\.path)
        selection = nil
        reloadTree()
    }

    /// Whether `url` is `ancestor` itself or lives inside it.
    private func isSelfOrAncestor(_ ancestor: URL, of url: URL?) -> Bool {
        guard let url else { return false }
        return url == ancestor || url.path.hasPrefix(ancestor.path + "/")
    }

    /// Move the dropped URLs that Slackpad manages (under `rootURL`) into
    /// `folder`. Returns whether any were eligible, so an external-only drop is
    /// rejected by the UI.
    @discardableResult
    func moveAll(_ urls: [URL], into folder: URL) -> Bool {
        guard let root = rootURL else { return false }
        let managed = urls.filter { $0.path.hasPrefix(root.path + "/") }
        for url in managed {
            move(url, into: folder)
        }
        return !managed.isEmpty
    }

    /// Move a file or folder into `folder`. No-op for invalid moves.
    func move(_ src: URL, into folder: URL) {
        // Only move items Slackpad manages; a Finder drag would otherwise
        // relocate unrelated user files into the notes folder.
        guard let root = rootURL,
              src.path.hasPrefix(root.path + "/"),
              folder == root || folder.path.hasPrefix(root.path + "/") else { return }
        guard src.deletingLastPathComponent() != folder else { return }
        guard !folder.path.hasPrefix(src.path + "/"), folder != src else { return }
        let dest = folder.appendingPathComponent(src.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        guard (try? FileManager.default.moveItem(at: src, to: dest)) != nil else { return }
        // Fix up any open note / selection / expansion / last-open path that
        // pointed at the moved item or inside a moved folder.
        remapPaths(from: src, to: dest)
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
        var suffix = 2
        while FileManager.default.fileExists(atPath: dest.path), dest != url {
            dest = parent.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
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
        // Preserve the creation date (atomic write resets it) and only move the
        // state to `dest` when the rename actually succeeds.
        Self.writePreservingCreationDate(newContent.data(using: .utf8) ?? Data(), to: url)
        var final = url
        if dest != url, (try? FileManager.default.moveItem(at: url, to: dest)) != nil {
            final = dest
        }
        if settings.lastOpenNote == url.path { settings.lastOpenNote = final.path }
        selection = final
        reloadTree()
    }

    /// Replace the first line of `content`, keeping the rest of the body intact.
    static func replacingFirstLine(_ content: String, with first: String) -> String {
        if let newline = content.firstIndex(of: "\n") {
            return first + String(content[newline...])
        }
        return first
    }

    /// After moving `oldDir` to `newDir`, fix up any state that pointed inside it.
    private func remapPaths(from oldDir: URL, to newDir: URL) {
        func remap(_ url: URL) -> URL? {
            if url == oldDir { return newDir }
            let prefix = oldDir.path + "/"
            guard url.path.hasPrefix(prefix) else { return nil }
            let relative = String(url.path.dropFirst(prefix.count))
            return newDir.appendingPathComponent(relative)
        }
        if let open = openNoteURL, let moved = remap(open) { openNoteURL = moved }
        // Remap the persisted last-open path independently: the editor may be
        // closed while its note is moved as part of a folder move.
        if let last = settings.lastOpenNote, let moved = remap(URL(fileURLWithPath: last)) {
            settings.lastOpenNote = moved.path
        }
        if let sel = selection, let moved = remap(sel) { selection = moved }
        expanded = Set(expanded.map { remap($0) ?? $0 })
        settings.expandedFolders = expanded.map(\.path)
    }
}
