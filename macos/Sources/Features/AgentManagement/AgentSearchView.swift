import SwiftUI
import GhosttyKit

struct AgentSearchResult: Identifiable {
    let agent: String
    let project: String
    let task: String
    let key: String
    var id: String { key }
}

struct AgentSearchView: View {
    @ObservedObject var config: AgentConfig
    @ObservedObject var bridge: AgentTerminalBridge
    let onSelectAgent: (String, String, AgentProject) -> Void  // key, displayName, project
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var appeared = false
    @State private var keyMonitor: Any?
    @FocusState private var isSearchFocused: Bool

    private var results: [AgentSearchResult] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        var matches: [AgentSearchResult] = []
        for project in config.projects {
            for task in project.tasks {
                for agent in task.agents {
                    if q.isEmpty || agent.lowercased().contains(q)
                        || project.name.lowercased().contains(q)
                        || task.name.lowercased().contains(q) {
                        matches.append(AgentSearchResult(
                            agent: agent,
                            project: project.name,
                            task: task.name,
                            key: AgentConfig.agentKey(project: project.name, task: task.name, agent: agent)
                        ))
                    }
                }
            }
        }
        return matches
    }

    var body: some View {
        VStack(spacing: 6) {
            searchBar
            if !results.isEmpty {
                resultsList
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(appeared ? 1.0 : 0.95)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(duration: 0.3, bounce: 0.1)) { appeared = true }
            Task { isSearchFocused = true }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                switch event.keyCode {
                case 126: // up arrow
                    if selectedIndex > 0 { selectedIndex -= 1 }
                    return nil
                case 125: // down arrow
                    if selectedIndex < results.count - 1 { selectedIndex += 1 }
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        }
        .onChange(of: query) { _ in selectedIndex = 0 }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search agents\u{2026}", text: $query)
                .font(.system(.title3, design: .monospaced, weight: .medium))
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit { activateSelected() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    resultRow(result, selected: index == selectedIndex)
                        .onTapGesture { selectedIndex = index; activateSelected() }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 320)
    }

    private func resultRow(_ result: AgentSearchResult, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(bridge.state(for: result.key).color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.agent)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .lineLimit(1)

                Text("\(result.project) / \(result.task)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            stateLabel(for: result.key)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
    }

    private func activateSelected() {
        guard selectedIndex < results.count else { return }
        let result = results[selectedIndex]
        guard let project = config.projects.first(where: { $0.name == result.project }) else { return }
        onSelectAgent(result.key, result.agent, project)
        onDismiss()
    }

    private func stateLabel(for key: String) -> some View {
        let state = bridge.state(for: key)
        return Text(state.label)
            .font(.system(.caption2, design: .monospaced, weight: .medium))
            .foregroundStyle(state.color)
    }
}
