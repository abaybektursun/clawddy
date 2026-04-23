import SwiftUI
import GhosttyKit

// MARK: - Sidebar

struct AgentSidebarView: View {
    var config: AgentConfig
    var bridge: AgentBridge
    let onSelectAgent: (UUID, AgentProject) -> Void
    var onForkAgent: ((UUID, AgentProject, String) -> Void)?  // sourceId, project, task
    var onDeleteAgent: ((UUID) -> Void)?

    @State private var selectedID: UUID?
    @State private var editText = ""
    @State private var addingAgentTo: (project: String, task: String)?
    @State private var editingProject: String?
    @State private var editingTask: (project: String, task: String)?
    @State private var editingAgent: UUID?
    @State private var pendingDirectory: (project: String, path: String)?
    @State private var hoveredID: UUID?

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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(config.projects) { project in
                    Section {
                        projectContent(project)
                    } header: {
                        projectHeader(project)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Project Header

    private func projectHeader(_ project: AgentProject) -> some View {
        HStack(spacing: 0) {
            if editingProject == project.name {
                TextField("Project name", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .onSubmit { confirmRenameProject(old: project.name) }
                    .onExitCommand { editingProject = nil }
            } else {
                Text(project.name.uppercased())
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .tracking(1.0)
                    .onTapGesture(count: 2) {
                        editText = project.name
                        editingProject = project.name
                    }
            }

            Spacer(minLength: 8)

            Menu {
                Button("Add Task") {
                    let name = "Task \(project.tasks.count + 1)"
                    config.addTask(project: project.name, name: name)
                }
                Button("Rename Project") {
                    editText = project.name
                    editingProject = project.name
                }
                Button("Set Directory\u{2026}") { pickDirectory(project: project.name) }
                Divider()
                Button("Delete Project", role: .destructive) {
                    DispatchQueue.main.async {
                        for task in project.tasks {
                            for agent in task.agents {
                                onDeleteAgent?(agent.id)
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

    // MARK: - Project Content

    @ViewBuilder
    private func projectContent(_ project: AgentProject) -> some View {
        if let dir = project.workingDirectory {
            Text(compactPath(dir))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
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

            ForEach(task.agents) { entry in
                if let agent = bridge.agents[entry.id] {
                    AgentRow(
                        agent: agent,
                        isSelected: selectedID == entry.id,
                        isHovered: hoveredID == entry.id,
                        isEditing: editingAgent == entry.id,
                        editText: editingAgent == entry.id ? $editText : .constant(""),
                        onCommitRename: { confirmRenameAgent(id: entry.id) },
                        onCancelEdit: { editingAgent = nil }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedID = entry.id
                        onSelectAgent(entry.id, project)
                    }
                    .onHover { h in hoveredID = h ? entry.id : (hoveredID == entry.id ? nil : hoveredID) }
                    .contextMenu {
                        Button("Rename Agent") {
                            editText = agent.name
                            editingAgent = entry.id
                        }
                        Button("Fork Agent") {
                            onForkAgent?(entry.id, project, task.name)
                        }
                        Divider()
                        Button("Delete Agent", role: .destructive) {
                            DispatchQueue.main.async {
                                onDeleteAgent?(entry.id)
                            }
                        }
                    }
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

            if editingTask?.project == project.name && editingTask?.task == task.name {
                TextField("Task name", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .onSubmit { confirmRenameTask(project: project.name, old: task.name) }
                    .onExitCommand { editingTask = nil }
            } else {
                Text(task.name)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) {
                        editText = task.name
                        editingTask = (project.name, task.name)
                    }
            }

            Spacer(minLength: 4)

            Button {
                editText = ""
                addingAgentTo = (project.name, task.name)
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
                    if let _ = bridge.createAgent(name: name, config: config,
                        project: project, task: task) {
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

            let count = config.allAgentEntries.count
            Text("\(count) agent\(count == 1 ? "" : "s")")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Rename Helpers

    private func confirmRenameProject(old: String) {
        let new = editText.trimmingCharacters(in: .whitespaces)
        if !new.isEmpty && new != old {
            config.renameProject(old: old, new: new)
        }
        editingProject = nil
    }

    private func confirmRenameTask(project: String, old: String) {
        let new = editText.trimmingCharacters(in: .whitespaces)
        if !new.isEmpty && new != old {
            config.renameTask(project: project, old: old, new: new)
        }
        editingTask = nil
    }

    private func confirmRenameAgent(id: UUID) {
        let new = editText.trimmingCharacters(in: .whitespaces)
        defer { editingAgent = nil }
        guard !new.isEmpty else { return }

        config.renameAgent(id: id, newName: new)
        bridge.requestRename(id: id, newName: new)
    }

    // MARK: - Directory

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
        config.projects[i].workingDirectory = path
        config.save()
    }

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

                Button { pendingDirectory = nil } label: {
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
        .padding(.bottom, 6)
    }

    // MARK: - Utilities

    private func compactPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

}

// MARK: - Agent Row (per-row observation)

struct AgentRow: View {
    var agent: AgentInstance
    let isSelected: Bool
    let isHovered: Bool
    let isEditing: Bool
    @Binding var editText: String
    let onCommitRename: () -> Void
    let onCancelEdit: () -> Void

    var body: some View {
        let state = agent.displayState
        HStack(spacing: 10) {
            statusDot(state)
                .frame(width: 10, height: 10)

            if isEditing {
                TextField("agent name", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelEdit)
            } else {
                Text(agent.name)
                    .font(.system(.body, design: .monospaced, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if !state.label.isEmpty {
                    Text(state.label)
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(state.color)
                        .contentTransition(.opacity)
                }

                stateIcon(state)
                    .frame(width: 14, alignment: .center)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(rowBackground(state: state))
    }

    // MARK: - Status Dot

    private func statusDot(_ state: DisplayState) -> some View {
        let isInactive = state == .inactive || state == .dead
        return Image(systemName: isInactive ? "circle" : "circle.fill")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(state.color)
    }

    // MARK: - State Icon

    @ViewBuilder
    private func stateIcon(_ state: DisplayState) -> some View {
        if let icon = state.iconName {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state.color)
        }
    }

    // MARK: - Row Background

    private func rowBackground(state: DisplayState) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected
                ? state.selectionTint.opacity(0.18)
                : (isHovered ? Color.secondary.opacity(0.08) : Color.clear))
    }
}
