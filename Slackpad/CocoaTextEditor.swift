import SwiftUI

/// A plain-text editor backed by NSTextView. Gives us programmatic scroll,
/// focus control and the standard macOS key bindings (emacs-style Ctrl-A/E/K
/// etc.) for free. The file on disk stays plain `.txt`.
struct CocoaTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var scrollToBottomToken: Int
    var restoreCursor: Int
    var restoreToken: Int
    var selectFirstLineToken: Int
    var onEdit: () -> Void
    var onCursor: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.string = text
        Self.applyLinks(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Never overwrite the string while the IME is composing: textDidChange
        // doesn't fire for marked text, so `text` is stale and rewriting it here
        // would wipe the composition and jump the caret to the end.
        if textView.string != text, !textView.hasMarkedText() {
            // Setting the string can fire textDidChange synchronously; suppress
            // the write-back so we don't publish editorText mid view-update
            // ("Publishing changes from within view updates").
            context.coordinator.isProgrammatic = true
            textView.string = text
            context.coordinator.isProgrammatic = false
            Self.applyLinks(textView)
        }
        if textView.font != font { textView.font = font }

        let coord = context.coordinator
        if coord.lastScroll != scrollToBottomToken {
            coord.lastScroll = scrollToBottomToken
            DispatchQueue.main.async { textView.scrollToEndOfDocument(nil) }
        }
        if coord.lastRestore != restoreToken {
            coord.lastRestore = restoreToken
            let offset = min(max(restoreCursor, 0), (textView.string as NSString).length)
            DispatchQueue.main.async {
                textView.setSelectedRange(NSRange(location: offset, length: 0))
                textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
            }
        }
        if coord.lastSelectFirstLine != selectFirstLineToken {
            coord.lastSelectFirstLine = selectFirstLineToken
            let nsString = textView.string as NSString
            let firstLineEnd = nsString.range(of: "\n").location
            let length = firstLineEnd == NSNotFound ? nsString.length : firstLineEnd
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: 0, length: length))
            }
        }
    }

    /// Mark http(s) URLs in the body as clickable links. This only adds display
    /// attributes to the text storage; the string (and the saved .txt) stays plain.
    static func applyLinks(_ textView: NSTextView) {
        // Editing attributes during IME composition disturbs the marked text and
        // jumps the caret; wait until composition commits.
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.removeAttribute(.link, range: full)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        detector.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let url = match?.url, url.scheme == "http" || url.scheme == "https",
                  let range = match?.range else { return }
            storage.addAttribute(.link, value: url, range: range)
        }
    }

    /// Only used on the main thread.
    final class Coordinator: NSObject, NSTextViewDelegate, @unchecked Sendable {
        var parent: CocoaTextEditor
        var lastScroll = 0
        var lastRestore = 0
        var lastSelectFirstLine = 0
        var isProgrammatic = false
        private weak var editedTextView: NSTextView?
        private var linkToken = 0

        init(_ parent: CocoaTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammatic, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onEdit()
            // Debounce link detection: scanning the whole document with
            // NSDataDetector on every keystroke is O(n) and slow for big notes.
            editedTextView = textView
            linkToken += 1
            let token = linkToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, linkToken == token, let textView = editedTextView else { return }
                CocoaTextEditor.applyLinks(textView)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onCursor(textView.selectedRange().location)
        }
    }
}
