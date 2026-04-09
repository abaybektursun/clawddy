import SwiftUI
import GhosttyKit

private enum EditTarget: Equatable {
    case project(String)
    case task(project: String, task: String)
    case agent(project: String, task: String, agent: String)
}

struct AgentSidebarView: View {
    @ObservedObject var config: AgentConfig
    var bridge: AgentTerminalBridge
    let onSelectAgent: (String, String, AgentProject) -> Void
    var onRekeyAgent: ((String, String) -> Void)?
    var onForkAgent: ((String, String, String, AgentProject) -> Void)?  // sourceKey, newKey, newName, project
    var onSendTextToAgent: ((String, String) -> Void)?  // key, text

    @State private var selectedKey: String?
    @State private var editText = ""
    @State private var addingAgentTo: (project: String, task: String)?
    @State private var editing: EditTarget?
    @State private var pendingDirectory: (project: String, path: String)?

    // Snapshot of states — updated by timer, avoids @ObservedObject on bridge
    @State private var stateSnapshot: [String: AgentState] = [:]

    var body: some View {
        Group {
            if config.projects.isEmpty {
                emptyState
            } else {
                agentList
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                bottomBar
            }
        }
        .onAppear { stateSnapshot = bridge.agentStates }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            let current = bridge.agentStates
            if current != stateSnapshot { stateSnapshot = current }
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
            if editing == .project(project.name) {
                TextField("Project name", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .onSubmit { confirmRenameProject(old: project.name) }
                    .onExitCommand { editing = nil }
            } else {
                Text(project.name.uppercased())
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .tracking(1.0)
                    .onTapGesture(count: 2) {
                        addingAgentTo = nil
                        editText = project.name
                        editing = .project(project.name)
                    }
            }

            Spacer(minLength: 8)

            Menu {
                Button("Add Task") {
                    let name = "Task \(project.tasks.count + 1)"
                    config.addTask(project: project.name, name: name)
                }
                Button("Rename Project") {
                    addingAgentTo = nil
                    editText = project.name
                    editing = .project(project.name)
                }
                Button("Set Directory\u{2026}") { pickDirectory(project: project.name) }
                Divider()
                Button("Delete Project", role: .destructive) {
                    DispatchQueue.main.async {
                        for task in project.tasks {
                            for agent in task.agents {
                                let key = AgentConfig.agentKey(project: project.name, task: task.name, agent: agent)
                                bridge.stopTracking(agent: key)
                            }
                        }
                        config.removeProject(name: project.name)
                    }
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
        if let dir = project.workingDirectory {
            Text(compactPath(dir))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
                .listRowSeparator(.hidden)
                .padding(.bottom, 6)
        }

        if pendingDirectory?.project == project.name {
            directoryWarning(project: project)
        }

        if project.tasks.isEmpty {
            Text("No tasks — add one from the \u{2026} menu")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
                .padding(.vertical, 4)
        }

        ForEach(project.tasks) { task in
            taskLabel(task, project: project)
                .listRowSeparator(.hidden)

            ForEach(task.agents, id: \.self) { agent in
                let key = AgentConfig.agentKey(project: project.name, task: task.name, agent: agent)
                agentRow(agent: agent, key: key, project: project, task: task)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedKey = key
                        onSelectAgent(key, agent, project)
                    }
            }

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
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 2, height: 12)

            if editing == .task(project: project.name, task: task.name) {
                TextField("Task name", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .onSubmit { confirmRenameTask(project: project.name, old: task.name) }
                    .onExitCommand { editing = nil }
            } else {
                Text(task.name)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) {
                        addingAgentTo = nil
                        editText = task.name
                        editing = .task(project: project.name, task: task.name)
                    }
            }

            Spacer(minLength: 4)

            Button {
                editing = nil
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
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: - Agent Row

    private func agentRow(agent: String, key: String, project: AgentProject, task: AgentTask) -> some View {
        let isSelected = selectedKey == key
        let state = stateSnapshot[key] ?? .notStarted
        let isEditing = editing == .agent(project: project.name, task: task.name, agent: agent)
        return HStack(spacing: 10) {
            statusDot(state)
                .frame(width: 8, height: 8)

            if isEditing {
                TextField("agent name", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .onSubmit {
                        confirmRenameAgent(project: project.name, task: task.name, old: agent)
                    }
                    .onExitCommand { editing = nil }
            } else {
                Text(agent)
                    .font(.system(.body, design: .monospaced, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) {
                        addingAgentTo = nil
                        editText = agent
                        editing = .agent(project: project.name, task: task.name, agent: agent)
                    }
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                if !state.label.isEmpty {
                    Text(state.label)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(state.color)
                }

                stateIndicator(state)
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
            Button("Rename Agent") {
                addingAgentTo = nil
                editText = agent
                editing = .agent(project: project.name, task: task.name, agent: agent)
            }
            Button("Fork Agent") {
                forkAgent(sourceAgent: agent, sourceKey: key, project: project, task: task)
            }
            Divider()
            Button("Delete Agent", role: .destructive) {
                DispatchQueue.main.async {
                    bridge.stopTracking(agent: key)
                    config.removeAgent(project: project.name, task: task.name, name: agent)
                }
            }
        }
    }

    // MARK: - Fork

    private func forkAgent(sourceAgent: String, sourceKey: String, project: AgentProject, task: AgentTask) {
        // Generate a unique name: {name}-fork, {name}-fork-2, etc.
        let existingAgents = Set(task.agents)
        var newName = "\(sourceAgent)-fork"
        var suffix = 2
        while existingAgents.contains(newName) {
            newName = "\(sourceAgent)-fork-\(suffix)"
            suffix += 1
        }

        // Add new agent to config
        guard config.addAgent(project: project.name, task: task.name, name: newName) else { return }

        let newKey = AgentConfig.agentKey(project: project.name, task: task.name, agent: newName)
        onForkAgent?(sourceKey, newKey, newName, project)
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
        .padding(.horizontal, 6)
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

    // MARK: - Status Visuals

    @ViewBuilder
    private func statusDot(_ state: AgentState) -> some View {
        if state == .notStarted {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        } else {
            Circle().foregroundColor(state.color)
        }
    }

    @ViewBuilder
    private func stateIndicator(_ state: AgentState) -> some View {
        if let icon = state.iconName {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(state.color)
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
        panel.message = "Working directory for all agents in this project"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let project = config.projects.first(where: { $0.name == name })
        let hasExistingDir = project?.workingDirectory != nil
        let hasAgents = !(project?.tasks.flatMap(\.agents).isEmpty ?? true)

        if hasExistingDir && hasAgents {
            pendingDirectory = (name, url.path)
        } else {
            applyWorkingDirectory(project: name, path: url.path)
        }
    }

    private func applyWorkingDirectory(project name: String, path: String) {
        guard let i = config.projects.firstIndex(where: { $0.name == name }) else { return }
        for task in config.projects[i].tasks {
            for agent in task.agents {
                bridge.clearSession(
                    agent: AgentConfig.agentKey(project: name, task: task.name, agent: agent)
                )
            }
        }
        config.projects[i].workingDirectory = path
        config.save()
    }

    // MARK: - Rename

    private func confirmRenameProject(old: String) {
        let new = editText.trimmingCharacters(in: .whitespaces)
        if !new.isEmpty && new != old {
            if let project = config.projects.first(where: { $0.name == old }) {
                for task in project.tasks {
                    for agent in task.agents {
                        let oldKey = AgentConfig.agentKey(project: old, task: task.name, agent: agent)
                        let newKey = AgentConfig.agentKey(project: new, task: task.name, agent: agent)
                        bridge.rekey(old: oldKey, new: newKey)
                        onRekeyAgent?(oldKey, newKey)
                    }
                }
            }
            config.renameProject(old: old, new: new)
        }
        editing = nil
    }

    private func confirmRenameTask(project: String, old: String) {
        let new = editText.trimmingCharacters(in: .whitespaces)
        if !new.isEmpty && new != old {
            if let proj = config.projects.first(where: { $0.name == project }),
               let task = proj.tasks.first(where: { $0.name == old }) {
                for agent in task.agents {
                    let oldKey = AgentConfig.agentKey(project: project, task: old, agent: agent)
                    let newKey = AgentConfig.agentKey(project: project, task: new, agent: agent)
                    bridge.rekey(old: oldKey, new: newKey)
                    onRekeyAgent?(oldKey, newKey)
                }
            }
            config.renameTask(project: project, old: old, new: new)
        }
        editing = nil
    }

    private func confirmRenameAgent(project: String, task: String, old: String) {
        let new = editText.trimmingCharacters(in: .whitespaces)
        defer { editing = nil }
        guard !new.isEmpty, new != old else { return }

        let oldKey = AgentConfig.agentKey(project: project, task: task, agent: old)
        let newKey = AgentConfig.agentKey(project: project, task: task, agent: new)

        guard config.renameAgent(project: project, task: task, old: old, new: new) else { return }

        // Update bridge state and surface mapping
        bridge.rekey(old: oldKey, new: newKey)
        onRekeyAgent?(oldKey, newKey)

        // Send /rename to the running Claude session so its display name updates too.
        // We use the new key (since the surface was just rekeyed).
        onSendTextToAgent?(newKey, "/rename \(new)\n")
    }

    // MARK: - Directory Warning

    private func directoryWarning(project: AgentProject) -> some View {
        let agentCount = project.tasks.flatMap(\.agents).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(.caption))
                Text("AGENT SESSIONS WILL BE LOST")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(.red)
            }

            Text("\(agentCount) agent\(agentCount == 1 ? "" : "s") will lose conversation history.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.red.opacity(0.8))

            HStack(spacing: 12) {
                Button {
                    guard let pending = pendingDirectory else { return }
                    pendingDirectory = nil
                    applyWorkingDirectory(project: pending.project, path: pending.path)
                } label: {
                    Text("Reset Sessions")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.red, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    pendingDirectory = nil
                } label: {
                    Text("Cancel")
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.red.opacity(0.25), lineWidth: 0.5))
        .listRowSeparator(.hidden)
        .padding(.bottom, 6)
    }
}
