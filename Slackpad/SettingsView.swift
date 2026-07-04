import SwiftUI
import AppKit

/// The Settings window (⌘,): Slack webhook, post behaviour, save location,
/// editor font and note sorting.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    private let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Slack") {
                TextField("Webhook URL", text: $settings.webhookURL, prompt: Text("https://hooks.slack.com/services/..."))
                    .textFieldStyle(.roundedBorder)
                if !settings.webhookURL.isEmpty && !settings.isWebhookConfigured {
                    Text("https:// で始まる URL を入力してください")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Picker("Enter キー", selection: $settings.enterToSend) {
                    Text("送信（改行は Shift+Enter）").tag(true)
                    Text("改行（送信は ⌘Enter）").tag(false)
                }
            }

            Section("保存先") {
                LabeledContent("フォルダ") {
                    Text(model.rootURL?.path ?? "未選択")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("変更...") { model.chooseRoot() }
            }

            Section("エディタのフォント") {
                Picker("フォント", selection: fontSelection) {
                    Text("システムフォント").tag("")
                    Divider()
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Stepper(value: $settings.fontSize, in: 0...48, step: 1) {
                    Text(settings.fontSize > 0 ? "サイズ: \(Int(settings.fontSize)) pt" : "サイズ: 標準")
                }
            }

            Section("メモ一覧の並び") {
                Picker("並び替え", selection: $settings.sortKey) {
                    ForEach(SortKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                Picker("順序", selection: $settings.sortAscending) {
                    Text("昇順").tag(true)
                    Text("降順").tag(false)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fontSelection: Binding<String> {
        Binding(
            get: { settings.fontName ?? "" },
            set: { settings.fontName = $0.isEmpty ? nil : $0 }
        )
    }
}
