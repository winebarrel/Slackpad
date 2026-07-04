import SwiftUI

@main
struct SlackpadApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.settings)
                .frame(minWidth: 640, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新規メモ") { model.newNote() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.needsRoot)
                Button("新規フォルダ") { model.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.needsRoot)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.settings)
        }
    }
}

/// Gate: onboarding until a root folder exists, then the main window.
private struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.needsRoot {
                OnboardingView()
            } else {
                ContentView()
            }
        }
        .onAppear { model.start() }
    }
}
