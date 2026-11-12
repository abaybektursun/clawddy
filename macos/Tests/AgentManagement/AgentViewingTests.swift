import Foundation
import Testing
@testable import Ghostty

/// Which agent the user is looking at is one value, the workspace model's
/// `viewedAgentID`; the bridge asks through `isViewed` (P3.11). The harness
/// answers as `ClawddyController` does, with the window's key state under
/// the test's control.
@MainActor
struct AgentViewingTests {
    /// A completion that arrives while its agent is viewed in the key
    /// workspace window leaves no unread mark and posts nothing.
    @Test func completionWhileViewedLeavesNoUnread() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        h.view(id)
        #expect(h.workspace.viewedAgentID == id)

        try h.hook(id, "UserPromptSubmit")
        try h.hook(id, "Stop")

        let agent = try h.agent(id)
        #expect(agent.lastAppliedCompletion != nil)
        #expect(agent.unreadCompletion == nil)
        #expect(agent.displayState == .idle)
        #expect(h.notifier.posted.isEmpty)
        #expect(try h.persisted("unreadCompletions").isEmpty)
    }

    /// Once the user switches to another agent, a completion of the first
    /// leaves an unread mark and is notified; looking back acknowledges it.
    @Test func completionAfterSwitchingAwayLeavesUnread() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let other = try h.addAgent("Other")
        h.start()
        try h.launch(id)
        try h.launch(other)
        h.view(id)
        try h.hook(id, "UserPromptSubmit")

        h.view(other)
        #expect(h.workspace.viewedAgentID == other)
        try h.hook(id, "Stop")

        let agent = try h.agent(id)
        #expect(agent.unreadCompletion != nil)
        #expect(agent.displayState == .finished)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).completed"])
        #expect(Set(try h.persisted("unreadCompletions").keys) == [id])

        h.view(id)
        #expect(agent.unreadCompletion == nil)
        #expect(try h.persisted("unreadCompletions").isEmpty)
    }

    /// Viewing also takes the workspace window being key: a completion that
    /// arrives while the user is in another app leaves an unread mark, which
    /// the window becoming key again acknowledges.
    @Test func completionWhileWindowIsNotKeyLeavesUnread() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        h.view(id)
        try h.hook(id, "UserPromptSubmit")

        h.setWindowKey(false)
        try h.hook(id, "Stop")

        let agent = try h.agent(id)
        #expect(agent.unreadCompletion != nil)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).completed"])

        h.setWindowKey(true)
        #expect(agent.unreadCompletion == nil)
    }

    /// A passive selection is not viewing, and viewing ends when the
    /// selection moves to another agent, but not when only the scope does.
    @Test func viewingFollowsTheSelection() {
        let model = AgentWorkspaceModel(defaults: nil)
        let first = UUID()
        let second = UUID()

        model.apply(.reveal(scope: nil, agentID: first))
        #expect(model.viewedAgentID == nil)
        model.setViewingSelectedAgent(true)
        #expect(model.viewedAgentID == first)
        model.apply(.userSelectedScope(.attention, agentID: first))
        #expect(model.viewedAgentID == first)

        model.apply(.userSelectedAgent(second))
        #expect(model.viewedAgentID == nil)
        model.setViewingSelectedAgent(true)
        #expect(model.viewedAgentID == second)
        model.setViewingSelectedAgent(false)
        #expect(model.viewedAgentID == nil)
    }
}
