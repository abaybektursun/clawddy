import Foundation
import Testing
@testable import Ghostty

/// At most three CLIs start at once (`AgentBridge.startConcurrency`, flows.md
/// 4.5): a burst waits its turn, never runs out of time while waiting, says
/// so in plain words, and asks "is this conversation open elsewhere?" with
/// one listing. And what of a record is written, and when
/// (`AgentBridge.saveRecord`).
@MainActor
struct AgentStartQueueTests {
    /// Ten agents opened at once: three begin, the rest wait their turn and
    /// say so; each one whose CLI comes up lets the next begin; none that
    /// waited runs out of time, however long the wait.
    @Test func aBurstOfStartsWaitsItsTurn() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let ids = try (0..<10).map { try h.addAgent("agent \($0)") }
        h.start()
        for id in ids { try h.activate(id) }

        #expect(h.providers.launchRequests.count == AgentBridge.startConcurrency)
        let waiting = try ids.filter { try h.agent($0).waitsToStart }
        #expect(waiting.count == 7)
        for id in waiting {
            #expect(try h.agent(id).sentence == .app("Waiting to start. 3 agents start at a time."))
        }

        // Each CLI that comes up lets one more begin, until all have; those
        // that waited longest waited far past the start limit, and none
        // failed.
        var begun = h.providers.launchRequests.count
        while begun < ids.count {
            h.scheduler.advance(by: AgentBridge.startLimit - 1)
            let up = h.providers.launchRequests.map(\.agentID).filter { id in (try? h.agent(id).runtime.inputReady) == false }
            for id in up { try h.osc(id, "state=idle:app=claude-code") }
            h.scheduler.advance(by: 0)
            #expect(h.providers.launchRequests.count == min(ids.count, begun + up.count))
            begun = h.providers.launchRequests.count
        }
        for id in ids { #expect(try h.agent(id).record.problem == nil) }
        #expect(try ids.allSatisfy { try !h.agent($0).waitsToStart })
    }

    /// Last review ruling 5: settled means stopped. An agent settled (here
    /// by removing its project) while its launch waits its turn is taken
    /// off the queue and never launched when a slot opens; nothing sent to
    /// it is typed, and opening it launches nothing until it is brought back.
    @Test func aSettledAgentIsNeverLaunchedOrSentTo() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let ids = try (0..<5).map { try h.addAgent("agent \($0)") }
        h.start()
        for id in ids { try h.activate(id) }
        let queued = ids[4]
        #expect(try h.agent(queued).waitsToStart)
        #expect(h.bridge.settle(id: queued, includingWorking: true))
        #expect(try !h.agent(queued).waitsToStart)
        #expect(try h.agent(queued).processState != .launching)
        // Every slot opens: the settled one never begins.
        for request in h.providers.launchRequests { try h.osc(request.agentID, "state=idle:app=claude-code") }
        h.scheduler.advance(by: 0)
        #expect(h.providers.launchRequests.count == 4)
        #expect(!h.providers.launchRequests.contains { $0.agentID == queued })
        var result: AgentSendResult?
        h.bridge.send("hello", to: queued, by: .person) { result = $0 }
        #expect(result == .notReady)
        try h.activate(queued)
        #expect(!h.providers.launchRequests.contains { $0.agentID == queued })
        // Settling one that is up: sends to it are refused too.
        let up = ids[0]
        #expect(h.bridge.settle(id: up))
        result = nil
        h.bridge.send("hello", to: up, by: .person) { result = $0 }
        #expect(result == .notReady)
        // Brought back, it starts as before.
        h.bridge.unsettle(id: queued)
        try h.activate(queued)
        #expect(h.providers.launchRequests.contains { $0.agentID == queued })
    }

    /// The person's open goes ahead of the agents waiting.
    @Test func thePersonsOpenGoesFirst() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let ids = try (0..<6).map { try h.addAgent("agent \($0)") }
        h.start()
        let project = try #require(h.config.project(forAgent: ids[0]))
        for id in ids {
            _ = h.bridge.startAgent(
                task: "task", provider: .claudeCode, launchProfile: AgentLaunchProfile(),
                config: h.config, project: project, host: h.host)
            _ = id
        }
        let started = h.providers.launchRequests.count
        try h.activate(ids[5])
        let first = try #require(h.providers.launchRequests.first)
        try h.osc(first.agentID, "state=idle:app=claude-code")
        h.scheduler.advance(by: 0)
        #expect(h.providers.launchRequests.count == started + 1)
        #expect(h.providers.launchRequests.last?.agentID == ids[5])
    }

    /// The launches of one burst share one listing of the running
    /// conversations; the next burst takes a new one.
    @Test func aBurstAsksOnceWhetherConversationsRunElsewhere() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let ids = try (0..<5).map { try h.addAgent("agent \($0)") }
        let later = try h.addAgent("later")
        h.start()
        for id in ids { try h.activate(id) }
        while h.providers.launchRequests.count < ids.count {
            let up = h.providers.launchRequests.map(\.agentID).filter { id in (try? h.agent(id).runtime.inputReady) == false }
            try h.osc(try #require(up.first), "state=idle:app=claude-code")
            h.scheduler.advance(by: 0)
        }
        let listings = h.providers.launchRequests.map { ObjectIdentifier($0.liveSessions) }
        #expect(Set(listings).count == 1)

        // All are up: the next start is a new burst.
        for id in ids where try !h.agent(id).runtime.inputReady { try h.osc(id, "state=idle:app=claude-code") }
        h.scheduler.advance(by: 0)
        try h.activate(later)
        #expect(h.providers.launchRequests.last?.agentID == later)
        #expect(ObjectIdentifier(try #require(h.providers.launchRequests.last).liveSessions) != listings[0])
    }

    /// One listing answers every launch that shares it: Claude's list of
    /// running conversations is asked for once for two resumes.
    @Test func oneListingAnswersEveryLaunchOfABurst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clawddy-listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let claude = folder.appendingPathComponent("claude")
        let calls = folder.appendingPathComponent("calls")
        try Data("#!/bin/sh\necho x >> '\(calls.path)'\necho '[]'\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let provider = ClaudeCodeProvider(root: AgentDataRoot(url: folder.appendingPathComponent("root")))
        let shared = AgentLiveSessions()
        for session in ["s-1", "s-2"] {
            var request = AgentLaunchRequest(
                agentID: UUID(), name: "Agent", provider: .claudeCode, launchProfile: AgentLaunchProfile(),
                workingDirectory: nil, environmentPath: folder.path, launchGeneration: UUID(),
                session: AgentSessionBinding(provider: .claudeCode, sessionID: session))
            request.liveSessions = shared
            guard case .success = provider.prepareLaunch(request) else {
                Issue.record("A launch with a readable listing failed.")
                return
            }
        }
        #expect(shared.taken == 1)
        #expect(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count == 1)
    }

    // MARK: What is written, and when

    /// The step a working CLI reports, many times a second, is never
    /// written; every change a restart or find depends on is, at once.
    @Test func onlyWhatARestartNeedsIsWritten() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("agent")
        h.start()
        try h.launch(id)
        try h.startTurn(id)
        try h.hook(id, "UserPromptSubmit", text: "build it")
        let file = AgentRecord.url(id, h.root.statusDir)
        let written = try Data(contentsOf: file)
        #expect(try AgentRecord.load(id, from: h.root.statusDir)?.state == .working)

        for step in 0..<20 {
            try h.osc(id, "state=working:app=claude-code:msg=\(Data("Step \(step)".utf8).base64EncodedString())")
        }
        #expect(try h.agent(id).record.activity == "Step 19")
        #expect(try Data(contentsOf: file) == written)

        try h.osc(id, "state=done:app=claude-code")
        let saved = try #require(try AgentRecord.load(id, from: h.root.statusDir))
        #expect(saved.state == .finished)
        #expect(saved.activity == nil)
        #expect(saved.prompts.map(\.text) == ["build it"])
    }

    /// A turn a restart cut off goes on with its age: the continuation keeps
    /// the turn's start.
    @Test func aContinuationKeepsTheTurnsAge() throws {
        var record = AgentRecord()
        record.state = .working
        record.cutOff = true
        record.changedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var state = AgentRuntimeSnapshot()
        state.record = record
        let next = AgentStateReducer.reduce(
            state, event: .continuedByApp(prompt: AgentBridge.continueMessage),
            at: Date(timeIntervalSinceReferenceDate: 5_000)).state
        #expect(next.record.changedAt == Date(timeIntervalSinceReferenceDate: 1_000))
        #expect(next.record.continuedInARow == 1)
    }
}
