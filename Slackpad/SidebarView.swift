import SwiftUI

/// Left pane: folders and notes in a single tree. Folders nest and their
/// expansion state is persisted. Notes drag into folders to move. Selecting a
/// row and pressing Return (or right-click > Rename) renames it inline.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    // Local selection so the List writes to @State rather than to the shared
    // model's observable state, which would publish mid view-update on every
    // click ("Publishing changes from within view updates"). Synced both ways.
    // A Set enables multi-selection; only deletion is offered for >1 items.
    @State private var selection: Set<URL> = []
    @State private var renaming: URL?
    @State private var renameText = ""

    var body: some View {
        List(selection: $selection) {
            ForEach(model.tree) { node in
                NodeRow(
                    node: node,
                    selection: selection,
                    renaming: $renaming,
                    renameText: $renameText,
                    begin: begin,
                    commit: commit,
                    cancel: cancel,
                    deleteSelection: { model.deleteAll(selection) }
                )
            }
        }
        .contextMenu {
            // Right-click on empty space: create at the root. Row right-clicks
            // use the row's own menu.
            Button("New Note") { model.newNote(in: model.rootURL) }
            Button("New Folder") { model.newFolder(in: model.rootURL) }
        }
        .onChange(of: selection) { _, value in
            // Open the note only for a single selection; a multi-selection
            // clears the model's current-note context (the editor stays open).
            let single = value.count == 1 ? value.first : nil
            if single != model.selection { model.userSelected(single) }
        }
        .onChange(of: model.selection) { _, value in
            // Sync only on a real programmatic selection (⌘N, rename, restore):
            // collapse to that single item. A nil (the multi-select echo or a
            // delete) is ignored so it doesn't clear an active multi-selection.
            if let value, selection != [value] { selection = [value] }
        }
        .onAppear { selection = model.selection.map { Set([$0]) } ?? [] }
        // Start an inline rename when the model asks (e.g. a new note), so its
        // name is immediately editable in the sidebar with the whole name
        // selected for type-to-replace.
        .onChange(of: model.beginRenameToken) { _, _ in
            if let url = model.renameTargetURL { begin(url) }
        }
        .onDeleteCommand { model.deleteAll(selection) }
        .onKeyPress(.return) {
            guard renaming == nil, selection.count == 1, let sel = selection.first else { return .ignored }
            begin(sel)
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let root = model.rootURL else { return false }
            return model.moveAll(urls, into: root)
        }
    }

    private func begin(_ url: URL) {
        // Folders keep their full name (which may contain dots); only notes
        // drop the .txt extension.
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        renameText = isDir.boolValue ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        renaming = url
    }

    private func commit() {
        guard let url = renaming else { return }
        renaming = nil
        model.rename(url, to: renameText)
    }

    private func cancel() {
        renaming = nil
    }
}

private struct NodeRow: View {
    @Environment(AppModel.self) private var model
    let node: NoteNode
    let selection: Set<URL>
    @Binding var renaming: URL?
    @Binding var renameText: String
    let begin: (URL) -> Void
    let commit: () -> Void
    let cancel: () -> Void
    let deleteSelection: () -> Void

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: model.expansionBinding(node.url)) {
                ForEach(node.children ?? []) { child in
                    NodeRow(
                        node: child,
                        selection: selection,
                        renaming: $renaming,
                        renameText: $renameText,
                        begin: begin,
                        commit: commit,
                        cancel: cancel,
                        deleteSelection: deleteSelection
                    )
                }
            } label: {
                // Attach the menu/drop to the label only, not the whole
                // DisclosureGroup, otherwise its region covers the child rows
                // and acting on a descendant hits this folder instead.
                label(system: "folder")
                    .contextMenu { menu }
                    .dropDestination(for: URL.self) { urls, _ in
                        model.moveAll(urls, into: node.url)
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
            // White field + label-coloured text so it stays legible over the
            // row's blue selection highlight (Finder-style).
            RenameField(text: $renameText, onCommit: commit, onCancel: cancel)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Name")
        } else {
            Label(node.name, systemImage: system)
                .draggable(node.url)
        }
    }

    @ViewBuilder private var menu: some View {
        if selection.count > 1, selection.contains(node.url) {
            // Multi-selection: only deletion is offered.
            Button("Move to Trash", role: .destructive, action: deleteSelection)
        } else {
            Button("Rename") { begin(node.url) }
            Divider()
            Button("New Note") { model.selection = node.url; model.newNote() }
            Button("New Folder") { model.selection = node.url; model.newFolder() }
            Divider()
            Button("Move to Trash", role: .destructive) { model.delete(node.url) }
        }
    }
}

/// Inline rename field backed by NSTextField. Unlike SwiftUI's TextField it can
/// select all of its text the instant it appears, so a new note's "Untitled"
/// name is highlighted and typing replaces it (Finder style). Commits on Return
/// or focus loss, cancels on Escape.
private struct RenameField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusSelectingTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        // Transparent field; the legible white background is drawn in SwiftUI
        // behind it (see label()), matching the plain-text-field look and
        // keeping the text readable over the row's blue selection highlight.
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .labelColor
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameField

        init(_ parent: RenameField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_: Notification) {
            // Return, Tab and click-away all end editing; commit the name.
            // Escape is intercepted in doCommandBy and cancels before this runs.
            parent.onCommit()
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

/// NSTextField that selects all its text once it is placed in a window, so the
/// rename starts with the whole name highlighted.
private final class FocusSelectingTextField: NSTextField {
    private var didFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didFocus else { return }
        didFocus = true
        // Defer so the window is key and can take first responder.
        DispatchQueue.main.async { [weak self] in
            self?.selectText(nil)
        }
    }
}
