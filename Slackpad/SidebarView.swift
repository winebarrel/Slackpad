import SwiftUI

/// Left pane: folders and notes in a single tree. Folders nest and their
/// expansion state is persisted. Notes drag into folders to move.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.tree) { node in
                NodeRow(node: node)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let root = model.rootURL else { return false }
            for u in urls { model.move(u, into: root) }
            return true
        }
    }
}

private struct NodeRow: View {
    @EnvironmentObject var model: AppModel
    let node: NoteNode

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: model.expansionBinding(node.url)) {
                ForEach(node.children ?? []) { child in
                    NodeRow(node: child)
                }
            } label: {
                Label(node.name, systemImage: "folder")
                    .draggable(node.url)
            }
            .tag(node.url)
            .contextMenu { menu }
            .dropDestination(for: URL.self) { urls, _ in
                for u in urls { model.move(u, into: node.url) }
                return true
            }
        } else {
            Label(node.name, systemImage: "doc.text")
                .tag(node.url)
                .draggable(node.url)
                .contextMenu { menu }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("新規メモ") { model.selection = node.url; model.newNote() }
        Button("新規フォルダ") { model.selection = node.url; model.newFolder() }
        Divider()
        Button("ゴミ箱に入れる", role: .destructive) { model.delete(node.url) }
    }
}
