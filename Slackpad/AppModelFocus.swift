import SwiftUI

/// Keyboard-focus coordination between the note editor and the Slack input.
extension AppModel {
    /// Toggle keyboard focus between the note editor and the Slack post field
    /// (⌘L). Uses the key window's first responder to decide the direction.
    func toggleFieldFocus() {
        guard isEditorActive else { return }
        if NSApp.keyWindow?.firstResponder is SendingTextView {
            focusEditorToken += 1
        } else {
            focusPostFieldToken += 1
        }
    }

    /// When the editor gains focus, select the open note in the sidebar (e.g.
    /// after a multi-selection, so the highlight follows the visible note).
    func editorFocused() {
        guard let open = openNoteURL, selection != open else { return }
        selection = open
    }
}
