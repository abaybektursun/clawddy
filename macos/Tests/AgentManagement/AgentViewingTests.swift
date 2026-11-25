import Foundation
import Testing
import UserNotifications
@testable import Ghostty

/// Which agent the user is looking at is one value, the workspace model's
/// `viewedAgentID`; the bridge asks through `isViewed` (P3.11). The harness
/// answers as `ClawddyController` does, with the window's key state under
/// the test's control.
@MainActor
struct AgentViewingTests {
    /// A completion that arrives while its agent is viewed in the key
    /// workspace window leaves no unread mark and posts nothing, but is
    /// announced.
    @Test func completionWhileViewedLeavesNoUnread() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        h.view(id)
        #expect(h.workspace.viewedAgentID == id)

        try h.completeTurn(id)

        let agent = try h.agent(id)
        #expect(agent.lastAppliedCompletion != nil)
        #expect(!agent.record.unread)
        #expect(agent.terminal == .idle)
        #expect(h.notifier.posted.isEmpty)
        #expect(try h.recordedUnread().isEmpty)
        // VoiceOver still hears it: the user's focus is in the terminal.
        #expect(h.notifier.announced == ["Agent, Finished"])
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
        try h.startTurn(id)

        h.view(other)
        #expect(h.workspace.viewedAgentID == other)
        try h.osc(id, "state=done:app=claude-code")

        let agent = try h.agent(id)
        #expect(agent.record.unread)
        #expect(agent.shownState == .finishedUnread)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).completed"])
        #expect(try h.recordedUnread() == [id])

        h.view(id)
        #expect(!agent.record.unread)
        #expect(try h.recordedUnread().isEmpty)
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
        try h.startTurn(id)

        h.setWindowKey(false)
        try h.osc(id, "state=done:app=claude-code")

        let agent = try h.agent(id)
        #expect(agent.record.unread)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).completed"])

        h.setWindowKey(true)
        #expect(!agent.record.unread)
    }

    /// A notification says what is asked (design plan section 8): the
    /// agent's name as its title, its project as its subtitle, its headline
    /// as its body. A wait is time-sensitive; Done is passive; none
    /// sounds.
    @Test func notificationsSayWhatIsAsked() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let asking = try h.addAgent("soundings")
        let signIn = try h.addAgent("deploy")
        let finishing = try h.addAgent("review")
        h.start()
        for id in [asking, signIn, finishing] { try h.launch(id) }
        try h.startTurn(asking)
        try h.osc(asking, "state=blocked:app=claude-code:kind=question")
        try h.osc(signIn, "state=blocked:app=claude-code:kind=auth")
        try h.completeTurn(finishing)

        let shown = h.notifier.posted.map { [$0.content.title, $0.content.subtitle, $0.content.body] }
        #expect(shown == [
            ["soundings", AgentBridgeHarness.projectName, "Has a question"],
            ["deploy", AgentBridgeHarness.projectName, "Login expired. Open it and run /login."],
            ["review", AgentBridgeHarness.projectName, "Finished"],
        ])
        // No sounds (the brief).
        #expect(h.notifier.posted.allSatisfy { $0.content.sound == nil })
        #expect(h.notifier.posted.map(\.content.interruptionLevel) == [.timeSensitive, .active, .passive])
        #expect(h.notifier.announced == ["soundings, Has a question", "deploy, Login expired. Open it and run /login.", "review, Finished"])

        try h.startTurn(asking)
        try h.osc(asking, "state=blocked:app=claude-code:kind=permission")
        #expect(h.notifier.posted.last?.content.body == "Has a question")
    }

    /// The agent whose terminal the user is looking at, in the key window,
    /// is never notified, of a wait or a completion: nothing is posted and
    /// nothing sounds. Once the window is not key, it is.
    @Test func theViewedAgentIsNeverNotified() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        h.view(id)

        try h.startTurn(id)
        try h.osc(id, "state=blocked:app=claude-code:kind=permission")
        try h.osc(id, "state=working:app=claude-code")
        try h.completeTurn(id)
        #expect(h.notifier.posted.isEmpty)
        #expect(h.notifier.announced == ["Agent, Has a question", "Agent, Finished"])

        h.setWindowKey(false)
        try h.startTurn(id)
        try h.osc(id, "state=blocked:app=claude-code:kind=permission")
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).waiting"])
    }

    /// With "Notify when an agent is waiting" off, nothing is posted; the
    /// announcement for VoiceOver still is.
    @Test func nothingIsPostedWithNotificationsOff() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        h.bridge.notifies = { false }
        h.setWindowKey(false)
        try h.startTurn(id)
        try h.osc(id, "state=blocked:app=claude-code:kind=permission")
        #expect(h.notifier.posted.isEmpty)
        #expect(!h.notifier.announced.isEmpty)
    }

    /// Showing an agent is not viewing it, and viewing ends when another
    /// agent is shown or the person goes home, but not when the same agent
    /// is shown again.
    @Test func viewingFollowsTheShownAgent() {
        let model = AgentWorkspaceModel(defaults: nil)
        let project = UUID()
        let first = UUID()
        let second = UUID()

        model.show(.inside(first), in: project)
        #expect(model.viewedAgentID == nil)
        model.setViewingShownAgent(true)
        #expect(model.viewedAgentID == first)
        model.show(.inside(first), in: project)
        #expect(model.viewedAgentID == first)

        model.show(.inside(second), in: project)
        #expect(model.viewedAgentID == nil)
        model.setViewingShownAgent(true)
        #expect(model.viewedAgentID == second)
        model.show(.home, in: project)
        #expect(model.viewedAgentID == nil)
    }

    /// Each project keeps where it was left, for the next start too: the
    /// agent it was left inside, or home.
    @Test func eachProjectKeepsWhereItWasLeft() throws {
        let suite = "clawddy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (a, b, agent) = (UUID(), UUID(), UUID())
        let model = AgentWorkspaceModel(defaults: defaults)
        model.show(.inside(agent), in: a)
        model.show(.home, in: b)
        model.switchTo(a)
        #expect(model.shownAgentID == agent)

        let again = AgentWorkspaceModel(defaults: defaults)
        #expect(again.currentProjectID == a)
        #expect(again.views == [a: .inside(agent), b: .home])
        again.switchTo(b)
        #expect(again.shownAgentID == nil)
    }
}
