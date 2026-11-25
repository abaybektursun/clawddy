import Foundation
import Testing
@testable import Ghostty

/// A file that cannot be read or written is an error the user sees, never a
/// silent fallback (P3.9). The first five tests are the flipped
/// `knownWrong_corrupt…`, `knownWrong_undecodableRecordDroppedSilently` and
/// `knownWrong_emptyTurnIDKeptAsEmptyString`.
@MainActor
struct AgentFailLoudTests {
    /// A record that cannot be read: that agent alone shows a problem
    /// naming the file, the app says why, keeps the file as evidence and
    /// saves nothing over it, and nothing launches it on a record of
    /// defaults (last review ruling 2).
    @Test func corruptRecordIsReportedAndKept() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.completeTurn(id)
        let file = AgentRecord.url(id, h.root.statusDir)
        var corrupt = Data()

        try h.restart {
            let data = try Data(contentsOf: file)
            corrupt = data.prefix(data.count / 2)
            try corrupt.write(to: file)
        }

        let agent = try h.agent(id)
        #expect(!agent.record.unread)
        #expect(agent.terminal == .notRunning)
        #expect(agent.record.state == .problem)
        #expect(agent.record.problem?.text?.contains(file.path) == true)
        let issue = try #require(h.bridge.storageErrors[file])
        #expect(issue.hasPrefix("The record of Agent could not be read ("))
        #expect(h.diagnostics.messages.contains(issue))
        // Nothing launches it, and the file is left alone.
        let launches = h.providers.launchRequests.count
        try h.activate(id)
        #expect(h.providers.launchRequests.count == launches)
        #expect(try Data(contentsOf: file) == corrupt)
    }

    /// No file means the defaults; a file that does not decode means the
    /// least permissive mode, and the reason.
    @Test func corruptPreferencesFallBackToStandardAndSayWhy() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let url = h.root.preferencesFile
        #expect(AgentPreferencesStore.load(from: url) == AgentPreferencesStore.Loaded(preferences: AgentPreferences()))
        try AgentPreferencesStore.save(
            AgentPreferences(claudeCodeDefaultStartMode: .unrestricted, codexDefaultStartMode: .unrestricted),
            to: url)
        let data = try Data(contentsOf: url)
        try data.prefix(data.count - 2).write(to: url)

        let loaded = AgentPreferencesStore.load(from: url)

        #expect(loaded.preferences.defaultStartMode(for: .claudeCode) == .standard)
        #expect(loaded.preferences.defaultStartMode(for: .codex) == .standard)
        #expect(loaded.error?.hasPrefix("Agent defaults could not be read from \(url.path) (") == true)
        #expect(loaded.error?.hasSuffix("so new agents start with standard permissions.") == true)
        #expect(try Data(contentsOf: url) == data.prefix(data.count - 2))
    }

    /// The launch stops before the provider is asked for anything, says
    /// which file it could not read, and offers only Start Fresh, which
    /// forgets that file and starts a new session.
    @Test func corruptBindingIsExplicitFailure() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let file = h.statusFile(id, "session.json")
        let corrupt = Data(#"{"provider":"claudeCode","sessionID":"session-"#.utf8)
        try corrupt.write(to: file)
        h.start()

        try h.activate(id)

        let agent = try h.agent(id)
        #expect(h.providers.launchRequests.isEmpty)
        #expect(agent.shownState == .problem)
        #expect(agent.canOnlyStartFresh)
        #expect(agent.record.problem?.text?.hasPrefix(
            "The saved Claude Code session could not be read, so the agent was not started. \(file.path) could not be read: ") == true)
        #expect(try Data(contentsOf: file) == corrupt)
        #expect(try h.launchScripts().isEmpty)
        // Restart would fail on the same file.
        try h.activate(id)
        #expect(h.providers.launchRequests.isEmpty)

        let project = try #require(h.config.project(forAgent: id))
        h.bridge.startFresh(id: id, host: h.host, project: project)

        let request = try #require(h.providers.launchRequests.first)
        #expect(request.session == nil)
        #expect(!h.exists(file))
        #expect(agent.terminal == .starting)
        #expect(!agent.canOnlyStartFresh)
    }

    /// A binding that cannot be read is shown at start, with the message its
    /// launch would give, and the agent offers only Start Fresh.
    @Test func corruptBindingIsShownAtStart() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let file = h.statusFile(id, "session.json")
        try Data(#"{"provider":"claudeCode","sessionID":"session-"#.utf8).write(to: file)

        h.start()

        let agent = try h.agent(id)
        #expect(agent.shownState == .problem)
        #expect(agent.canOnlyStartFresh)
        #expect(agent.record.problem?.text?.hasPrefix(
            "The saved Claude Code session could not be read, so the agent was not started. \(file.path) could not be read: ") == true)
        #expect(h.providers.launchRequests.isEmpty)
    }

    @Test func undecodableRecordIsLoggedWithItsOffset() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.osc(id, "state=working:app=claude-code")
        let events = h.statusFile(id, "events")
        let offset = try h.size(events)
        let before = h.diagnostics.messages.count

        try h.append(id, h.record("UserPromptSubmit", generation: try h.generation(id))
            .replacingOccurrences(of: #""provider":"claudeCode""#, with: #""provider":"""#))
        h.poll()

        // The lost report is shown, not only logged.
        #expect(try h.agent(id).record.problem == AgentRecord.Problem(kind: .reportFailed))
        let reported = Array(h.diagnostics.messages.dropFirst(before))
        #expect(reported.count == 1)
        #expect(reported.first?.hasPrefix("undecodable record in \(events.path) at byte \(offset): provider") == true)
        // The records after it apply.
        try h.hook(id, "UserPromptSubmit")
        #expect(try h.agent(id).activityState == .reasoning)
    }

    /// The hook script writes "" for a field its payload did not carry.
    @Test func emptyTurnIDIsAbsent() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .codex)
        h.start()
        try h.launch(id)
        try h.startTurn(id)

        try h.hook(id, "agent-turn-complete", turn: "")
        let agent = try h.agent(id)
        #expect(agent.record.unread)
        #expect(agent.lastAppliedCompletion?.turnID == nil)
        #expect(agent.lastAppliedCompletion?.turnID == nil)
        #expect(agent.metadata?.sessionID == "session-1")
        #expect(agent.metadata?.modelID == nil)
        #expect(agent.metadata?.permissionMode == nil)
    }

    /// A write into a folder that cannot take it throws, and leaves the old
    /// file and no temporary file behind.
    @Test func atomicWritePropagatesFailure() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("clawddy-atomic-write-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            #expect(throws: Never.self) {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
                try fm.removeItem(at: folder)
            }
        }
        let file = folder.appendingPathComponent("agents.json")
        try Data("old".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)

        #expect(throws: (any Error).self) {
            try AgentConfig.atomicWrite(Data("new".utf8), to: file)
        }
        #expect(try Data(contentsOf: file) == Data("old".utf8))
        #expect(try fm.contentsOfDirectory(atPath: folder.path) == ["agents.json"])
    }

    /// A failed save of `agents.json` says why; written off the main thread,
    /// in order, as a record is, the change stays (final review part 2).
    @Test func failedConfigSaveIsShown() async throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: h.root.url.path)
        defer {
            #expect(throws: Never.self) {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: h.root.url.path)
            }
        }

        #expect(h.config.addProject(name: "Second") != nil)
        h.config.waitForWrites()
        // The failure reaches the main thread's next turn.
        try await Task.sleep(for: .milliseconds(50))

        #expect(h.config.projects.map(\.name) == [AgentBridgeHarness.projectName, "Second"])
        #expect(h.config.persistenceErrorMessage?.hasPrefix("Agents configuration could not be saved: ") == true)
    }

    /// A failed save of a record is listed with the configuration issue
    /// until a save succeeds.
    @Test func failedRecordSaveIsShown() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: h.root.statusDir.path)

        try h.completeTurn(id)

        let file = AgentRecord.url(id, h.root.statusDir)
        let issue = try #require(h.bridge.storageErrors[file])
        #expect(issue.hasPrefix("The record of Agent could not be saved: "))
        #expect(h.diagnostics.messages.contains(issue))

        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: h.root.statusDir.path)
        h.view(id)
        #expect(h.bridge.storageErrors.isEmpty)
        #expect(try h.recordedUnread().isEmpty)
    }
}
