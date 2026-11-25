import Foundation
import Testing
import UserNotifications
@testable import Ghostty

/// An agent is never closed (`docs/clawddy-design/flows.md` 2.2, 4.5, 6.14):
/// showing it starts nothing, a stop the person chose holds, an unexpected
/// stop is a problem, and a quit continues the turns it cut off.
@MainActor
struct AgentFlowsTests {
    // MARK: Passing through starts nothing (flows.md 4.5)

    /// Entering agents one after another, without typing, starts none of
    /// them, however long each is shown: only a deliberate open or a key
    /// typed into its terminal starts a CLI.
    @Test func showingAnAgentStartsNothing() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let first = try h.addAgent("first")
        let second = try h.addAgent("second")
        h.start()

        h.view(first)
        h.scheduler.advance(by: 2)
        h.view(second)
        h.scheduler.advance(by: 2)

        #expect(h.providers.launchRequests.isEmpty)
        #expect(h.workspace.shownAgentID == second)
    }

    /// An agent the person stopped, by exiting its provider, choosing "Stop
    /// agent" or closing its terminal, stays stopped while it is shown and
    /// when it is shown again; opening it resumes its conversation.
    @Test func aStopThePersonChoseHolds() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("agent")
        let other = try h.addAgent("other")
        h.start()
        h.view(id)
        try h.launch(id)
        let agent = try h.agent(id)

        func expectHeld() {
            #expect(agent.runtime.stoppedOnPurpose)
            #expect(agent.terminal == .notRunning)
            h.view(other)
            h.view(id)
            let launches = h.providers.launchRequests.count
            h.scheduler.advance(by: 5)
            #expect(h.providers.launchRequests.count == launches)
        }
        func open() throws {
            try h.activate(id)
            #expect(agent.terminal == .starting)
            #expect(h.providers.launchRequests.last?.session?.sessionID == "session-1")
            try h.osc(id, "state=idle:app=claude-code")
        }

        // `/exit`: status 0, then the launch script ends and its terminal
        // closes.
        try h.providerQuit(id, status: 0)
        #expect(!h.host.hasSurface(id: id))
        expectHeld()
        try open()

        // Closing its terminal while it runs, once the person agrees.
        h.bridge.surfaceClosed(id: id, generation: try h.generation(id), processAlive: true)
        #expect(h.host.calls.last == .confirmClose(id))
        h.host.answerClose(confirmed: true)
        expectHeld()
        try h.activate(id)
        #expect(agent.terminal == .starting)
        #expect(!agent.runtime.stoppedOnPurpose)
        #expect(h.notifier.posted.isEmpty)
    }

    // MARK: Flow 7: an agent dies

    /// An unexpected stop is a problem with the app's sentence, notified
    /// once; nothing restarts it by itself (`docs/clawddy-design/flows.md`
    /// 2.2). Opening it does.
    @Test func anUnexpectedStopIsAProblem() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("agent")
        h.start()
        try h.launch(id)
        let agent = try h.agent(id)

        // A crash: the provider exits with status 1 and its terminal closes.
        try h.providerQuit(id, status: 1)
        #expect(h.providers.launchRequests.count == 1)
        #expect(agent.shownState == .problem)
        #expect(agent.sentence == .app("Claude Code stopped (status 1). Type here to continue."))
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).error"])
        #expect(h.notifier.posted.first?.content.body == "Claude Code stopped (status 1). Type here to continue.")

        // Showing it does not bring it back; opening it does, resuming it.
        h.view(id)
        h.scheduler.advance(by: 1)
        #expect(h.providers.launchRequests.count == 1)
        try h.activate(id)
        #expect(h.providers.launchRequests.count == 2)
        #expect(h.providers.launchRequests.last?.session?.sessionID == "session-1")

        // Its terminal closes under it, with no exit report.
        try h.osc(id, "state=idle:app=claude-code")
        try h.terminalClosed(id)
        #expect(agent.record.problem == AgentRecord.Problem(kind: .exited))
        #expect(h.providers.launchRequests.count == 2)
    }

    /// A stop of an agent that is not selected never takes the selection,
    /// and nothing restarts it.
    @Test func aRestartNeverTakesTheSelection() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let background = try h.addAgent("background")
        let selected = try h.addAgent("selected")
        h.start()
        try h.launch(background)
        try h.launch(selected)
        h.view(selected)

        try h.providerQuit(background, status: 1)

        #expect(h.providers.launchRequests.count == 2)
        #expect(h.workspace.shownAgentID == selected)
        #expect(try h.agent(background).record.problem == AgentRecord.Problem(kind: .exited, status: 1))
    }

    // MARK: Flow 1: opening Clawddy

    /// Agents a quit cut off mid-turn continue by themselves (flows.md
    /// 6.14): the selected one first, then the configuration's order, at most
    /// three starting at a time, each when one before it reads its input or
    /// has failed. Each resumes its conversation with the continuation as
    /// its first prompt, marked as the app's, after the dim notice; agents
    /// that were finished or at their prompt start nothing. The selection
    /// does not move.
    @Test func cutOffAgentsContinueThreeAtATime() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let ids = try ["a", "b", "c", "d", "e"].map { try h.addAgent($0) }
        let finished = try h.addAgent("finished")
        let ready = try h.addAgent("ready")
        h.start()
        for id in ids { try h.launch(id); try h.startTurn(id) }
        try h.launch(finished)
        try h.completeTurn(finished)
        try h.launch(ready)
        let before = h.providers.launchRequests.count

        try h.restart()
        h.view(ids[3])
        h.bridge.continueCutOffAgents(selected: ids[3], host: h.host)
        func started() -> [UUID] { h.providers.launchRequests.dropFirst(before).map(\.agentID) }
        #expect(started() == [ids[3], ids[0], ids[1]])
        for request in h.providers.launchRequests.dropFirst(before) {
            #expect(request.firstPrompt == AgentBridge.continueMessage)
            #expect(request.notice == AgentBridge.continueNotice)
        }
        let continued = try h.agent(ids[0])
        #expect(continued.record.state == .working && continued.record.cutOff && continued.record.continuedInARow == 1)
        #expect(continued.record.prompts.last?.text == AgentBridge.continueMessage)
        #expect(continued.record.prompts.last?.by == .app)
        #expect(continued.record.sentence(cli: "Claude Code") == .app("Continuing after a restart (1 of 3)"))

        // Launched with a prompt, a CLI reads its input at its first working.
        try h.osc(ids[0], "state=working:app=claude-code")
        h.scheduler.advance(by: 0)
        #expect(started() == [ids[3], ids[0], ids[1], ids[2]])
        try h.providerExited(ids[1], status: 1)
        h.scheduler.advance(by: 0)
        #expect(started() == [ids[3], ids[0], ids[1], ids[2], ids[4]])
        h.scheduler.advance(by: 60)
        #expect(!started().contains(finished) && !started().contains(ready))
        #expect(h.workspace.shownAgentID == ids[3])

        // The CLI's own report of the continuation is not a second prompt.
        try h.hook(ids[0], "UserPromptSubmit", text: AgentBridge.continueMessage)
        #expect(continued.record.prompts.filter { $0.text == AgentBridge.continueMessage }.count == 1)
        // A finished turn ends the story.
        try h.osc(ids[0], "state=done:app=claude-code")
        #expect(continued.record.state == .finished && !continued.record.cutOff && continued.record.continuedInARow == 0)
    }

    /// A turn under way when Clawddy quits is cut off: the agent comes back
    /// with its record saying so; an agent at its prompt has no mark. A crash
    /// or a kill does the same: the record was written with each change.
    @Test func aQuitOrACrashCutsOffTheTurn() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let busy = try h.addAgent("busy")
        let ready = try h.addAgent("ready")
        h.start()
        try h.launch(busy)
        try h.launch(ready)
        try h.startTurn(busy)
        #expect(h.bridge.quitNotice
            == "1 agent is working. It stops now and continues by itself when Clawddy opens again.")

        try h.restart()
        #expect(try h.agent(busy).record.cutOff)
        #expect(try h.agent(ready).terminal == .notRunning)
        #expect(try AgentRecord.load(busy, from: h.root.statusDir)?.cutOff == true)
        #expect(try AgentRecord.load(ready, from: h.root.statusDir)?.cutOff != true)

        h.bridge.continueCutOffAgents(selected: nil, host: h.host)
        try h.osc(busy, "state=working:app=claude-code")
        try h.restart()
        let agent = try h.agent(busy)
        #expect(agent.record.cutOff && agent.record.continuedInARow == 1)
        let before = h.providers.launchRequests.count
        h.bridge.continueCutOffAgents(selected: nil, host: h.host)
        #expect(h.providers.launchRequests.dropFirst(before).map(\.agentID) == [busy])
        #expect(agent.record.sentence(cli: "Claude Code") == .app("Continuing after a restart (2 of 3)"))
        #expect(h.notifier.posted.isEmpty)
    }

    /// Three continuations in a row without a finished turn; the fourth is
    /// not sent, and the agent stops and asks (words.md). A prompt of the
    /// person's starts the count again.
    @Test func aFourthContinuationInARowStops() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("agent")
        h.start()
        try h.launch(id)
        try h.startTurn(id)
        for count in 1...3 {
            try h.restart()
            h.bridge.continueCutOffAgents(selected: nil, host: h.host)
            #expect(try h.agent(id).record.continuedInARow == count)
            try h.osc(id, "state=working:app=claude-code")
        }
        try h.restart()
        let before = h.providers.launchRequests.count
        h.bridge.continueCutOffAgents(selected: nil, host: h.host)
        #expect(h.providers.launchRequests.count == before)
        let agent = try h.agent(id)
        #expect(agent.record.problem == AgentRecord.Problem(kind: .cutOffTooOften))
        #expect(agent.record.sentence(cli: "Claude Code")
            == .app("Cut off by three restarts. Open it to continue."))
        #expect(agent.record.isWaitingOnYou)

        try h.activate(id)
        try h.osc(id, "state=idle:app=claude-code")
        try h.hook(id, "UserPromptSubmit", text: "go on")
        try h.startTurn(id)
        #expect(agent.record.continuedInARow == 0 && agent.record.problem == nil)
    }

    /// A conversation live in another terminal is never resumed: the agent
    /// A settled agent is never continued: settled while working, its turn
    /// ends, interrupted, at the next start, and the quit does not count it.
    @Test func aSettledWorkingAgentIsNotContinued() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let settled = try h.addAgent("settled")
        let busy = try h.addAgent("busy")
        h.start()
        for id in [settled, busy] { try h.launch(id); try h.startTurn(id) }
        h.bridge.settle(id: settled, includingWorking: true)
        #expect(h.bridge.quitNotice
            == "1 agent is working. It stops now and continues by itself when Clawddy opens again.")
        try h.restart()
        let before = h.providers.launchRequests.count
        #expect(h.bridge.continueCutOffAgents(selected: nil, host: h.host) == 1)
        #expect(h.providers.launchRequests.dropFirst(before).map(\.agentID) == [busy])
        let agent = try h.agent(settled)
        #expect(agent.record.state == .finished && agent.record.interrupted && !agent.record.cutOff)
        #expect(agent.record.settledAt != nil)
    }

    /// Cut off before its CLI had a conversation (Codex binds one at its first
    /// turn's end), an agent starts fresh with its first instruction, labelled
    /// as the app's, counting toward the three. A continuation is recorded
    /// when its CLI is started with it: a launch that fails records none.
    @Test func aSessionlessCutOffAgentStartsAgainFromItsInstruction() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let codex = try h.addAgent("codex", provider: .codex)
        let failing = try h.addAgent("failing")
        let blank = try h.addAgent("blank", provider: .codex)
        h.start()
        try h.activate(codex)
        try h.osc(codex, "state=idle:app=codex")
        h.scheduler.advance(by: 3)
        h.host.screens[codex] = Self.screen("›  Ask Codex to do anything")
        var sent: AgentSendResult?
        h.bridge.send("make the export work offline", to: codex, by: .person) { sent = $0 }
        #expect(sent == .sent)
        try h.launch(failing)
        try h.startTurn(failing)
        try h.activate(blank)
        try h.osc(blank, "state=idle:app=codex")
        try h.osc(blank, "state=working:app=codex")
        h.scheduler.advance(by: 3)
        try h.restart()

        h.providers.prepareLaunch = { request in
            request.agentID == failing ? .failure(.sessionOpenElsewhere(.claudeCode, "session-1"))
                : .success(AgentPreparedLaunch(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:],
                    metadataAvailability: .waiting))
        }
        let before = h.providers.launchRequests.count
        h.bridge.continueCutOffAgents(selected: nil, host: h.host)
        let requests = Array(h.providers.launchRequests.dropFirst(before))
        let fresh = try #require(requests.first { $0.agentID == codex })
        #expect(fresh.session == nil)
        #expect(fresh.firstPrompt == AgentBridge.restartLabel + " make the export work offline")
        let agent = try h.agent(codex)
        #expect(agent.record.prompts.last?.text == fresh.firstPrompt && agent.record.prompts.last?.by == .app)
        #expect(agent.record.continuedInARow == 1 && agent.record.cutOff)

        let failed = try h.agent(failing)
        #expect(failed.record.problem == AgentRecord.Problem(kind: .openElsewhere))
        #expect(!failed.record.prompts.contains { $0.by == .app } && failed.record.continuedInARow == 0)

        // No conversation and no instruction: its turn is over.
        #expect(!requests.contains { $0.agentID == blank })
        #expect(try h.agent(blank).record.state == .finished && h.agent(blank).record.interrupted)
    }

    /// An `idle` with no turn under way leaves working, except the start-up
    /// `idle` of a launch given a prompt, before that prompt's turn.
    @Test func anIdleWithoutATurnLeavesWorking() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        h.start()
        let project = try #require(h.config.projects.first)
        let entry = try #require(h.bridge.startAgent(
            task: "tidy", provider: .claudeCode, launchProfile: AgentLaunchProfile(),
            config: h.config, project: project, host: h.host))
        let agent = try h.agent(entry.id)
        try h.osc(entry.id, "state=idle:app=claude-code")
        #expect(agent.record.state == .working)
        try h.osc(entry.id, "state=idle:app=claude-code")
        #expect(agent.record.state == .finished && !agent.record.interrupted)
        try h.osc(entry.id, "state=clear:app=claude-code")
        #expect(agent.record.state == .finished)
    }

    private static func screen(_ input: String) -> String {
        ["• Done.", "", input, "  gpt · ~/work"].joined(separator: "\n")
    }

    /// stops with the words.md problem, and the next launch tries again.
    @Test func aConversationOpenElsewhereIsNotResumed() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("agent")
        h.start()
        h.providers.prepareLaunch = { _ in .failure(.sessionOpenElsewhere(.claudeCode, "s-1")) }
        try h.activate(id)
        let agent = try h.agent(id)
        #expect(agent.record.problem == AgentRecord.Problem(kind: .openElsewhere))
        #expect(agent.record.sentence(cli: "Claude Code")
            == .app("Open in another terminal. Close it there to continue."))
        h.providers.prepareLaunch = { _ in
            .success(AgentPreparedLaunch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:],
                metadataAvailability: .waiting))
        }
        try h.activate(id)
        #expect(agent.record.problem == nil)
    }

    // MARK: Flow 8: continuing an earlier conversation

    /// An agent's last screen, kept when its CLI ends or the app quits, is
    /// what its tile shows while it does not run: written 0600 beside its
    /// record and read again at the next start (flows.md 4.1).
    @Test func theLastScreenIsKeptForTheNextStart() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("agent")
        h.start()
        h.bridge.saveScreen("⏺ Read(a)\n  ⎿  9 lines\n", of: id)

        try h.restart()
        #expect(try h.agent(id).savedScreen == "⏺ Read(a)\n  ⎿  9 lines\n")
        let file = AgentTail.savedScreenURL(id, h.root.statusDir)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
