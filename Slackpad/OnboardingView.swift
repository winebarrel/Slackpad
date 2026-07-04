import SwiftUI

/// Shown until a root folder is chosen. The app cannot store notes without it,
/// so this keeps prompting until the user picks one.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Choose where to store notes")
                .font(.title2.bold())
            Text("Notes are stored as .txt files in this folder.\nYou can change this later in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose Folder...") { model.chooseRoot() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 300)
    }
}
