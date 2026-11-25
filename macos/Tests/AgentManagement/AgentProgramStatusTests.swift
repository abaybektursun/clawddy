import Combine
import Foundation
import Testing
import UserNotifications
@testable import Ghostty

private let idle = "state=idle:app=claude-code"
private let working = "state=working:app=claude-code"
private let done = "state=done:app=claude-code"
private let clear = "state=clear"
/// c3's summary, which the `done` ending its compaction repeats.
private let greetedSummary = "state=done:app=claude-code:msg=Z3JlZXRlZCB1c2VyOyBubyB0YXNrIHBlbmRpbmc="
/// c2's failure: a model that does not exist.
private let modelError = "state=error:app=claude-code:msg=VGhlcmUncyBhbiBpc3N1ZSB3aXRoIHRoZSBzZWxlY3RlZCBtb2RlbCAocDM1YS1pbnZhbGlkLW1vZGVsKS4gSXQgbWF5IG5vdCBleGlzdCBvciB5b3UgbWF5IG5vdCBoYXZlIGFjY2VzcyB0byBpdC4gUnVuIC9tb2RlbCB0byBwaWNrIGEgZGlmZmVyZW50IG1vZGVsLg=="
private let modelErrorText = "There's an issue with the selected model (p35a-invalid-model). It may not exist or you may not have access to it. Run /model to pick a different model."
/// How long a hook record takes to reach the bridge through the event file.
private let hookDelay: TimeInterval = 0.25

/// Claude's turn activity from its program status (P3.5). Each test replays
/// what `docs/clawddy-refactor/cli-facts.md` captured, report bodies and
/// their times since spawn, through the agent's terminal; hook records reach
/// the bridge `hookDelay` after Claude ran the hook. Notification
/// identifiers end in `.completed`, `.waiting` or `.error`.
@MainActor
struct AgentProgramStatusTests {
    // MARK: F1: what Claude reports

    /// F1 (exp2): nothing is reported until the folder trust dialog is
    /// accepted (Enter at 2.683 s). The first report, `idle` at 3.047 s,
    /// shows Claude ready: alive, its launch script gone, and no "status
    /// unavailable" when the 10 s launch timeout passes.
    @Test func firstReportWithin10sPreventsStatusUnavailable() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.activate(id)
        let agent = try h.agent(id)
        #expect(agent.terminal == .starting)
        #expect(try h.launchScripts().count == 1)

        try h.osc(id, at: 3.047, idle)

        #expect(agent.terminal == .idle)
        #expect(agent.processState == .running)
        #expect(agent.telemetryHealth == .live)
        #expect(try h.launchScripts().isEmpty)
        try h.at(12)
        #expect(agent.terminal == .idle)
        #expect(h.notifier.posted.isEmpty)
        #expect(h.notifier.announced.isEmpty)
    }

    /// F1 (exp1): declining the trust dialog reports `clear`, and Claude
    /// exits with status 1, which the launch script reports at once. `clear`
    /// is no sign of life, so the launch failed to start.
    @Test func declinedTrustIsAStartFailure() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.activate(id)
        let agent = try h.agent(id)

        try h.osc(id, at: 2.283, clear)
        #expect(agent.processState == .launching)
        #expect(agent.terminal == .starting)
        #expect(try h.launchScripts().count == 1)
        try h.at(2.555)
        try h.providerExited(id, status: 1)

        #expect(agent.shownState == .problem)
        #expect(agent.record.problem?.text == "It exited before its session started.")
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).error"])
    }

    /// F1 and F2 (exp2): a tool that needs permission reports `working` with
    /// what it does, then `blocked` with kind `permission`: the agent waits
    /// for the user, notified once, time-sensitive, and announced. Esc on the
    /// prompt reports `idle`: the agent is ready again, and no turn was
    /// completed.
    @Test func escOnPermissionPromptReturnsToIdle() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.osc(id, at: 21.103, working)
        try h.osc(id, at: 23.922, "state=working:app=claude-code:msg=Q3JlYXRpbmcgZW1wdHkgbWFya2VyIGZpbGU=")
        #expect(agent.activityState == .executing)
        try h.osc(id, at: 24.020, "state=blocked:app=claude-code:kind=permission:msg=YXBwcm92ZSBCYXNoOiB0b3VjaCBzcGlrZV9tYXJrZXIudHh0")

        #expect(agent.record.state == .asks)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).waiting"])
        let waiting = try #require(h.notifier.posted.last)
        #expect(waiting.content.interruptionLevel == .timeSensitive)
        #expect(waiting.content.sound == nil)
        #expect(h.notifier.announced == ["Agent, approve Bash: touch spike_marker.txt"])

        try h.osc(id, at: 34.394, idle)

        #expect(agent.terminal == .idle)
        #expect(agent.turnState == .inactive)
        #expect(agent.record.state != .asks)
        #expect(agent.lastAppliedCompletion == nil)
        #expect(h.notifier.posted.count == 1)
        #expect(h.notifier.announced.count == 1)
    }

    /// F1 (exp3): AskUserQuestion reports `blocked` with kind `question`;
    /// the answer brings `working`, `done` completes the turn, and the
    /// summary `done` 2.3 s later adds nothing.
    @Test func questionWaitsForInputAndTheAnswerCompletes() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.osc(id, at: 22.125, working)
        try h.osc(id, at: 25.498, "state=blocked:app=claude-code:kind=question:msg=YW5zd2VyOiBXaGljaCBkbyB5b3UgY2hvb3NlOiBBIG9yIEI/IChBIMK3IEIp")
        #expect(agent.record.state == .asks)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).waiting"])

        try h.osc(id, at: 28.803, working)
        #expect(agent.activityState == .executing)
        try h.osc(id, at: 30.396, done)
        #expect(agent.shownState == .finishedUnread)
        try h.osc(id, at: 32.672, "state=done:app=claude-code:msg=YW5zd2VyZWQgQS9CIHF1ZXN0aW9uIHdpdGggbGV0dGVyIEE=")

        #expect(agent.shownState == .finishedUnread)
        #expect(h.notifier.posted.map(\.identifier) == [
            "clawddy.\(id.uuidString).waiting",
            "clawddy.\(id.uuidString).completed",
        ])
        #expect(h.notifier.announced == ["Agent, Which do you choose: A or B? (A · B)", "Agent, Finished"])
    }

    // MARK: F2: how turns end

    /// F2 (exp2): `done` comes as the turn ends and stays; a second `done`
    /// carrying a summary follows 2.0 s later. One turn, one completion.
    /// Until its prompt reaches the bridge the agent shows what it showed
    /// before.
    @Test func secondDoneIsNotASecondCompletion() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.osc(id, at: 10.135, working)
        try h.at(10.3)
        #expect(agent.terminal == .idle)
        // Its hook ran by 10.268, when the title it set appeared.
        try h.hook(id, at: 10.16 + hookDelay, "UserPromptSubmit")
        #expect(agent.terminal == .busy)
        try h.osc(id, at: 12.908, done)
        let completion = try #require(agent.lastAppliedCompletion)
        #expect(completion.sessionID == "session-1")
        #expect(agent.shownState == .finishedUnread)
        let notification = try #require(h.notifier.posted.last)
        #expect(notification.identifier == "clawddy.\(id.uuidString).completed")
        #expect(notification.content.interruptionLevel == .passive)
        #expect(notification.content.sound == nil)

        try h.osc(id, at: 14.911, "state=done:app=claude-code:msg=cmVwbGllZCB3aXRoIHRoZSBzaW5nbGUgd29yZCBvayBhcyByZXF1ZXN0ZWQ=")

        #expect(agent.lastAppliedCompletion == completion)
        #expect(agent.lastAppliedCompletion == completion)
        #expect(h.notifier.posted.count == 1)
        #expect(h.notifier.announced == ["Agent, Finished"])
        #expect(try h.recordedUnread() == [id])
        // Done is unread, not a request for attention.
        #expect(h.waitingCounts == [0, 1])
    }

    /// F2 (exp2): Esc mid-turn reports `idle` 46 ms later. The turn ends as
    /// interrupted: ready, nothing completed, nothing notified.
    @Test func interruptReturnsToIdleWithNoCompletion() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.osc(id, at: 44.527, working)
        try h.at(47.0)
        #expect(agent.activityState == .executing)
        try h.osc(id, at: 47.824, idle)

        #expect(agent.terminal == .idle)
        #expect(agent.turnState == .inactive)
        #expect(agent.lastAppliedCompletion == nil)
        #expect(!agent.record.unread)
        #expect(h.notifier.posted.isEmpty)
        #expect(h.notifier.announced.isEmpty)
        #expect(h.waitingCounts == [0])
    }

    /// F2 and P3.5a case 7 (c1): `/clear` reports `working` and, 63 ms
    /// later, `idle`. No turn starts, so the unread completion of the turn
    /// before stays and nothing is notified; the hooks rebind the agent to
    /// the new session Claude starts.
    @Test func clearBlipRaisesNothing() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)
        try h.osc(id, at: 19.277, working)
        try h.osc(id, at: 21.189, done)
        try h.osc(id, at: 22.852, "state=done:app=claude-code:msg=cmVwbGllZCAnbm8nIGFzIHJlcXVlc3RlZA==")
        let unread = try #require(agent.lastAppliedCompletion)
        let counts = h.waitingCounts

        try h.osc(id, at: 28.470, working)
        try h.osc(id, at: 28.533, idle)
        try h.hook(id, at: 28.504 + hookDelay, "SessionEnd")
        try h.hook(id, at: 28.548 + hookDelay, "SessionStart", session: "session-after-clear")
        try h.at(29)

        #expect(agent.shownState == .finishedUnread)
        #expect(agent.lastAppliedCompletion == unread)
        #expect(agent.processState == .running)
        #expect(agent.sessionID == "session-after-clear")
        #expect(try h.binding(id).sessionID == "session-after-clear")
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).completed"])
        #expect(h.notifier.announced.count == 1)
        #expect(h.waitingCounts == counts)
    }

    /// F1 and F2 (exp2): `/exit` reports `working`, then `clear` three times
    /// within 16 ms. Nothing is raised, and nothing touches the terminal,
    /// which these reports reach inside the app tick. The launch script's
    /// exit report ends the launch, also inside the app tick; the login shell
    /// keeps the terminal.
    @Test func exitBlipRaisesNothingAndTheExitReportEndsTheLaunch() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)
        let calls = h.host.calls

        try h.osc(id, at: 70.026, working)
        try h.osc(id, at: 70.035, clear)
        try h.osc(id, at: 70.041, clear)
        try h.osc(id, at: 70.042, clear)
        try h.at(70.5)
        #expect(agent.terminal == .idle)
        #expect(agent.processState == .running)
        #expect(h.host.calls == calls)
        try h.at(71.143)
        try h.providerExited(id, status: 0)

        #expect(agent.terminal == .notRunning)
        #expect(h.host.calls == calls)
        #expect(h.host.hasSurface(id: id))
        #expect(h.waitingCounts == [0])
        #expect(h.notifier.posted.isEmpty)
        #expect(h.notifier.announced.isEmpty)
    }

    // MARK: P3.5a cases

    /// Case 1 (c1): a prompt submitted 1.07 s after `done` cancels that
    /// turn's summary; the next summary comes 1.72 s after its `done`,
    /// before the next `working`. Three turns, three completions.
    @Test func promptSoonAfterDoneCompletesEachTurnOnce() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.osc(id, at: 10.224, working)
        try h.hook(id, at: 10.535 + hookDelay, "UserPromptSubmit")
        try h.osc(id, at: 13.841, done)
        try h.osc(id, at: 14.912, working)
        try h.hook(id, at: 14.933 + hookDelay, "UserPromptSubmit")
        try h.at(15.2)
        #expect(agent.terminal == .busy)
        #expect(!agent.record.unread)
        try h.osc(id, at: 17.060, done)
        try h.osc(id, at: 18.775, "state=done:app=claude-code:msg=cmVwbGllZCAneWVzJyBhcyByZXF1ZXN0ZWQ=")
        try h.osc(id, at: 19.277, working)
        try h.hook(id, at: 19.300 + hookDelay, "UserPromptSubmit")
        try h.osc(id, at: 21.189, done)
        try h.osc(id, at: 22.852, "state=done:app=claude-code:msg=cmVwbGllZCAnbm8nIGFzIHJlcXVlc3RlZA==")

        #expect(agent.shownState == .finishedUnread)
        #expect(h.notifier.posted.map(\.identifier)
            == Array(repeating: "clawddy.\(id.uuidString).completed", count: 3))
    }

    /// Case 2 and amendment 4 (c2): a failed turn reports `error` with
    /// Claude's text 439 ms after `working`; its `StopFailure` hook runs
    /// 15 ms later and reaches the bridge after the report. The agent shows
    /// the text, and each failed turn is notified and announced once.
    @Test func failureNotifiesOnceWhenTheReportComesFirst() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)
        let error = "clawddy.\(id.uuidString).error"

        try h.osc(id, at: 9.987, working)
        try h.hook(id, at: 10.011 + hookDelay, "UserPromptSubmit")
        try h.osc(id, at: 10.426, modelError)
        #expect(agent.shownState == .problem)
        #expect(agent.record.problem?.text == modelErrorText)
        #expect(h.notifier.posted.last?.content.interruptionLevel == .active)
        try h.hook(id, at: 10.441 + hookDelay, "StopFailure")
        #expect(agent.record.problem?.text == modelErrorText)
        #expect(h.notifier.posted.map(\.identifier) == [error])

        // The next prompt fails the same way: a second failed turn.
        try h.osc(id, at: 18.093, working)
        try h.hook(id, at: 18.120 + hookDelay, "UserPromptSubmit")
        #expect(agent.terminal == .busy)
        #expect(agent.record.problem == nil)
        try h.osc(id, at: 18.487, modelError)
        try h.hook(id, at: 18.509 + hookDelay, "StopFailure")

        #expect(agent.shownState == .problem)
        #expect(!agent.record.unread)
        #expect(h.notifier.posted.map(\.identifier) == [error, error])
        #expect(h.notifier.announced == ["Agent, \(modelErrorText)", "Agent, \(modelErrorText)"])
    }

    /// Amendment 4: nothing orders the two channels. A `StopFailure` record
    /// that comes before the report fails the turn with a general message;
    /// the report then only adds Claude's text.
    @Test func failureNotifiesOnceWhenTheHookComesFirst() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.osc(id, at: 9.987, working)
        try h.hook(id, at: 10.300, "StopFailure")
        #expect(agent.shownState == .problem)
        #expect(agent.record.problem == AgentRecord.Problem(kind: .error))
        try h.osc(id, at: 10.426, modelError)

        #expect(agent.record.problem?.text == modelErrorText)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).error"])
        #expect(h.notifier.announced == ["Agent, Stopped with an error. Open it to see why."])
    }

    /// Review M5: the `StopFailure` record of a failure the report already
    /// raised changes nothing even when an `idle` (Esc on the failed turn)
    /// or a settled next turn reaches the bridge in between: one failed turn
    /// is one notification, and the running turn stays running.
    @Test func lateStopFailureOfAReportedFailureChangesNothing() throws {
        // A problem stays until the next turn (`flows.md` 2.2).
        for (between, shown) in [(idle, AgentShownState.problem), (working, .working)] {
            let h = try AgentBridgeHarness()
            defer { h.remove() }
            let id = try h.addAgent("Agent")
            h.start()
            h.spawn()
            try h.launch(id)
            let agent = try h.agent(id)

            try h.osc(id, at: 9.987, working)
            try h.osc(id, at: 10.426, modelError)
            #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).error"])
            try h.osc(id, at: 10.45, between)
            // The record, written at 10.441, reaches the bridge up to 0.3 s
            // later: after a `working` at 10.45, and its prompt, have started
            // the next turn.
            if between == working { try h.hook(id, at: 10.72, "UserPromptSubmit") }
            try h.at(10.74)
            #expect(agent.shownState == shown)
            try h.hook(id, at: 10.741, "StopFailure")

            #expect(agent.shownState == shown)
            #expect((agent.record.problem == nil) == (between == working))
            #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).error"])
            #expect(h.notifier.announced == ["Agent, \(modelErrorText)"])
            // The next failure is reported again.
            try h.osc(id, at: 20, working)
            try h.osc(id, at: 20.4, modelError)
            try h.hook(id, at: 20.42 + hookDelay, "StopFailure")
            #expect(h.notifier.posted.map(\.identifier).count == 2)
        }
    }

    /// Review M7: a `StopFailure` record that reaches the bridge after the
    /// exit report fails nothing more: the provider has gone, as for a late
    /// prompt, and its exit is the one problem.
    @Test func stopFailureAfterTheExitReportChangesNothing() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.startTurn(id)
        try h.providerExited(id, status: 1)
        let agent = try h.agent(id)
        let exited = AgentRecord.Problem(kind: .exited, status: 1)
        #expect(agent.record.problem == exited)

        try h.hook(id, "StopFailure")

        #expect(agent.record.problem == exited)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).error"])
        #expect(h.notifier.announced == ["Agent, Claude Code stopped (status 1). Type here to continue."])
    }

    /// Case 2 and amendment 2 (c2b): with no route to the API, `error` comes
    /// 106 ms after `working`, inside the turn-start delay. A failure is
    /// never a blip: the turn starts and fails at once, notified once.
    @Test func failureWithinTheTurnStartDelayStillFails() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.osc(id, at: 7.445, working)
        try h.osc(id, at: 7.551, "state=error:app=claude-code:msg=QVBJIEVycm9yOiBDb25uZWN0aW9uIHJlZnVzZWQg4oCUIGEgZmlyZXdhbGwgb3IgcHJveHkgbWF5IGJlIGJsb2NraW5nIGl0IChFQ09OTlJFRlVTRUQp")
        #expect(agent.shownState == .problem)
        #expect(agent.record.problem?.text
            == "API Error: Connection refused — a firewall or proxy may be blocking it (ECONNREFUSED)")
        try h.hook(id, at: 7.578 + hookDelay, "StopFailure")
        try h.at(8)

        #expect(agent.shownState == .problem)
        #expect(agent.turnState == .inactive)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).error"])
    }

    /// Case 3 and amendment 1 (c3): `/compact` is reported as one `working`
    /// of 13.2 s, ended by a `done` that repeats the previous summary. Its
    /// `PreCompact` hook, `trigger: "manual"`, reaches the bridge after the
    /// turn-start delay and makes the turn a compaction, shown as optimizing
    /// context; its `done` completes nothing. `SessionStart` (source
    /// `compact`) and `PostCompact` reach the bridge after that `done` and
    /// change nothing.
    @Test func manualCompactionIsNotACompletion() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)
        try h.osc(id, at: 12.931, working)
        try h.hook(id, at: 12.951 + hookDelay, "UserPromptSubmit")
        try h.osc(id, at: 15.220, done)
        try h.osc(id, at: 16.665, greetedSummary)
        let completion = try #require(agent.lastAppliedCompletion)

        // The user types `/compact` in the agent, so it is looked at.
        h.view(id)
        try h.osc(id, at: 22.627, working)
        try h.hook(id, at: 22.653 + hookDelay, "PreCompact", trigger: "manual")
        #expect(agent.turnState == .compaction)
        #expect(agent.terminal == .compacting)
        try h.at(35.5)
        #expect(agent.terminal == .compacting)
        try h.osc(id, at: 35.840, greetedSummary)
        #expect(agent.terminal == .idle)
        try h.hook(id, at: 35.787 + hookDelay, "SessionStart")
        try h.hook(id, at: 35.819 + hookDelay, "PostCompact", trigger: "manual")

        #expect(agent.terminal == .idle)
        #expect(agent.turnState == .inactive)
        #expect(agent.lastAppliedCompletion == completion)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).completed"])
        #expect(h.notifier.announced == ["Agent, Finished"])
    }

    /// Amendment 1, the hook inside the turn-start delay: the compaction
    /// starts at once. After a turn that left no summary its `done` is bare,
    /// and only the hook tells it from a completion. A compaction longer
    /// than 30 s stays one until its `done`.
    @Test func manualCompactionHookWithinTheTurnStartDelay() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.osc(id, at: 1.0, working)
        try h.hook(id, at: 1.2, "PreCompact", trigger: "manual")
        #expect(agent.terminal == .compacting)
        try h.at(40)
        #expect(agent.terminal == .compacting)
        try h.osc(id, at: 41, done)

        #expect(agent.terminal == .idle)
        #expect(agent.lastAppliedCompletion == nil)
        #expect(h.notifier.posted.isEmpty)
    }

    /// The hook before its `working`, not captured: with no turn under way
    /// it changes nothing, since it cannot be told from a hook that comes
    /// after a short compaction's `done`. The compaction runs as a turn, and
    /// its `done`, which repeats the previous summary, completes nothing.
    @Test func manualCompactionHookBeforeItsWorking() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.hook(id, at: 22.600, "PreCompact", trigger: "manual")
        #expect(agent.turnState == .inactive)
        try h.osc(id, at: 22.627, working)
        try h.at(22.627 + h.providers.table.claudeCode.turnStartDelay)
        #expect(agent.activityState == .executing)
        try h.osc(id, at: 35.840, greetedSummary)

        #expect(agent.terminal == .idle)
        #expect(agent.lastAppliedCompletion == nil)
        #expect(h.notifier.posted.isEmpty)
    }

    /// A compaction so short that its `done` comes before its `PreCompact`
    /// record: the record finds no turn and changes nothing, so the next real
    /// turn still completes.
    @Test func manualCompactionHookAfterItsDoneChangesNothing() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.osc(id, at: 1.0, working)
        try h.osc(id, at: 1.1, greetedSummary)
        try h.hook(id, at: 1.3, "PreCompact", trigger: "manual")
        #expect(agent.turnState == .inactive)
        try h.osc(id, at: 5.0, working)
        try h.osc(id, at: 7.0, done)

        #expect(agent.shownState == .finishedUnread)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).completed"])
    }

    /// An automatic compaction (`trigger: "auto"`, not captured) runs inside
    /// a real turn: it shows while it runs, and the turn's `done` still
    /// completes the turn.
    @Test func automaticCompactionKeepsTheTurnsCompletion() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.startTurn(id)
        try h.hook(id, "PreCompact", trigger: "auto")
        #expect(agent.terminal == .compacting)
        try h.hook(id, "PostCompact", trigger: "auto")
        #expect(agent.activityState == .executing)
        try h.osc(id, done)

        #expect(agent.shownState == .finishedUnread)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).completed"])
    }

    /// Amendment 3: every captured `done` that completed a turn was bare. A
    /// `done` carrying a summary that ends a turn, here a compaction whose
    /// hook never came, ends it without completing it.
    @Test func doneWithSummaryNeverCompletes() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.osc(id, at: 22.627, working)
        try h.at(30)
        #expect(agent.activityState == .executing)
        try h.osc(id, at: 35.840, greetedSummary)

        #expect(agent.terminal == .idle)
        #expect(agent.turnState == .inactive)
        #expect(agent.lastAppliedCompletion == nil)
        #expect(h.notifier.posted.isEmpty)
        #expect(h.notifier.announced.isEmpty)
    }

    /// Case 4 and amendment 5 (c4): the external editor (Ctrl-G), Ctrl-Z and
    /// `fg` report nothing for 19.8 s, and the completed turn stays as it
    /// is. The next prompt reports as usual.
    @Test func suspendAndEditorReportNothingAndTheLastStateStays() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)
        try h.osc(id, at: 16.887, working)
        try h.osc(id, at: 19.569, done)
        try h.osc(id, at: 21.166, "state=done:app=claude-code:msg=Z3JlZXRlZCB0aGUgdXNlcjsgbm90aGluZyBwZW5kaW5n")
        let completion = try #require(agent.lastAppliedCompletion)

        try h.at(40.9)
        #expect(agent.shownState == .finishedUnread)
        #expect(agent.lastAppliedCompletion == completion)
        #expect(agent.telemetryHealth == .live)
        try h.osc(id, at: 40.952, working)
        try h.osc(id, at: 43.176, done)
        try h.osc(id, at: 44.764, "state=done:app=claude-code:msg=cmVwbGllZCAnb2snIGFzIHJlcXVlc3RlZA==")

        #expect(agent.lastAppliedCompletion != completion)
        #expect(h.notifier.posted.map(\.identifier)
            == Array(repeating: "clawddy.\(id.uuidString).completed", count: 2))
    }

    /// Case 5 (c5b): a foreground `sleep 130` reports one `working` with
    /// what it does and then nothing for 131 s. A long silence is normal for
    /// this source: no "status delayed".
    @Test func longSilentTurnDoesNotShowStatusDelayed() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)

        try h.osc(id, at: 9.762, working)
        try h.osc(id, at: 13.737, "state=working:app=claude-code:msg=V2FpdGluZyBmb3IgMTMwIHNlY29uZHM=")
        try h.at(145)
        #expect(agent.activityState == .executing)
        #expect(agent.telemetryHealth == .live)
        try h.osc(id, at: 145.060, done)
        try h.osc(id, at: 146.749, "state=done:app=claude-code:msg=cmFuIHNsZWVwIDEzMCBpbiBmb3JlZ3JvdW5kOyByZXBsaWVkIGZpbmlzaGVk")

        #expect(agent.shownState == .finishedUnread)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).completed"])
    }

    /// Case 5 and amendment 2 (c5): `/exit` while background work runs opens
    /// a confirmation, reported as `working` and, 14 ms later, a `done` that
    /// repeats the last summary. No turn starts: the unread completion stays
    /// and nothing is notified. The session then ends by SIGHUP: `clear`
    /// three times and `SessionEnd`.
    @Test func exitConfirmationBlipRaisesNothing() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        h.spawn()
        try h.launch(id)
        let agent = try h.agent(id)
        let backgroundSummary = "state=done:app=claude-code:msg=c2xlZXAgMTMwIHJ1bm5pbmcgaW4gYmFja2dyb3VuZDsgd2lsbCByZXBseSB3aGVuIGRvbmU="
        try h.osc(id, at: 12.434, working)
        try h.osc(id, at: 16.216, "state=working:app=claude-code:msg=V2FpdGluZyAxMzAgc2Vjb25kcw==")
        try h.osc(id, at: 22.651, "state=working:app=claude-code:msg=V2FpdGluZyAxMzAgc2Vjb25kcyBpbiB0aGUgYmFja2dyb3VuZA==")
        try h.osc(id, at: 24.746, done)
        try h.osc(id, at: 26.355, backgroundSummary)
        let unread = try #require(agent.lastAppliedCompletion)

        try h.osc(id, at: 31.952, working)
        try h.osc(id, at: 31.966, backgroundSummary)
        try h.at(39)
        #expect(agent.lastAppliedCompletion == unread)
        #expect(agent.shownState == .finishedUnread)
        #expect(agent.turnState == .inactive)
        for _ in 0..<3 { try h.osc(id, at: 39.048, clear) }
        try h.hook(id, at: 39.681 + hookDelay, "SessionEnd")

        #expect(agent.processState == .running)
        #expect(agent.record.problem == nil)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).completed"])
    }

    /// Flows capture a (2026-11-14): a new agent's first turn, then
    /// `/resume <id>` typed in Claude to an earlier conversation of the same
    /// folder, then a turn there. `/resume` reports `working` for 280 ms and
    /// `idle`, and submits no prompt, so it is no turn: the agent never shows
    /// Working for it, and the Done before it stays unread. Its hooks end the
    /// agent's session and start the earlier one in the same launch. The
    /// agent is bound to the conversation it now shows, and its turns are
    /// still tracked: the prompt starts Working and reads the Done before,
    /// then Done with a notification.
    @Test func resumeInsideClaudeKeepsTrackingTurns() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        try h.useRealClaudeLaunch()
        let id = try h.addAgent("agent 1")
        h.start()
        h.spawn()
        try h.activate(id)
        let agent = try h.agent(id)
        let first = try #require(agent.sessionID)
        try h.osc(id, at: 0.422, idle)
        try h.hook(id, at: 0.249 + hookDelay, "SessionStart", session: first)
        try h.osc(id, at: 8.118, working)
        try h.hook(id, at: 8.136 + hookDelay, "UserPromptSubmit", session: first)
        #expect(agent.terminal == .busy)
        try h.osc(id, at: 9.684, done)
        try h.osc(id, at: 11.708, "state=done:app=claude-code:msg=cmVwbGllZCB3aXRoIHRoZSBzaW5nbGUgd29yZCBvayBhcyByZXF1ZXN0ZWQ=")
        #expect(agent.shownState == .finishedUnread)
        #expect(try h.binding(id).sessionID == first)

        let before = agent.lastAppliedCompletion
        try h.osc(id, at: 16.064, working)
        try h.at(16.343)
        #expect(agent.shownState == .finishedUnread)
        try h.osc(id, at: 16.344, idle)
        try h.hook(id, at: 16.293 + hookDelay, "SessionEnd", session: first)
        try h.hook(id, at: 16.320 + hookDelay, "SessionStart", session: "earlier-conversation")
        try h.at(18)
        #expect(agent.shownState == .finishedUnread)
        #expect(agent.lastAppliedCompletion == before)
        #expect(agent.sessionID == "earlier-conversation")
        #expect(try h.binding(id).sessionID == "earlier-conversation")

        try h.osc(id, at: 25.549, working)
        try h.hook(id, at: 25.577 + hookDelay, "UserPromptSubmit", session: "earlier-conversation")
        #expect(agent.terminal == .busy)
        #expect(!agent.record.unread)
        try h.osc(id, at: 26.735, done)
        try h.osc(id, at: 28.432, "state=done:app=claude-code:msg=cmVwbGllZCAneWVzJyBhcyByZXF1ZXN0ZWQ=")
        #expect(agent.shownState == .finishedUnread)
        #expect(agent.lastAppliedCompletion?.sessionID == "earlier-conversation")
        #expect(h.notifier.posted.map(\.identifier)
            == Array(repeating: "clawddy.\(id.uuidString).completed", count: 2))
    }

    // MARK: What does not count

    /// Reports after the launch ended change nothing: after the launch
    /// script's exit report, before its terminal closes, including the exit
    /// report printed again; from an earlier launch; and from a terminal
    /// that has closed.
    @Test func reportsAfterExitAreIgnored() async throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let agent = try h.agent(id)
        let first = try h.generation(id)
        try h.providerExited(id, status: 0)
        let exited = agent.runtime

        try h.osc(id, working)
        h.scheduler.advance(by: 1)
        try h.osc(id, "state=blocked:app=claude-code:kind=permission")
        try h.osc(id, modelError)
        // The launch ends once: a second exit report, with a status that
        // would have been a start failure, changes nothing either.
        try h.providerExited(id, status: 1)
        #expect(agent.runtime == exited)
        #expect(agent.terminal == .notRunning)
        #expect(agent.turnState == .inactive)

        try h.activate(id)
        h.bridge.programStatus(id: id, generation: first, report: try programStatus(idle))
        #expect(h.diagnostics.messages.last == "ignored program status for \(id)")
        #expect(agent.terminal == .starting)

        try h.osc(id, idle)
        try h.providerExited(id, status: 0)
        let surface = try #require(h.host.surfaces[id])
        surface.childExited.send()
        await yieldToMainActor(until: { agent.surfaceState == .closed })
        NotificationCenter.default.post(
            name: .ghosttyDidReceiveProgramStatus,
            object: surface,
            userInfo: [Notification.Name.ProgramStatusKey: try programStatus(working)])
        h.bridge.programStatus(
            id: id,
            generation: try h.generation(id),
            report: try programStatus("state=blocked:app=claude-code:kind=permission"))
        h.scheduler.advance(by: 1)

        #expect(agent.terminal == .notRunning)
        #expect(agent.record.state != .asks)
        #expect(agent.turnState == .inactive)
        #expect(h.notifier.posted.isEmpty)
        #expect(h.notifier.announced.isEmpty)
    }

    /// Codex's terminal reports drive its state as Claude's do. Its
    /// start-up `working`, before any prompt, lasts up to 2.4 s and starts
    /// no turn; one that stands 3 s does.
    @Test func codexSurfaceReportsDriveCodexState() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Codex", provider: .codex)
        h.start()
        try h.activate(id)
        let agent = try h.agent(id)

        try h.osc(id, "state=idle:app=codex")
        #expect(agent.processState == .running)
        try h.osc(id, "state=working:app=codex")
        h.scheduler.advance(by: 2.4)
        try h.osc(id, "state=idle:app=codex")
        #expect(agent.turnState == .inactive)
        #expect(agent.terminal == .idle)

        try h.osc(id, "state=working:app=codex")
        h.scheduler.advance(by: 3)
        #expect(agent.turnState == .active(turnID: nil))
        try h.osc(id, "state=error:app=codex")
        #expect(agent.shownState == .problem)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).error"])
    }

    /// Only the program's own record counts. A record beneath it never
    /// changes the agent's state, and is ignored without a word. (The record
    /// `clawddy` is the launch script's exit report.)
    @Test func subRecordsAreIgnored() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let agent = try h.agent(id)
        let before = h.diagnostics.messages

        try h.osc(id, "state=working:id=task.1:app=claude-code")
        try h.osc(id, "state=blocked:id=task.1/tool:kind=permission:app=claude-code")
        h.scheduler.advance(by: 1)

        #expect(agent.terminal == .idle)
        #expect(agent.turnState == .inactive)
        #expect(h.notifier.posted.isEmpty)
        #expect(h.diagnostics.messages == before)
    }
}

/// The program-status mapping alone, as the reducer applies it: one report
/// and the turn it finds give the turn, activity, the record's state and
/// effects after it. No bridge, no clock.
struct AgentProgramStatusMappingTests {
    private struct Row {
        var report: String
        var before: AgentTurnState
        var after: AgentTurnState
        var activity: AgentActivityState
        var record: AgentRecord.State = .finished
        var effects: [AgentRuntimeEffect] = []
    }

    @Test func reportAndTurnGiveTheNextTurnAndEffects() throws {
        let active = AgentTurnState.active(turnID: nil)
        let rows = [
            Row(report: "state=working", before: .inactive, after: .starting, activity: .idle),
            Row(report: "state=working", before: .starting, after: .starting, activity: .idle),
            Row(report: "state=working", before: active, after: active, activity: .executing),
            Row(report: "state=blocked:kind=permission", before: active, after: active, activity: .executing,
                record: .asks, effects: [.waitingForUser]),
            Row(report: "state=blocked:kind=question", before: .starting, after: active, activity: .executing,
                record: .asks, effects: [.waitingForUser]),
            Row(report: "state=blocked:kind=auth", before: .inactive, after: .inactive, activity: .idle,
                record: .problem, effects: [.failed]),
            Row(report: "state=done", before: active, after: .inactive, activity: .idle,
                effects: [.completed, .unreadChanged]),
            Row(report: "state=done:msg=c3VtbWFyeQ==", before: active, after: .inactive, activity: .idle),
            Row(report: "state=done", before: .compaction, after: .inactive, activity: .idle),
            Row(report: "state=done", before: .starting, after: .inactive, activity: .idle),
            Row(report: "state=done", before: .inactive, after: .inactive, activity: .idle),
            Row(report: "state=idle", before: active, after: .inactive, activity: .idle),
            Row(report: "state=idle", before: .compaction, after: .inactive, activity: .idle),
            Row(report: "state=idle", before: .starting, after: .inactive, activity: .idle),
            Row(report: "state=clear", before: active, after: .inactive, activity: .idle),
            Row(report: "state=error", before: .starting, after: .inactive, activity: .idle, record: .problem, effects: [.failed]),
            Row(report: "state=error", before: active, after: .inactive, activity: .idle, record: .problem, effects: [.failed]),
        ]
        for row in rows {
            let result = try reduce(row.before, .programStatus(programStatus(row.report)))
            let label = "\(row.report) after \(row.before)"
            #expect(result.state.turnState == row.after, "\(label)")
            #expect(result.state.activityState == row.activity, "\(label)")
            #expect(result.state.record.state == row.record, "\(label)")
            #expect(result.effects == row.effects, "\(label)")
        }
    }

    /// A `working` that no prompt follows starts its turn only when it has
    /// stood for the delay, which the bridge's timer reports; a prompt
    /// starts the turn at once. Either reads the turn before
    /// (`flows.md` 2.2).
    @Test func settledStartBeginsTheTurn() {
        let generation = UUID()
        var state = running(.starting, generation: generation)
        state.record.unread = true
        let stale = AgentStateReducer.reduce(state, event: .turnStartSettled(generation: UUID()))
        #expect(stale.state == state)

        let settled = AgentStateReducer.reduce(state, event: .turnStartSettled(generation: generation))
        #expect(settled.state.turnState == .active(turnID: nil))
        #expect(settled.state.activityState == .executing)
        #expect(settled.state.record.state == .working && !settled.state.record.unread)
        #expect(settled.effects == [.unreadChanged])

        let prompted = AgentStateReducer.reduce(state, event: .provider(
            generation: generation, provider: .claudeCode, eventID: "prompt",
            event: .promptSubmitted("prompt"), isViewed: false))
        #expect(prompted.state.turnState == .active(turnID: nil))
        #expect(!prompted.state.record.unread)
        #expect(prompted.effects == [.unreadChanged])
    }

    /// `PreCompact` with `trigger: "manual"` makes the turn under way a
    /// compaction, and changes nothing with none under way.
    @Test func manualCompactionMarksOnlyATurnUnderWay() {
        for (before, after) in [
            (AgentTurnState.starting, AgentTurnState.compaction),
            (.active(turnID: nil), .compaction),
            (.inactive, .inactive),
        ] {
            let result = reduce(before, .manualCompactionStarted)
            #expect(result.state.turnState == after, "\(before)")
            #expect(result.effects.isEmpty, "\(before)")
        }
    }

    /// `StopFailure` fails a turn once: after Claude's own `error` report it
    /// only takes the record off the ones due.
    @Test func stopFailureAfterTheErrorReportChangesNothing() throws {
        let failed = try reduce(.active(turnID: nil), .programStatus(programStatus("state=error:msg=bm8gcm91dGU=")))
        #expect(failed.effects == [.failed])
        #expect(failed.state.record.problem?.text == "no route")
        #expect(failed.state.stopFailuresDue == 1)
        var recorded = failed.state
        recorded.stopFailuresDue = 0

        let generation = try #require(failed.state.launchGeneration)
        let hook = AgentStateReducer.reduce(failed.state, event: .provider(
            generation: generation,
            provider: .claudeCode,
            eventID: "hook",
            event: .turnFailed(AgentFailure(error: "server_error", text: "no route")),
            isViewed: false))
        #expect(hook.state == recorded)
        #expect(hook.effects.isEmpty)
    }

    private func running(_ turn: AgentTurnState, generation: UUID) -> AgentRuntimeSnapshot {
        var state = AgentRuntimeSnapshot(
            surfaceState: .open,
            processState: .running,
            activityState: .idle,
            telemetryHealth: .live,
            launchGeneration: generation)
        state.inputReady = true
        state.turnState = turn
        switch turn {
        case .active: state.activityState = .executing
        case .compaction: state.activityState = .compacting
        case .inactive, .starting: break
        }
        return state
    }

    private func reduce(
        _ turn: AgentTurnState,
        _ event: AgentDomainEvent
    ) -> (state: AgentRuntimeSnapshot, effects: [AgentRuntimeEffect]) {
        let generation = UUID()
        return AgentStateReducer.reduce(running(turn, generation: generation), event: .provider(
            generation: generation,
            provider: .claudeCode,
            eventID: "event",
            event: event,
            isViewed: false))
    }
}
