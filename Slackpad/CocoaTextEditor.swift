import SwiftUI
import AppKit

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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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
        textView.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            // Setting the string can fire textDidChange synchronously; suppress
            // the write-back so we don't publish editorText mid view-update
            // ("Publishing changes from within view updates").
            context.coordinator.isProgrammatic = true
            textView.string = text
            context.coordinator.isProgrammatic = false
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

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CocoaTextEditor
        var lastScroll = 0
        var lastRestore = 0
        var lastSelectFirstLine = 0
        var isProgrammatic = false

        init(_ parent: CocoaTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammatic, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onEdit()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onCursor(textView.selectedRange().location)
        }
    }
}
