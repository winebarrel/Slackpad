import SwiftUI

/// NSTextView subclass that turns Return into "send" according to the
/// configured behaviour, leaving newline insertion to the other combo.
final class SendingTextView: NSTextView {
    var enterToSend = true
    var onSend: (() -> Void)?
    /// Reports whether the field looks empty (no text and not composing), so
    /// the placeholder can hide the moment IME composition starts.
    var onVisualEmptyChange: ((Bool) -> Void)?

    private func reportVisualEmpty() {
        onVisualEmptyChange?(string.isEmpty && !hasMarkedText())
    }

    override func didChangeText() {
        super.didChangeText()
        reportVisualEmpty()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        reportVisualEmpty()
    }

    override func unmarkText() {
        super.unmarkText()
        reportVisualEmpty()
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // While the IME is composing (marked text), let Return confirm the
        // candidate instead of sending.
        if isReturn, !hasMarkedText() {
            let shift = event.modifierFlags.contains(.shift)
            let cmd = event.modifierFlags.contains(.command)
            if enterToSend {
                if !shift, !cmd { onSend?(); return }
            } else {
                if cmd { onSend?(); return }
            }
        }
        super.keyDown(with: event)
    }
}

/// The Slack input field. A few lines tall, Slack-style, with configurable
/// Enter-to-send. Disabled (non-editable) when no webhook is configured.
struct PostField: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var enterToSend: Bool
    var isEnabled: Bool
    var focusToken: Int
    var onSend: () -> Void
    var onEmptyChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let size = scroll.contentSize
        let container = NSTextContainer(size: NSSize(width: size.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let layout = NSLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let textView = SendingTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = font
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.onSend = { [weak coordinator = context.coordinator] in coordinator?.parent.onSend() }
        textView.onVisualEmptyChange = { [weak coordinator = context.coordinator] empty in
            coordinator?.parent.onEmptyChange(empty)
        }
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? SendingTextView else { return }
        // Push text into the view only when it isn't being edited, or when
        // clearing to empty with no IME composition in progress. Writing during
        // composition would reset the marked text and drop the first character.
        if textView.string != text,
           textView.window?.firstResponder !== textView || (text.isEmpty && !textView.hasMarkedText())
        {
            // Setting the string can fire textDidChange synchronously; suppress
            // the write-back so we don't publish the binding mid view-update.
            context.coordinator.isProgrammatic = true
            textView.string = text
            context.coordinator.isProgrammatic = false
        }
        if textView.font != font { textView.font = font }
        textView.enterToSend = enterToSend
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        if context.coordinator.lastFocus != focusToken {
            context.coordinator.lastFocus = focusToken
            // Don't focus a disabled field (no webhook), or ⌘L would land on a
            // non-editable control.
            if isEnabled {
                DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PostField
        var lastFocus = 0
        var isProgrammatic = false
        init(_ parent: PostField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammatic, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
