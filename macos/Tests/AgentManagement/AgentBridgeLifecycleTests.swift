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

    @Test func surfaceDeathIsExitedAndCleansUp() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.activate(id)
        let surface = try #require(h.host.surfaces[id])

        // The heartbeat, every 10 s, asks each surface whether its process
        // has exited.
        surface.processExited = true
        h.scheduler.advance(by: 10)

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

        h.scheduler.advance(by: 10)
        #expect(h.surfaceDeaths == [id])
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
        let offset = try h.persisted("eventOffsets")[id] as? Int
        #expect(offset == (try h.size(h.statusFile(id, "events"))))

        try h.hook(id, "UserPromptSubmit")
        #expect(try h.agent(id).displayState == .thinking)
    }

    @Test func replayedEventIDAppliesOnce() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit", eventID: "prompt-1")
        try h.hook(id, "Stop", eventID: "stop-1")
        let agent = try h.agent(id)
        let completion = try #require(agent.unreadCompletion)
        #expect(completion.eventID == "stop-1:0")

        // The same records again, as a duplicated or replayed file holds them.
        try h.hook(id, "UserPromptSubmit", eventID: "prompt-1")
        try h.hook(id, "Stop", eventID: "stop-1")

        #expect(agent.displayState == .finished)
        #expect(agent.unreadCompletion == completion)
        #expect(h.notifier.posted.count == 1)
    }

    @Test func eventsPresentAtStartupNeverApply() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let earlier = UUID()
        for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
            try h.append(id, h.record(event, generation: earlier))
        }

        h.start()

        let agent = try h.agent(id)
        #expect(agent.displayState == .inactive)
        #expect(h.notifier.posted.isEmpty)
        let offset = try h.persisted("eventOffsets")[id] as? Int
        #expect(offset == (try h.size(h.statusFile(id, "events"))))

        try h.activate(id)
        h.poll()
        #expect(agent.displayState == .launching)
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
