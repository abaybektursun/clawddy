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

        // Freshness is judged after each poll; the heartbeat polls every 10 s.
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
        #expect(try h.persisted("eventOffsets")[id] as? Int == 0)
        try h.hook(id, "UserPromptSubmit")
        #expect(try h.agent(id).displayState == .thinking)
    }

    @Test func renameWhileIdleIsTypedImmediately() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)

        h.bridge.requestRename(id: id, newName: "New Name")

        #expect(try h.agent(id).name == "New Name")
        #expect(h.sentText == [SentText(id: id, text: "/rename New Name\n")])
        #expect(try h.persisted("pendingRenames").isEmpty)
    }

    @Test func renameWhileWorkingIsDeferredPersistedThenTyped() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.hook(id, "UserPromptSubmit")

        h.bridge.requestRename(id: id, newName: "New Name")
        #expect(h.sentText.isEmpty)
        #expect(try h.persisted("pendingRenames")[id] as? String == "New Name")

        try h.hook(id, "Stop")
        #expect(h.sentText == [SentText(id: id, text: "/rename New Name\n")])
        #expect(try h.persisted("pendingRenames").isEmpty)
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
