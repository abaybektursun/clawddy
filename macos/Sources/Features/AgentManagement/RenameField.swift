import SwiftUI
import AppKit

/// Inline rename TextField with auto-focus, select-all on appear,
/// commit-on-blur, and inline error display. Used wherever the sidebar
/// supports renaming (project, task, agent) or creating-with-naming.
///
/// Behavior:
///   Enter      → onCommit
///   Esc        → onCancel
///   Blur       → onCommit (parent decides whether failure keeps editor open)
///   On appear  → focus + select all
struct RenameField: View {
    @Binding var text: String
    var placeholder: String
    var error: String?
    var font: Font = .body
    var onCommit: () -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool
    @State private var didActivate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(font)
                .focused($focused)
                .lineLimit(1)
                .onSubmit(onCommit)
                .onExitCommand(perform: onCancel)
                .onChange(of: focused) { _, isFocused in
                    // Commit on blur, but only after initial focus has been
                    // established — otherwise the very first transition during
                    // view setup would trigger a spurious commit.
                    if didActivate && !isFocused {
                        onCommit()
                    }
                }
                .onAppear {
                    focused = true
                    DispatchQueue.main.async {
                        didActivate = true
                        // Select all current text via the responder chain.
                        // SwiftUI TextField doesn't expose selectAll directly.
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                }
                .overlay(alignment: .bottom) {
                    if error != nil {
                        Rectangle()
                            .fill(.red)
                            .frame(height: 1)
                            .offset(y: 2)
                    }
                }

            if let error {
                Text(error)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
    }
}
