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

    /// Right: nothing is typed into a terminal whose provider has exited; Claude takes the new name as `--name` at its next launch (P3.6).
    @Test func knownWrong_renameTypedIntoFallbackShellAfterExit() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")
        try h.hook(id, "Stop")
        try h.providerExited(id, status: 0)
        let agent = try h.agent(id)
        #expect(agent.processState == .exited)
        #expect(agent.displayState == .finished)

        h.bridge.requestRename(id: id, newName: "Renamed")

        #expect(h.sentText == [SentText(id: id, text: "/rename Renamed\n")])
    }

    /// Right: closing an agent terminal whose process is alive asks first (P3.3).
    @Test func knownWrong_closeWithLiveProcessDestroysWithoutConfirmation() async throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let surface = try #require(h.host.surfaces[id])
        let agent = try h.agent(id)

        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: surface,
            userInfo: ["process_alive": true])

        // The close reaches the bridge through a main-actor task, so nothing
        // has changed when the post returns.
        #expect(agent.surfaceState == .open)
        await yieldToMainActor(until: { agent.surfaceState == .closed })
        #expect(agent.displayState == .dead)
        #expect(h.surfaceDeaths == [id])
        #expect(h.host.calls.last == .remove(id))
    }

    /// Right: an undecodable record is logged with its offset (P3.9).
    @Test func knownWrong_undecodableRecordDroppedSilently() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let before = h.diagnostics.messages

        try h.append(id, h.record("UserPromptSubmit", generation: try h.generation(id))
            .replacingOccurrences(of: #""provider":"claudeCode""#, with: #""provider":"""#))
        h.poll()

        #expect(try h.agent(id).displayState == .idle)
        #expect(h.diagnostics.messages == before)
        let offset = try h.persisted("eventOffsets")[id] as? Int
        #expect(offset == (try h.size(h.statusFile(id, "events"))))
    }

    /// Right: an unreadable state file is an error the user sees, and is not replaced (P3.9).
    @Test func knownWrong_corruptStateFileStartsEmpty() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")
        try h.hook(id, "Stop")
        let reported = h.diagnostics.messages.count

        try h.restart {
            let data = try Data(contentsOf: h.root.stateFile)
            try data.prefix(data.count / 2).write(to: h.root.stateFile)
        }

        let agent = try h.agent(id)
        #expect(agent.unreadCompletion == nil)
        #expect(agent.displayState == .inactive)
        #expect(h.diagnostics.messages.dropFirst(reported).allSatisfy { $0.hasPrefix("started") })
        // The next save replaces the unreadable file.
        h.config.load()
        #expect(try h.persisted("unreadCompletions").isEmpty)
    }

    /// Right: a corrupt preferences file falls back to standard mode and shows the error (P3.9).
    @Test func knownWrong_corruptPreferencesAreUnrestricted() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let url = h.root.preferencesFile
        try AgentPreferencesStore.save(
            AgentPreferences(claudeCodeDefaultStartMode: .standard, codexDefaultStartMode: .standard),
            to: url)
        #expect(AgentPreferencesStore.load(from: url).defaultStartMode(for: .claudeCode) == .standard)

        let data = try Data(contentsOf: url)
        try data.prefix(data.count - 2).write(to: url)

        let loaded = AgentPreferencesStore.load(from: url)
        #expect(loaded == AgentPreferences())
        #expect(loaded.defaultStartMode(for: .claudeCode) == .unrestricted)
        #expect(loaded.defaultStartMode(for: .codex) == .unrestricted)
    }

    /// Right: an unreadable binding is an explicit failed state, not a fresh session (P3.9).
    @Test func knownWrong_corruptBindingLaunchesFresh() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        try Data(#"{"provider":"claudeCode","sessionID":"session-"#.utf8)
            .write(to: h.statusFile(id, "session.json"))
        h.start()

        try h.activate(id)

        let request = try #require(h.providers.launchRequests.first)
        #expect(request.session == nil)
        #expect(request.pendingFork == nil)
        #expect(try h.agent(id).displayState == .launching)
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

    /// Right: the bridge publishes its aggregate state at start (P3.1).
    @Test func knownWrong_aggregateNotPublishedAtStartup() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")
        try h.hook(id, "Stop")

        try h.restart()

        #expect(h.bridge.aggregateState == .attention)
        #expect(h.aggregateChanges.isEmpty)
    }

    /// Right: a field the hook payload did not carry is absent, so the turn ID is nil (P3.9).
    @Test func knownWrong_emptyTurnIDKeptAsEmptyString() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)

        try h.hook(id, "UserPromptSubmit", turn: "")
        let agent = try h.agent(id)
        #expect(agent.turnState == .active(turnID: ""))

        try h.hook(id, "Stop", turn: "")
        #expect(agent.unreadCompletion?.turnID == "")
        #expect(agent.lastAppliedCompletion?.turnID == "")
        #expect(agent.metadata?.modelID == "")
        #expect(agent.metadata?.permissionMode == "")
    }

    /// Right: a host that refuses to present leaves the agent in a failed-to-start state (P3.2).
    @Test func knownWrong_hostRefusingPresentLeavesAgentLaunching() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.host.refusesPresent = true

        try h.activate(id)

        let agent = try h.agent(id)
        #expect(h.host.calls == [.select(id), .present(id)])
        #expect(agent.displayState == .launching)
        #expect(agent.surfaceState == .opening)
        #expect(agent.processState == .launching)
        #expect(try h.launchScripts().isEmpty)
        #expect(h.presentationChanges.isEmpty)
        // The launch timeout still fires, but a surface that is still opening
        // shows as starting whatever the telemetry says, so it stays so.
        h.scheduler.advance(by: 10)
        #expect(agent.telemetryHealth == .unavailable(
            "The terminal is running, but agent activity status is unavailable."))
        #expect(agent.displayState == .launching)
    }
}
