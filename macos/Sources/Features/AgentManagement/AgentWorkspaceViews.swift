import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Observation

enum AgentWorkspaceMotion {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.2)
    }
}

/// One source for the Move Up/Down pair used by project, task, and agent rows.
/// `onMove` receives -1 (up) or +1 (down).
@ViewBuilder
private func moveUpDownMenuButtons(
    canMoveUp: Bool,
    canMoveDown: Bool,
    onMove: @escaping (Int) -> Void
) -> some View {
    Button("Move Up", systemImage: "arrow.up") { onMove(-1) }
        .disabled(!canMoveUp)
    Button("Move Down", systemImage: "arrow.down") { onMove(1) }
        .disabled(!canMoveDown)
}

/// The accessibility-action twin of `moveUpDownMenuButtons`: actions are
/// omitted (not disabled) when unavailable, per accessibility convention.
@ViewBuilder
private func moveUpDownAccessibilityActions(
    canMoveUp: Bool,
    canMoveDown: Bool,
    onMove: @escaping (Int) -> Void
) -> some View {
    if canMoveUp { Button("Move Up") { onMove(-1) } }
    if canMoveDown { Button("Move Down") { onMove(1) } }
}

@Observable
@MainActor
final class AgentWorkspaceModel {
    enum Scope: Hashable, Sendable {
        case all
        case attention
        case running
        case project(UUID)
        case task(projectID: UUID, taskID: UUID)
    }

    enum DefaultsKey {
        static let scope = "clawddy.workspace.scope"
        static let selectedAgentID = "clawddy.workspace.selectedAgentID"
        static let preferredAgents = "clawddy.workspace.preferredAgents"
        static let collapsedProjects = "clawddy.workspace.collapsedProjects"
    }

    private(set) var selection: AgentWorkspaceSelectionState
    var scope: Scope { selection.scope }
    var selectedAgentID: UUID? { selection.agentID }
    var searchQuery = ""
    private var preferredAgents: [String: UUID] = [:]
    private var collapsedProjectIDs: Set<UUID> = []
    private var hasPersistedProjectDisclosure = false
    let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let restoredScope: Scope
        if let raw = defaults?.string(forKey: DefaultsKey.scope),
           let restored = Self.decodeScope(raw) {
            restoredScope = restored
        } else {
            restoredScope = .all
        }
        let restoredAgentID: UUID?
        if let rawID = defaults?.string(forKey: DefaultsKey.selectedAgentID) {
            restoredAgentID = UUID(uuidString: rawID)
        } else {
            restoredAgentID = nil
        }
        selection = AgentWorkspaceSelectionState(
            scope: restoredScope,
            agentID: restoredAgentID)
        if let stored = defaults?.dictionary(
            forKey: DefaultsKey.preferredAgents) as? [String: String] {
            preferredAgents = stored.reduce(into: [:]) { result, pair in
                if let id = UUID(uuidString: pair.value) { result[pair.key] = id }
            }
        }
        if let stored = defaults?.stringArray(
            forKey: DefaultsKey.collapsedProjects) {
            collapsedProjectIDs = Set(stored.compactMap(UUID.init(uuidString:)))
            hasPersistedProjectDisclosure = true
        }
    }

    @discardableResult
    func apply(
        _ action: AgentWorkspaceSelectionAction
    ) -> AgentWorkspaceSelectionEffect {
        let transition = AgentWorkspaceSelectionReducer.reduce(selection, action: action)
        if transition.state != selection {
            selection = transition.state
            if case .task(let projectID, _) = selection.scope,
               collapsedProjectIDs.remove(projectID) != nil {
                persistCollapsedProjects()
            }
            defaults?.set(encodedScope, forKey: DefaultsKey.scope)
            defaults?.set(
                selectedAgentID?.uuidString,
                forKey: DefaultsKey.selectedAgentID)
        }
        return transition.effect
    }

    func recordExplicitSelection(
        agentID: UUID,
        projectID: UUID,
        taskID: UUID
    ) {
        preferredAgents[Self.preferenceKey(projectID: projectID)] = agentID
        preferredAgents[Self.preferenceKey(taskID: taskID)] = agentID
        persistPreferredAgents()
    }

    func preferredAgentID(for scope: Scope) -> UUID? {
        switch scope {
        case .project(let projectID):
            return preferredAgents[Self.preferenceKey(projectID: projectID)]
        case .task(_, let taskID):
            return preferredAgents[Self.preferenceKey(taskID: taskID)]
        default:
            return nil
        }
    }

    func isProjectExpanded(_ projectID: UUID) -> Bool {
        !collapsedProjectIDs.contains(projectID)
    }

    func setProjectExpanded(_ expanded: Bool, projectID: UUID) {
        let changed = expanded
            ? collapsedProjectIDs.remove(projectID) != nil
            : collapsedProjectIDs.insert(projectID).inserted
        if changed { persistCollapsedProjects() }
    }

    func reconcile(with config: AgentConfig) {
        let projectIDs = Set(config.projects.map(\.id))
        var reconciledScope = scope
        switch scope {
        case .project(let id) where !projectIDs.contains(id):
            reconciledScope = .all
        case .task(let projectID, let taskID):
            let taskExists = config.projects
                .first(where: { $0.id == projectID })?
                .tasks.contains(where: { $0.id == taskID }) == true
            if !taskExists { reconciledScope = .all }
        default:
            break
        }
        var reconciledAgentID = selectedAgentID
        if let selectedAgentID,
           !config.allAgentEntries.contains(where: { $0.id == selectedAgentID }) {
            reconciledAgentID = nil
        }
        if reconciledScope != scope || reconciledAgentID != selectedAgentID {
            _ = apply(.reveal(scope: reconciledScope, agentID: reconciledAgentID))
        }
        if !hasPersistedProjectDisclosure {
            collapsedProjectIDs = AgentNavigationDisclosurePolicy
                .initialCollapsedProjectIDs(
                    validProjectIDs: projectIDs,
                    selectedScope: scope)
            hasPersistedProjectDisclosure = true
            persistCollapsedProjects()
        }
        let reconciledCollapsed = AgentNavigationDisclosurePolicy
            .reconciledCollapsedProjectIDs(
                collapsedProjectIDs,
                validProjectIDs: projectIDs,
                selectedScope: scope)
        if reconciledCollapsed != collapsedProjectIDs {
            collapsedProjectIDs = reconciledCollapsed
            persistCollapsedProjects()
        }
        let validAgentIDs = Set(config.allAgentEntries.map(\.id))
        let reconciledPreferences = preferredAgents.filter {
            validAgentIDs.contains($0.value)
        }
        if reconciledPreferences != preferredAgents {
            preferredAgents = reconciledPreferences
            persistPreferredAgents()
        }
    }

    private func persistPreferredAgents() {
        let encoded = preferredAgents.mapValues(\.uuidString)
        defaults?.set(encoded, forKey: DefaultsKey.preferredAgents)
    }

    private func persistCollapsedProjects() {
        defaults?.set(
            collapsedProjectIDs.map(\.uuidString).sorted(),
            forKey: DefaultsKey.collapsedProjects)
    }

    private static func preferenceKey(projectID: UUID) -> String {
        "project:\(projectID.uuidString)"
    }

    private static func preferenceKey(taskID: UUID) -> String {
        "task:\(taskID.uuidString)"
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
            return "The running process and terminal will close. This cannot be undone."
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
    let onSelectScope: (AgentWorkspaceModel.Scope) -> Void

    @State private var choosingProjectDirectory = false
    @State private var directoryProjectID: UUID?
    @State private var renameTarget: WorkspaceRenameTarget?
    @State private var deletion: DestructiveAction?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let userScopeSelection = Binding(
            get: { model.scope },
            set: { onSelectScope($0) })
        List(selection: userScopeSelection) {
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
                ForEach(Array(config.projects.enumerated()), id: \.element.id) { projectIndex, project in
                    // Native disclosure: AppKit draws the chevron, indents the
                    // children, and animates; we only own the expansion state.
                    DisclosureGroup(isExpanded: projectExpansion(project)) {
                        ForEach(Array(project.tasks.enumerated()), id: \.element.id) { taskIndex, task in
                            hierarchyLabel(
                                task.name,
                                icon: "list.bullet.rectangle",
                                state: aggregateState(for: task))
                                .tag(AgentWorkspaceModel.Scope.task(
                                    projectID: project.id,
                                    taskID: task.id))
                                .contextMenu {
                                    Button("Rename", systemImage: "pencil") {
                                        renameTarget = .task(project.id, task.id, task.name)
                                    }
                                    Divider()
                                    moveUpDownMenuButtons(
                                        canMoveUp: taskIndex > project.tasks.startIndex,
                                        canMoveDown: taskIndex < project.tasks.index(before: project.tasks.endIndex),
                                        onMove: { moveTask(task.id, in: project.id, to: taskIndex + $0) })
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
                                .draggable(AgentWorkspaceDragPayload(.task(task.id)))
                                .dropDestination(for: AgentWorkspaceDragPayload.self) { payloads, _ in
                                    handleTaskDrop(
                                        payloads,
                                        project: project,
                                        task: task,
                                        taskIndex: taskIndex)
                                }
                                .accessibilityActions {
                                    moveUpDownAccessibilityActions(
                                        canMoveUp: taskIndex > project.tasks.startIndex,
                                        canMoveDown: taskIndex < project.tasks.index(before: project.tasks.endIndex),
                                        onMove: { moveTask(task.id, in: project.id, to: taskIndex + $0) })
                                }
                        }
                    } label: {
                        hierarchyLabel(
                            project.name,
                            icon: "folder",
                            state: aggregateState(for: project),
                            quietCount: model.isProjectExpanded(project.id)
                                ? nil : project.tasks.flatMap(\.agents).count)
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
                                moveUpDownMenuButtons(
                                    canMoveUp: projectIndex > config.projects.startIndex,
                                    canMoveDown: projectIndex < config.projects.index(before: config.projects.endIndex),
                                    onMove: { moveProject(project.id, to: projectIndex + $0) })
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    deletion = .deleteProject(
                                        id: project.id,
                                        name: project.name,
                                        agentCount: project.tasks.flatMap(\.agents).count)
                                }
                            }
                            .draggable(AgentWorkspaceDragPayload(.project(project.id)))
                            .dropDestination(for: AgentWorkspaceDragPayload.self) { payloads, _ in
                                handleProjectDrop(
                                    payloads,
                                    project: project,
                                    projectIndex: projectIndex)
                            }
                            .accessibilityActions {
                                moveUpDownAccessibilityActions(
                                    canMoveUp: projectIndex > config.projects.startIndex,
                                    canMoveDown: projectIndex < config.projects.index(before: config.projects.endIndex),
                                    onMove: { moveProject(project.id, to: projectIndex + $0) })
                            }
                    }
                    .tag(AgentWorkspaceModel.Scope.project(project.id))
                    .accessibilityHint("Shows every agent in this project")
                }

                WorkspaceAppendDropTarget { payloads in
                    guard let payload = payloads.first,
                          case .project = payload.item
                    else { return false }
                    return perform(
                        AgentWorkspaceMove(
                            item: payload.item,
                            destination: .projects(index: config.projects.count)),
                        actionName: "Move Project")
                }
            }
        }
        .listStyle(.sidebar)
        // AppKit's sidebar item owns the glass; the List draws content only.
        .scrollContentBackground(.hidden)
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
                .help(selectedProject == nil ? "Select a project to add a task" : "Add Task")

                Spacer()

                if let error = config.errorMessage {
                    Button("Reveal Configuration Issue", systemImage: "exclamationmark.triangle.fill") {
                        let target = FileManager.default.fileExists(atPath: config.root.agentsFile.path)
                            ? config.root.agentsFile
                            : config.root.url
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
        state: DisplayState?,
        quietCount: Int? = nil
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
            } else if let quietCount, quietCount > 0 {
                Text(quietCount, format: .number)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
        .help(state.map { "\(title): \($0.label)" } ?? "\(title): No agents")
        .accessibilityValue(accessibilityValue(state: state, quietCount: quietCount))
    }

    private func accessibilityValue(state: DisplayState?, quietCount: Int?) -> String {
        if let state { return "Aggregated status: \(state.label)" }
        if let quietCount {
            return "\(quietCount) agent\(quietCount == 1 ? "" : "s")"
        }
        return "No agents"
    }

    /// Two-way disclosure state. Collapsing a project whose task is selected
    /// first moves the selection up to the project, so nothing selected hides.
    private func projectExpansion(_ project: AgentProject) -> Binding<Bool> {
        Binding(
            get: { model.isProjectExpanded(project.id) },
            set: { expanded in
                if !expanded,
                   let replacement = AgentNavigationDisclosurePolicy
                       .replacementScopeWhenCollapsing(
                           projectID: project.id,
                           selectedScope: model.scope) {
                    onSelectScope(replacement)
                }
                withAnimation(AgentWorkspaceMotion.animation(reduceMotion: reduceMotion)) {
                    model.setProjectExpanded(expanded, projectID: project.id)
                }
            })
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

    private func handleProjectDrop(
        _ payloads: [AgentWorkspaceDragPayload],
        project: AgentProject,
        projectIndex: Int
    ) -> Bool {
        guard let payload = payloads.first else { return false }
        let move: AgentWorkspaceMove
        switch payload.item {
        case .project(let sourceID):
            if sourceID == project.id { return true }
            let sourceIndex = config.projects.firstIndex(where: { $0.id == sourceID })
            move = AgentWorkspaceMove(
                item: payload.item,
                destination: .projects(index: AgentWorkspaceDropIndex.before(
                    sourceIndex: sourceIndex,
                    targetIndex: projectIndex,
                    inSameContainer: true)))
        case .task:
            move = AgentWorkspaceMove(
                item: payload.item,
                destination: .tasks(
                    projectID: project.id,
                    index: project.tasks.count))
        case .agent:
            return false
        }
        return perform(move, actionName: "Move Workspace Item")
    }

    private func handleTaskDrop(
        _ payloads: [AgentWorkspaceDragPayload],
        project: AgentProject,
        task: AgentTask,
        taskIndex: Int
    ) -> Bool {
        guard let payload = payloads.first else { return false }
        let move: AgentWorkspaceMove
        switch payload.item {
        case .task(let sourceID):
            if sourceID == task.id { return true }
            let sourceProject = config.projects.first(where: {
                $0.tasks.contains(where: { $0.id == sourceID })
            })
            let sourceIndex = sourceProject?.tasks.firstIndex(where: { $0.id == sourceID })
            move = AgentWorkspaceMove(
                item: payload.item,
                destination: .tasks(
                    projectID: project.id,
                    index: AgentWorkspaceDropIndex.before(
                        sourceIndex: sourceIndex,
                        targetIndex: taskIndex,
                        inSameContainer: sourceProject?.id == project.id)))
        case .agent:
            move = AgentWorkspaceMove(
                item: payload.item,
                destination: .agents(
                    projectID: project.id,
                    taskID: task.id,
                    index: task.agents.count))
        case .project:
            return false
        }
        return perform(move, actionName: "Move Workspace Item")
    }

    private func perform(_ move: AgentWorkspaceMove, actionName: String) -> Bool {
        withAnimation(AgentWorkspaceMotion.animation(reduceMotion: reduceMotion)) {
            AgentWorkspaceTransactions.perform(
                move,
                on: config,
                undoManager: undoManager,
                actionName: actionName)
        }
    }

    private func moveProject(_ id: UUID, to index: Int) {
        _ = perform(
            AgentWorkspaceMove(
                item: .project(id),
                destination: .projects(index: index)),
            actionName: "Move Project")
    }

    private func moveTask(_ id: UUID, in projectID: UUID, to index: Int) {
        _ = perform(
            AgentWorkspaceMove(
                item: .task(id),
                destination: .tasks(projectID: projectID, index: index)),
            actionName: "Move Task")
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
        onSelectScope(.project(id))
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
            onSelectScope(.task(projectID: projectID, taskID: taskID))
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
            onSelectScope(.all)
        case .deleteTask(let projectID, let taskID, _, _):
            guard let project = config.projects.first(where: { $0.id == projectID }),
                  let task = project.tasks.first(where: { $0.id == taskID })
            else { return }
            let agentIDs = task.agents.map(\.id)
            guard config.removeTask(projectId: projectID, taskId: taskID) else { return }
            bridge.removeAgentRuntimes(ids: agentIDs)
            onSelectScope(.project(projectID))
        case .resetSessions(let projectID, let newPath, _):
            applyDirectory(newPath, to: projectID)
        case .deleteAgent:
            // Presented by AgentListView, never by this view.
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
    var visualAuditScenario: AgentVisualAuditScenario?
    let onSelectAgent: (UUID, AgentProject, AgentSelectionIntent) -> Void
    let onReconcileSelection: ([UUID], UUID?) -> Void
    let onActivateAgent: (UUID, AgentProject) -> Void
    let onForkAgent: (UUID, AgentProject, String) -> Void
    let onDeleteAgent: (UUID) -> Void

    @State private var renameTarget: WorkspaceRenameTarget?
    @State private var showingNewAgent = false
    @State private var deletion: DestructiveAction?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// List writes represent deliberate mouse or keyboard selection. Other
    /// code writes directly to the model and is handled as a passive reveal
    /// by `onChange`, preventing automatic filtering from acknowledging a
    /// series of completed agents the user did not choose.
    private var userSelection: Binding<UUID?> {
        Binding(
            get: { model.selectedAgentID },
            set: { id in
                guard let id, let project = config.project(forAgent: id) else { return }
                onSelectAgent(id, project, .inspect)
            })
    }

    private var visibleAgents: [AgentListItem] {
        let ranks = AgentOrdering.ranks(in: config.allAgentEntries.map(\.id))
        return config.projects.flatMap { project in
            project.tasks.flatMap { task in
                task.agents.compactMap { entry in
                    guard let instance = bridge.agents[entry.id],
                          AgentWorkspaceProjection.includes(
                            instance,
                            project: project,
                            task: task,
                            scope: model.scope),
                          AgentWorkspaceProjection.matchesSearch(
                            entry,
                            project: project,
                            task: task,
                            instance: instance,
                            query: model.searchQuery)
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

    private var emptyPresentation: AgentListEmptyPresentation {
        AgentListEmptyStatePolicy.presentation(
            scope: model.scope,
            searchQuery: model.searchQuery)
    }

    var body: some View {
        // A concrete container: `.sheet`/`.onAppear` below must attach once,
        // not per child as they would on a Group.
        VStack(spacing: 0) {
            if visibleAgents.isEmpty {
                ContentUnavailableView {
                    Label(emptyPresentation.title, systemImage: emptyPresentation.symbolName)
                } description: {
                    Text(emptyPresentation.message)
                } actions: {
                    if emptyPresentation.offersCreation, selectedTask != nil {
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
                        AgentListRow(
                            agent: instance,
                            location: rowLocation(project: project, task: task))
                            .tag(entry.id)
                            .contentShape(Rectangle())
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
                                moveUpDownMenuButtons(
                                    canMoveUp: item.task.agents.first?.id != entry.id,
                                    canMoveDown: item.task.agents.last?.id != entry.id,
                                    onMove: { moveAgent(entry.id, in: item, by: $0) })
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    deletion = .deleteAgent(id: entry.id, name: entry.name)
                                }
                            }
                            .draggable(AgentWorkspaceDragPayload(.agent(entry.id)))
                            .dropDestination(for: AgentWorkspaceDragPayload.self) { payloads, _ in
                                handleAgentDrop(payloads, before: item)
                            }
                            .accessibilityActions {
                                moveUpDownAccessibilityActions(
                                    canMoveUp: item.task.agents.first?.id != entry.id,
                                    canMoveDown: item.task.agents.last?.id != entry.id,
                                    onMove: { moveAgent(entry.id, in: item, by: $0) })
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
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
                    .help(selectedTask == nil ? "Choose a task to create an agent" : "New Agent")
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
                            deletion = .deleteAgent(id: item.id, name: item.entry.name)
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
        .onChange(of: visibleAgents.map(\.id), initial: true) { _, visibleIDs in
            onReconcileSelection(visibleIDs, mostImportantVisibleAgentID())
        }
        .onAppear {
            if visualAuditScenario == .newAgent
                || visualAuditScenario == .newAgentConfigured {
                showingNewAgent = true
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
                taskName: selectedTask?.1.name ?? "this task",
                visualAuditScenario: visualAuditScenario,
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
                    onSelectAgent(entry.id, project, .inspect)
                    return true
                })
        }
        .confirmationDialog(
            deletion?.title ?? "",
            isPresented: Binding(
                get: { deletion != nil },
                set: { if !$0 { deletion = nil } }
            ),
            presenting: deletion
        ) { action in
            Button(action.confirmLabel, role: action.role) {
                if case .deleteAgent(let id, _) = action { onDeleteAgent(id) }
                deletion = nil
            }
            Button("Cancel", role: .cancel) { deletion = nil }
        } message: { Text($0.message) }
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

    private func mostImportantVisibleAgentID() -> UUID? {
        AgentImportance.mostImportant(
            in: visibleAgents.enumerated().map { rank, item in
                AgentImportanceCandidate(
                    id: item.id,
                    state: item.instance.displayState,
                    lastAuthoritativeChange: item.instance.lastAuthoritativeChange,
                    configurationRank: rank)
            },
            preferredID: model.preferredAgentID(for: model.scope))
    }

    private func handleAgentDrop(
        _ payloads: [AgentWorkspaceDragPayload],
        before item: AgentListItem
    ) -> Bool {
        guard let payload = payloads.first,
              case .agent(let sourceID) = payload.item,
              let destinationIndex = item.task.agents.firstIndex(where: {
                  $0.id == item.id
              })
        else { return false }
        if sourceID == item.id { return true }
        let sourceTask = config.task(forAgent: sourceID)
        let sourceIndex = sourceTask?.agents.firstIndex(where: { $0.id == sourceID })
        return withAnimation(AgentWorkspaceMotion.animation(reduceMotion: reduceMotion)) {
            AgentWorkspaceTransactions.perform(
                AgentWorkspaceMove(
                    item: payload.item,
                    destination: .agents(
                        projectID: item.project.id,
                        taskID: item.task.id,
                        index: AgentWorkspaceDropIndex.before(
                            sourceIndex: sourceIndex,
                            targetIndex: destinationIndex,
                            inSameContainer: sourceTask?.id == item.task.id))),
                on: config,
                undoManager: undoManager,
                actionName: "Move Agent")
        }
    }

    private func moveAgent(_ id: UUID, in item: AgentListItem, by offset: Int) {
        guard let sourceIndex = item.task.agents.firstIndex(where: { $0.id == id }) else { return }
        _ = withAnimation(AgentWorkspaceMotion.animation(reduceMotion: reduceMotion)) {
            AgentWorkspaceTransactions.perform(
                AgentWorkspaceMove(
                    item: .agent(id),
                    destination: .agents(
                        projectID: item.project.id,
                        taskID: item.task.id,
                        index: sourceIndex + offset)),
                on: config,
                undoManager: undoManager,
                actionName: "Move Agent")
        }
    }

    private func rowLocation(project: AgentProject, task: AgentTask) -> String? {
        switch model.scope {
        case .task:
            return nil
        case .project:
            return task.name
        case .all, .attention, .running:
            return "\(project.name) › \(task.name)"
        }
    }

}

/// A stable trailing insertion zone completes row-based "drop before" targets
/// without changing list geometry while a drag is in flight.
private struct WorkspaceAppendDropTarget: View {
    let onDrop: ([AgentWorkspaceDragPayload]) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Color.clear
            .frame(height: 8)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .opacity(isTargeted ? 1 : 0)
            }
            .dropDestination(
                for: AgentWorkspaceDragPayload.self,
                action: { payloads, _ in onDrop(payloads) },
                isTargeted: { isTargeted = $0 })
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
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
    let location: String?

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
                    if agent.displayState.showsListLabel {
                        Text(agent.displayState.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 4) {
                    Label(agent.provider.displayName, systemImage: agent.provider.symbolName)
                    if let location {
                        Text("·")
                        Text(location)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                AgentMetadataCompactLine(agent: agent)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agent.name)
        .accessibilityValue([
            agent.provider.displayName,
            agent.displayState.label,
            location,
            agent.metadataAccessibilityValue,
        ].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint("Selects this agent. Press Return to start or focus.")
    }
}

private struct NewAgentSheet: View {
    private static let providerDefaultsKey = "clawddy.newAgent.provider"

    var bridge: AgentBridge
    let taskName: String
    let visualAuditScenario: AgentVisualAuditScenario?
    let failureMessage: () -> String?
    let commit: (String, AgentProviderID, AgentLaunchProfile) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentCreationDraft
    @State private var error: String?
    @State private var showsRunSettings = false
    @FocusState private var nameFocused: Bool

    init(
        bridge: AgentBridge,
        taskName: String,
        visualAuditScenario: AgentVisualAuditScenario?,
        failureMessage: @escaping () -> String?,
        commit: @escaping (String, AgentProviderID, AgentLaunchProfile) -> Bool
    ) {
        self.bridge = bridge
        self.taskName = taskName
        self.visualAuditScenario = visualAuditScenario
        self.failureMessage = failureMessage
        self.commit = commit
        _draft = State(initialValue: AgentCreationDraft(
            provider: Self.restoredProvider,
            preferences: AgentPreferencesStore.load(from: bridge.root.preferencesFile)))
    }

    private static var restoredProvider: AgentProviderID {
        guard let raw = UserDefaults.standard.string(forKey: providerDefaultsKey),
              let provider = AgentProviderID(rawValue: raw)
        else { return .claudeCode }
        return provider
    }

    private var health: AgentProviderHealth {
        bridge.providerHealth[draft.provider] ?? AgentProviderHealth()
    }

    private var canCreate: Bool {
        draft.canCreate(providerHealth: health)
    }

    private var providerSelection: Binding<AgentProviderID> {
        Binding(
            get: { draft.provider },
            set: { provider in
                draft.transition(
                    to: provider,
                    preferences: AgentPreferencesStore.load(from: bridge.root.preferencesFile))
                error = nil
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Agent")
                    .font(.title3.weight(.semibold))
                Text("Create a coding agent in \(taskName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Name")
                    .font(.callout.weight(.medium))
                TextField("Agent name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(create)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Provider")
                    .font(.callout.weight(.medium))
                Picker("Provider", selection: providerSelection) {
                    ForEach(AgentProviderID.allCases) { option in
                        Label(option.displayName, systemImage: option.symbolName)
                            .tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                providerStatus
            }

            DisclosureGroup(isExpanded: $showsRunSettings) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Start mode")
                        Picker("Start mode", selection: $draft.startMode) {
                            ForEach(AgentStartMode.allCases) { option in
                                Text(draft.provider.startModeTitle(option)).tag(option)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Model")
                        TextField("Model", text: $draft.modelID, prompt: Text("Provider default"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                    GridRow {
                        Text("Reasoning")
                        Picker("Reasoning", selection: $draft.reasoningEffort) {
                            ForEach(draft.provider.reasoningEffortOptions) { option in
                                Text(option.title).tag(option.value)
                            }
                        }
                        .labelsHidden()
                    }
                }
                .padding(.top, 10)
                Text(draft.provider.startModeDescription(draft.startMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run Settings")
                        .font(.callout.weight(.medium))
                    Text(draft.launchSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
        .frame(width: 480)
        .onAppear {
            if visualAuditScenario == .newAgentConfigured {
                draft.name = "Release review"
                draft.transition(
                    to: .codex,
                    preferences: AgentPreferencesStore.load(from: bridge.root.preferencesFile))
                draft.modelID = "gpt-5.6"
                draft.reasoningEffort = "high"
                showsRunSettings = true
            }
            nameFocused = true
            bridge.refreshProviderHealth()
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
        .accessibilityLabel("\(draft.provider.displayName): \(health.conciseStatus)")
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
                return "Install the \(draft.provider.displayName) CLI before creating this agent."
        case .unavailable(let reason):
            return reason
        case .ready(_, let version):
            switch health.authentication {
            case .signedOut:
                return "You can complete sign-in when the terminal opens."
            case .unavailable(let reason):
                return reason
            case .checking, .signedIn:
                break
            }
            if draft.provider == .codex {
                let prefix = version.map { "\($0). " } ?? ""
                return "\(prefix)On first use, Codex may ask you to review Clawddy’s activity hook with /hooks."
            }
            return version
        }
    }

    private func create() {
        guard canCreate else { return }
        if commit(draft.normalizedName, draft.provider, draft.launchProfile) {
            UserDefaults.standard.set(
                draft.provider.rawValue,
                forKey: Self.providerDefaultsKey)
            dismiss()
        } else {
            error = failureMessage() ?? "That name is already in use."
            nameFocused = true
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
    @FocusState private var nameFocused: Bool

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
                .focused($nameFocused)
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
        .onAppear { nameFocused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if commit(trimmed) {
            dismiss()
        } else {
            error = failureMessage() ?? "That name is already in use."
            nameFocused = true
        }
    }
}
