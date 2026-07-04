import SwiftUI

/// Left pane: folders and notes in a single tree. Folders nest and their
/// expansion state is persisted. Notes drag into folders to move. Selecting a
/// row and pressing Return (or right-click > 名前を変更) renames it inline.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: URL?
    @State private var renameText = ""
    @FocusState private var renameFocus: URL?

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.tree) { node in
                NodeRow(
                    node: node,
                    renaming: $renaming,
                    renameText: $renameText,
                    renameFocus: $renameFocus,
                    begin: begin,
                    commit: commit,
                    cancel: cancel
                )
            }
        }
        .onKeyPress(.return) {
            guard renaming == nil, let sel = model.selection else { return .ignored }
            begin(sel)
            return .handled
        }
        .onChange(of: renameFocus) { _, focus in
            if focus == nil, renaming != nil { commit() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let root = model.rootURL else { return false }
            for u in urls { model.move(u, into: root) }
            return true
        }
    }

    private func begin(_ url: URL) {
        renameText = url.deletingPathExtension().lastPathComponent
        renaming = url
        renameFocus = url
    }

    private func commit() {
        guard let url = renaming else { return }
        renaming = nil
        renameFocus = nil
        model.rename(url, to: renameText)
    }

    private func cancel() {
        renaming = nil
        renameFocus = nil
    }
}

private struct NodeRow: View {
    @EnvironmentObject var model: AppModel
    let node: NoteNode
    @Binding var renaming: URL?
    @Binding var renameText: String
    @FocusState.Binding var renameFocus: URL?
    let begin: (URL) -> Void
    let commit: () -> Void
    let cancel: () -> Void

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: model.expansionBinding(node.url)) {
                ForEach(node.children ?? []) { child in
                    NodeRow(
                        node: child,
                        renaming: $renaming,
                        renameText: $renameText,
                        renameFocus: $renameFocus,
                        begin: begin,
                        commit: commit,
                        cancel: cancel
                    )
                }
            } label: {
                label(system: "folder")
            }
            .tag(node.url)
            .contextMenu { menu }
            .dropDestination(for: URL.self) { urls, _ in
                for u in urls { model.move(u, into: node.url) }
                return true
            }
        } else {
            label(system: "doc.text")
                .tag(node.url)
                .contextMenu { menu }
        }
    }

    @ViewBuilder private func label(system: String) -> some View {
        if renaming == node.url {
            TextField("", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .focused($renameFocus, equals: node.url)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
        } else {
            Label(node.name, systemImage: system)
                .draggable(node.url)
        }
    }

    @ViewBuilder private var menu: some View {
        Button("名前を変更") { begin(node.url) }
        Divider()
        Button("新規メモ") { model.selection = node.url; model.newNote() }
        Button("新規フォルダ") { model.selection = node.url; model.newFolder() }
        Divider()
        Button("ゴミ箱に入れる", role: .destructive) { model.delete(node.url) }
    }
}
