import SwiftUI

@main
struct SlackpadApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.settings)
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
                .environmentObject(model)
                .environmentObject(model.settings)
        }
    }
}

/// Gate: onboarding until a root folder exists, then the main window.
private struct RootView: View {
    @EnvironmentObject var model: AppModel

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
