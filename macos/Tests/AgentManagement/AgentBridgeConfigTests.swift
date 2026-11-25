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
        #expect(agent.terminal == .notRunning)
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
        h.config.waitForWrites()
        let saved = try JSONDecoder().decode(
            AgentConfigFile.self,
            from: Data(contentsOf: h.root.agentsFile))
        #expect(saved.projects.first?.agents.first?.provider == .claudeCode)
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
        h.config.waitForWrites()
        let saved = try JSONDecoder().decode(
            AgentConfigFile.self,
            from: Data(contentsOf: h.root.agentsFile))
        #expect(saved.projects.first?.agents.first?.provider == .claudeCode)
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
        try h.completeTurn(id)

        try h.restart()

        let agent = try h.agent(id)
        #expect(agent.record.unread)
        #expect(agent.surfaceState == .inactive)
        #expect(agent.shownState == .finishedUnread)
    }

    /// A run whose configuration does not load, being of a newer schema or
    /// unreadable, knows no agents, so it writes nothing under the data
    /// root, at quit neither: the unread marks stay as the last run saved
    /// them. Once the configuration loads, each agent has its mark back.
    @Test func aConfigurationThatDoesNotLoadKeepsTheUnreadMarks() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.completeTurn(id)
        let record = AgentRecord.url(id, h.root.statusDir)
        h.config.waitForWrites()
        let readable = try Data(contentsOf: h.root.agentsFile)
        let newer = try #require(String(data: readable, encoding: .utf8))
            .replacingOccurrences(of: #""schemaVersion" : 6"#, with: #""schemaVersion" : 7"#)
        try #require(newer.contains(#""schemaVersion" : 7"#))

        for unreadable in [newer, "{"] {
            try h.restart { try Data(unreadable.utf8).write(to: h.root.agentsFile) }
            #expect(!h.config.isLoaded)
            #expect(h.bridge.agents.isEmpty)
            let state = try Data(contentsOf: record)
            let dates = try FileManager.default.attributesOfItem(atPath: record.path)[.modificationDate] as? Date
            h.bridge.shutdown()
            #expect(try Data(contentsOf: record) == state)
            #expect(try FileManager.default.attributesOfItem(atPath: record.path)[.modificationDate] as? Date == dates)
            #expect(try AgentRecord.load(id, from: h.root.statusDir)?.unread == true)
        }

        try h.restart { try Data("{".utf8).write(to: h.root.agentsFile) }
        try readable.write(to: h.root.agentsFile)
        h.config.load()
        #expect(try h.agent(id).record.unread)
        #expect(try h.agent(id).shownState == .finishedUnread)
        #expect(try h.recordedUnread() == [id])
    }
}
