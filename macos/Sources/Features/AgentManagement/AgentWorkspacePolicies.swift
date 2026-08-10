import Foundation
import CoreTransferable
import UniformTypeIdentifiers

enum AgentSelectionIntent: Equatable, Sendable {
    /// Keeps detail presentation synchronized with authoritative selection.
    case reveal
    /// Records deliberate user inspection and may acknowledge completed work.
    case inspect
}

struct AgentWorkspaceSelectionState: Equatable, Sendable {
    var scope: AgentWorkspaceModel.Scope
    var agentID: UUID?
}

enum AgentWorkspaceSelectionAction: Equatable, Sendable {
    /// Scope and descendant are committed together so observers never render
    /// a new scope with the previous scope's agent.
    case userSelectedScope(AgentWorkspaceModel.Scope, agentID: UUID?)
    /// Remains meaningful for an already-selected row; intent is an event,
    /// not something inferred from whether a UUID happened to mutate.
    case userSelectedAgent(UUID)
    case reveal(scope: AgentWorkspaceModel.Scope?, agentID: UUID?)
    case reconcile(visibleAgentIDs: Set<UUID>, fallbackAgentID: UUID?)
}

enum AgentWorkspaceSelectionEffect: Equatable, Sendable {
    case none
    case present(agentID: UUID?, intent: AgentSelectionIntent)
}

struct AgentWorkspaceSelectionTransition: Equatable, Sendable {
    var state: AgentWorkspaceSelectionState
    var effect: AgentWorkspaceSelectionEffect
}

/// The sole state machine for workspace navigation. A user event produces one
/// committed selection and at most one presentation effect; views never infer
/// intent from independent Observation callbacks.
enum AgentWorkspaceSelectionReducer {
    static func reduce(
        _ state: AgentWorkspaceSelectionState,
        action: AgentWorkspaceSelectionAction
    ) -> AgentWorkspaceSelectionTransition {
        switch action {
        case .userSelectedScope(let scope, let agentID):
            return AgentWorkspaceSelectionTransition(
                state: AgentWorkspaceSelectionState(scope: scope, agentID: agentID),
                effect: .present(agentID: agentID, intent: .reveal))

        case .userSelectedAgent(let agentID):
            var next = state
            next.agentID = agentID
            return AgentWorkspaceSelectionTransition(
                state: next,
                effect: .present(agentID: agentID, intent: .inspect))

        case .reveal(let scope, let agentID):
            var next = state
            if let scope { next.scope = scope }
            next.agentID = agentID
            return AgentWorkspaceSelectionTransition(
                state: next,
                effect: .present(agentID: agentID, intent: .reveal))

        case .reconcile(let visibleAgentIDs, let fallbackAgentID):
            if let current = state.agentID, visibleAgentIDs.contains(current) {
                return AgentWorkspaceSelectionTransition(state: state, effect: .none)
            }
            var next = state
            next.agentID = fallbackAgentID
            return AgentWorkspaceSelectionTransition(
                state: next,
                effect: .present(agentID: fallbackAgentID, intent: .reveal))
        }
    }
}

/// One product-wide ordering for urgency and relevance. Presentation,
/// aggregation, and task selection must not invent competing interpretations
/// of the same agent state.
enum AgentStatePriority {
    static func value(of state: DisplayState) -> Int {
        switch state {
        case .failed: return 140
        case .error: return 130
        case .authentication: return 125
        case .input: return 120
        case .permission: return 115
        case .finished: return 110
        case .statusUnavailable: return 100
        case .statusDelayed: return 95
        case .compacting: return 90
        case .working: return 80
        case .thinking: return 70
        case .launching: return 60
        case .idle: return 50
        case .inactive: return 40
        case .dead: return 30
        }
    }
}

struct AgentImportanceCandidate: Equatable, Sendable {
    var id: UUID
    var state: DisplayState
    var lastAuthoritativeChange: Date?
    var configurationRank: Int
}

/// Chooses the agent a deliberate project/task selection should reveal.
/// Runtime changes never call this policy on their own, so an agent becoming
/// urgent cannot steal focus while the user is working elsewhere.
enum AgentImportance {
    static func mostImportant<Candidates: Sequence>(
        in candidates: Candidates,
        preferredID: UUID?
    ) -> UUID? where Candidates.Element == AgentImportanceCandidate {
        candidates.max { lhs, rhs in
            precedes(lhs, rhs, preferredID: preferredID)
        }?.id
    }

    private static func precedes(
        _ lhs: AgentImportanceCandidate,
        _ rhs: AgentImportanceCandidate,
        preferredID: UUID?
    ) -> Bool {
        let leftPriority = AgentStatePriority.value(of: lhs.state)
        let rightPriority = AgentStatePriority.value(of: rhs.state)
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }

        let leftPreferred = lhs.id == preferredID
        let rightPreferred = rhs.id == preferredID
        if leftPreferred != rightPreferred {
            return !leftPreferred
        }

        let leftChanged = lhs.lastAuthoritativeChange ?? .distantPast
        let rightChanged = rhs.lastAuthoritativeChange ?? .distantPast
        if leftChanged != rightChanged {
            return leftChanged < rightChanged
        }

        if lhs.configurationRank != rhs.configurationRank {
            return lhs.configurationRank > rhs.configurationRank
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}

/// Shared projection for scope and search membership. Navigation selection and
/// list rendering must resolve from the same agent set or they can immediately
/// overwrite each other's selection.
@MainActor
enum AgentWorkspaceProjection {
    static func includes(
        _ agent: AgentInstance,
        project: AgentProject,
        task: AgentTask,
        scope: AgentWorkspaceModel.Scope
    ) -> Bool {
        switch scope {
        case .all: return true
        case .attention: return agent.displayState.needsAttention
        case .running: return agent.displayState.isActive
        case .project(let id): return project.id == id
        case .task(let projectID, let taskID):
            return project.id == projectID && task.id == taskID
        }
    }

    static func matchesSearch(
        _ entry: AgentEntry,
        project: AgentProject,
        task: AgentTask,
        instance: AgentInstance,
        query: String
    ) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
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

enum AgentWorkspaceItem: Equatable, Hashable, Sendable {
    case project(UUID)
    case task(UUID)
    case agent(UUID)
}

enum AgentWorkspaceDestination: Equatable, Sendable {
    case projects(index: Int)
    case tasks(projectID: UUID, index: Int)
    case agents(projectID: UUID, taskID: UUID, index: Int)
}

struct AgentWorkspaceMove: Equatable, Sendable {
    var item: AgentWorkspaceItem
    var destination: AgentWorkspaceDestination
}

enum AgentWorkspaceMoveError: Error, Equatable, Sendable {
    case itemNotFound
    case incompatibleDestination
    case destinationNotFound
    case duplicateName
}

/// Pure hierarchy mutation. The returned inverse command is computed from the
/// pre-move location and can be registered directly with NSUndoManager.
enum AgentWorkspaceMutation {
    static func apply(
        _ move: AgentWorkspaceMove,
        to projects: inout [AgentProject]
    ) -> Result<AgentWorkspaceMove, AgentWorkspaceMoveError> {
        var updatedProjects = projects
        let result = applyValidated(move, to: &updatedProjects)
        if case .success = result {
            projects = updatedProjects
        }
        return result
    }

    /// Destination indices describe the final index after the moved item has
    /// been removed. Keeping that contract here prevents individual views from
    /// inventing different off-by-one rules for downward moves.
    private static func applyValidated(
        _ move: AgentWorkspaceMove,
        to projects: inout [AgentProject]
    ) -> Result<AgentWorkspaceMove, AgentWorkspaceMoveError> {
        switch (move.item, move.destination) {
        case (.project(let id), .projects(let destinationIndex)):
            guard let sourceIndex = projects.firstIndex(where: { $0.id == id }) else {
                return .failure(.itemNotFound)
            }
            let project = projects.remove(at: sourceIndex)
            projects.insert(project, at: normalizedInsertionIndex(
                destinationIndex,
                count: projects.count))
            return .success(AgentWorkspaceMove(
                item: .project(id),
                destination: .projects(index: sourceIndex)))

        case (.task(let id), .tasks(let destinationProjectID, let destinationIndex)):
            guard let source = taskLocation(id: id, in: projects) else {
                return .failure(.itemNotFound)
            }
            guard let destinationProjectIndex = projects.firstIndex(where: {
                $0.id == destinationProjectID
            }) else {
                return .failure(.destinationNotFound)
            }
            let task = projects[source.projectIndex].tasks[source.itemIndex]
            guard !projects[destinationProjectIndex].tasks.contains(where: {
                $0.id != id && $0.name.localizedCaseInsensitiveCompare(task.name) == .orderedSame
            }) else {
                return .failure(.duplicateName)
            }
            projects[source.projectIndex].tasks.remove(at: source.itemIndex)
            guard let updatedDestinationProjectIndex = projects.firstIndex(where: {
                $0.id == destinationProjectID
            }) else {
                return .failure(.destinationNotFound)
            }
            projects[updatedDestinationProjectIndex].tasks.insert(
                task,
                at: normalizedInsertionIndex(
                    destinationIndex,
                    count: projects[updatedDestinationProjectIndex].tasks.count))
            return .success(AgentWorkspaceMove(
                item: .task(id),
                destination: .tasks(
                    projectID: projects[source.projectIndex].id,
                    index: source.itemIndex)))

        case (
            .agent(let id),
            .agents(let destinationProjectID, let destinationTaskID, let destinationIndex)
        ):
            guard let source = agentLocation(id: id, in: projects) else {
                return .failure(.itemNotFound)
            }
            guard let destination = taskLocation(
                projectID: destinationProjectID,
                taskID: destinationTaskID,
                in: projects)
            else {
                return .failure(.destinationNotFound)
            }
            let agent = projects[source.projectIndex]
                .tasks[source.taskIndex]
                .agents[source.itemIndex]
            guard !projects[destination.projectIndex]
                .tasks[destination.itemIndex]
                .agents.contains(where: {
                    $0.id != id
                        && $0.name.localizedCaseInsensitiveCompare(agent.name) == .orderedSame
                })
            else {
                return .failure(.duplicateName)
            }
            let sourceProjectID = projects[source.projectIndex].id
            let sourceTaskID = projects[source.projectIndex].tasks[source.taskIndex].id
            projects[source.projectIndex].tasks[source.taskIndex].agents.remove(at: source.itemIndex)
            guard let updatedDestination = taskLocation(
                projectID: destinationProjectID,
                taskID: destinationTaskID,
                in: projects)
            else {
                return .failure(.destinationNotFound)
            }
            projects[updatedDestination.projectIndex]
                .tasks[updatedDestination.itemIndex]
                .agents.insert(
                    agent,
                    at: normalizedInsertionIndex(
                        destinationIndex,
                        count: projects[updatedDestination.projectIndex]
                            .tasks[updatedDestination.itemIndex].agents.count))
            return .success(AgentWorkspaceMove(
                item: .agent(id),
                destination: .agents(
                    projectID: sourceProjectID,
                    taskID: sourceTaskID,
                    index: source.itemIndex)))

        default:
            return .failure(.incompatibleDestination)
        }
    }

    private struct ItemLocation {
        var projectIndex: Int
        var taskIndex: Int = 0
        var itemIndex: Int
    }

    private static func taskLocation(
        id: UUID,
        in projects: [AgentProject]
    ) -> ItemLocation? {
        for projectIndex in projects.indices {
            if let taskIndex = projects[projectIndex].tasks.firstIndex(where: { $0.id == id }) {
                return ItemLocation(projectIndex: projectIndex, itemIndex: taskIndex)
            }
        }
        return nil
    }

    private static func taskLocation(
        projectID: UUID,
        taskID: UUID,
        in projects: [AgentProject]
    ) -> ItemLocation? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let taskIndex = projects[projectIndex].tasks.firstIndex(where: {
                  $0.id == taskID
              })
        else { return nil }
        return ItemLocation(projectIndex: projectIndex, itemIndex: taskIndex)
    }

    private static func agentLocation(
        id: UUID,
        in projects: [AgentProject]
    ) -> ItemLocation? {
        for projectIndex in projects.indices {
            for taskIndex in projects[projectIndex].tasks.indices {
                if let agentIndex = projects[projectIndex].tasks[taskIndex]
                    .agents.firstIndex(where: { $0.id == id }) {
                    return ItemLocation(
                        projectIndex: projectIndex,
                        taskIndex: taskIndex,
                        itemIndex: agentIndex)
                }
            }
        }
        return nil
    }

    private static func normalizedInsertionIndex(_ requested: Int, count: Int) -> Int {
        min(max(0, requested), count)
    }
}

enum AgentWorkspaceDropIndex {
    /// Converts an AppKit/SwiftUI "drop before this original row" index into
    /// the move engine's final post-removal index contract.
    static func before(
        sourceIndex: Int?,
        targetIndex: Int,
        inSameContainer: Bool
    ) -> Int {
        guard inSameContainer, let sourceIndex, sourceIndex < targetIndex else {
            return targetIndex
        }
        return targetIndex - 1
    }
}

extension UTType {
    static let clawddyWorkspaceItem = UTType(
        exportedAs: "com.mitchellh.ghostty.clawddy.workspace-item")
}

struct AgentWorkspaceDragPayload: Codable, Transferable {
    enum Kind: String, Codable {
        case project
        case task
        case agent
    }

    var kind: Kind
    var id: UUID

    init(_ item: AgentWorkspaceItem) {
        switch item {
        case .project(let id):
            kind = .project
            self.id = id
        case .task(let id):
            kind = .task
            self.id = id
        case .agent(let id):
            kind = .agent
            self.id = id
        }
    }

    var item: AgentWorkspaceItem {
        switch kind {
        case .project: return .project(id)
        case .task: return .task(id)
        case .agent: return .agent(id)
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .clawddyWorkspaceItem)
    }
}

enum AgentWorkspaceTransactions {
    /// Runs one durable move and registers the exact inverse. Undo invokes the
    /// same transaction boundary, which naturally registers redo.
    @discardableResult
    static func perform(
        _ move: AgentWorkspaceMove,
        on config: AgentConfig,
        undoManager: UndoManager?,
        actionName: String
    ) -> Bool {
        guard let inverse = config.move(move) else { return false }
        undoManager?.registerUndo(withTarget: config) { [weak undoManager] target in
            perform(
                inverse,
                on: target,
                undoManager: undoManager,
                actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        return true
    }
}
