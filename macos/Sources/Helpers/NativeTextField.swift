import AppKit
import SwiftUI

enum NativeTextFieldCommand {
    case cancel
    case moveUp
    case moveDown
}
/// AppKit text input for mixed AppKit/SwiftUI surfaces. The window-owned field
/// editor preserves native selection, paste, undo, input methods, and keyboard
/// navigation; SwiftUI remains responsible only for layout and value state.
struct NativeTextField: NSViewRepresentable {
    enum Style {
        case rounded
        case plain
        case search
    }

    let placeholder: String
    @Binding var text: String
    var style: Style = .rounded
    var font: NSFont?
    var accessibilityLabel: String?
    var isFocused: Binding<Bool>?
    var onSubmit: (() -> Void)?
    var onCommand: ((NativeTextFieldCommand) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField
        switch style {
        case .rounded:
            let textField = NSTextField()
            textField.bezelStyle = .roundedBezel
            field = textField
        case .plain:
            let textField = NSTextField()
            textField.isBordered = false
            textField.drawsBackground = false
            field = textField
        case .search:
            field = NSSearchField()
        }
        field.placeholderString = placeholder
        field.font = font
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel(accessibilityLabel ?? placeholder)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.font = font
        field.setAccessibilityLabel(accessibilityLabel ?? placeholder)

        guard let isFocused else { return }
        if isFocused.wrappedValue,
           field.window?.firstResponder !== field.currentEditor() {
            DispatchQueue.main.async { [weak field] in
                guard let field, field.window != nil else { return }
                field.window?.makeFirstResponder(field)
            }
        } else if !isFocused.wrappedValue,
                  field.window?.firstResponder === field.currentEditor() {
            field.window?.makeFirstResponder(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeTextField

        init(parent: NativeTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused?.wrappedValue = true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.isFocused?.wrappedValue = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCommand?(.cancel)
            case #selector(NSResponder.moveUp(_:)):
                parent.onCommand?(.moveUp)
            case #selector(NSResponder.moveDown(_:)):
                parent.onCommand?(.moveDown)
            case #selector(NSResponder.insertNewline(_:)) where parent.onSubmit != nil:
                parent.onSubmit?()
            default:
                return false
            }
            return true
        }

        @objc func submit(_ sender: NSTextField) {
            parent.text = sender.stringValue
            parent.onSubmit?()
        }
    }
}
