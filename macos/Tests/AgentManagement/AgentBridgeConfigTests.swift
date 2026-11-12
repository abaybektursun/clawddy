import Foundation
import Testing
@testable import Ghostty

/// Characterization of how `AgentBridge` follows external edits of
/// `agents.json` and restores its state at the next start, as the code
/// behaves after Phase 0.
@MainActor
struct AgentBridgeConfigTests {
    @Test func externalAddCreatesRuntime() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        try h.addAgent("Agent")
        h.start()
        let added = AgentEntry(name: "Added", provider: .codex)

        try h.editConfigExternally { $0.append(added) }

        let agent = try h.agent(added.id)
        #expect(agent.provider == .codex)
        #expect(agent.displayState == .inactive)
        #expect(h.bridge.agents.count == 2)
    }

    @Test func externalDeleteRemovesRuntime() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let other = try h.addAgent("Other")
        h.start()
        try h.activate(id)

        try h.editConfigExternally { $0.removeAll { $0.id == id } }

        #expect(h.bridge.agents[id] == nil)
        #expect(h.bridge.agents[other] != nil)
        #expect(h.surfaceDeaths == [id])
        #expect(h.host.calls.last == .remove(id))
        #expect(h.providers.cleanups == [id])
        #expect(try h.launchScripts().isEmpty)
    }

    /// A bound agent's provider is restored by `AgentConfig.load`, which
    /// saves the file again, before the bridge sees the edit.
    @Test func providerChangeOnBoundAgentIsReverted() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.editConfigExternally { $0[0] = AgentEntry(id: id, name: "Agent", provider: .codex) }

        #expect(h.config.allAgentEntries.first?.provider == .claudeCode)
        let saved = try JSONDecoder().decode(
            AgentConfigFile.self,
            from: Data(contentsOf: h.root.agentsFile))
        #expect(saved.projects.first?.tasks.first?.agents.first?.provider == .claudeCode)
        #expect(try h.agent(id) === agent)
        #expect(agent.provider == .claudeCode)
        #expect(!h.diagnostics.messages.contains { $0.hasPrefix("rejected provider change") })
    }

    /// An agent that is running but has no binding yet keeps its provider
    /// because the bridge restores the config entry.
    @Test func providerChangeOnActiveAgentIsRevertedByBridge() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.activate(id)

        try h.editConfigExternally { $0[0] = AgentEntry(id: id, name: "Agent", provider: .codex) }

        #expect(h.diagnostics.messages.contains(
            "rejected provider change for bound or active agent \(id)"))
        #expect(h.config.allAgentEntries.first?.provider == .claudeCode)
        let saved = try JSONDecoder().decode(
            AgentConfigFile.self,
            from: Data(contentsOf: h.root.agentsFile))
        #expect(saved.projects.first?.tasks.first?.agents.first?.provider == .claudeCode)
        #expect(try h.agent(id).provider == .claudeCode)
    }

    @Test func providerChangeOnNeverLaunchedAgentReplacesRuntime() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        let before = try h.agent(id)

        try h.editConfigExternally { $0[0] = AgentEntry(id: id, name: "Agent", provider: .codex) }

        let after = try h.agent(id)
        #expect(after !== before)
        #expect(after.provider == .codex)
        #expect(h.config.allAgentEntries.first?.provider == .codex)
    }

    @Test func persistedUnreadSurvivesRestart() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")
        try h.hook(id, "Stop")
        let unread = try #require(try h.agent(id).unreadCompletion)

        try h.restart()

        let agent = try h.agent(id)
        #expect(agent.unreadCompletion == unread)
        #expect(agent.lastAppliedCompletion == unread)
        #expect(agent.surfaceState == .inactive)
        #expect(agent.displayState == .finished)
    }
}
