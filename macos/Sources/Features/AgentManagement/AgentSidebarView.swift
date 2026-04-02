import SwiftUI
import GhosttyKit

struct AgentSidebarView: View {
    @ObservedObject var config: AgentConfig
    @ObservedObject var bridge: AgentTerminalBridge
    let onSelectAgent: (String, String, AgentProject) -> Void

    @State private var selectedKey: String?
    @State private var editText = ""
    @State private var addingAgentTo: (project: String, task: String)?

    var body: some View {
        VStack(spacing: 0) {
            if config.projects.isEmpty {
                emptyState
            } else {
                agentList
            }
            Divider()
            bottomBar
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.quaternary)
            Text("No projects yet")
                .font(.system(.callout, design: .monospaced, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("Create a project to start managing agents")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: - Agent List

    private var agentList: some View {
        List {
            ForEach(config.projects) { project in
                Section {
                    projectContent(project)
                } header: {
                    projectHeader(project)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Project

    private func projectHeader(_ project: AgentProject) -> some View {
        HStack(spacing: 0) {
            // Name — takes priority, never truncated
            Text(project.name.uppercased())
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .tracking(1.0)

            Spacer(minLength: 8)

            // Menu — fixed size, always accessible
            Menu {
                Button("Add Task") {
                    let name = "Task \(project.tasks.count + 1)"
                    config.addTask(project: project.name, name: name)
                }
                Button("Set Directory\u{2026}") { pickDirectory(project: project.name) }
                Divider()
                Button("Delete Project", role: .destructive) {
                    config.removeProject(name: project.name)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func projectContent(_ project: AgentProject) -> some View {
        // Working directory subtitle (under the section header)
        if let dir = project.workingDirectory {
            Text(compactPath(dir))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
                .listRowSeparator(.hidden)
                .padding(.bottom, 2)
        }

        if project.tasks.isEmpty {
            Text("No tasks — add one from the \u{2026} menu")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
                .padding(.vertical, 4)
        }

        ForEach(project.tasks) { task in
            // Task label — not selectable (no .tag), visually distinct
            taskLabel(task, project: project)
                .listRowSeparator(.hidden)

            // Agents under this task
            ForEach(task.agents, id: \.self) { agent in
                let key = AgentConfig.agentKey(project: project.name, task: task.name, agent: agent)
                agentRow(agent: agent, key: key, projectName: project.name, taskName: task.name)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedKey = key
                        onSelectAgent(key, agent, project)
                    }
            }

            // Inline "add agent" field
            if let adding = addingAgentTo,
               adding.project == project.name,
               adding.task == task.name {
                newAgentField(project: project.name, task: task.name)
            }
        }
    }

    // MARK: - Task Label

    private func taskLabel(_ task: AgentTask, project: AgentProject) -> some View {
        HStack(spacing: 6) {
            // Subtle line to indicate hierarchy
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 2, height: 12)

            Text(task.name)
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            Button {
                addingAgentTo = (project.name, task.name)
                editText = ""
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: - Agent Row
    //
    // Layout budget (sidebar min 220pt, list insets ~16pt each side = 188pt usable):
    //   dot(8) + gap(10) + name(flex) + gap(8) + pct(28) + gap(6) + icon(14) = 74pt fixed + name
    //   Name gets at least 114pt — enough for ~12 monospaced chars at 13pt.

    private func agentRow(agent: String, key: String, projectName: String, taskName: String) -> some View {
        let isSelected = selectedKey == key
        return HStack(spacing: 10) {
            statusDot(for: key)
                .frame(width: 8, height: 8)

            Text(agent)
                .font(.system(.body, design: .monospaced, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if let pct = contextPercent(for: key) {
                    Text("\(pct)%")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.quaternary)
                        .monospacedDigit()
                        .frame(minWidth: 28, alignment: .trailing)
                }

                stateIndicator(for: key)
                    .frame(width: 14, alignment: .center)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contextMenu {
            Button("Delete Agent", role: .destructive) {
                bridge.stopTracking(agent: key)
                config.removeAgent(project: projectName, task: taskName, name: agent)
            }
        }
    }

    // MARK: - New Agent Field

    private func newAgentField(project: String, task: String) -> some View {
        HStack(spacing: 10) {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                .frame(width: 8, height: 8)

            TextField("agent name", text: $editText)
                .font(.system(.body, design: .monospaced, weight: .medium))
                .textFieldStyle(.plain)
                .onSubmit {
                    let name = editText.trimmingCharacters(in: .whitespaces)
                    if config.addAgent(project: project, task: task, name: name) {
                        addingAgentTo = nil
                        editText = ""
                    }
                }
                .onExitCommand { addingAgentTo = nil }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button {
                let name = "Project \(config.projects.count + 1)"
                config.addProject(name: name)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(.caption))
                    Text("New Project")
                        .font(.system(.caption, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            let count = config.allAgentNames.count
            Text("\(count) agent\(count == 1 ? "" : "s")")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Status Dot

    @ViewBuilder
    private func statusDot(for key: String) -> some View {
        let state = bridge.state(for: key)
        if state == .notStarted {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        } else {
            Circle().foregroundColor(dotColor(for: state))
        }
    }

    private func dotColor(for state: AgentState) -> Color {
        switch state {
        case .notStarted:   return .gray
        case .terminalOnly: return .indigo
        case .claudeActive: return .cyan
        case .claudeIdle:   return .orange
        }
    }

    // MARK: - State Indicator

    @ViewBuilder
    private func stateIndicator(for key: String) -> some View {
        switch bridge.state(for: key) {
        case .claudeActive:
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.cyan)
        case .claudeIdle:
            Image(systemName: "moon.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
        case .terminalOnly:
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.indigo)
        case .notStarted:
            EmptyView()
        }
    }

    // MARK: - Context Percent

    private func contextPercent(for key: String) -> Int? {
        switch bridge.state(for: key) {
        case .claudeActive(let pct): return pct
        case .claudeIdle(let pct):   return pct
        default: return nil
        }
    }

    // MARK: - Utilities

    private func compactPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func pickDirectory(project name: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let i = config.projects.firstIndex(where: { $0.name == name }) else { return }
        config.projects[i].workingDirectory = url.path
        config.save()
    }
}
