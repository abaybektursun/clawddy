import AppKit
import Foundation
import Testing
@testable import Ghostty

/// The states the window shows (`flows.md` 2.1), a function of the record
/// alone, and the words for them (`words.md`).
struct AgentPresentationTests {
    private static func record(_ change: (inout AgentRecord) -> Void) -> AgentRecord {
        var record = AgentRecord()
        change(&record)
        return record
    }

    @Test func everyRecordStateHasOneShownState() {
        let cases: [(AgentRecord, AgentShownState, Bool)] = [
            (Self.record { $0.state = .working }, .working, false),
            (Self.record { $0.state = .asks }, .asks, true),
            (Self.record { $0.state = .problem }, .problem, true),
            (Self.record { $0.state = .finished; $0.unread = true }, .finishedUnread, true),
            (Self.record { $0.state = .finished }, .finished, false),
            (Self.record { $0.state = .paused }, .paused, false),
            (Self.record { $0.state = .limitReset }, .limitReset, true),
        ]
        for (record, state, waiting) in cases {
            #expect(AgentShownState(record) == state)
            #expect(record.isWaitingOnYou == waiting, "\(state)")
        }
        #expect(Set(cases.map { "\($0.1)" }).count == AgentShownState.allCases.count)
    }

    /// The marks' VoiceOver labels, as words.md writes them.
    @Test func everyStateIsNamedInTheWordsOfWordsMd() {
        #expect(AgentShownState.allCases.map(\.name) == [
            "Working", "Has a question", "Stopped with a problem", "Finished, unread", "Finished",
            "Paused at its usage limit", "Usage limit reset",
        ])
        #expect(AgentShownState.working.agePhrase(4 * 60) == "working for 4 minutes")
        #expect(AgentShownState.asks.agePhrase(10) == "asked just now")
        #expect(AgentShownState.finished.agePhrase(3 * 3600) == "finished 3 hours ago")
        #expect(AgentShownState.limitReset.agePhrase(60) == "reset 1 minute ago")
    }

    @Test func agesAreWrittenAsTheDesignSays() {
        #expect(AgentAge.short(10) == "now")
        #expect(AgentAge.short(44) == "now")
        #expect(AgentAge.short(4 * 60) == "4m")
        #expect(AgentAge.short(3 * 3600 + 5) == "3h")
        #expect(AgentAge.short(2 * 86400) == "2d")
        #expect(AgentAge.header(.working, age: 130) == "working 2m")
        #expect(AgentAge.header(.finished, age: 20) == "just now")
        #expect(AgentAge.header(.finishedUnread, age: 240) == "4m ago")
        #expect(AgentWaitingWords.count(0) == "No one is waiting")
        #expect(AgentWaitingWords.count(3) == "3 waiting on you")
    }

    /// The count of the dock badge, the status item and the top bar is the
    /// record's `isWaitingOnYou`: a question, a problem and a finished turn
    /// not yet seen; not a working agent.
    @MainActor
    @Test func onlyWaitingOnYouAsksForAttention() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let done = try h.addAgent("Done")
        let failed = try h.addAgent("Failed")
        let working = try h.addAgent("Working")
        h.start()
        try h.launch(done)
        try h.completeTurn(done)
        try h.launch(failed)
        try h.startTurn(failed)
        try h.osc(failed, "state=error:app=claude-code")
        try h.launch(working)
        try h.startTurn(working)

        #expect(h.bridge.waitingAgentCount == 2)
        #expect(h.waitingCounts == [0, 1, 2])
        #expect(Set(h.bridge.agents.values.filter(\.isWaiting).map(\.id)) == [done, failed])
    }

    /// The walk's order (flows.md 6.6): the current project first; within a
    /// project questions, then problems, then finished unread; within
    /// those, the longest waiting first.
    @MainActor
    @Test func waitingAgentsAreWalkedInTheDesignsOrder() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        try #require(h.config.addProject(name: "Other") != nil)
        let done = try h.addAgent("Done")
        let failed = try h.addAgent("Failed")
        let asks = try h.addAgent("Asks")
        let working = try h.addAgent("Working")
        let elsewhere = try #require(h.config.addAgent(project: "Other", name: "Elsewhere")).id
        h.start()
        try h.launch(done)
        try h.completeTurn(done)
        h.scheduler.advance(by: 5)
        try h.launch(failed)
        try h.startTurn(failed)
        try h.osc(failed, "state=error:app=claude-code")
        try h.launch(asks)
        try h.startTurn(asks)
        try h.osc(asks, "state=blocked:app=claude-code:kind=question")
        try h.launch(working)
        try h.startTurn(working)
        try h.launch(elsewhere)
        try h.completeTurn(elsewhere)
        let project = try #require(h.config.projects.first { $0.name == AgentBridgeHarness.projectName }).id
        let other = try #require(h.config.projects.first { $0.name == "Other" }).id

        #expect(AgentWaitingOrder.agents(projects: h.config.projects, agents: h.bridge.agents, currentProject: project).map(\.id)
            == [asks, failed, done, elsewhere])
        #expect(AgentWaitingOrder.agents(projects: h.config.projects, agents: h.bridge.agents, currentProject: other).map(\.id)
            == [elsewhere, asks, failed, done])
    }
}
