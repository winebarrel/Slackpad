import SwiftUI
import AppKit

/// NSTextView subclass that turns Return into "send" according to the
/// configured behaviour, leaving newline insertion to the other combo.
final class SendingTextView: NSTextView {
    var enterToSend = true
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn {
            let shift = event.modifierFlags.contains(.shift)
            let cmd = event.modifierFlags.contains(.command)
            if enterToSend {
                if !shift && !cmd { onSend?(); return }
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
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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

        let tv = SendingTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.font = font
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        tv.onSend = { [weak coordinator = context.coordinator] in coordinator?.parent.onSend() }
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? SendingTextView else { return }
        if tv.string != text { tv.string = text }
        if tv.font != font { tv.font = font }
        tv.enterToSend = enterToSend
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PostField
        init(_ parent: PostField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
