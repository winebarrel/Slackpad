import SwiftUI

/// Shown until a root folder is chosen. The app cannot store notes without it,
/// so this keeps prompting until the user picks one.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("メモの保存先を選択")
                .font(.title2.bold())
            Text("メモはこのフォルダに .txt ファイルとして保存されます。\nあとで設定から変更できます。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("フォルダを選択...") { model.chooseRoot() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 300)
    }
}
