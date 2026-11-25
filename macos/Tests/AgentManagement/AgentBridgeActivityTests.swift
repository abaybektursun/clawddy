import Foundation
import Testing
import UserNotifications
@testable import Ghostty

/// Characterization of how `AgentBridge` turns observations into activity,
/// notifications, unread state and renames. Hook records carry "" for absent
/// fields, as the hook script writes them. Every provider's turn activity
/// comes from its terminal's program status (P3.5); Codex's completion also
/// from its notify program's record.
@MainActor
struct AgentBridgeActivityTests {
    /// A Codex turn as its terminal reports it, completed by its notify
    /// program's record.
    @Test func promptPermissionCompletionSequence() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .codex)
        h.start()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.startTurn(id)
        #expect(agent.activityState == .executing)
        #expect(h.notifier.posted.isEmpty)

        try h.osc(id, "state=blocked:kind=permission:app=codex")
        #expect(agent.record.state == .asks)
        let waiting = try #require(h.notifier.posted.last)
        #expect(waiting.identifier == "clawddy.\(id.uuidString).waiting")
        #expect(waiting.content.interruptionLevel == .timeSensitive)
        #expect(waiting.content.sound == nil)

        try h.osc(id, "state=working:app=codex")
        try h.hook(id, "agent-turn-complete")
        #expect(agent.shownState == .finishedUnread)
        #expect(h.notifier.posted.count == 2)
        let completed = try #require(h.notifier.posted.last)
        #expect(completed.identifier == "clawddy.\(id.uuidString).completed")
        #expect(completed.content.interruptionLevel == .passive)
        #expect(completed.content.sound == nil)
        let unread = try #require(agent.lastAppliedCompletion)
        #expect(unread.sessionID == "session-1")
        #expect(unread.launchGeneration == agent.launchGeneration)
        #expect(try h.recordedUnread() == [id])
        // A question and an unread finish both wait on the person.
        #expect(h.waitingCounts == [0, 1, 0, 1])
    }

    @Test func completionWhileViewedNoUnreadNoNotification() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .codex)
        h.start()
        try h.launch(id)
        h.view(id)

        try h.startTurn(id)
        try h.hook(id, "agent-turn-complete")

        let agent = try h.agent(id)
        #expect(agent.terminal == .idle)
        #expect(!agent.record.unread)
        #expect(agent.lastAppliedCompletion != nil)
        #expect(h.notifier.posted.isEmpty)
        #expect(try h.recordedUnread().isEmpty)
    }

    @Test func viewingAcknowledgesPersistsAndClears() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.completeTurn(id)
        #expect(try h.recordedUnread() == [id])

        h.view(id)

        let agent = try h.agent(id)
        #expect(!agent.record.unread)
        #expect(agent.terminal == .idle)
        #expect(try h.recordedUnread().isEmpty)
        #expect(h.notifier.removed == [[
            "clawddy.\(id.uuidString).completed",
            "clawddy.\(id.uuidString).waiting",
            "clawddy.\(id.uuidString).error",
        ]])
        #expect(h.waitingCounts.last == 0)
    }

    /// Claude's `StopFailure` hook fails the turn its terminal reported, and
    /// the next turn clears the failure.
    @Test func stopFailureNeedsAttention() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.startTurn(id)

        try h.hook(id, "StopFailure")

        let agent = try h.agent(id)
        #expect(agent.shownState == .problem)
        #expect(agent.record.problem?.kind == .error)
        #expect(agent.sentence.text
            == "Stopped with an error. Open it to see why.")
        #expect(agent.record.problem == AgentRecord.Problem(kind: .error))
        #expect(!agent.record.unread)
        let error = try #require(h.notifier.posted.last)
        #expect(error.identifier == "clawddy.\(id.uuidString).error")
        #expect(error.content.interruptionLevel == .active)

        try h.startTurn(id)
        #expect(agent.activityState == .executing)
        #expect(agent.record.problem == nil)
    }

    @Test func partialLineWaitsForNewline() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.startTurn(id)
        let agent = try h.agent(id)

        try h.appendRaw(id, h.record("StopFailure", generation: try h.generation(id)))
        h.poll()
        #expect(agent.isRunning)

        try h.appendRaw(id, "\n")
        h.poll()
        #expect(agent.shownState == .problem)
    }

    @Test func journalOver1MiBCompactsAndLaterEventsApply() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.startTurn(id)
        let events = h.statusFile(id, "events")

        // One record of an event the provider table does not know, padded
        // past the 1 MiB compaction threshold.
        try h.append(id, h.record(
            "Padding",
            generation: try h.generation(id),
            session: String(repeating: "x", count: 1_048_576)))
        h.poll()

        #expect(try h.size(events) == 0)
        try h.hook(id, "StopFailure")
        #expect(try h.agent(id).shownState == .problem)
    }

    /// Compaction cuts off only what was read: records read before it never
    /// apply again, and the unread rest, here a record still being written,
    /// applies once it is complete.
    @Test func compactionNeitherReplaysNorLoses() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let agent = try h.agent(id)
        let launch = try h.generation(id)
        let error = "clawddy.\(id.uuidString).error"

        try h.osc(id, "state=working:app=claude-code")
        try h.append(id, h.record("UserPromptSubmit", generation: launch))
        try h.append(id, h.record(
            "Padding",
            generation: launch,
            session: String(repeating: "x", count: 1_048_576)))
        let unfinished = h.record("StopFailure", generation: launch)
        try h.appendRaw(id, unfinished)
        h.poll()

        #expect(agent.isRunning)
        #expect(h.notifier.posted.isEmpty)
        #expect(try Data(contentsOf: h.statusFile(id, "events")) == Data(unfinished.utf8))

        try h.appendRaw(id, "\n")
        h.poll()
        #expect(agent.shownState == .problem)
        #expect(h.notifier.posted.map(\.identifier) == [error])

        h.poll()
        #expect(h.notifier.posted.map(\.identifier) == [error])
    }

    /// Renaming changes the label at once and reaches no terminal, even while
    /// Claude waits at its prompt, where `/rename` used to be typed, or after
    /// a turn ends, where a queued one was. The next launch names the
    /// session with the new label.
    @Test func renameTypesNothingAndNextLaunchCarriesNewName() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        try h.useRealClaudeLaunch()
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id, session: "session-1")
        let agent = try h.agent(id)
        #expect(agent.terminal == .idle)
        let hostCalls = h.host.calls

        #expect(h.config.renameAgent(id: id, newName: "New Name"))
        h.bridge.renameAgent(id: id, newName: "New Name")
        #expect(agent.name == "New Name")
        try h.completeTurn(id)
        #expect(h.host.calls == hostCalls)
        #expect(try h.agent(id).record.nameSource == .person)

        try h.providerExited(id, status: 0)
        try h.activate(id)

        #expect(h.providers.launchRequests.last?.name == "New Name")
        #expect(try h.launchScript().contains(shellCommand(["--resume", "session-1", "--name", "New Name"])))
    }

    /// Status-line metadata is stamped with its file's modification time, and
    /// metadata from a hook record with the scheduler's time. A hook record
    /// that carries no model, here the `SessionStart` of a compaction, leaves
    /// the status line's model as it is.
    @Test func metadataFromStatusLineThenHook() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let url = h.statusFile(id, "metadata.json")
        try Data(#"{"session_id":"session-1","model":{"id":"claude-test","display_name":"Claude Test"}}"#.utf8)
            .write(to: url)
        let written = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path)

        h.poll()
        let agent = try h.agent(id)
        #expect(agent.metadata?.modelID == "claude-test")
        #expect(agent.metadata?.observedAt == written)
        #expect(agent.metadataAvailability == .available)

        try h.hook(id, "SessionStart")
        #expect(agent.metadata?.observedAt == h.scheduler.now)
        #expect(agent.metadata?.modelID == "claude-test")
        #expect(agent.metadata?.modelDisplayName == "Claude Test")
    }

    /// The hook script the launch installs, run with the arguments of the
    /// agent's settings overlay and Claude's payload fields, writes records
    /// the bridge applies: `SessionStart` binds the session, `PreCompact`
    /// carries its trigger, and `StopFailure` fails the turn. Claude's
    /// terminal reports the rest.
    @Test func realHookScriptFeedsTheBridge() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.activate(id)
        let generation = try h.generation(id)
        #expect(FileManager.default.isExecutableFile(
            atPath: AgentHookRuntime.scriptURL(root: h.root).path))
        let overlay = ClaudeCodeProvider(root: h.root)
            .overlayHooks(agentID: id, generation: generation)
        let groups = try #require(overlay["StopFailure"] as? [[String: Any]])
        let handlers = try #require(groups.first?["hooks"] as? [[String: Any]])
        let command = try #require(handlers.first?["command"] as? String)
        let session = "2f0c8b3e-6d43-4a51-9b7e-1c5d2a9e8f40"
        func run(_ payload: String) throws {
            #expect(try runHook(command, payload: payload, in: h.folder) == 0)
            h.poll()
        }
        let agent = try h.agent(id)

        try run(#"{"session_id":"\#(session)","transcript_path":"/dev/null","cwd":"/","hook_event_name":"SessionStart","source":"startup","model":"claude-test"}"#)
        #expect(agent.sessionID == session)
        #expect(try h.binding(id) == AgentSessionBinding(
            provider: .claudeCode,
            sessionID: session,
            launchGeneration: generation))
        // Liveness is the terminal's to report.
        #expect(agent.terminal == .starting)
        try h.osc(id, "state=idle:app=claude-code")
        #expect(agent.terminal == .idle)
        #expect(try h.launchScripts().isEmpty)

        try h.startTurn(id)
        try run(#"{"session_id":"\#(session)","hook_event_name":"PreCompact","trigger":"manual","custom_instructions":"","prompt_id":"prompt-1"}"#)
        #expect(agent.terminal == .compacting)
        try h.osc(id, "state=done:app=claude-code")
        #expect(agent.terminal == .idle)
        #expect(agent.lastAppliedCompletion == nil)

        try h.startTurn(id)
        try run(#"{"session_id":"\#(session)","hook_event_name":"StopFailure","error":"server_error","last_assistant_message":"API Error","prompt_id":"prompt-2"}"#)
        #expect(agent.shownState == .problem)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).error"])
    }

    /// Every `SessionStart` the real hook script records rebinds the agent,
    /// whatever its source, in the order Claude sends them (P3.5a case 7),
    /// once its session is on disk: after `/clear` the binding names the new
    /// session, and Restart resumes it. The launched session is saved by
    /// its first turn (review S1 capture).
    @Test func sessionStartHookRebindsAfterClear() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        try h.useRealClaudeLaunch()
        let id = try h.addAgent("Agent")
        h.start()
        try h.activate(id)
        let launched = try #require(h.agent(id).sessionID)
        let cleared = "8d0e5f6a-3b2c-4d1e-9f8a-7b6c5d4e3f2a"
        let agent = try h.agent(id)
        func run(_ payload: String) throws {
            let generation = try h.generation(id)
            let groups = ClaudeCodeProvider(root: h.root)
                .overlayHooks(agentID: id, generation: generation)["SessionStart"] as? [[String: Any]]
            let handlers = try #require(groups?.first?["hooks"] as? [[String: Any]])
            let command = try #require(handlers.first?["command"] as? String)
            #expect(try runHook(command, payload: payload, in: h.folder) == 0)
            h.poll()
        }
        func binding(_ session: String) throws -> AgentSessionBinding {
            AgentSessionBinding(provider: .claudeCode, sessionID: session, launchGeneration: try h.generation(id))
        }

        try run(#"{"session_id":"\#(launched)","hook_event_name":"SessionStart","source":"startup","model":"claude-test"}"#)
        try h.osc(id, "state=idle:app=claude-code")
        #expect(!h.exists(h.statusFile(id, "session.json")))
        try h.completeTurn(id)
        #expect(try h.binding(id) == binding(launched))
        try run(#"{"session_id":"\#(launched)","hook_event_name":"SessionEnd","reason":"clear"}"#)
        try run(#"{"session_id":"\#(cleared)","hook_event_name":"SessionStart","source":"clear"}"#)
        #expect(try h.binding(id) == binding(cleared))
        #expect(agent.sessionID == cleared)
        try run(#"{"session_id":"\#(cleared)","hook_event_name":"SessionStart","source":"compact","model":"claude-test"}"#)
        #expect(try h.binding(id) == binding(cleared))

        try h.providerExited(id, status: 0)
        try h.activate(id)
        #expect(try h.launchScript().contains(shellCommand(["--resume", cleared, "--name", "Agent"])))
        try run(#"{"session_id":"\#(cleared)","hook_event_name":"SessionStart","source":"resume"}"#)
        #expect(try h.binding(id) == binding(cleared))
        // A resumed session that started ends as usual.
        try run(#"{"session_id":"\#(cleared)","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#)
        #expect(agent.missingSessionID == nil)
        #expect(agent.record.problem == nil)
    }

    /// `/clear` ends the session with `SessionEnd`, `reason: "clear"`, while
    /// Claude's process goes on: the agent stays running and posts nothing,
    /// and the next `SessionStart` rebinds it. Only the exit report ends the
    /// process.
    @Test func sessionEndWithReasonClearKeepsAgentAlive() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.activate(id)
        let generation = try h.generation(id)
        let groups = ClaudeCodeProvider(root: h.root)
            .overlayHooks(agentID: id, generation: generation)["SessionEnd"] as? [[String: Any]]
        let handlers = try #require(groups?.first?["hooks"] as? [[String: Any]])
        let command = try #require(handlers.first?["command"] as? String)
        func run(_ payload: String) throws {
            #expect(try runHook(command, payload: payload, in: h.folder) == 0)
            h.poll()
        }
        let launched = "3c9a7e1f-2b4d-4e6a-8c0b-5d7f9a1b3c5e"
        let cleared = "7e5c3a1f-9d8b-4c6e-a2f0-1b3d5f7a9c2e"
        let agent = try h.agent(id)

        try run(#"{"session_id":"\#(launched)","hook_event_name":"SessionStart","source":"startup"}"#)
        try h.osc(id, "state=idle:app=claude-code")
        #expect(agent.terminal == .idle)

        try run(#"{"session_id":"\#(launched)","hook_event_name":"SessionEnd","reason":"clear"}"#)
        #expect(agent.processState == .running)
        #expect(agent.terminal == .idle)
        #expect(agent.record.problem == nil)
        #expect(h.bridge.runningAgentCount == 1)
        #expect(h.notifier.posted.isEmpty)

        try run(#"{"session_id":"\#(cleared)","hook_event_name":"SessionStart","source":"clear"}"#)
        #expect(agent.sessionID == cleared)
        #expect(try h.binding(id) == AgentSessionBinding(
            provider: .claudeCode,
            sessionID: cleared,
            launchGeneration: generation))
        try h.startTurn(id)
        #expect(agent.activityState == .executing)

        try h.providerExited(id, status: 0)
        #expect(agent.processState == .exited)
        #expect(agent.terminal == .notRunning)
    }

    /// The waiting count is the record's `isWaitingOnYou` and nothing else:
    /// a finished unread agent and a problem count, a settled one does not.
    @Test func theWaitingCountIsTheRecords() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let done = try h.addAgent("Done")
        let failed = try h.addAgent("Failed")
        h.start()
        try h.launch(done)
        try h.completeTurn(done)
        try h.launch(failed)
        try h.startTurn(failed)
        try h.osc(failed, "state=error:app=claude-code")
        #expect(h.bridge.waitingAgentCount == 2)
        #expect(h.waitingCounts == [0, 1, 2])
        #expect(Set(h.bridge.agents.values.filter(\.isWaiting).map(\.id)) == [done, failed])
        try h.agent(done).apply(.settled(includingWorking: false), at: h.scheduler.now)
        #expect(h.bridge.waitingAgentCount == 1)
    }

    /// Ruling 12: what a working agent reports of its activity changes
    /// neither its place in the waiting order nor what find reads of it;
    /// a transition changes both, and the waiting count follows it alone.
    @Test func activityWakesNeitherTheWaitingOrderNorFind() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Worker")
        h.start()
        try h.launch(id)
        try h.startTurn(id)
        let agent = try h.agent(id)
        let version = agent.searchVersion
        let counts = h.waitingCounts
        for step in 0..<20 {
            try h.osc(id, "state=working:app=claude-code:msg=" + Data("Running step \(step)".utf8).base64EncodedString())
        }
        #expect(agent.record.activity != nil)
        #expect(agent.searchVersion == version)
        #expect(agent.waitingKey == nil)
        #expect(h.waitingCounts == counts)
        try h.osc(id, "state=done:app=claude-code")
        #expect(agent.waitingKey != nil)
        #expect(agent.searchVersion > version)
        #expect(h.bridge.waitingAgentCount == 1)
    }

    /// A line of the event file that is no record, and a hook that could
    /// not record its event, each stop the agent with a problem saying so.
    @Test func lostReportsAreShown() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let garbled = try h.addAgent("Garbled")
        let failing = try h.addAgent("Failing")
        h.start()
        try h.launch(garbled)
        try h.launch(failing)
        try h.append(garbled, "{not a record")
        h.poll()
        #expect(try h.agent(garbled).record.problem == AgentRecord.Problem(kind: .reportFailed))
        try h.append(failing, #"{"schemaVersion":1,"provider":"claudeCode","launchGeneration":"\#(try h.generation(failing).uuidString)","hookEventName":"HookFailed","text":"Stop: could not record"}"#)
        h.poll()
        #expect(try h.agent(failing).record.problem == AgentRecord.Problem(kind: .reportFailed))
        #expect(h.notifier.posted.count == 2)
    }

    /// Codex's title stops spinning when its turn ends: the turn completes,
    /// and the notify that follows ends nothing more.
    @Test func codexTitleSpinnerEndsTheTurn() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Codex", provider: .codex)
        h.start()
        try h.launch(id)
        try h.startTurn(id)
        let generation = try h.generation(id)
        h.bridge.surfaceTitle(id: id, generation: generation, title: "⠙ work")
        h.bridge.surfaceTitle(id: id, generation: generation, title: "⠹ work")
        #expect(try h.agent(id).record.state == .working)
        h.bridge.surfaceTitle(id: id, generation: generation, title: "Fix the sheet | work")
        #expect(try h.agent(id).record.state == .finished)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).completed"])
        try h.hook(id, "agent-turn-complete", turn: "turn-1")
        #expect(h.notifier.posted.count == 1)
        #expect(try h.agent(id).record.state == .finished)
    }
}

/// Runs a hook command as Claude does: `/bin/sh -c`, the payload on standard
/// input, in an environment with no agent identity.
private func runHook(_ command: String, payload: String, in folder: URL) throws -> Int32 {
    let process = Process()
    let input = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = [
        "HOME": folder.appendingPathComponent("home").path,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": folder.appendingPathComponent("tmp").path,
    ]
    process.standardInput = input
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    return process.terminationStatus
}
