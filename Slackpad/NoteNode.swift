import Foundation

/// A node in the sidebar tree: either a folder (with children) or a `.txt` note.
struct NoteNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [NoteNode]?

    var id: URL { url }
    var name: String {
        isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    static func == (lhs: NoteNode, rhs: NoteNode) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

enum NoteTree {
    /// Recursively scan `root`, keeping only directories and `.txt` files.
    /// Hidden entries (dotfiles) and other extensions are skipped.
    static func scan(_ root: URL, sortKey: SortKey, ascending: Bool) -> [NoteNode] {
        children(of: root, sortKey: sortKey, ascending: ascending)
    }

    private static func children(of dir: URL, sortKey: SortKey, ascending: Bool) -> [NoteNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var nodes: [NoteNode] = []
        for url in entries {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            if isDir {
                nodes.append(NoteNode(
                    url: url,
                    isDirectory: true,
                    children: children(of: url, sortKey: sortKey, ascending: ascending)
                ))
            } else if url.pathExtension.lowercased() == "txt" {
                nodes.append(NoteNode(url: url, isDirectory: false, children: nil))
            }
        }
        return sorted(nodes, sortKey: sortKey, ascending: ascending)
    }

    /// Folders always come before notes; within each group apply the chosen order.
    private static func sorted(_ nodes: [NoteNode], sortKey: SortKey, ascending: Bool) -> [NoteNode] {
        let folders = nodes.filter { $0.isDirectory }
        let files = nodes.filter { !$0.isDirectory }
        return order(folders, sortKey: sortKey, ascending: ascending)
            + order(files, sortKey: sortKey, ascending: ascending)
    }

    private static func order(_ nodes: [NoteNode], sortKey: SortKey, ascending: Bool) -> [NoteNode] {
        let sorted = nodes.sorted { lhs, rhs in
            switch sortKey {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .created:
                return date(lhs.url, .creationDateKey) < date(rhs.url, .creationDateKey)
            }
        }
        return ascending ? sorted : sorted.reversed()
    }

    private static func date(_ url: URL, _ key: URLResourceKey) -> Date {
        let values = try? url.resourceValues(forKeys: [key])
        if key == .creationDateKey { return values?.creationDate ?? .distantPast }
        return values?.contentModificationDate ?? .distantPast
    }
}
