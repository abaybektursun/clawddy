import SwiftUI
import GhosttyKit

struct SettingsView: View {
    let preferencesFile: URL
    /// The preferences were saved: the app keeps them in memory, read once.
    let onSave: (AgentPreferences) -> Void
    @State private var preferences: AgentPreferences
    @State private var persistenceError: String?

    init(preferencesFile: URL, onSave: @escaping (AgentPreferences) -> Void = { _ in }) {
        self.preferencesFile = preferencesFile
        self.onSave = onSave
        let loaded = AgentPreferencesStore.load(from: preferencesFile)
        _preferences = State(initialValue: loaded.preferences)
        _persistenceError = State(initialValue: loaded.error)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Agent Defaults")
                    .font(.title2.weight(.semibold))
                Text("Choose how newly created agents start. Each agent keeps its selected mode.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(spacing: 0) {
                    providerRow(.claudeCode)
                    Divider()
                        .padding(.leading, 48)
                    providerRow(.codex)
                }
            }

            if usesUnrestrictedMode {
                Label(
                    "Unrestricted modes can run commands, access the network, and modify files without asking. Use them only in projects you trust.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Warning")
                    .accessibilityValue(
                        "Unrestricted modes can run commands, access the network, and modify files without asking. Use them only in projects you trust.")
            }

            if let persistenceError {
                Label(persistenceError, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Terminal Configuration")
                        .font(.callout.weight(.medium))
                    Text("Appearance, fonts, key bindings, and other terminal settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Configuration…") {
                    (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
                }
            }
        }
        .padding(24)
        .frame(width: 590)
    }

    private var usesUnrestrictedMode: Bool {
        AgentProviderID.allCases.contains {
            preferences.defaultStartMode(for: $0) == .unrestricted
        }
    }

    private func providerRow(_ provider: AgentProviderID) -> some View {
        let mode = preferences.defaultStartMode(for: provider)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: provider.symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName)
                    .font(.headline)
                Text(provider.startModeDescription(mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Picker(
                "Default start mode for \(provider.displayName)",
                selection: modeBinding(for: provider)
            ) {
                ForEach(AgentStartMode.allCases) { option in
                    Text(provider.startModeTitle(option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 220)
        }
        .padding(12)
        .accessibilityElement(children: .contain)
    }

    private func modeBinding(for provider: AgentProviderID) -> Binding<AgentStartMode> {
        Binding(
            get: { preferences.defaultStartMode(for: provider) },
            set: { newValue in
                var updated = preferences
                updated.setDefaultStartMode(newValue, for: provider)
                do {
                    try AgentPreferencesStore.save(updated, to: preferencesFile)
                    preferences = updated
                    onSave(updated)
                    persistenceError = nil
                } catch {
                    persistenceError = "Agent defaults could not be saved: \(error.localizedDescription)"
                }
            })
    }
}

#Preview {
    SettingsView(preferencesFile: FileManager.default.temporaryDirectory
        .appendingPathComponent("clawddy-settings-preview.json"))
}
