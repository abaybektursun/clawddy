import Foundation
import Testing
@testable import Ghostty

/// Behaviour of today's code that is wrong, pinned on purpose. Each test
/// asserts the wrong result and says, in the line above it, what the right
/// behaviour will be; the Phase 3 step that fixes it flips the assertion.
@MainActor
struct AgentBridgeKnownWrongTests {
    /// Right: a session started inside the agent's terminal (here a nested Codex, which inherits the CLAWDDY_* identity) neither ends the agent's turn nor replaces its binding.
    @Test func knownWrong_nestedSessionStartResetsActiveTurnAndRebinds() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .codex)
        h.start()
        try h.launch(id, session: "parent-session")
        try h.hook(id, "UserPromptSubmit", session: "parent-session")

        try h.hook(id, "SessionStart", session: "nested-session")

        let agent = try h.agent(id)
        #expect(agent.displayState == .idle)
        #expect(agent.turnState == .inactive)
        #expect(agent.sessionID == "nested-session")
        #expect(try h.binding(id).sessionID == "nested-session")
    }

    /// Right: every removal route deletes the agent's `<uuid>.*` status files (P3.10).
    @Test func knownWrong_externalDeleteLeavesStatusFiles() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let other = try h.addAgent("Other")
        h.start()
        try h.launch(id)
        try h.launch(other)

        try h.editConfigExternally { $0.removeAll { $0.id == id } }

        #expect(h.bridge.agents[id] == nil)
        #expect(h.exists(h.statusFile(id, "events")))
        #expect(h.exists(h.statusFile(id, "session.json")))
        // Deleting through the bridge does remove them.
        #expect(h.bridge.deleteAgent(id: other, config: h.config))
        #expect(!h.exists(h.statusFile(other, "events")))
        #expect(!h.exists(h.statusFile(other, "session.json")))
    }
}
