import Combine
import Foundation
import Testing
@testable import Ghostty

/// A new agent without a form or a naming step: "New agent" creates an agent
/// at once with the saved defaults, at the end of its project, under a free
/// "agent N", which its conversation's title replaces until the person
/// names it (`docs/clawddy-design/flows.md` 4.3, 6.3).
@MainActor
struct AgentNewAgentTests {
    private static let defaults = AgentCreationDraft(provider: .claudeCode, preferences: AgentPreferences())

    /// The agent goes last in its project, named by the app.
    @Test func aNewAgentGoesLast() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let old = try h.addAgent("old")
        let running = try h.addAgent("running")
        h.start()
        try h.launch(running)

        let id = try newAgent(h)

        #expect(h.config.projects[0].agents.map(\.id) == [old, running, id])
        #expect(h.config.projects[0].agents.last?.name == "agent 1")
        #expect(try h.agent(id).autoNamed)
    }

    /// The saved default: the CLI last chosen, Claude Code until then, kept
    /// for the next start.
    @Test func theProviderIsTheOneLastChosen() throws {
        let suite = "clawddy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AgentWorkspaceModel(defaults: defaults).newAgentProvider == .claudeCode)
        AgentWorkspaceModel(defaults: defaults).newAgentProvider = .codex
        #expect(AgentWorkspaceModel(defaults: defaults).newAgentProvider == .codex)
    }

    // MARK: The name a conversation gives

    /// Until the user names it, an agent's name is Clawddy's: Claude is not
    /// given it, and the title Claude gives the conversation, cleaned,
    /// becomes the agent's name, saved and kept across a restart. Its own
    /// "Claude Code", the list of conversations, a status glyph, a title
    /// another agent of the project has and anything after the provider
    /// left are handled as `AgentConversationTitle` says.
    @Test func theConversationsTitleNamesTheAgentUntilTheUserDoes() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        try h.addAgent("Single word reply")
        h.start()
        let id = try newAgent(h)
        try h.activate(id)
        #expect(h.providers.launchRequests.last?.namedByUser == false)
        let surface = try #require(h.host.surfaces[id])
        try h.osc(id, "state=idle:app=claude-code")

        // The capture's titles, in order (`cli-facts.md`, flows 2 capture).
        surface.title.send("agent 1")
        surface.title.send("Claude Code")
        surface.title.send("claude · resume")
        #expect(try h.agent(id).name == "agent 1")
        surface.title.send("✳ Single word reply")
        #expect(try h.agent(id).name == "Single word reply 2")
        #expect(h.config.project(forAgent: id)?.agents.first { $0.id == id }?.name == "Single word reply 2")

        // Kept for the next start, and still Clawddy's.
        try h.restart()
        #expect(try h.agent(id).name == "Single word reply 2")
        #expect(try h.agent(id).autoNamed)

        // The person's name is never replaced, and Claude is given it.
        try h.activate(id)
        #expect(h.config.renameAgent(id: id, newName: "login fix"))
        h.bridge.renameAgent(id: id, newName: "login fix")
        #expect(try !h.agent(id).autoNamed)
        try h.osc(id, "state=idle:app=claude-code")
        try #require(h.host.surfaces[id]).title.send("Something else")
        #expect(try h.agent(id).name == "login fix")
        try h.restart()
        #expect(try !h.agent(id).autoNamed)
        try h.activate(id)
        #expect(h.providers.launchRequests.last?.namedByUser == true)
    }

    /// What a terminal title gives as a name.
    @Test func aTitleIsCleanedIntoAName() {
        let folder = "/Users/example/projects/work"
        #expect(AgentConversationTitle.name(from: "Claude Code", folder: folder) == nil)
        #expect(AgentConversationTitle.name(from: "claude · resume", folder: folder) == nil)
        #expect(AgentConversationTitle.name(from: "✳ Single word reply", folder: folder) == "Single word reply")
        #expect(AgentConversationTitle.name(from: "◐ Claude Code", folder: folder) == nil)
        #expect(AgentConversationTitle.name(from: "👻", folder: folder) == nil)
        // Ghostty's own title once Claude clears its own at exit.
        #expect(AgentConversationTitle.name(from: folder, folder: folder) == nil)
        #expect(AgentConversationTitle.name(from: "~/projects/work", folder: folder) == nil)
        #expect(AgentConversationTitle.name(from: "", folder: folder) == nil)
        #expect(AgentConversationTitle.name(from: "⠙ work", folder: folder) == nil)
        #expect(AgentConversationTitle.name(from: "Reply ok | work", folder: folder) == "Reply ok")
        #expect(AgentConversationTitle.name(from: "Claude settings migration", folder: folder)
            == "Claude settings migration")
        let long = AgentConversationTitle.name(
            from: "Investigate the flaky renderer tests on the CI machines", folder: folder)
        #expect(long == "Investigate the flaky renderer tests on…")
        #expect(long?.count == 40)
    }

    /// What "New agent" creates, as `ClawddyController.newAgent` does.
    private func newAgent(_ h: AgentBridgeHarness) throws -> UUID {
        let project = try #require(h.config.projects.first)
        return try #require(h.bridge.createAgent(
            name: AgentNames.free("agent 1", among: project.agents),
            provider: Self.defaults.provider,
            launchProfile: Self.defaults.launchProfile,
            config: h.config,
            project: project.name,
            nameSource: .app)).id
    }
}
