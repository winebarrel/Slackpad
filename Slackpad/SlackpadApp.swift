import SwiftUI

/// Persists the window's position and size across launches. Restores the saved
/// frame the moment the view is attached to the window (viewDidMoveToWindow),
/// before it is displayed, to avoid a flash at the default position. Saves on
/// move/resize. (SwiftUI's WindowGroup does not reliably honour
/// setFrameAutosaveName, so this is manual.)
struct WindowAccessor: NSViewRepresentable {
    let key: String

    func makeCoordinator() -> Coordinator {
        Coordinator(key: key)
    }

    func makeNSView(context: Context) -> NSView {
        let view = FrameRestoringView()
        view.onWindow = { [coordinator = context.coordinator] window in
            coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

    /// NSView that reports its window as soon as it is attached, which happens
    /// before the window is ordered on screen.
    final class FrameRestoringView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?
        private var reported = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, !reported { reported = true; onWindow?(window) }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let key: String
        weak var window: NSWindow?

        init(key: String) {
            self.key = key
        }

        func attach(to window: NSWindow) {
            guard self.window == nil else { return }
            self.window = window
            // Hide the window until it is positioned, so SwiftUI's launch-time
            // centering isn't visible as a flash.
            window.alphaValue = 0
            restore()
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                restore() // re-apply after SwiftUI centers
                window.alphaValue = 1 // reveal at the restored frame
                // Register observers only now, after the centering, so the
                // transient center() move doesn't overwrite the saved position.
                let center = NotificationCenter.default
                center.addObserver(self, selector: #selector(save), name: NSWindow.didMoveNotification, object: window)
                center.addObserver(self, selector: #selector(save), name: NSWindow.didEndLiveResizeNotification, object: window)
            }
        }

        private func restore() {
            guard let window, let saved = UserDefaults.standard.string(forKey: key) else { return }
            window.setFrame(NSRectFromString(saved), display: false)
        }

        @objc private func save() {
            guard let window else { return }
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
        }
    }
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
                .background(WindowAccessor(key: "SlackpadMainWindowFrame"))
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { model.newNote() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.needsRoot)
                Button("New Folder") { model.newFolder() }
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
