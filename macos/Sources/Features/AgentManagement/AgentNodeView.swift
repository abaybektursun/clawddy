import SwiftUI

struct AgentNodeView: View {
    let name: String
    let state: AgentState
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showDeletePopover = false

    private var dotColor: Color {
        switch state {
        case .notStarted:   return .gray
        case .terminalOnly: return .indigo
        case .claudeActive: return .cyan
        case .claudeIdle:   return .orange
        }
    }

    private var contextPercent: Int? {
        switch state {
        case .claudeActive(let pct): return pct
        case .claudeIdle(let pct):   return pct
        default:                      return nil
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    if state == .notStarted {
                        Circle()
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                            .frame(width: 8, height: 8)
                    } else {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 8, height: 8)
                    }

                    Text(name)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .lineLimit(1)

                    if let pct = contextPercent {
                        Text("\(pct)%")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.04), in: Capsule())
                    }
                }

                Spacer(minLength: 8)

                Button { showDeletePopover = true } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .popover(isPresented: $showDeletePopover) {
                    Button {
                        showDeletePopover = false
                        onDelete()
                    } label: {
                        Text("Delete \(name)")
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(AgentNodePressStyle())
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.15)) { isHovered = hovering }
        }
    }
}

private struct AgentNodePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}
