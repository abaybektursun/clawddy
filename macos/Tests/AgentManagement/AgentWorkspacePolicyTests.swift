import Foundation
import Testing
@testable import Ghostty

struct AgentWorkspacePolicyTests {
    @Test func scopeSelectionCommitsScopeAndDescendantInOneTransition() {
        let projectID = UUID()
        let taskID = UUID()
        let previousAgentID = UUID()
        let selectedAgentID = UUID()
        let initial = AgentWorkspaceSelectionState(
            scope: .all,
            agentID: previousAgentID)
        let selectedScope = AgentWorkspaceModel.Scope.task(
            projectID: projectID,
            taskID: taskID)

        let transition = AgentWorkspaceSelectionReducer.reduce(
            initial,
            action: .userSelectedScope(selectedScope, agentID: selectedAgentID))

        #expect(transition.state == AgentWorkspaceSelectionState(
            scope: selectedScope,
            agentID: selectedAgentID))
        #expect(transition.effect == .present(
            agentID: selectedAgentID,
            intent: .reveal))
    }

    @Test func clickingAlreadySelectedAgentStillEmitsOneInspection() {
        let selectedAgentID = UUID()
        let initial = AgentWorkspaceSelectionState(
            scope: .all,
            agentID: selectedAgentID)

        let transition = AgentWorkspaceSelectionReducer.reduce(
            initial,
            action: .userSelectedAgent(selectedAgentID))

        #expect(transition.state == initial)
        #expect(transition.effect == .present(
            agentID: selectedAgentID,
            intent: .inspect))
    }

    @Test func reconciliationPreservesVisibleSelectionWithoutPresentation() {
        let selectedAgentID = UUID()
        let initial = AgentWorkspaceSelectionState(
            scope: .attention,
            agentID: selectedAgentID)

        let transition = AgentWorkspaceSelectionReducer.reduce(
            initial,
            action: .reconcile(
                visibleAgentIDs: Set([selectedAgentID, UUID()]),
                fallbackAgentID: UUID()))

        #expect(transition.state == initial)
        #expect(transition.effect == .none)
    }

    @Test func reconciliationReplacesHiddenSelectionExactlyOnce() {
        let fallbackAgentID = UUID()
        let initial = AgentWorkspaceSelectionState(
            scope: .running,
            agentID: UUID())

        let transition = AgentWorkspaceSelectionReducer.reduce(
            initial,
            action: .reconcile(
                visibleAgentIDs: Set([fallbackAgentID]),
                fallbackAgentID: fallbackAgentID))

        #expect(transition.state.agentID == fallbackAgentID)
        #expect(transition.effect == .present(
            agentID: fallbackAgentID,
            intent: .reveal))
    }

    @Test func importancePrefersUrgencyThenExplicitHistoryThenStableOrder() {
        let now = Date()
        let first = UUID()
        let preferred = UUID()
        let urgent = UUID()
        let candidates = [
            AgentImportanceCandidate(
                id: first,
                state: .working,
                lastAuthoritativeChange: now,
                configurationRank: 0),
            AgentImportanceCandidate(
                id: preferred,
                state: .working,
                lastAuthoritativeChange: now,
                configurationRank: 1),
            AgentImportanceCandidate(
                id: urgent,
                state: .permission,
                lastAuthoritativeChange: .distantPast,
                configurationRank: 2),
        ]

        #expect(AgentImportance.mostImportant(
            in: candidates,
            preferredID: preferred) == urgent)
        #expect(AgentImportance.mostImportant(
            in: candidates.dropLast(),
            preferredID: preferred) == preferred)
    }

    @Test func importanceUsesLatestFactThenConfigurationOrderForTies() {
        let earlier = Date(timeIntervalSinceReferenceDate: 10)
        let later = Date(timeIntervalSinceReferenceDate: 20)
        let first = UUID()
        let recent = UUID()
        let candidates = [
            AgentImportanceCandidate(
                id: first,
                state: .idle,
                lastAuthoritativeChange: earlier,
                configurationRank: 0),
            AgentImportanceCandidate(
                id: recent,
                state: .idle,
                lastAuthoritativeChange: later,
                configurationRank: 1),
        ]

        #expect(AgentImportance.mostImportant(
            in: candidates,
            preferredID: nil) == recent)
        #expect(AgentImportance.mostImportant(
            in: candidates.map {
                var candidate = $0
                candidate.lastAuthoritativeChange = later
                return candidate
            },
            preferredID: nil) == first)
    }

    @Test func projectTaskAndAgentMovesRoundTripWithTheirInverse() throws {
        let firstAgent = AgentEntry(id: UUID(), name: "First")
        let secondAgent = AgentEntry(id: UUID(), name: "Second")
        let firstTask = AgentTask(id: UUID(), name: "Task A", agents: [firstAgent])
        let secondTask = AgentTask(id: UUID(), name: "Task B", agents: [secondAgent])
        let firstProject = AgentProject(id: UUID(), name: "Project A", tasks: [firstTask])
        let secondProject = AgentProject(id: UUID(), name: "Project B", tasks: [secondTask])
        let original = [firstProject, secondProject]
        var projects = original

        let projectInverse = try AgentWorkspaceMutation.apply(
            AgentWorkspaceMove(
                item: .project(firstProject.id),
                destination: .projects(index: 1)),
            to: &projects).get()
        #expect(projects.map(\.id) == [secondProject.id, firstProject.id])
        _ = try AgentWorkspaceMutation.apply(projectInverse, to: &projects).get()
        #expect(projects.map(\.id) == original.map(\.id))

        let taskInverse = try AgentWorkspaceMutation.apply(
            AgentWorkspaceMove(
                item: .task(firstTask.id),
                destination: .tasks(projectID: secondProject.id, index: 1)),
            to: &projects).get()
        #expect(projects[1].tasks.map(\.id) == [secondTask.id, firstTask.id])
        _ = try AgentWorkspaceMutation.apply(taskInverse, to: &projects).get()
        #expect(projects[0].tasks.map(\.id) == [firstTask.id])

        let agentInverse = try AgentWorkspaceMutation.apply(
            AgentWorkspaceMove(
                item: .agent(firstAgent.id),
                destination: .agents(
                    projectID: secondProject.id,
                    taskID: secondTask.id,
                    index: 1)),
            to: &projects).get()
        #expect(projects[1].tasks[0].agents.map(\.id) == [secondAgent.id, firstAgent.id])
        _ = try AgentWorkspaceMutation.apply(agentInverse, to: &projects).get()
        #expect(projects[0].tasks[0].agents.map(\.id) == [firstAgent.id])
    }

    @Test func sameContainerDestinationIsTheFinalIndex() throws {
        let first = AgentProject(id: UUID(), name: "First")
        let second = AgentProject(id: UUID(), name: "Second")
        let third = AgentProject(id: UUID(), name: "Third")
        var projects = [first, second, third]

        let inverse = try AgentWorkspaceMutation.apply(
            AgentWorkspaceMove(
                item: .project(first.id),
                destination: .projects(index: 2)),
            to: &projects).get()

        #expect(projects.map(\.id) == [second.id, third.id, first.id])
        _ = try AgentWorkspaceMutation.apply(inverse, to: &projects).get()
        #expect(projects.map(\.id) == [first.id, second.id, third.id])
    }

    @Test func sameContainerTaskAndAgentMovesRoundTripExactly() throws {
        let agents = ["A", "B", "C"].map { AgentEntry(name: $0) }
        let tasks = [
            AgentTask(name: "First", agents: agents),
            AgentTask(name: "Second"),
            AgentTask(name: "Third"),
        ]
        let project = AgentProject(name: "Project", tasks: tasks)
        var projects = [project]

        let taskInverse = try AgentWorkspaceMutation.apply(
            AgentWorkspaceMove(
                item: .task(tasks[0].id),
                destination: .tasks(projectID: project.id, index: 2)),
            to: &projects).get()
        #expect(projects[0].tasks.map(\.id) == [tasks[1].id, tasks[2].id, tasks[0].id])
        _ = try AgentWorkspaceMutation.apply(taskInverse, to: &projects).get()
        #expect(projects == [project])

        let agentInverse = try AgentWorkspaceMutation.apply(
            AgentWorkspaceMove(
                item: .agent(agents[0].id),
                destination: .agents(
                    projectID: project.id,
                    taskID: tasks[0].id,
                    index: 2)),
            to: &projects).get()
        #expect(projects[0].tasks[0].agents.map(\.id) == [
            agents[1].id, agents[2].id, agents[0].id,
        ])
        _ = try AgentWorkspaceMutation.apply(agentInverse, to: &projects).get()
        #expect(projects == [project])
    }

    @Test func dropBeforeIndexCompensatesOnlyForDownwardSameContainerMoves() {
        #expect(AgentWorkspaceDropIndex.before(
            sourceIndex: 0,
            targetIndex: 2,
            inSameContainer: true) == 1)
        #expect(AgentWorkspaceDropIndex.before(
            sourceIndex: 2,
            targetIndex: 0,
            inSameContainer: true) == 0)
        #expect(AgentWorkspaceDropIndex.before(
            sourceIndex: 0,
            targetIndex: 2,
            inSameContainer: false) == 2)
    }

    @Test func movesRejectIncompatibleDestinationsAndDuplicateNames() {
        let agent = AgentEntry(id: UUID(), name: "Agent")
        let duplicate = AgentEntry(id: UUID(), name: "agent")
        let sourceTask = AgentTask(id: UUID(), name: "Task", agents: [agent])
        let destinationTask = AgentTask(id: UUID(), name: "Other", agents: [duplicate])
        let project = AgentProject(
            id: UUID(),
            name: "Project",
            tasks: [sourceTask, destinationTask])
        var projects = [project]

        #expect(AgentWorkspaceMutation.apply(
            AgentWorkspaceMove(
                item: .agent(agent.id),
                destination: .projects(index: 0)),
            to: &projects) == .failure(.incompatibleDestination))
        #expect(AgentWorkspaceMutation.apply(
            AgentWorkspaceMove(
                item: .agent(agent.id),
                destination: .agents(
                    projectID: project.id,
                    taskID: destinationTask.id,
                    index: 1)),
            to: &projects) == .failure(.duplicateName))
        #expect(projects[0].tasks[0].agents.map(\.id) == [agent.id])
    }

    @Test func rejectedMoveIsAtomic() {
        let agent = AgentEntry(id: UUID(), name: "Agent")
        let task = AgentTask(id: UUID(), name: "Task", agents: [agent])
        let project = AgentProject(id: UUID(), name: "Project", tasks: [task])
        var projects = [project]

        #expect(AgentWorkspaceMutation.apply(
            AgentWorkspaceMove(
                item: .agent(agent.id),
                destination: .agents(
                    projectID: UUID(),
                    taskID: UUID(),
                    index: 0)),
            to: &projects) == .failure(.destinationNotFound))
        #expect(projects[0].tasks[0].agents.map(\.id) == [agent.id])
    }
}
