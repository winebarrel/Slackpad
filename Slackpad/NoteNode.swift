import Foundation

/// A node in the sidebar tree: either a folder (with children) or a `.txt` note.
///
/// Identity is the URL (stable across reloads), but equality is synthesized
/// over all stored properties — including `children` — so SwiftUI notices when
/// a folder's contents change and refreshes that subtree.
struct NoteNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [NoteNode]?

    var id: URL {
        url
    }

    var name: String {
        isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}

enum NoteTree {
    /// Recursively scan `root`, keeping only directories and `.txt` files.
    /// Hidden entries (dotfiles) and other extensions are skipped.
    static func scan(_ root: URL, sortKey: SortKey, ascending: Bool) -> [NoteNode] {
        children(of: root, sortKey: sortKey, ascending: ascending)
    }

    private static func children(of dir: URL, sortKey: SortKey, ascending: Bool) -> [NoteNode] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var nodes: [NoteNode] = []
        for url in entries {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
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
        let folders = nodes.filter(\.isDirectory)
        let files = nodes.filter { !$0.isDirectory }
        return order(folders, sortKey: sortKey, ascending: ascending)
            + order(files, sortKey: sortKey, ascending: ascending)
    }

    private static func order(_ nodes: [NoteNode], sortKey: SortKey, ascending: Bool) -> [NoteNode] {
        let sorted: [NoteNode]
        switch sortKey {
        case .name:
            sorted = nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .created:
            // Read each creation date once, not on every comparison.
            let dates = Dictionary(uniqueKeysWithValues: nodes.map { ($0.url, date($0.url, .creationDateKey)) })
            sorted = nodes.sorted { (dates[$0.url] ?? .distantPast) < (dates[$1.url] ?? .distantPast) }
        }
        return ascending ? sorted : Array(sorted.reversed())
    }

    private static func date(_ url: URL, _ key: URLResourceKey) -> Date {
        let values = try? url.resourceValues(forKeys: [key])
        if key == .creationDateKey { return values?.creationDate ?? .distantPast }
        return values?.contentModificationDate ?? .distantPast
    }
}
