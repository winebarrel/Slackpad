import SwiftUI
import AppKit

/// A plain-text editor backed by NSTextView. Gives us programmatic scroll,
/// focus control and the standard macOS key bindings (emacs-style Ctrl-A/E/K
/// etc.) for free. The file on disk stays plain `.txt`.
struct CocoaTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var scrollToBottomToken: Int
    var focusToken: Int
    var restoreCursor: Int
    var restoreToken: Int
    var onEdit: () -> Void
    var onCursor: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.font = font
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        if tv.font != font { tv.font = font }

        let coord = context.coordinator
        if coord.lastScroll != scrollToBottomToken {
            coord.lastScroll = scrollToBottomToken
            DispatchQueue.main.async { tv.scrollToEndOfDocument(nil) }
        }
        if coord.lastFocus != focusToken {
            coord.lastFocus = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        if coord.lastRestore != restoreToken {
            coord.lastRestore = restoreToken
            let offset = min(max(restoreCursor, 0), (tv.string as NSString).length)
            DispatchQueue.main.async {
                tv.setSelectedRange(NSRange(location: offset, length: 0))
                tv.scrollRangeToVisible(NSRange(location: offset, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CocoaTextEditor
        var lastScroll = 0
        var lastFocus = 0
        var lastRestore = 0

        init(_ parent: CocoaTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.onEdit()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.onCursor(tv.selectedRange().location)
        }
    }
}
