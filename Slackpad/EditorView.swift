import SwiftUI

/// Right pane: the note body editor on top, the Slack post field at the bottom.
/// Shown only when a note is open; otherwise a placeholder.
struct EditorView: View {
    @Environment(AppModel.self) private var model
    let settings: AppSettings
    @State private var draft = ""
    @State private var fieldEmpty = true
    @State private var postFieldHeight: CGFloat = 56

    private static let minPostHeight: CGFloat = 44
    private static let maxPostHeight: CGFloat = 500

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isEditorActive {
                VStack(spacing: 0) {
                    CocoaTextEditor(
                        text: $model.editorText,
                        font: settings.editorFont,
                        scrollToBottomToken: model.scrollToBottomToken,
                        restoreCursor: model.restoreCursor,
                        restoreToken: model.restoreToken,
                        focusToken: model.focusEditorToken,
                        canPostSelection: settings.isWebhookConfigured,
                        convertTabToSpaces: settings.convertTabToSpaces,
                        tabWidth: settings.tabWidth,
                        onEdit: { model.scheduleSave() },
                        onCursor: { model.updateCursor($0) },
                        onPostSelection: { model.postSelection($0) },
                        onFocus: { model.editorFocused() }
                    )
                    .frame(maxHeight: .infinity)
                    resizeHandle
                    postBar
                }
            } else {
                ContentUnavailableView(
                    "Select a Note",
                    systemImage: "doc.text",
                    description: Text("Pick a note from the list, or press ⌘N to create one")
                )
            }
        }
        // A draft belongs to the note it was typed in; drop it when the open
        // note changes (or the editor closes) so it can't post to another note.
        .onChange(of: model.openNoteURL) { _, _ in
            draft = ""
            fieldEmpty = true
        }
    }

    /// Draggable divider that resizes the Slack post field, with an up/down
    /// resize cursor.
    private var resizeHandle: some View {
        ZStack {
            Divider()
            ResizeHandle { delta in
                postFieldHeight = min(max(postFieldHeight + delta, Self.minPostHeight), Self.maxPostHeight)
            }
        }
        .frame(height: 8)
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
                    isEnabled: settings.isWebhookConfigured,
                    focusToken: model.focusPostFieldToken,
                    onSend: send,
                    onEmptyChange: { fieldEmpty = $0 }
                )

                if fieldEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: postFieldHeight)
        }
        .background(.background)
    }

    private var placeholder: String {
        settings.isWebhookConfigured
            ? "Message to post to Slack..."
            : "Enter a Webhook URL in Settings"
    }

    private func send() {
        let text = draft
        guard settings.isWebhookConfigured, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.post(text)
        draft = ""
        fieldEmpty = true
    }
}

/// A thin horizontal drag strip that shows the up/down resize cursor and
/// reports vertical drag deltas (positive = dragged up).
private struct ResizeHandle: NSViewRepresentable {
    var onDrag: (CGFloat) -> Void

    func makeNSView(context _: Context) -> HandleNSView {
        HandleNSView(onDrag: onDrag)
    }

    func updateNSView(_ nsView: HandleNSView, context _: Context) {
        nsView.onDrag = onDrag
    }

    final class HandleNSView: NSView {
        var onDrag: (CGFloat) -> Void
        private var lastLocationY: CGFloat = 0

        init(onDrag: @escaping (CGFloat) -> Void) {
            self.onDrag = onDrag
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func mouseDown(with event: NSEvent) {
            lastLocationY = event.locationInWindow.y
        }

        override func mouseDragged(with event: NSEvent) {
            let locationY = event.locationInWindow.y
            onDrag(locationY - lastLocationY) // window coords: up is positive → grow the field
            lastLocationY = locationY
        }
    }
}
