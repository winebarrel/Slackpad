import SwiftUI

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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Webhook URL")
                    TextField("Webhook URL", text: $settings.webhookURL, prompt: Text("https://hooks.slack.com/services/..."))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                if !settings.webhookURL.isEmpty, !settings.isWebhookConfigured {
                    Text("Enter a URL starting with https://")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Picker("Return key", selection: $settings.enterToSend) {
                    Text("Send (Shift+Return for newline)").tag(true)
                    Text("Newline (⌘Return to send)").tag(false)
                }
                Picker("Timestamp", selection: $settings.postTimestamp) {
                    ForEach(PostTimestamp.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            }

            Section("Location") {
                LabeledContent("Folder") {
                    Text(model.rootURL?.path ?? "Not selected")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Change...") { model.chooseRoot() }
            }

            Section("Editor") {
                Picker("Font", selection: fontSelection) {
                    Text("System Font").tag("")
                    Divider()
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Stepper(value: $settings.fontSize, in: 0 ... 48, step: 1) {
                    Text(settings.fontSize > 0 ? "Size: \(Int(settings.fontSize)) pt" : "Size: Default")
                }
                Toggle("Convert tab to spaces", isOn: $settings.convertTabToSpaces)
                Stepper(value: $settings.tabWidth, in: 1 ... 8, step: 1) {
                    Text("Spaces: \(settings.tabWidth)")
                }
                .disabled(!settings.convertTabToSpaces)
            }

            Section("Sort Notes") {
                Picker("Sort by", selection: $settings.sortKey) {
                    ForEach(SortKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                Picker("Order", selection: $settings.sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
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

#Preview("Slackpad Settings") {
    let model = AppModel()
    model.settings.webhookURL = "https://hooks.slack.com/services/T000/B000/XXXX"
    model.rootURL = URL(fileURLWithPath: "/Users/you/Documents")
    return SettingsView()
        .environment(model)
        .environment(model.settings)
}
