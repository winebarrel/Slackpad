import SwiftUI

/// Left pane: folders and notes in a single tree. Folders nest and their
/// expansion state is persisted. Notes drag into folders to move. Selecting a
/// row and pressing Return (or right-click > 名前を変更) renames it inline.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    // Local selection so the List writes to @State rather than to the shared
    // model's observable state, which would publish mid view-update on every
    // click ("Publishing changes from within view updates"). Synced both ways.
    @State private var selection: URL?
    @State private var renaming: URL?
    @State private var renameText = ""
    @FocusState private var renameFocus: URL?

    var body: some View {
        List(selection: $selection) {
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
        .contextMenu {
            // Right-click on empty space: create at the root. Row right-clicks
            // use the row's own menu.
            Button("新規メモ") { model.newNote(in: model.rootURL) }
            Button("新規フォルダ") { model.newFolder(in: model.rootURL) }
        }
        .onChange(of: selection) { _, value in
            if value != model.selection { model.userSelected(value) }
        }
        .onChange(of: model.selection) { _, value in
            if value != selection { selection = value }
        }
        .onAppear { selection = model.selection }
        .onKeyPress(.return) {
            guard renaming == nil, let sel = selection else { return .ignored }
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
    @Environment(AppModel.self) private var model
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
                // Attach the menu/drop to the label only, not the whole
                // DisclosureGroup, otherwise its region covers the child rows
                // and acting on a descendant hits this folder instead.
                label(system: "folder")
                    .contextMenu { menu }
                    .dropDestination(for: URL.self) { urls, _ in
                        for u in urls { model.move(u, into: node.url) }
                        return true
                    }
            }
            .tag(node.url)
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
