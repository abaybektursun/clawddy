import SwiftUI

/// Spotlight-style agent picker. Hosts Ghostty's generic CommandPaletteView
/// (pure SwiftUI key handling — no global NSEvent monitor) populated with
/// one CommandOption per agent. Selecting an option calls onSelectAgent.
///
/// The palette dismisses by flipping its isPresented binding to false; we
/// observe that and call onDismiss (which hides the hosting panel). We then
/// re-arm isPresented to true so the next show is interactive — the SwiftUI
/// view stays mounted across panel show/hide cycles (the panel just orders
/// in/out), so this @State persists.
struct AgentCommandPaletteView: View {
    var config: AgentConfig
    var bridge: AgentBridge
    let onSelectAgent: (UUID, AgentProject) -> Void
    let onDismiss: () -> Void

    @State private var isPresented: Bool = true

    private var commandOptions: [CommandOption] {
        var options: [CommandOption] = []
        for project in config.projects {
            for task in project.tasks {
                for entry in task.agents {
                    let instance = bridge.agents[entry.id]
                    let state = instance?.displayState ?? .inactive
                    let id = entry.id
                    let proj = project
                    options.append(CommandOption(
                        title: entry.name,
                        subtitle: "\(entry.provider.displayName) · \(project.name) / \(task.name)",
                        description: ([state.label]
                            + entry.launchProfile.searchTerms
                            + (instance?.metadata?.searchTerms ?? []))
                            .joined(separator: " · "),
                        leadingIcon: state.iconName,
                        leadingColor: state.color,
                        badge: state.label,
                        action: { onSelectAgent(id, proj) }
                    ))
                }
            }
        }
        return options
    }

    var body: some View {
        CommandPaletteView(
            isPresented: $isPresented,
            options: commandOptions,
            placeholder: "Search agents\u{2026}"
        )
        .onChange(of: isPresented) { _, newValue in
            guard !newValue else { return }
            onDismiss()
            // Re-arm so the next panel show is interactive — the panel
            // just orders in/out; the SwiftUI tree stays mounted.
            DispatchQueue.main.async { isPresented = true }
        }
    }
}
