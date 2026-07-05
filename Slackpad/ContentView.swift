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
        // Show the open note's filename in the window title (display only;
        // renaming is done from the sidebar).
        .navigationTitle(model.windowTitle)
    }
}

#Preview("Meeting notes") {
    let model = AppModel()
    let manager = FileManager.default
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SlackpadPreview-\(UUID().uuidString)")
    let projects = dir.appendingPathComponent("Projects")
    try? manager.createDirectory(at: projects, withIntermediateDirectories: true)
    try? """
    Agenda
    - Review the roadmap
    - Pick the release date
    - Assign follow-ups

    Posted to Slack
    10:15 Standup done, shipping the beta today
    11:00 Release notes drafted: https://example.com
    """
    .write(to: dir.appendingPathComponent("Meeting notes.txt"), atomically: true, encoding: .utf8)
    try? "- keep notes as plain text\n- post to Slack while writing\n- add fuzzy search someday"
        .write(to: dir.appendingPathComponent("Ideas.txt"), atomically: true, encoding: .utf8)
    try? "Write the README\nAdd screenshots\nTag the first release"
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
