import Combine
import Foundation
import Testing
import UserNotifications
@testable import Ghostty

/// Characterization of how `AgentBridge` launches agents, ends them, and
/// filters the records it reads, as the code behaves after Phase 0.
@MainActor
struct AgentBridgeLifecycleTests {
    @Test func launchShowsStartingAndPresentsOneSurface() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()

        try h.activate(id)

        let agent = try h.agent(id)
        #expect(agent.displayState == .launching)
        #expect(agent.displayState.label == "Starting")
        #expect(agent.surfaceState == .open)
        #expect(agent.processState == .launching)
        #expect(agent.telemetryHealth == .awaiting)
        #expect(h.host.calls == [.select(id), .present(id)])
        #expect(h.host.surfaces.count == 1)
        #expect(h.presentationChanges == [id])
        #expect(h.providers.launchRequests.count == 1)
        let request = try #require(h.providers.launchRequests.first)
        #expect(request.launchGeneration == agent.launchGeneration)
        #expect(request.environmentPath == h.binFolder.path)
        #expect(request.session == nil)
        #expect(request.pendingFork == nil)
        // The terminal runs the launch script, which waits in the root's
        // launch folder until the provider is seen alive.
        let command = try #require(h.host.surfaces[id]?.configuration.command)
        #expect(command.hasPrefix(h.root.launchDir.path + "/"))
        #expect(try h.launchScripts() == [URL(fileURLWithPath: command).lastPathComponent])
        // Start publishes the idle aggregate state; starting a launch
        // publishes none.
        #expect(h.aggregateChanges == [.idle])
    }

    /// Flipped from `knownWrong_aggregateNotPublishedAtStartup` (P3.1): a
    /// relaunch with an unread completion publishes attention at start,
    /// before any event arrives.
    @Test func aggregatePublishedAtStartup() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")
        try h.hook(id, "Stop")

        try h.restart()

        #expect(h.bridge.aggregateState == .attention)
        #expect(h.aggregateChanges == [.attention])
    }

    @Test func secondActivationDuringPreparationStartsNothing() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()

        h.io.hold()
        try h.activate(id)
        try h.activate(id)
        #expect(h.host.calls == [.select(id), .select(id)])
        #expect(h.providers.launchRequests.isEmpty)

        h.io.release()
        #expect(h.providers.launchRequests.count == 1)
        #expect(h.host.calls == [.select(id), .select(id), .present(id)])
        #expect(h.host.surfaces.count == 1)
        #expect(try h.launchScripts().count == 1)
    }

    @Test func noHookFor10sIsStatusUnavailable() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.activate(id)
        let agent = try h.agent(id)

        h.scheduler.advance(by: 9.9)
        #expect(agent.displayState == .launching)

        h.scheduler.advance(by: 0.2)
        #expect(agent.displayState == .statusUnavailable)
        #expect(agent.telemetryHealth == .unavailable(
            "The terminal is running, but agent activity status is unavailable."))
        #expect(agent.processState == .launching)
        #expect(h.aggregateChanges == [.idle])
        #expect(h.notifier.posted.isEmpty)
    }

    @Test func sessionStartIsReadyRemovesScriptWritesBinding() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.activate(id)
        #expect(try h.launchScripts().count == 1)

        try h.hook(id, "SessionStart", session: "session-1")

        let agent = try h.agent(id)
        #expect(agent.displayState == .idle)
        #expect(agent.displayState.label == "Ready")
        #expect(agent.processState == .running)
        #expect(agent.telemetryHealth == .live)
        #expect(agent.sessionID == "session-1")
        #expect(try h.launchScripts().isEmpty)
        #expect(try h.binding(id) == AgentSessionBinding(
            provider: .claudeCode,
            sessionID: "session-1",
            launchGeneration: agent.launchGeneration))
        #expect(h.aggregateChanges == [.idle])

        h.scheduler.advance(by: 11)
        #expect(agent.displayState == .idle)
    }

    @Test func missingExecutableIsCouldntStart() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        // The real Claude launch, on a PATH that has no `claude`.
        h.providers.prepareLaunch = h.providers.real.prepareLaunch

        try h.activate(id)

        let agent = try h.agent(id)
        #expect(agent.displayState == .failed)
        #expect(agent.displayState.label == "Couldn't Start")
        #expect(agent.failureMessage
            == AgentProviderIssue.executableMissing(.claudeCode).localizedDescription)
        #expect(agent.surfaceState == .failed)
        #expect(agent.processState == .exited)
        #expect(h.host.calls == [.select(id)])
        #expect(try h.launchScripts().isEmpty)
        // The failure raises the aggregate state from the idle one published
        // at start, but posts no notification.
        #expect(h.aggregateChanges == [.idle, .attention])
        #expect(h.notifier.posted.isEmpty)

        h.scheduler.advance(by: 11)
        #expect(agent.displayState == .failed)
    }

    /// Flipped from `knownWrong_hostRefusingPresentLeavesAgentLaunching`
    /// (P3.2): with no terminal to run the launch, the agent couldn't start,
    /// and the launch timeout changes nothing afterwards.
    @Test func hostRefusingPresentLeavesAgentFailedToStart() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.host.refusesPresent = true

        try h.activate(id)

        let agent = try h.agent(id)
        #expect(h.host.calls == [.select(id), .present(id)])
        #expect(agent.displayState == .failed)
        #expect(agent.failureMessage == "The agent's terminal could not be opened.")
        #expect(agent.surfaceState == .failed)
        #expect(agent.processState == .exited)
        #expect(try h.launchScripts().isEmpty)
        #expect(h.presentationChanges.isEmpty)
        #expect(h.aggregateChanges == [.idle, .attention])
        #expect(h.notifier.posted.isEmpty)
        h.scheduler.advance(by: 10)
        #expect(agent.displayState == .failed)
        #expect(agent.telemetryHealth == .awaiting)
    }

    @Test func providerExitBeforeSessionStartIsStartFailure() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.activate(id)

        try h.providerExited(id, status: 127)

        let agent = try h.agent(id)
        #expect(agent.displayState == .failed)
        #expect(agent.failureMessage
            == "The provider exited before the agent session started (status 127).")
        #expect(agent.processState == .exited)
        // The login shell the launch script falls back to keeps the surface.
        #expect(agent.surfaceState == .open)
        #expect(h.host.hasSurface(id: id))
        #expect(try h.launchScripts().isEmpty)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).error"])
        #expect(h.notifier.posted.first?.content.interruptionLevel == .active)
        #expect(h.aggregateChanges == [.idle, .attention])
    }

    @Test func forkLaunchUsesPendingForkAndClearsItOnSessionStart() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let sourceID = try h.addAgent("Source")
        h.start()
        try h.launch(sourceID, session: "source-session")

        let fork = try #require(h.bridge.forkAgent(
            sourceId: sourceID,
            config: h.config,
            project: AgentBridgeHarness.projectName,
            task: AgentBridgeHarness.taskName))
        #expect(fork.name == "Source-fork")
        #expect(h.exists(h.statusFile(fork.id, "fork.json")))

        try h.activate(fork.id)
        let request = try #require(h.providers.launchRequests.last)
        #expect(request.agentID == fork.id)
        #expect(request.pendingFork == AgentPendingFork(
            provider: .claudeCode,
            sourceSessionID: "source-session"))
        #expect(request.session == nil)

        try h.hook(fork.id, "SessionStart", session: "fork-session")
        #expect(!h.exists(h.statusFile(fork.id, "fork.json")))
        #expect(try h.binding(fork.id).sessionID == "fork-session")
    }

    @Test func surfaceDeathIsExitedAndCleansUp() async throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.activate(id)
        let surface = try #require(h.host.surfaces[id])

        // The terminal shows that its process exited, and stays open.
        surface.childExited.send()
        await yieldToMainActor(until: { !h.surfaceDeaths.isEmpty })

        let agent = try h.agent(id)
        #expect(agent.displayState == .dead)
        #expect(agent.displayState.label == "Exited")
        #expect(agent.surfaceState == .closed)
        #expect(agent.processState == .exited)
        #expect(try h.launchScripts().isEmpty)
        #expect(h.surfaceDeaths == [id])
        #expect(h.host.calls.last == .remove(id))
        #expect(h.providers.cleanups == [id])
        #expect(h.presentationChanges == [id, id])

        // The removed surface reports nothing more.
        surface.childExited.send()
        await yieldToMainActor(until: { false }, limit: 10)
        #expect(h.surfaceDeaths == [id])
    }

    /// An exit that leaves the terminal open (after an abnormally short run,
    /// or with `wait-after-command`) is an event, not something a timer
    /// finds: it ends the launch with no time passing, and is handled after
    /// the app tick that raised it, which must not free the surface.
    @Test func childExitWithoutCloseEndsLaunchAtOnce() async throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        #expect(!h.scheduler.hasRepeatingTimer)
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")
        let agent = try h.agent(id)
        let surface = try #require(h.host.surfaces[id])

        surface.childExited.send()
        #expect(agent.surfaceState == .open)
        await yieldToMainActor(until: { agent.surfaceState == .closed })

        #expect(agent.displayState == .dead)
        #expect(agent.processState == .exited)
        #expect(agent.turnState == .inactive)
        #expect(!h.host.hasSurface(id: id))
        #expect(h.surfaceDeaths == [id])
        #expect(h.aggregateChanges == [.idle, .running(1), .idle])
        #expect(!h.scheduler.hasRepeatingTimer)
    }

    /// The host owns the only record of a surface. A close it reports ends
    /// that agent's launch and removes the surface with its observers;
    /// another agent's surface and launch are untouched.
    @Test func surfaceDeathFromHostRemovesOnlyRecord() async throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let other = try h.addAgent("Other")
        h.start()
        try h.launch(id)
        try h.launch(other)
        let surface = try #require(h.host.surfaces[id])

        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: surface,
            userInfo: ["process_alive": false])
        await yieldToMainActor(until: { !h.host.hasSurface(id: id) })

        let agent = try h.agent(id)
        #expect(agent.displayState == .dead)
        #expect(agent.surfaceState == .closed)
        #expect(!h.host.hasSurface(id: id))
        #expect(h.surfaceDeaths == [id])
        #expect(h.providers.cleanups == [id])
        #expect(try h.agent(other).displayState == .idle)
        #expect(h.host.hasSurface(id: other))

        // The removed surface reports nothing more.
        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: surface,
            userInfo: ["process_alive": false])
        await yieldToMainActor(until: { false }, limit: 10)
        #expect(h.surfaceDeaths == [id])
        #expect(h.host.hasSurface(id: other))
    }

    /// Flipped from `knownWrong_closeWithLiveProcessDestroysWithoutConfirmation`
    /// (P3.3): closing an agent terminal whose process is alive asks first.
    /// Cancel keeps the terminal; Close ends the launch.
    @Test func closeWithLiveProcessAsksFirst() async throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let surface = try #require(h.host.surfaces[id])
        let agent = try h.agent(id)
        let closeWhileRunning = {
            NotificationCenter.default.post(
                name: Ghostty.Notification.ghosttyCloseSurface,
                object: surface,
                userInfo: ["process_alive": true])
        }

        closeWhileRunning()

        // The close reaches the bridge through a main-actor task, so nothing
        // has happened when the post returns.
        #expect(h.host.calls == [.select(id), .present(id)])
        await yieldToMainActor(until: { h.host.calls.last == .confirmClose(id) })
        #expect(h.host.calls == [.select(id), .present(id), .confirmClose(id)])
        #expect(agent.surfaceState == .open)
        #expect(h.surfaceDeaths.isEmpty)

        h.host.answerClose(confirmed: false)
        #expect(agent.displayState == .idle)
        #expect(h.host.hasSurface(id: id))
        #expect(h.surfaceDeaths.isEmpty)

        closeWhileRunning()
        await yieldToMainActor(until: { h.host.calls.filter { $0 == .confirmClose(id) }.count == 2 })
        #expect(h.host.calls.last == .confirmClose(id))
        h.host.answerClose(confirmed: true)
        #expect(agent.displayState == .dead)
        #expect(agent.surfaceState == .closed)
        #expect(h.surfaceDeaths == [id])
        #expect(h.host.calls.last == .remove(id))
    }

    /// Quitting stops the agents whose provider is starting or running, so
    /// it asks and names them; agents that exited or never started do not
    /// count. The sentence follows Ghostty's own text for terminal windows.
    @Test func quitWithRunningAgentsAsks() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let running = try h.addAgent("Running")
        let starting = try h.addAgent("Starting")
        let exited = try h.addAgent("Exited")
        try h.addAgent("Never Started")
        h.start()
        #expect(h.bridge.runningAgentCount == 0)
        #expect(AgentQuitConfirmation.notice(runningAgents: h.bridge.runningAgentCount) == nil)

        try h.launch(running)
        try h.activate(starting)
        try h.launch(exited)
        try h.providerExited(exited, status: 0)

        #expect(h.bridge.runningAgentCount == 2)
        #expect(AgentQuitConfirmation.notice(runningAgents: h.bridge.runningAgentCount)
            == "2 agents are running. Their sessions can be resumed.")
        #expect(AgentQuitConfirmation.notice(runningAgents: 1)
            == "1 agent is running. Its session can be resumed.")
        let terminalText = "The terminal still has a running process. If you quit, the process will be killed."
        #expect(AgentQuitConfirmation.informativeText(terminalText, runningAgents: 2)
            == terminalText + "\n\n2 agents are running. Their sessions can be resumed.")
        #expect(AgentQuitConfirmation.informativeText(terminalText, runningAgents: 0) == terminalText)
    }

    /// A close the host reports for an earlier launch, here one that was
    /// still on its way when the agent restarted, changes nothing.
    @Test func closeFromEarlierLaunchIsIgnored() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let first = try h.generation(id)
        try h.providerExited(id, status: 0)
        try h.activate(id)

        h.bridge.surfaceClosed(id: id, generation: first, processAlive: false)

        let agent = try h.agent(id)
        #expect(agent.displayState == .launching)
        #expect(agent.surfaceState == .open)
        #expect(h.host.hasSurface(id: id))
        #expect(h.surfaceDeaths.isEmpty)
        #expect(try h.launchScripts().count == 1)
        #expect(h.diagnostics.messages.contains("ignored close of an earlier surface of \(id)"))
    }

    /// Program status reaches the bridge inline, from the surface the host
    /// presents, tagged with its agent and launch. A surface the host does
    /// not present reaches nothing, and a report for an earlier launch is
    /// ignored.
    @Test func programStatusReachesBridgeWithAgentAndGeneration() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let other = try h.addAgent("Other")
        h.start()
        try h.launch(id)
        try h.launch(other)
        let launch = try h.generation(id)
        let surface = try #require(h.host.surfaces[id])
        let working = Ghostty.Action.ProgramStatus(
            state: .working, kind: nil, progress: nil, id: nil, app: nil, title: nil, message: nil)
        let blocked = Ghostty.Action.ProgramStatus(
            state: .blocked, kind: .permission, progress: nil, id: nil, app: nil, title: nil,
            message: nil)

        NotificationCenter.default.post(
            name: .ghosttyDidReceiveProgramStatus,
            object: surface,
            userInfo: [Notification.Name.ProgramStatusKey: working])

        #expect(h.bridge.lastProgramStatus == [id: working])
        #expect(h.diagnostics.messages.last
            == "program status \(id) generation \(launch): working kind=- id=-")

        let before = h.diagnostics.messages
        NotificationCenter.default.post(
            name: .ghosttyDidReceiveProgramStatus,
            object: NSObject(),
            userInfo: [Notification.Name.ProgramStatusKey: blocked])
        #expect(h.bridge.lastProgramStatus == [id: working])
        #expect(h.diagnostics.messages == before)

        h.bridge.programStatus(id: id, generation: UUID(), report: blocked)
        #expect(h.bridge.lastProgramStatus == [id: working])
        #expect(h.diagnostics.messages.last == "ignored program status for \(id)")
        // Reporting changes no agent state yet.
        #expect(try h.agent(id).displayState == .idle)
    }

    @Test func restartNewGenerationIgnoresOldEvents() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let first = try h.generation(id)
        try h.providerExited(id, status: 0)
        #expect(try h.agent(id).displayState == .dead)
        #expect(h.host.hasSurface(id: id))

        try h.activate(id)

        let second = try h.generation(id)
        #expect(second != first)
        #expect(Array(h.host.calls.suffix(3)) == [.remove(id), .select(id), .present(id)])
        #expect(h.surfaceDeaths.isEmpty)
        #expect(h.providers.cleanups == [id])
        // The new launch resumes the session the first one bound.
        #expect(h.providers.launchRequests.last?.session?.sessionID == "session-1")

        try h.append(id, h.record("UserPromptSubmit", generation: first))
        h.poll()
        #expect(try h.agent(id).displayState == .launching)
        #expect(h.diagnostics.messages.contains("ignored stale launch event for \(id)"))

        try h.hook(id, "SessionStart")
        #expect(try h.agent(id).displayState == .idle)
    }

    @Test func providerMismatchAndUnknownSchemaAreSkippedAndAcknowledged() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let launch = try h.generation(id)

        try h.append(id, h.record("UserPromptSubmit", generation: launch, provider: .codex))
        try h.append(id, h.record("UserPromptSubmit", generation: launch)
            .replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":2"#))
        h.poll()

        #expect(try h.agent(id).displayState == .idle)
        #expect(h.diagnostics.messages.contains("ignored provider-mismatched event for \(id)"))
        #expect(h.diagnostics.messages.contains("ignored unsupported event schema for \(id): 2"))

        // The next read starts after them.
        try h.hook(id, "UserPromptSubmit")
        #expect(try h.agent(id).displayState == .thinking)
        #expect(h.diagnostics.messages.filter { $0.hasPrefix("ignored provider-mismatched") }.count == 1)
        #expect(h.diagnostics.messages.filter { $0.hasPrefix("ignored unsupported event schema") }.count == 1)
    }

    /// Reading starts at the end of each event file when the bridge starts:
    /// records already there, here a whole earlier turn, are never read, so
    /// they reach neither the state nor the generation check. A record
    /// appended later is read.
    @Test func eventsPresentAtStartupNeverApply() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let earlier = UUID()
        for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
            try h.append(id, h.record(event, generation: earlier))
        }

        h.start()
        h.poll()

        let agent = try h.agent(id)
        #expect(agent.displayState == .inactive)
        #expect(agent.unreadCompletion == nil)
        #expect(h.notifier.posted.isEmpty)
        #expect(!h.diagnostics.messages.contains("ignored stale launch event for \(id)"))

        try h.append(id, h.record("UserPromptSubmit", generation: earlier))
        h.poll()
        #expect(h.diagnostics.messages.filter { $0 == "ignored stale launch event for \(id)" }.count == 1)

        try h.activate(id)
        h.poll()
        #expect(agent.displayState == .launching)
    }

    /// No terminal outlives the app. An agent that was working when the app
    /// quit is not running after the restart, and what its hooks wrote after
    /// the last read never applies; another agent's unread completion stays.
    @Test func agentRunningAtQuitIsNotRunningAfterRestart() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let other = try h.addAgent("Other")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")
        try h.launch(other)
        try h.hook(other, "UserPromptSubmit")
        try h.hook(other, "Stop")
        let generation = try h.generation(id)
        let posted = h.notifier.posted.count

        try h.restart {
            try h.append(id, h.record("Stop", generation: generation))
        }
        h.poll()

        let agent = try h.agent(id)
        #expect(agent.displayState == .inactive)
        #expect(agent.surfaceState == .inactive)
        #expect(agent.processState == .notStarted)
        #expect(agent.unreadCompletion == nil)
        #expect(try h.agent(other).displayState == .finished)
        #expect(h.bridge.runningAgentCount == 0)
        #expect(h.notifier.posted.count == posted)
        #expect(!h.diagnostics.messages.contains("ignored stale launch event for \(id)"))
    }

    /// When the host is gone by the time the launch is prepared, the script
    /// is deleted on the global queue, outside the IO queue (through the
    /// `global` seam here), and the agent stays starting.
    @Test func launchScriptDeletedWhenHostIsGoneBeforePreparationEnds() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()

        h.io.hold()
        var temporaryHost: FakeSurfaceHost? = FakeSurfaceHost()
        try h.activate(id, host: temporaryHost)
        weak var released = temporaryHost
        temporaryHost = nil
        #expect(released == nil)
        h.io.release()

        #expect(h.providers.launchRequests.count == 1)
        #expect(try h.launchScripts().isEmpty)
        #expect(try h.agent(id).displayState == .launching)
    }
}
