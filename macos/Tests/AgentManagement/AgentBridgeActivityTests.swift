import Foundation
import Testing
import UserNotifications
@testable import Ghostty

/// Characterization of how `AgentBridge` turns hook records into activity,
/// notifications, unread state and renames, as the code behaves after
/// Phase 0. Records carry "" for absent fields, as the hook script writes
/// them.
@MainActor
struct AgentBridgeActivityTests {
    @Test func promptToolPermissionStopSequence() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.hook(id, "UserPromptSubmit")
        #expect(agent.displayState == .thinking)
        try h.hook(id, "PreToolUse")
        #expect(agent.displayState == .working)
        try h.hook(id, "PostToolUse")
        #expect(agent.displayState == .thinking)
        #expect(h.notifier.posted.isEmpty)

        try h.hook(id, "PermissionRequest")
        #expect(agent.displayState == .permission)
        let waiting = try #require(h.notifier.posted.last)
        #expect(waiting.identifier == "clawddy.\(id.uuidString).waiting")
        #expect(waiting.content.interruptionLevel == .timeSensitive)
        #expect(waiting.content.sound != nil)

        try h.hook(id, "Stop")
        #expect(agent.displayState == .finished)
        #expect(h.notifier.posted.count == 2)
        let completed = try #require(h.notifier.posted.last)
        #expect(completed.identifier == "clawddy.\(id.uuidString).completed")
        #expect(completed.content.interruptionLevel == .passive)
        #expect(completed.content.sound == nil)
        let unread = try #require(agent.unreadCompletion)
        #expect(unread.sessionID == "session-1")
        #expect(unread.launchGeneration == agent.launchGeneration)
        #expect(Set(try h.persisted("unreadCompletions").keys) == [id])
        #expect(h.aggregateChanges == [.idle, .running(1), .attention])
    }

    @Test func stopWhileViewedNoUnreadNoNotification() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        h.bridge.setCurrentlyViewedAgent(id)

        try h.hook(id, "UserPromptSubmit")
        try h.hook(id, "Stop")

        let agent = try h.agent(id)
        #expect(agent.displayState == .idle)
        #expect(agent.unreadCompletion == nil)
        #expect(agent.lastAppliedCompletion != nil)
        #expect(h.notifier.posted.isEmpty)
        #expect(try h.persisted("unreadCompletions").isEmpty)
    }

    @Test func viewingAcknowledgesPersistsAndClears() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")
        try h.hook(id, "Stop")
        #expect(Set(try h.persisted("unreadCompletions").keys) == [id])

        h.bridge.setCurrentlyViewedAgent(id)

        let agent = try h.agent(id)
        #expect(agent.unreadCompletion == nil)
        #expect(agent.displayState == .idle)
        #expect(try h.persisted("unreadCompletions").isEmpty)
        #expect(h.notifier.removed == [[
            "clawddy.\(id.uuidString).completed",
            "clawddy.\(id.uuidString).waiting",
            "clawddy.\(id.uuidString).error",
        ]])
        #expect(h.aggregateChanges.last == .idle)
    }

    @Test func stopFailureNeedsAttention() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")

        try h.hook(id, "StopFailure")

        let agent = try h.agent(id)
        #expect(agent.displayState == .error)
        #expect(agent.displayState.label == "Needs Attention")
        #expect(agent.runtimeErrorMessage == "The agent reported a runtime error.")
        #expect(agent.unreadCompletion == nil)
        let error = try #require(h.notifier.posted.last)
        #expect(error.identifier == "clawddy.\(id.uuidString).error")
        #expect(error.content.interruptionLevel == .active)

        try h.hook(id, "UserPromptSubmit")
        #expect(agent.displayState == .thinking)
        #expect(agent.runtimeErrorMessage == nil)
    }

    @Test func toolFailureKeepsTurn() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")
        try h.hook(id, "PreToolUse")

        try h.hook(id, "PostToolUseFailure")

        let agent = try h.agent(id)
        #expect(agent.displayState == .thinking)
        #expect(agent.turnState == .active(turnID: ""))
        #expect(agent.runtimeErrorMessage == nil)
        #expect(h.notifier.posted.isEmpty)
        try h.hook(id, "PermissionRequest")
        #expect(agent.displayState == .permission)
    }

    @Test func compactionExpiresAfter30s() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")

        try h.hook(id, "PreCompact")
        let agent = try h.agent(id)
        #expect(agent.displayState == .compacting)
        #expect(agent.displayState.label == "Optimizing Context")

        h.scheduler.advance(by: 29)
        #expect(agent.displayState == .compacting)
        h.scheduler.advance(by: 2)
        #expect(agent.displayState == .thinking)
    }

    @Test func silent120sIsDelayedAndRecovers() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")
        let agent = try h.agent(id)

        // A turn with no provider fact for 120 s shows as delayed.
        h.scheduler.advance(by: 115)
        #expect(agent.displayState == .thinking)
        h.scheduler.advance(by: 10)
        #expect(agent.displayState == .statusDelayed)
        #expect(agent.displayState.label == "Status Delayed")
        #expect(agent.telemetryHealth == .delayed)

        try h.hook(id, "PreToolUse")
        #expect(agent.displayState == .working)
        #expect(agent.telemetryHealth == .live)
    }

    @Test func partialLineWaitsForNewline() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.appendRaw(id, h.record("UserPromptSubmit", generation: try h.generation(id)))
        h.poll()
        #expect(agent.displayState == .idle)

        try h.appendRaw(id, "\n")
        h.poll()
        #expect(agent.displayState == .thinking)
    }

    @Test func journalOver1MiBCompactsAndLaterEventsApply() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let events = h.statusFile(id, "events")

        // One record of an event the provider table does not know, padded
        // past the 1 MiB compaction threshold.
        try h.append(id, h.record(
            "Padding",
            generation: try h.generation(id),
            session: String(repeating: "x", count: 1_048_576)))
        h.poll()

        #expect(try h.size(events) == 0)
        try h.hook(id, "UserPromptSubmit")
        #expect(try h.agent(id).displayState == .thinking)
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
        let waiting = "clawddy.\(id.uuidString).waiting"
        let completed = "clawddy.\(id.uuidString).completed"

        try h.append(id, h.record("UserPromptSubmit", generation: launch))
        try h.append(id, h.record("PermissionRequest", generation: launch))
        try h.append(id, h.record(
            "Padding",
            generation: launch,
            session: String(repeating: "x", count: 1_048_576)))
        let unfinished = h.record("Stop", generation: launch)
        try h.appendRaw(id, unfinished)
        h.poll()

        #expect(agent.displayState == .permission)
        #expect(h.notifier.posted.map(\.identifier) == [waiting])
        #expect(try Data(contentsOf: h.statusFile(id, "events")) == Data(unfinished.utf8))

        try h.appendRaw(id, "\n")
        h.poll()
        #expect(agent.displayState == .finished)
        #expect(h.notifier.posted.map(\.identifier) == [waiting, completed])

        h.poll()
        try h.hook(id, "UserPromptSubmit")
        #expect(agent.displayState == .thinking)
        #expect(h.notifier.posted.map(\.identifier) == [waiting, completed])
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
        #expect(agent.displayState == .idle)
        let hostCalls = h.host.calls

        #expect(h.config.renameAgent(id: id, newName: "New Name"))
        h.bridge.renameAgent(id: id, newName: "New Name")
        #expect(agent.name == "New Name")
        try h.hook(id, "UserPromptSubmit")
        try h.hook(id, "Stop")
        #expect(h.host.calls == hostCalls)
        let state = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: h.root.stateFile)) as? [String: Any])
        #expect(state["pendingRenames"] == nil)

        try h.providerExited(id, status: 0)
        try h.activate(id)

        #expect(h.providers.launchRequests.last?.name == "New Name")
        #expect(try h.launchScript().contains(shellCommand(["--resume", "session-1", "--name", "New Name"])))
    }

    /// Status-line metadata is stamped with its file's modification time, and
    /// metadata from a hook record with the scheduler's time. The hook
    /// record's empty model then replaces the status line's model.
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

        try h.hook(id, "UserPromptSubmit")
        #expect(agent.metadata?.observedAt == h.scheduler.now)
        #expect(agent.metadata?.modelID == "")
        #expect(agent.metadata?.displayModel == "Claude Test")
    }

    /// The hook script the launch installs, run with the arguments of the
    /// agent's settings overlay and Claude's payload fields, writes records
    /// the bridge applies.
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
        let groups = try #require(overlay["Stop"] as? [[String: Any]])
        let handlers = try #require(groups.first?["hooks"] as? [[String: Any]])
        let command = try #require(handlers.first?["command"] as? String)
        let session = "2f0c8b3e-6d43-4a51-9b7e-1c5d2a9e8f40"
        func run(_ payload: String) throws {
            #expect(try runHook(command, payload: payload, in: h.folder) == 0)
            h.poll()
        }
        let agent = try h.agent(id)

        try run(#"{"session_id":"\#(session)","transcript_path":"/dev/null","cwd":"/","hook_event_name":"SessionStart","source":"startup","model":"claude-test"}"#)
        #expect(agent.displayState == .idle)
        #expect(agent.sessionID == session)
        #expect(try h.launchScripts().isEmpty)
        #expect(try h.binding(id) == AgentSessionBinding(
            provider: .claudeCode,
            sessionID: session,
            launchGeneration: generation))

        try run(#"{"session_id":"\#(session)","hook_event_name":"UserPromptSubmit","prompt":"hello","prompt_id":"prompt-1","permission_mode":"default"}"#)
        #expect(agent.displayState == .thinking)
        #expect(agent.turnState == .active(turnID: ""))

        try run(#"{"session_id":"\#(session)","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"},"prompt_id":"prompt-1","permission_mode":"default"}"#)
        #expect(agent.displayState == .permission)

        try run(#"{"session_id":"\#(session)","hook_event_name":"Stop","prompt_id":"prompt-1","stop_hook_active":false}"#)
        #expect(agent.displayState == .finished)
        #expect(agent.unreadCompletion?.sessionID == session)
        #expect(h.notifier.posted.map(\.identifier) == [
            "clawddy.\(id.uuidString).waiting",
            "clawddy.\(id.uuidString).completed",
        ])
    }

    /// Every `SessionStart` the real hook script records rebinds the agent,
    /// whatever its source, in the order Claude sends them (P3.5a case 7):
    /// after `/clear` the binding names the new session, and Restart
    /// resumes it.
    @Test func sessionStartHookRebindsAfterClear() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        try h.useRealClaudeLaunch()
        let id = try h.addAgent("Agent")
        h.start()
        try h.activate(id)
        let launched = try h.binding(id).sessionID
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
        #expect(agent.failureMessage == nil)
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
