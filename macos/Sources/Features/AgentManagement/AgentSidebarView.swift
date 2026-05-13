import SwiftUI
import GhosttyKit

// MARK: - Edit State

/// Which kind of edit is in progress. UUID-keyed so renames don't invalidate the target.
enum EditTarget: Equatable {
    case project(UUID)
    case task(projectId: UUID, taskId: UUID)
    case agent(UUID)
    case newAgent(projectId: UUID, taskId: UUID)
}

/// Single source of truth for inline edits. Invariant: at most one edit active.
struct EditState: Equatable {
    var target: EditTarget
    var text: String
    var error: String?
}

// MARK: - Destructive Action

/// All irreversible operations the sidebar can trigger. Routed through a single
/// `.confirmationDialog` so every destructive action follows the same pattern:
/// click → confirm → execute.
enum DestructiveAction: Identifiable {
    case deleteProject(id: UUID, name: String, agentCount: Int)
    case deleteTask(projectId: UUID, taskId: UUID, name: String, agentCount: Int)
    case deleteAgent(id: UUID, name: String)
    case resetSessions(projectId: UUID, newPath: String, agentCount: Int)

    var id: String {
        switch self {
        case .deleteProject(let id, _, _):       return "project-\(id)"
        case .deleteTask(_, let id, _, _):       return "task-\(id)"
        case .deleteAgent(let id, _):            return "agent-\(id)"
        case .resetSessions(let id, _, _):       return "reset-\(id)"
        }
    }

    var title: String {
        switch self {
        case .deleteProject(_, let name, _): return "Delete project \u{201C}\(name)\u{201D}?"
        case .deleteTask(_, _, let name, _): return "Delete task \u{201C}\(name)\u{201D}?"
        case .deleteAgent(_, let name):      return "Delete agent \u{201C}\(name)\u{201D}?"
        case .resetSessions:                 return "Change working directory?"
        }
    }

    var message: String {
        switch self {
        case .deleteProject(_, _, let n) where n > 0:
            return "\(n) agent\(n == 1 ? "" : "s") will be removed. This cannot be undone."
        case .deleteProject:
            return "This cannot be undone."
        case .deleteTask(_, _, _, let n) where n > 0:
            return "\(n) agent\(n == 1 ? "" : "s") will be removed. This cannot be undone."
        case .deleteTask:
            return "This cannot be undone."
        case .deleteAgent:
            return "The agent's terminal will be closed. This cannot be undone."
        case .resetSessions(_, _, let n):
            return "\(n) agent\(n == 1 ? "" : "s") will lose conversation history. This cannot be undone."
        }
    }

    var confirmLabel: String {
        switch self {
        case .deleteProject, .deleteTask, .deleteAgent: return "Delete"
        case .resetSessions:                            return "Reset Sessions"
        }
    }
}

// MARK: - Sidebar

struct AgentSidebarView: View {
    var config: AgentConfig
    var bridge: AgentBridge
    let onSelectAgent: (UUID, AgentProject) -> Void
    var onForkAgent: ((UUID, AgentProject, String) -> Void)?  // sourceId, project, task
    var onDeleteAgent: ((UUID) -> Void)?

    @State private var selectedID: UUID?
    @State private var edit: EditState?
    @State private var pendingDestruction: DestructiveAction?
    /// Project IDs the user has collapsed. Empty default = all expanded.
    /// Keyed by UUID so rename doesn't orphan entries.
    @State private var collapsedProjects: Set<UUID> = []

    // MARK: - Edit Helpers

    private func beginEdit(_ target: EditTarget, initial: String) {
        edit = EditState(target: target, text: initial, error: nil)
    }

    private func cancelEdit() { edit = nil }

    private func isEditing(_ target: EditTarget) -> Bool { edit?.target == target }

    /// First unique name in the sequence "<base>", "<base> 2", "<base> 3", …
    private func uniqueName(base: String, isTaken: (String) -> Bool) -> String {
        if !isTaken(base) { return base }
        var i = 2
        while isTaken("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Create a project with an auto-unique placeholder name, then immediately
    /// enter rename mode with text pre-selected. Esc keeps the placeholder.
    private func createNewProject() {
        let name = uniqueName(base: "New Project") { candidate in
            config.projects.contains { $0.name == candidate }
        }
        if let id = config.addProject(name: name) {
            beginEdit(.project(id), initial: name)
        }
    }

    /// Same pattern for tasks within a project. Expands the project section
    /// first so the inline rename field is visible.
    private func createNewTask(in project: AgentProject) {
        collapsedProjects.remove(project.id)
        let name = uniqueName(base: "New Task") { candidate in
            project.tasks.contains { $0.name == candidate }
        }
        if let id = config.addTask(project: project.name, name: name) {
            beginEdit(.task(projectId: project.id, taskId: id), initial: name)
        }
    }

    /// Maximum length for any rename input. Long names break sidebar layout and
    /// have no legitimate use — 64 chars accommodates descriptive names without
    /// risking truncation.
    private static let maxNameLength = 64

    /// Binding to the in-progress edit's text. Reads "" when no edit active;
    /// writes are no-ops in that case (defensive — UI shouldn't render when inactive).
    /// Caps length at `maxNameLength`; clears error so stale messages don't linger.
    private var editText: Binding<String> {
        Binding(
            get: { edit?.text ?? "" },
            set: { v in
                guard var e = edit else { return }
                e.text = String(v.prefix(Self.maxNameLength))
                e.error = nil
                edit = e
            }
        )
    }

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
        .onChange(of: selectedID) { _, newId in
            guard let id = newId, let project = config.project(forAgent: id) else { return }
            onSelectAgent(id, project)
        }
        .confirmationDialog(
            pendingDestruction?.title ?? "",
            isPresented: Binding(
                get: { pendingDestruction != nil },
                set: { if !$0 { pendingDestruction = nil } }
            ),
            presenting: pendingDestruction
        ) { action in
            Button(action.confirmLabel, role: .destructive) {
                performDestructive(action)
            }
            Button("Cancel", role: .cancel) { pendingDestruction = nil }
        } message: { action in
            Text(action.message)
        }
    }

    // MARK: - Destructive Execution

    private func performDestructive(_ action: DestructiveAction) {
        defer { pendingDestruction = nil }
        switch action {
        case .deleteProject(let id, _, _):
            if let project = config.projects.first(where: { $0.id == id }) {
                for task in project.tasks {
                    for agent in task.agents {
                        onDeleteAgent?(agent.id)
                    }
                }
            }
            config.removeProject(id: id)

        case .deleteTask(let projectId, let taskId, _, _):
            if let project = config.projects.first(where: { $0.id == projectId }),
               let task = project.tasks.first(where: { $0.id == taskId }) {
                for agent in task.agents {
                    onDeleteAgent?(agent.id)
                }
            }
            config.removeTask(projectId: projectId, taskId: taskId)

        case .deleteAgent(let id, _):
            onDeleteAgent?(id)

        case .resetSessions(let projectId, let path, _):
            applyWorkingDirectory(projectId: projectId, path: path)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Projects", systemImage: "folder.badge.plus")
        } description: {
            Text("Create your first project to start managing agents.")
        } actions: {
            Button("New Project", action: createNewProject)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    // MARK: - Agent List

    private var agentList: some View {
        List(selection: $selectedID) {
            ForEach(config.projects) { project in
                // Own the disclosure — we render our own persistent chevron in
                // `projectHeader` and conditionally render content. This sidesteps
                // `Section(isExpanded:)` whose hover-revealed chevron shifted layout
                // and caused the ellipsis button to move under the cursor.
                projectHeader(project)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()

                if !collapsedProjects.contains(project.id) {
                    projectContent(project)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Toggle expansion for a project. Used by the chevron button in the header.
    private func toggleExpansion(_ project: AgentProject) {
        if collapsedProjects.contains(project.id) {
            collapsedProjects.remove(project.id)
        } else {
            collapsedProjects.insert(project.id)
        }
    }

    // MARK: - Project Header

    private func projectHeader(_ project: AgentProject) -> some View {
        let isCollapsed = collapsedProjects.contains(project.id)
        return HStack(spacing: 6) {
            // Persistent disclosure chevron. Owning this ourselves keeps the
            // row layout stable regardless of hover state.
            Button { toggleExpansion(project) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: isCollapsed)
            .help(isCollapsed ? "Expand" : "Collapse")

            if isEditing(.project(project.id)) {
                RenameField(
                    text: editText,
                    placeholder: "Project name",
                    error: edit?.error,
                    font: .system(.caption, design: .monospaced, weight: .bold),
                    onCommit: { confirmRenameProject(id: project.id) },
                    onCancel: { cancelEdit() }
                )
            } else {
                Text(project.name.uppercased())
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .tracking(1.0)
                    .onTapGesture(count: 2) {
                        beginEdit(.project(project.id), initial: project.name)
                    }
            }

            Spacer(minLength: 8)

            // Default Menu style: invokes NSMenu on click, no persistent
            // NSPopUpButton in the hierarchy — avoids the constraint-invalidation
            // cycle that Menu(.borderlessButton) caused.
            Menu {
                Button("Add Task") { createNewTask(in: project) }
                Button("Rename Project") {
                    beginEdit(.project(project.id), initial: project.name)
                }
                Button("Set Directory\u{2026}") { pickDirectory(projectId: project.id) }
                Divider()
                Button("Delete Project", role: .destructive) {
                    let count = project.tasks.flatMap(\.agents).count
                    pendingDestruction = .deleteProject(
                        id: project.id, name: project.name, agentCount: count
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(.body, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Project options")
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Project Content

    @ViewBuilder
    private func projectContent(_ project: AgentProject) -> some View {
        if let dir = project.workingDirectory {
            Text(compactPath(dir))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
                .padding(.bottom, 8)
                .selectionDisabled()
        }

        if project.tasks.isEmpty {
            Text("No tasks — add one from the \u{2026} menu")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
                .padding(.vertical, 8)
                .selectionDisabled()
        }

        ForEach(project.tasks) { task in
            taskLabel(task, project: project)
                .selectionDisabled()

            ForEach(task.agents) { entry in
                if let agent = bridge.agents[entry.id] {
                    let editingThis = isEditing(.agent(entry.id))
                    AgentRow(
                        agent: agent,
                        isEditing: editingThis,
                        editText: editingThis ? editText : .constant(""),
                        editError: editingThis ? edit?.error : nil,
                        onCommitRename: { confirmRenameAgent(id: entry.id) },
                        onCancelEdit: { cancelEdit() }
                    )
                    .tag(entry.id)
                    .contextMenu {
                        Button("Rename Agent") {
                            beginEdit(.agent(entry.id), initial: agent.name)
                        }
                        Button("Fork Agent") {
                            onForkAgent?(entry.id, project, task.name)
                        }
                        Divider()
                        Button("Delete Agent", role: .destructive) {
                            pendingDestruction = .deleteAgent(id: entry.id, name: agent.name)
                        }
                    }
                }
            }

            if isEditing(.newAgent(projectId: project.id, taskId: task.id)) {
                newAgentField(project: project.name, task: task.name)
                    .selectionDisabled()
            }
        }
    }

    // MARK: - Task Label

    private func taskLabel(_ task: AgentTask, project: AgentProject) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 2, height: 12)

            if isEditing(.task(projectId: project.id, taskId: task.id)) {
                RenameField(
                    text: editText,
                    placeholder: "Task name",
                    error: edit?.error,
                    font: .system(.caption, design: .monospaced, weight: .medium),
                    onCommit: { confirmRenameTask(projectId: project.id, taskId: task.id) },
                    onCancel: { cancelEdit() }
                )
            } else {
                Text(task.name)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) {
                        beginEdit(.task(projectId: project.id, taskId: task.id), initial: task.name)
                    }
            }

            Spacer(minLength: 4)

            Button {
                beginEdit(.newAgent(projectId: project.id, taskId: task.id), initial: "")
            } label: {
                Image(systemName: "plus")
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add agent")
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contextMenu {
            Button("Rename Task") {
                beginEdit(.task(projectId: project.id, taskId: task.id), initial: task.name)
            }
            Button("Add Agent") {
                beginEdit(.newAgent(projectId: project.id, taskId: task.id), initial: "")
            }
            Divider()
            Button("Delete Task", role: .destructive) {
                pendingDestruction = .deleteTask(
                    projectId: project.id,
                    taskId: task.id,
                    name: task.name,
                    agentCount: task.agents.count
                )
            }
        }
    }

    // MARK: - New Agent Field

    private func newAgentField(project: String, task: String) -> some View {
        HStack(spacing: 10) {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                .frame(width: 8, height: 8)

            RenameField(
                text: editText,
                placeholder: "Agent name",
                error: edit?.error,
                font: .system(.body, design: .monospaced, weight: .medium),
                onCommit: { confirmNewAgent(project: project, task: task) },
                onCancel: { cancelEdit() }
            )
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button(action: createNewProject) {
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
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    // MARK: - Rename Helpers

    private func confirmRenameProject(id: UUID) {
        let text = (edit?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let current = config.projects.first(where: { $0.id == id })?.name
        // Empty or unchanged → silent cancel (no error noise from blur).
        if text.isEmpty || text == current { cancelEdit(); return }

        if config.renameProject(id: id, newName: text) {
            cancelEdit()
        } else {
            edit?.error = "Name already used"
        }
    }

    private func confirmRenameTask(projectId: UUID, taskId: UUID) {
        let text = (edit?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let current = config.projects
            .first(where: { $0.id == projectId })?
            .tasks.first(where: { $0.id == taskId })?.name
        if text.isEmpty || text == current { cancelEdit(); return }

        if config.renameTask(projectId: projectId, taskId: taskId, newName: text) {
            cancelEdit()
        } else {
            edit?.error = "Name already used in this project"
        }
    }

    private func confirmRenameAgent(id: UUID) {
        let new = (edit?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty → cancel silently. Agents are UUID-keyed so duplicate display
        // names are tolerated; no error path needed.
        guard !new.isEmpty else { cancelEdit(); return }

        config.renameAgent(id: id, newName: new)
        bridge.requestRename(id: id, newName: new)
        cancelEdit()
    }

    private func confirmNewAgent(project: String, task: String) {
        let name = (edit?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty draft → silent cancel (blur with no input = abandon).
        guard !name.isEmpty else { cancelEdit(); return }

        if bridge.createAgent(name: name, config: config,
                              project: project, task: task) != nil {
            cancelEdit()
        } else {
            edit?.error = "Name already used in this task"
        }
    }

    // MARK: - Directory

    private func pickDirectory(projectId: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Working directory for all agents in this project"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let project = config.projects.first(where: { $0.id == projectId })
        let hasExistingDir = project?.workingDirectory != nil
        let agentCount = project?.tasks.flatMap(\.agents).count ?? 0

        if hasExistingDir && agentCount > 0 {
            // Destructive: route through the unified confirm dialog.
            pendingDestruction = .resetSessions(
                projectId: projectId, newPath: url.path, agentCount: agentCount
            )
        } else {
            applyWorkingDirectory(projectId: projectId, path: url.path)
        }
    }

    private func applyWorkingDirectory(projectId: UUID, path: String) {
        guard let i = config.projects.firstIndex(where: { $0.id == projectId }) else { return }
        config.projects[i].workingDirectory = path
        config.save()
    }

    // MARK: - Utilities

    private func compactPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

}

// MARK: - Agent Row (per-row observation)
//
// Selection styling, row background, and hover are provided by `List` with
// `.listStyle(.sidebar)`. AgentRow renders only the row content.

struct AgentRow: View {
    var agent: AgentInstance
    let isEditing: Bool
    @Binding var editText: String
    var editError: String?
    let onCommitRename: () -> Void
    let onCancelEdit: () -> Void

    var body: some View {
        let state = agent.displayState
        HStack(spacing: 10) {
            statusDot(state)
                .frame(width: 10, height: 10)

            if isEditing {
                RenameField(
                    text: $editText,
                    placeholder: "Agent name",
                    error: editError,
                    font: .system(.body, design: .monospaced, weight: .medium),
                    onCommit: onCommitRename,
                    onCancel: onCancelEdit
                )
            } else {
                Text(agent.name)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if !state.label.isEmpty {
                    Text(state.label)
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                stateIcon(state)
                    .frame(width: 14, alignment: .center)
            }
        }
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
}
