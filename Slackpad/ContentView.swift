import SwiftUI

/// The main two-pane window: collapsible sidebar tree + editor/post pane.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
                .onDeleteCommand { model.deleteSelection() }
                .toolbar {
                    ToolbarItemGroup {
                        Button { model.newFolder() } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .help("New Folder")

                        Button { model.newNote() } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .help("New Note (⌘N)")
                    }
                }
        } detail: {
            EditorView(settings: model.settings)
        }
        .onChange(of: model.settings.sortKey) { _, _ in model.reloadTree() }
        .onChange(of: model.settings.sortAscending) { _, _ in model.reloadTree() }
        .onChange(of: columnVisibility) { _, value in
            model.persistSidebarVisible(value != .detailOnly)
        }
        .onAppear {
            columnVisibility = model.sidebarVisible ? .all : .detailOnly
        }
    }
}
