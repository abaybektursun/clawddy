import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Observation

@Observable
@MainActor
final class AgentWorkspaceModel {
    enum Scope: Hashable {
        case all
        case attention
        case running
        case project(UUID)
        case task(projectID: UUID, taskID: UUID)
    }

    private enum DefaultsKey {
        static let scope = "clawddy.workspace.scope"
        static let selectedAgentID = "clawddy.workspace.selectedAgentID"
    }

    var scope: Scope = .all {
        didSet { UserDefaults.standard.set(encodedScope, forKey: DefaultsKey.scope) }
    }
    var selectedAgentID: UUID? {
        didSet {
            UserDefaults.standard.set(
                selectedAgentID?.uuidString,
                forKey: DefaultsKey.selectedAgentID)
        }
    }
    var searchQuery = ""

    init() {
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.scope),
           let restored = Self.decodeScope(raw) {
            scope = restored
        }
        if let rawID = UserDefaults.standard.string(forKey: DefaultsKey.selectedAgentID) {
            selectedAgentID = UUID(uuidString: rawID)
        }
    }

    func reconcile(with config: AgentConfig) {
        let projectIDs = Set(config.projects.map(\.id))
        switch scope {
        case .project(let id) where !projectIDs.contains(id):
            scope = .all
        case .task(let projectID, let taskID):
            let taskExists = config.projects
                .first(where: { $0.id == projectID })?
                .tasks.contains(where: { $0.id == taskID }) == true
            if !taskExists { scope = .all }
        default:
            break
        }
        if let selectedAgentID,
           !config.allAgentEntries.contains(where: { $0.id == selectedAgentID }) {
            self.selectedAgentID = nil
        }
    }

    private var encodedScope: String {
        switch scope {
        case .all: return "all"
        case .attention: return "attention"
        case .running: return "running"
        case .project(let id): return "project:\(id.uuidString)"
        case .task(let projectID, let taskID):
            return "task:\(projectID.uuidString):\(taskID.uuidString)"
        }
    }

    private static func decodeScope(_ raw: String) -> Scope? {
        let parts = raw.split(separator: ":").map(String.init)
        switch parts.first {
        case "all": return .all
        case "attention": return .attention
        case "running": return .running
        case "project" where parts.count == 2:
            return UUID(uuidString: parts[1]).map(Scope.project)
        case "task" where parts.count == 3:
            guard let projectID = UUID(uuidString: parts[1]),
                  let taskID = UUID(uuidString: parts[2])
            else { return nil }
            return .task(projectID: projectID, taskID: taskID)
        default:
            return nil
        }
    }
}

private enum WorkspaceRenameTarget: Identifiable {
    case newTask(UUID)
    case project(UUID, String)
    case task(UUID, UUID, String)
    case agent(UUID, String)

    var id: String {
        switch self {
        case .newTask(let projectID): return "new-task-\(projectID)"
        case .project(let id, _): return "project-\(id)"
        case .task(_, let id, _): return "task-\(id)"
        case .agent(let id, _): return "agent-\(id)"
        }
    }

    var currentName: String {
        switch self {
        case .newTask: return "New Task"
        case .project(_, let name), .task(_, _, let name), .agent(_, let name): return name
        }
    }

    var title: String {
        switch self {
        case .newTask: return "New Task"
        case .project, .task, .agent: return "Rename"
        }
    }
}

enum AgentSelectionIntent: Equatable {
    /// Keeps detail presentation synchronized with a programmatic selection.
    case reveal
    /// Records that the user deliberately exposed this agent's detail content.
    case inspect
}

/// Irreversible or session-affecting workspace operations. Keeping these in one
/// model gives every entry point the same confirmation copy and behavior.
enum DestructiveAction: Identifiable {
    case deleteProject(id: UUID, name: String, agentCount: Int)
    case deleteTask(projectId: UUID, taskId: UUID, name: String, agentCount: Int)
    case deleteAgent(id: UUID, name: String)
    case resetSessions(projectId: UUID, newPath: String, agentCount: Int)

    var id: String {
        switch self {
        case .deleteProject(let id, _, _): return "project-\(id)"
        case .deleteTask(_, let id, _, _): return "task-\(id)"
        case .deleteAgent(let id, _): return "agent-\(id)"
        case .resetSessions(let id, _, _): return "reset-\(id)"
        }
    }

    var title: String {
        switch self {
        case .deleteProject(_, let name, _): return "Delete project \u{201C}\(name)\u{201D}?"
        case .deleteTask(_, _, let name, _): return "Delete task \u{201C}\(name)\u{201D}?"
        case .deleteAgent(_, let name): return "Delete agent \u{201C}\(name)\u{201D}?"
        case .resetSessions: return "Change working directory?"
        }
    }

    var message: String {
        switch self {
        case .deleteProject(_, _, let count) where count > 0:
            return "\(count) agent\(count == 1 ? "" : "s") will be removed. This cannot be undone."
        case .deleteProject:
            return "This cannot be undone."
        case .deleteTask(_, _, _, let count) where count > 0:
            return "\(count) agent\(count == 1 ? "" : "s") will be removed. This cannot be undone."
        case .deleteTask:
            return "This cannot be undone."
        case .deleteAgent:
            return "The agent's terminal will be closed. This cannot be undone."
        case .resetSessions(_, _, let count):
            return "\(count) existing agent\(count == 1 ? "" : "s") will use the new directory after being restarted. Conversation history is preserved."
        }
    }

    var confirmLabel: String {
        switch self {
        case .deleteProject, .deleteTask, .deleteAgent: return "Delete"
        case .resetSessions: return "Change Directory"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .deleteProject, .deleteTask, .deleteAgent: return .destructive
        case .resetSessions: return nil
        }
    }
}

struct AgentNavigationView: View {
    var config: AgentConfig
    var bridge: AgentBridge
    var model: AgentWorkspaceModel

    @State private var choosingProjectDirectory = false
    @State private var directoryProjectID: UUID?
    @State private var renameTarget: WorkspaceRenameTarget?
    @State private var deletion: DestructiveAction?

    var body: some View {
        @Bindable var bindableModel = model
        List(selection: $bindableModel.scope) {
            Section("Workspace") {
                navigationRow(
                    "All Agents",
                    icon: "person.2",
                    count: config.allAgentEntries.count
                )
                .tag(AgentWorkspaceModel.Scope.all)

                navigationRow(
                    "Needs Attention",
                    icon: "bell.badge",
                    count: bridge.agents.values.filter { $0.displayState.needsAttention }.count,
                    tint: .orange
                )
                .tag(AgentWorkspaceModel.Scope.attention)

                navigationRow(
                    "Running",
                    icon: "bolt",
                    count: bridge.agents.values.filter { $0.displayState.isActive }.count,
                    tint: .green
                )
                .tag(AgentWorkspaceModel.Scope.running)
            }

            Section("Projects") {
                ForEach(config.projects) { project in
                    hierarchyLabel(
                        project.name,
                        icon: "folder",
                        state: aggregateState(for: project))
                        .tag(AgentWorkspaceModel.Scope.project(project.id))
                        .contextMenu {
                            Button("New Task", systemImage: "plus") { addTask(to: project) }
                            Button("Rename", systemImage: "pencil") {
                                renameTarget = .project(project.id, project.name)
                            }
                            Button("Choose Directory…", systemImage: "folder") {
                                directoryProjectID = project.id
                                choosingProjectDirectory = true
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                deletion = .deleteProject(
                                    id: project.id,
                                    name: project.name,
                                    agentCount: project.tasks.flatMap(\.agents).count)
                            }
                        }
                        .accessibilityHint("Shows every agent in this project")

                    ForEach(project.tasks) { task in
                        hierarchyLabel(
                            task.name,
                            icon: "list.bullet.rectangle",
                            state: aggregateState(for: task))
                            .padding(.leading, 18)
                            .tag(AgentWorkspaceModel.Scope.task(
                                projectID: project.id,
                                taskID: task.id))
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") {
                                    renameTarget = .task(project.id, task.id, task.name)
                                }
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    deletion = .deleteTask(
                                        projectId: project.id,
                                        taskId: task.id,
                                        name: task.name,
                                        agentCount: task.agents.count)
                                }
                            }
                            .accessibilityHint("Shows agents in \(task.name)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Add Project", systemImage: "folder.badge.plus") {
                    directoryProjectID = nil
                    choosingProjectDirectory = true
                }
                .labelStyle(.iconOnly)
                .help("Add Project")

                Button("Add Task", systemImage: "plus.rectangle.on.folder") {
                    guard let project = selectedProject else { return }
                    addTask(to: project)
                }
                .labelStyle(.iconOnly)
                .disabled(selectedProject == nil)
                .help("Add Task")

                Spacer()

                if let error = config.errorMessage {
                    Button("Reveal Configuration Issue", systemImage: "exclamationmark.triangle.fill") {
                        let target = FileManager.default.fileExists(atPath: AgentConfig.configURL.path)
                            ? AgentConfig.configURL
                            : AgentConfig.baseDir
                        NSWorkspace.shared.activateFileViewerSelecting([target])
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .help(error)
                        .accessibilityLabel("Configuration error")
                        .accessibilityValue(error)
                        .accessibilityHint("Reveals the configuration in Finder")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .fileImporter(
            isPresented: $choosingProjectDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            if let directoryProjectID {
                setDirectory(url.path, for: directoryProjectID)
            } else {
                addProject(at: url)
            }
        }
        .sheet(item: $renameTarget) { target in
            WorkspaceNameSheet(
                title: target.title,
                initialName: target.currentName,
                failureMessage: { config.persistenceErrorMessage },
                commit: { name in rename(target, to: name) })
        }
        .confirmationDialog(
            deletion?.title ?? "",
            isPresented: Binding(
                get: { deletion != nil },
                set: { if !$0 { deletion = nil } }
            ),
            presenting: deletion
        ) { action in
            Button(action.confirmLabel, role: action.role) { delete(action) }
            Button("Cancel", role: .cancel) { deletion = nil }
        } message: { Text($0.message) }
    }

    private var selectedProject: AgentProject? {
        switch model.scope {
        case .project(let projectID), .task(let projectID, _):
            return config.projects.first(where: { $0.id == projectID })
        default:
            return nil
        }
    }

    private func navigationRow(
        _ title: String,
        icon: String,
        count: Int,
        tint: Color = .accentColor
    ) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if count > 0 {
                Text(count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
            }
        }
    }

    private func hierarchyLabel(
        _ title: String,
        icon: String,
        state: DisplayState?
    ) -> some View {
        HStack(spacing: 6) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(state?.color ?? Color.secondary)
            }
            Spacer(minLength: 4)
            if let state, state != .inactive, state != .idle {
                HStack(spacing: 3) {
                    if let iconName = state.iconName {
                        Image(systemName: iconName)
                            .foregroundStyle(state.color)
                    }
                    Text(state.label)
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .lineLimit(1)
                .accessibilityHidden(true)
            }
        }
        .help(state.map { "\(title): \($0.label)" } ?? "\(title): No agents")
        .accessibilityValue(state.map { "Aggregated status: \($0.label)" } ?? "No agents")
    }

    private func aggregateState(for project: AgentProject) -> DisplayState? {
        AgentStateAggregation.representative(of: project.tasks.lazy.flatMap { task in
            task.agents.compactMap { bridge.agents[$0.id]?.displayState }
        })
    }

    private func aggregateState(for task: AgentTask) -> DisplayState? {
        AgentStateAggregation.representative(of: task.agents.lazy.compactMap {
            bridge.agents[$0.id]?.displayState
        })
    }

    private func addProject(at url: URL) {
        let base = url.lastPathComponent.isEmpty ? "Project" : url.lastPathComponent
        var name = base
        var suffix = 2
        while config.projects.contains(where: { $0.name == name }) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        guard let id = config.addProject(name: name, workingDirectory: url.path) else { return }
        model.scope = .project(id)
    }

    private func addTask(to project: AgentProject) {
        renameTarget = .newTask(project.id)
    }

    private func setDirectory(_ path: String, for projectID: UUID) {
        guard let project = config.projects.first(where: { $0.id == projectID }) else { return }
        let count = project.tasks.flatMap(\.agents).count
        guard count > 0 else {
            applyDirectory(path, to: projectID)
            return
        }
        deletion = .resetSessions(projectId: projectID, newPath: path, agentCount: count)
    }

    private func rename(_ target: WorkspaceRenameTarget, to name: String) -> Bool {
        switch target {
        case .newTask(let projectID):
            guard let project = config.projects.first(where: { $0.id == projectID }),
                  let taskID = config.addTask(project: project.name, name: name)
            else { return false }
            model.scope = .task(projectID: projectID, taskID: taskID)
            return true
        case .project(let id, _):
            return config.renameProject(id: id, newName: name)
        case .task(let projectID, let taskID, _):
            return config.renameTask(projectId: projectID, taskId: taskID, newName: name)
        case .agent:
            return false
        }
    }

    private func delete(_ action: DestructiveAction) {
        defer { deletion = nil }
        switch action {
        case .deleteProject(let id, _, _):
            guard let project = config.projects.first(where: { $0.id == id }) else { return }
            let agentIDs = project.tasks.flatMap(\.agents).map(\.id)
            guard config.removeProject(id: id) else { return }
            bridge.removeAgentRuntimes(ids: agentIDs)
            model.scope = .all
        case .deleteTask(let projectID, let taskID, _, _):
            guard let project = config.projects.first(where: { $0.id == projectID }),
                  let task = project.tasks.first(where: { $0.id == taskID })
            else { return }
            let agentIDs = task.agents.map(\.id)
            guard config.removeTask(projectId: projectID, taskId: taskID) else { return }
            bridge.removeAgentRuntimes(ids: agentIDs)
            model.scope = .project(projectID)
        case .resetSessions(let projectID, let newPath, _):
            applyDirectory(newPath, to: projectID)
        case .deleteAgent:
            break
        }
    }

    private func applyDirectory(_ path: String, to projectID: UUID) {
        config.setWorkingDirectory(path, forProject: projectID)
    }
}

struct AgentListView: View {
    var config: AgentConfig
    var bridge: AgentBridge
    var model: AgentWorkspaceModel
    let onSelectAgent: (UUID, AgentProject, AgentSelectionIntent) -> Void
    let onClearSelection: () -> Void
    let onActivateAgent: (UUID, AgentProject) -> Void
    let onForkAgent: (UUID, AgentProject, String) -> Void
    let onDeleteAgent: (UUID) -> Void

    @State private var renameTarget: WorkspaceRenameTarget?
    @State private var showingNewAgent = false
    @State private var pendingDelete: AgentEntry?

    /// List writes represent deliberate mouse or keyboard selection. Other
    /// code writes directly to the model and is handled as a passive reveal
    /// by `onChange`, preventing automatic filtering from acknowledging a
    /// series of completed agents the user did not choose.
    private var userSelection: Binding<UUID?> {
        Binding(
            get: { model.selectedAgentID },
            set: { id in
                model.selectedAgentID = id
                guard let id, let project = config.project(forAgent: id) else { return }
                onSelectAgent(id, project, .inspect)
            })
    }

    private var visibleAgents: [AgentListItem] {
        let ranks = AgentOrdering.ranks(in: config.allAgentEntries.map(\.id))
        return config.projects.flatMap { project in
            project.tasks.flatMap { task in
                task.agents.compactMap { entry in
                    guard let instance = bridge.agents[entry.id], includes(instance, project, task),
                          matchesSearch(entry, project, task, instance)
                    else { return nil }
                    return AgentListItem(
                        entry: entry,
                        project: project,
                        task: task,
                        instance: instance)
                }
            }
        }.sorted { AgentOrdering.precedes($0.id, $1.id, ranks: ranks) }
    }

    var body: some View {
        @Bindable var bindableModel = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Agents", text: $bindableModel.searchQuery)
                    .textFieldStyle(.plain)
                if !model.searchQuery.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") {
                        model.searchQuery = ""
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .overlay(alignment: .bottom) { Divider() }

            if visibleAgents.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text(emptyDescription)
                } actions: {
                    if selectedTask != nil {
                        Button("New Agent", systemImage: "plus") { showingNewAgent = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: userSelection) {
                    ForEach(visibleAgents) { item in
                        let entry = item.entry
                        let project = item.project
                        let task = item.task
                        let instance = item.instance
                        AgentListRow(agent: instance, project: project.name, task: task.name)
                            .tag(entry.id)
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                onActivateAgent(entry.id, project)
                            })
                            .contextMenu {
                                Button("Start or Focus", systemImage: "terminal") {
                                    onActivateAgent(entry.id, project)
                                }
                                Button("Rename", systemImage: "pencil") {
                                    renameTarget = .agent(entry.id, entry.name)
                                }
                                Button("Fork", systemImage: "arrow.triangle.branch") {
                                    onForkAgent(entry.id, project, task.name)
                                }
                                .disabled(!bridge.providerCapabilities(for: entry.provider).fork.isSupported)
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDelete = entry
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .onKeyPress(.return) {
                    guard let id = model.selectedAgentID,
                          let project = config.project(forAgent: id)
                    else { return .ignored }
                    onActivateAgent(id, project)
                    return .handled
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("New Agent", systemImage: "plus") { showingNewAgent = true }
                    .disabled(selectedTask == nil)
                Spacer()
                if let item = selectedVisibleAgent {
                    Menu("Agent Actions", systemImage: "ellipsis.circle") {
                        Button("Start or Focus", systemImage: "terminal") {
                            onActivateAgent(item.id, item.project)
                        }
                        Button("Rename", systemImage: "pencil") {
                            renameTarget = .agent(item.id, item.entry.name)
                        }
                        Button("Fork", systemImage: "arrow.triangle.branch") {
                            onForkAgent(item.id, item.project, item.task.name)
                        }
                        .disabled(!bridge.providerCapabilities(
                            for: item.entry.provider).fork.isSupported)
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            pendingDelete = item.entry
                        }
                    }
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .help("Agent Actions")
                }
                Text("\(visibleAgents.count) agent\(visibleAgents.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .onChange(of: model.selectedAgentID) { _, id in
            guard let id, let project = config.project(forAgent: id) else { return }
            onSelectAgent(id, project, .reveal)
        }
        .onChange(of: visibleAgents.map(\.id), initial: true) { _, visibleIDs in
            if let selectedID = model.selectedAgentID, visibleIDs.contains(selectedID) {
                return
            }
            model.selectedAgentID = visibleIDs.first
            if visibleIDs.isEmpty {
                onClearSelection()
            }
        }
        .sheet(item: $renameTarget) { target in
            WorkspaceNameSheet(
                title: "Rename Agent",
                initialName: target.currentName,
                failureMessage: { config.persistenceErrorMessage },
                commit: { name in
                    guard case .agent(let id, _) = target,
                          config.renameAgent(id: id, newName: name)
                    else { return false }
                    bridge.requestRename(id: id, newName: name)
                    return true
                })
        }
        .sheet(isPresented: $showingNewAgent) {
            NewAgentSheet(
                bridge: bridge,
                failureMessage: { config.persistenceErrorMessage },
                commit: { name, provider, launchProfile in
                    guard let (project, task) = selectedTask,
                          let entry = bridge.createAgent(
                            name: name,
                            provider: provider,
                            launchProfile: launchProfile,
                            config: config,
                            project: project.name,
                            task: task.name)
                    else { return false }
                    model.selectedAgentID = entry.id
                    return true
                })
        }
        .confirmationDialog(
            pendingDelete.map { "Delete agent “\($0.name)”?" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { entry in
            Button("Delete", role: .destructive) {
                onDeleteAgent(entry.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("The running process and terminal will close. This cannot be undone.")
        }
    }

    private var selectedTask: (AgentProject, AgentTask)? {
        guard case .task(let projectID, let taskID) = model.scope,
              let project = config.projects.first(where: { $0.id == projectID }),
              let task = project.tasks.first(where: { $0.id == taskID })
        else { return nil }
        return (project, task)
    }

    private var selectedVisibleAgent: AgentListItem? {
        guard let id = model.selectedAgentID else { return nil }
        return visibleAgents.first(where: { $0.id == id })
    }

    private var emptyTitle: String {
        model.searchQuery.isEmpty ? "No Agents" : "No Results"
    }

    private var emptyDescription: String {
        model.searchQuery.isEmpty
            ? "Choose a task and create an agent to begin."
            : "No agents match “\(model.searchQuery)”."
    }

    private func includes(_ agent: AgentInstance, _ project: AgentProject, _ task: AgentTask) -> Bool {
        switch model.scope {
        case .all: return true
        case .attention: return agent.displayState.needsAttention
        case .running: return agent.displayState.isActive
        case .project(let id): return project.id == id
        case .task(let projectID, let taskID): return project.id == projectID && task.id == taskID
        }
    }

    private func matchesSearch(
        _ entry: AgentEntry,
        _ project: AgentProject,
        _ task: AgentTask,
        _ instance: AgentInstance
    ) -> Bool {
        let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return ([
            entry.name, project.name, task.name, instance.displayState.label,
            entry.provider.displayName,
        ]
            + entry.launchProfile.searchTerms
            + (instance.metadata?.searchTerms ?? []))
            .contains(where: { $0.localizedCaseInsensitiveContains(query) })
    }

}

private struct AgentListItem: Identifiable {
    let entry: AgentEntry
    let project: AgentProject
    let task: AgentTask
    let instance: AgentInstance

    var id: UUID { entry.id }
}

private struct AgentListRow: View {
    var agent: AgentInstance
    let project: String
    let task: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: agent.displayState.iconName ?? "circle")
                .foregroundStyle(agent.displayState.color)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(agent.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(agent.displayState.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(agent.provider.displayName) · \(project) · \(task)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                AgentMetadataCompactLine(agent: agent)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agent.name)
        .accessibilityValue("\(agent.provider.displayName). \(agent.displayState.label). \(project), \(task). \(agent.metadataAccessibilityValue)")
        .accessibilityHint("Selects this agent. Press Return to start or focus.")
    }
}

private struct NewAgentSheet: View {
    private struct EffortOption: Identifiable {
        let id: String
        let title: String
        let value: String?
    }

    var bridge: AgentBridge
    let failureMessage: () -> String?
    let commit: (String, AgentProviderID, AgentLaunchProfile) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var provider = Self.restoredProvider
    @State private var model = ""
    @State private var effort: String?
    @State private var startMode = AgentPreferencesStore.load()
        .defaultStartMode(for: Self.restoredProvider)
    @State private var error: String?
    @State private var showsRunSettings = false
    @FocusState private var focused: Bool

    private static var restoredProvider: AgentProviderID {
        guard let raw = UserDefaults.standard.string(forKey: "clawddy.newAgent.provider"),
              let provider = AgentProviderID(rawValue: raw)
        else { return .claudeCode }
        return provider
    }

    private var health: AgentProviderHealth {
        bridge.providerHealth[provider] ?? AgentProviderHealth()
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && health.isReadyToLaunch
    }

    private var effortOptions: [EffortOption] {
        var options = [EffortOption(
            id: "default",
            title: "Provider Default",
            value: nil)]
        if provider == .codex {
            options.append(EffortOption(id: "minimal", title: "Minimal", value: "minimal"))
        }
        options += [
            EffortOption(id: "low", title: "Low", value: "low"),
            EffortOption(id: "medium", title: "Medium", value: "medium"),
            EffortOption(id: "high", title: "High", value: "high"),
            EffortOption(id: "xhigh", title: "Extra High", value: "xhigh"),
        ]
        if provider == .claudeCode {
            options.append(EffortOption(id: "max", title: "Maximum", value: "max"))
        }
        return options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Agent")
                    .font(.title3.weight(.semibold))
                Text("Choose the coding agent for this conversation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("Agent Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(create)

            VStack(alignment: .leading, spacing: 10) {
                Text("Provider")
                    .font(.headline)
                Picker("Provider", selection: $provider) {
                    ForEach(AgentProviderID.allCases) { option in
                        Label(option.displayName, systemImage: option.symbolName)
                            .tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                providerStatus
            }

            DisclosureGroup("Run Settings", isExpanded: $showsRunSettings) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Start mode")
                        Picker("Start mode", selection: $startMode) {
                            ForEach(AgentStartMode.allCases) { option in
                                Text(provider.startModeTitle(option)).tag(option)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Model")
                        TextField("Provider default", text: $model)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Model")
                    }
                    GridRow {
                        Text("Reasoning")
                        Picker("Reasoning", selection: $effort) {
                            ForEach(effortOptions) { option in
                                Text(option.title).tag(option.value)
                            }
                        }
                        .labelsHidden()
                    }
                }
                .padding(.top, 10)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(error)")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Agent", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear {
            focused = true
            bridge.refreshProviderHealth()
        }
        .onChange(of: provider) { _, _ in
            model = ""
            effort = nil
            startMode = AgentPreferencesStore.load().defaultStartMode(for: provider)
            error = nil
        }
    }

    @ViewBuilder
    private var providerStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: providerStatusIcon)
                .foregroundStyle(providerStatusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(health.conciseStatus)
                    .font(.callout.weight(.medium))
                if let detail = providerStatusDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.displayName): \(health.conciseStatus)")
        .accessibilityValue(providerStatusDetail ?? "No additional details")
    }

    private var providerStatusIcon: String {
        switch health.installation {
        case .checking: return "ellipsis.circle"
        case .ready:
            switch health.authentication {
            case .checking: return "ellipsis.circle"
            case .signedIn:
                return health.integrationIssue == nil
                    ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            case .signedOut: return "person.crop.circle.badge.exclamationmark"
            case .unavailable: return "questionmark.circle.fill"
            }
        case .missing, .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private var providerStatusColor: Color {
        switch health.installation {
        case .checking: return .secondary
        case .ready:
            switch health.authentication {
            case .signedIn: return health.integrationIssue == nil ? .green : .orange
            case .checking, .unavailable: return .secondary
            case .signedOut: return .orange
            }
        case .missing, .unavailable: return .red
        }
    }

    private var providerStatusDetail: String? {
        if let issue = health.integrationIssue {
            return "Activity status may be limited: \(issue)"
        }
        switch health.installation {
        case .checking:
            return "Checking the login-shell PATH and sign-in status."
        case .missing:
            return "Install the \(provider.displayName) CLI before creating this agent."
        case .unavailable(let reason):
            return reason
        case .ready(_, let version):
            if health.authentication == .signedOut {
                return "You can complete sign-in when the terminal opens."
            }
            if provider == .codex {
                let prefix = version.map { "\($0). " } ?? ""
                return "\(prefix)On first use, Codex may ask you to review Clawddy’s activity hook with /hooks."
            }
            return version
        }
    }

    private func create() {
        guard canCreate else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = AgentLaunchProfile(
            modelID: selectedModel.isEmpty ? nil : selectedModel,
            reasoningEffort: effort,
            startMode: startMode)
        if commit(trimmed, provider, profile) {
            UserDefaults.standard.set(provider.rawValue, forKey: "clawddy.newAgent.provider")
            dismiss()
        } else {
            error = failureMessage() ?? "That name is already in use."
            focused = true
        }
    }
}

private struct WorkspaceNameSheet: View {
    let title: String
    let initialName: String
    let failureMessage: () -> String?
    let commit: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(
        title: String,
        initialName: String,
        failureMessage: @escaping () -> String? = { nil },
        commit: @escaping (String) -> Bool
    ) {
        self.title = title
        self.initialName = initialName
        self.failureMessage = failureMessage
        self.commit = commit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(error)")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if commit(trimmed) {
            dismiss()
        } else {
            error = failureMessage() ?? "That name is already in use."
            focused = true
        }
    }
}
