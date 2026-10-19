import AppKit
import SwiftUI

/// A native search field for the explorer.
///
/// The Results screen scopes search to the list, so the field lives in the
/// inspector rather than in the window toolbar. AppKit supplies the standard
/// search field behavior: placeholder, clear button, Escape-to-clear, and
/// VoiceOver text-field semantics.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    /// A token the Results screen increments when the Find command runs.
    /// `NSSearchField` owns first-responder status, so focus is requested
    /// through the view rather than through a SwiftUI focus state.
    let focusRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .small
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search results")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = prompt

        guard context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var lastFocusRequest: Int

        init(_ parent: SearchField) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
                return false
            }
            control.stringValue = ""
            parent.text = ""
            return true
        }
    }
}
