import SwiftUI

/// The main two-pane window: collapsible sidebar tree + editor/post pane.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
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

#Preview("Slackpad") {
    let model = AppModel()
    let manager = FileManager.default
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SlackpadPreview-\(UUID().uuidString)")
    let projects = dir.appendingPathComponent("Projects")
    try? manager.createDirectory(at: projects, withIntermediateDirectories: true)
    try? "Meeting notes\n\n10:15 Standup done\n11:00 Ship the beta"
        .write(to: dir.appendingPathComponent("Meeting notes.txt"), atomically: true, encoding: .utf8)
    try? "Ideas\n\n- keep notes as plain text\n- post to Slack while writing"
        .write(to: dir.appendingPathComponent("Ideas.txt"), atomically: true, encoding: .utf8)
    try? "Slackpad\n\nWrite the README."
        .write(to: projects.appendingPathComponent("Slackpad.txt"), atomically: true, encoding: .utf8)

    model.settings.webhookURL = "https://hooks.slack.com/services/preview"
    model.rootURL = dir
    model.reloadTree()
    model.expanded = [projects]
    let open = dir.appendingPathComponent("Meeting notes.txt")
    model.selection = open
    model.openNote(open)

    return ContentView()
        .environment(model)
        .frame(width: 820, height: 520)
}
