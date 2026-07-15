import Foundation
import Testing
@testable import Ghostty

struct AgentOrderingTests {
    @Test func ranksFollowPersistedProjectTaskAndInsertionOrder() throws {
        let first = AgentEntry(id: UUID(), name: "Zulu")
        let second = AgentEntry(id: UUID(), name: "Alpha")
        let third = AgentEntry(id: UUID(), name: "Middle")
        let projects = [
            AgentProject(
                name: "First project",
                tasks: [AgentTask(name: "First task", agents: [first, second])]),
            AgentProject(
                name: "Second project",
                tasks: [AgentTask(name: "Second task", agents: [third])]),
        ]

        let ranks = AgentOrdering.ranks(in: projects.flatMap { project in
            project.tasks.flatMap { $0.agents.map(\.id) }
        })

        #expect(ranks[first.id] == 0)
        #expect(ranks[second.id] == 1)
        #expect(ranks[third.id] == 2)
        #expect(AgentOrdering.precedes(first.id, second.id, ranks: ranks))
        #expect(AgentOrdering.precedes(second.id, third.id, ranks: ranks))
    }

    @Test func filteringDoesNotChangeRelativeOrder() throws {
        let entries = (0..<5).map { AgentEntry(id: UUID(), name: "Agent \($0)") }
        let projects = [
            AgentProject(
                name: "Project",
                tasks: [AgentTask(name: "Task", agents: entries)]),
        ]
        let ranks = AgentOrdering.ranks(in: projects.flatMap { project in
            project.tasks.flatMap { $0.agents.map(\.id) }
        })
        let filtered = [entries[4], entries[1], entries[3]].sorted {
            AgentOrdering.precedes($0.id, $1.id, ranks: ranks)
        }

        #expect(filtered.map(\.id) == [entries[1].id, entries[3].id, entries[4].id])
    }

    @Test func unknownIDsHaveDeterministicFallbackOrder() throws {
        let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))

        #expect(AgentOrdering.precedes(first, second, ranks: [:]))
        #expect(!AgentOrdering.precedes(second, first, ranks: [:]))
    }
}
