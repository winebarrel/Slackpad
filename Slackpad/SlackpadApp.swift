import SwiftUI
import AppKit

/// Persists the window's position and size across launches by giving its
/// NSWindow a frame autosave name (AppKit stores the frame in UserDefaults).
struct WindowAccessor: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window yet in makeNSView; defer until it is attached.
        DispatchQueue.main.async {
            view.window?.setFrameAutosaveName(name)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@main
struct SlackpadApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.settings)
                .frame(minWidth: 640, minHeight: 420)
                .background(WindowAccessor(name: "SlackpadMainWindow"))
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
