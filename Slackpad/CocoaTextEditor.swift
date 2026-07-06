import SwiftUI

/// NSTextView that reports when it gains keyboard focus.
final class FocusReportingTextView: NSTextView {
    var onFocus: (() -> Void)?

    /// Spaces to insert for a Tab keypress, or nil to insert a literal tab.
    var tabReplacement: String?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    override func insertTab(_ sender: Any?) {
        guard let spaces = tabReplacement else {
            super.insertTab(sender)
            return
        }
        // insertText keeps undo working and fires the delegate's textDidChange.
        insertText(spaces, replacementRange: selectedRange())
    }
}

/// A plain-text editor backed by NSTextView. Gives us programmatic scroll,
/// focus control and the standard macOS key bindings (emacs-style Ctrl-A/E/K
/// etc.) for free. The file on disk stays plain `.txt`.
struct CocoaTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var scrollToBottomToken: Int
    var restoreCursor: Int
    var restoreToken: Int
    var focusToken: Int
    var canPostSelection: Bool
    var convertTabToSpaces: Bool
    var tabWidth: Int
    var onEdit: () -> Void
    var onCursor: (Int) -> Void
    var onPostSelection: (String) -> Void
    var onFocus: () -> Void

    /// Spaces to substitute for a Tab, or nil to keep the literal tab.
    private var tabReplacement: String? {
        convertTabToSpaces ? String(repeating: " ", count: max(1, tabWidth)) : nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder

        // Build an explicit TextKit 1 stack: we edit textStorage directly (link
        // attributes), which glitches TextKit 2's layout (end of text vanishing
        // until the next redraw).
        let size = scroll.contentSize
        let container = NSTextContainer(size: NSSize(width: size.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let layout = NSLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let textView = FocusReportingTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.string = text
        textView.tabReplacement = tabReplacement
        textView.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocus() }
        scroll.documentView = textView
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
        if let focusView = textView as? FocusReportingTextView { focusView.tabReplacement = tabReplacement }

        let coord = context.coordinator
        if coord.lastFocus != focusToken {
            coord.lastFocus = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
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
        var lastFocus = 0
        var isProgrammatic = false
        private weak var editedTextView: NSTextView?
        private weak var menuTextView: NSTextView?
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

        func textView(_ view: NSTextView, menu: NSMenu, for _: NSEvent, at _: Int) -> NSMenu? {
            guard parent.canPostSelection, view.selectedRange().length > 0 else { return menu }
            menuTextView = view
            let item = NSMenuItem(title: "Post Selection to Slack", action: #selector(postSelection(_:)), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        /// Menu actions run on the main thread; @objc methods are otherwise
        /// nonisolated and can't touch main-actor AppKit APIs under Swift 6.
        @MainActor @objc private func postSelection(_: Any?) {
            guard let textView = menuTextView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            parent.onPostSelection((textView.string as NSString).substring(with: range))
        }
    }
}
