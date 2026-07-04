import SwiftUI

/// Right pane: the note body editor on top, the Slack post field at the bottom.
/// Shown only when a note is open; otherwise a placeholder.
struct EditorView: View {
    @Environment(AppModel.self) private var model
    let settings: AppSettings
    @State private var draft = ""
    @State private var fieldEmpty = true

    var body: some View {
        @Bindable var model = model
        if model.isEditorActive {
            VStack(spacing: 0) {
                CocoaTextEditor(
                    text: $model.editorText,
                    font: settings.editorFont,
                    scrollToBottomToken: model.scrollToBottomToken,
                    focusToken: model.focusToken,
                    restoreCursor: model.restoreCursor,
                    restoreToken: model.restoreToken,
                    selectFirstLineToken: model.selectFirstLineToken,
                    onEdit: { model.scheduleSave() },
                    onCursor: { model.updateCursor($0) }
                )
                Divider()
                postBar
            }
        } else {
            ContentUnavailableView(
                "メモを選択",
                systemImage: "doc.text",
                description: Text("左のリストからメモを選ぶか、⌘N で新規作成")
            )
        }
    }

    private var postBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.postError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
            ZStack(alignment: .topLeading) {
                PostField(
                    text: $draft,
                    font: settings.editorFont,
                    enterToSend: settings.enterToSend,
                    isEnabled: settings.isWebhookConfigured && !model.isSending,
                    onSend: send,
                    onEmptyChange: { fieldEmpty = $0 }
                )
                .frame(height: 56)

                if fieldEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(.background)
    }

    private var placeholder: String {
        settings.isWebhookConfigured
            ? "Slackに投稿する文..."
            : "設定でWebhook URLを入力してください"
    }

    private func send() {
        let text = draft
        guard settings.isWebhookConfigured, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.post(text)
        draft = ""
        fieldEmpty = true
    }
}
