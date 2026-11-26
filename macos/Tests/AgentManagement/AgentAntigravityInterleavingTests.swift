import Foundation
import Testing
@testable import Ghostty

/// agy's two channels, merged every way (coordinator, after the third review
/// of the pairing code). Its terminal reports arrive at once, its hook
/// records up to about a quarter of a second later, each channel in its own
/// order. For each case every merge of the two sequences that keeps each
/// sequence's order is applied to the reducer with agy's rules, and the
/// outcome is checked: each real prompt recorded once and never queued; a
/// wake-up records no prompt; one completion (one `.completed` effect) per
/// completed turn, none for an interrupted one; the last reply is the last
/// completed turn's Stop text; finished, unread exactly when the last
/// completed turn was not viewed (or interrupted, read); and the fields
/// that pair records with reports at rest at the end.
///
/// One rule excludes merges that cannot happen: a turn's Stop record is
/// written after the turn's work, so after its last `working` (and after
/// a permission it asked), and a record never arrives before a report
/// emitted after it was written (reports arrive at once, records later):
/// no Stop comes before its own turn's last non-`done` report (for the turn
/// behind the start dialog, the trust report: probe `stage5/trustprompt`,
/// the report at 0.16 s, its Stop at 5.1 s). A start
/// record (a prompt or agy starting a turn itself) may come on either side
/// of its turn's `working` and before the previous turn's `done`
/// (probes `stage5/queue2`: the queued turn's PreInvocation 0.9 s before
/// the `done` of the turn before).
@MainActor
struct AgentAntigravityInterleavingTests {
    private static let rules = AntigravityProvider(
        root: AgentDataRoot(url: URL(fileURLWithPath: "/nonexistent")),
        dataFolder: URL(fileURLWithPath: "/nonexistent")).entry.reports
    private static let generation = UUID()

    /// One item of either channel.
    enum Item: Equatable {
        case report(state: String, kind: String?, message: String?)
        case record(event: String, invocation: String?, step: String?, text: String?)

        static let working = Item.report(state: "working", kind: nil, message: nil)
        static let idle = Item.report(state: "idle", kind: nil, message: nil)
        static let trust = Item.report(state: "blocked", kind: "permission", message: "Trust this folder?")
        static let approve = Item.report(state: "blocked", kind: "permission", message: "Approve Bash: make")
        static func done(_ reply: String) -> Item { .report(state: "done", kind: nil, message: reply) }
        static func prompt(_ text: String) -> Item { .record(event: "PreInvocation", invocation: "0", step: "USER_INPUT", text: text) }
        static let selfStart = Item.record(event: "PreInvocation", invocation: "0", step: "PLANNER_RESPONSE", text: "earlier words")
        static func stop(_ reply: String) -> Item { .record(event: "Stop", invocation: nil, step: nil, text: reply) }
        static let sessionStart = Item.record(event: "SessionStart", invocation: nil, step: nil, text: nil)
    }

    /// One turn: its reports, its records, what it records and how it ends.
    struct Turn {
        var name: String
        var reports: [Item]
        var records: [Item]
        var prompt: String?
        /// The Stop text of a completed turn; nil for an interrupted one.
        var reply: String?
    }

    static func normal(_ n: Int) -> Turn {
        Turn(name: "normal", reports: [.working, .done("Reply \(n).")], records: [.prompt("task \(n)"), .stop("Reply \(n).")],
             prompt: "task \(n)", reply: "Reply \(n).")
    }

    static func wakeUp(_ n: Int) -> Turn {
        Turn(name: "wake-up", reports: [.working, .done("Woke \(n).")], records: [.selfStart, .stop("Woke \(n).")],
             prompt: nil, reply: "Woke \(n).")
    }

    static func interrupted(_ n: Int) -> Turn {
        Turn(name: "interrupted", reports: [.working, .idle], records: [.prompt("task \(n)")], prompt: "task \(n)", reply: nil)
    }

    static func permission(_ n: Int) -> Turn {
        Turn(name: "permission", reports: [.working, .approve, .working, .done("Ran \(n).")],
             records: [.prompt("task \(n)"), .stop("Ran \(n).")], prompt: "task \(n)", reply: "Ran \(n).")
    }

    static let kinds: [(Int) -> Turn] = [normal, wakeUp, interrupted, permission]

    /// Whether `order` keeps the exclusion rule: each Stop after the last
    /// non-`done` report of its own turn (`turns` give each item's turn).
    static func possible(_ order: [Item], turns: [Turn]) -> Bool {
        var stopTurn = 0
        var reportsSeen = 0
        let reportCounts = turns.map { $0.reports.count }
        for item in order {
            switch item {
            case .report: reportsSeen += 1
            case .record(let event, _, _, _):
                guard event == "Stop" else { continue }
                // The k-th Stop is the k-th completed turn's.
                guard let turn = turns.indices.filter({ turns[$0].reply != nil }).dropFirst(stopTurn).first else { continue }
                stopTurn += 1
                let needed = reportCounts[..<turn].reduce(0, +) + reportCounts[turn] - 1
                if reportsSeen < needed { return false }
            }
        }
        return true
    }

    /// Every merge of `a` and `b` that keeps the order within each.
    static func merges(_ a: [Item], _ b: [Item]) -> [[Item]] {
        if a.isEmpty { return [b] }
        if b.isEmpty { return [a] }
        return merges(Array(a.dropFirst()), b).map { [a[0]] + $0 } + merges(a, Array(b.dropFirst())).map { [b[0]] + $0 }
    }

    /// An agent whose agy reads its input, finished, its last turn read or
    /// unread.
    static func finishedAgent(unread: Bool) -> AgentRuntimeSnapshot {
        var record = AgentRecord()
        record.state = .finished
        record.lastMessage = "Before."
        record.unread = unread
        var state = AgentRuntimeSnapshot(
            surfaceState: .open, processState: .running, activityState: .idle, telemetryHealth: .live,
            launchGeneration: generation, record: record)
        state.inputReady = true
        state.sessionID = "c-1"
        return state
    }

    /// The meanings agy's provider table gives a record of `item`.
    static func events(of item: Item, viewed: Bool) throws -> [AgentRuntimeEvent] {
        func provider(_ event: AgentDomainEvent) -> AgentRuntimeEvent {
            .provider(generation: generation, provider: .antigravity, eventID: UUID().uuidString, event: event, isViewed: viewed)
        }
        switch item {
        case let .report(state, kind, message):
            let states: [String: Ghostty.Action.ProgramStatus.State] = ["idle": .idle, "working": .working, "done": .done, "blocked": .blocked]
            let kinds: [String: Ghostty.Action.ProgramStatus.Kind] = ["permission": .permission, "question": .question]
            let status = Ghostty.Action.ProgramStatus(
                state: try #require(states[state]), kind: kind.flatMap { kinds[$0] }, progress: nil, id: nil, app: "antigravity",
                title: nil, message: message)
            return [provider(.programStatus(status))]
        case let .record(event, invocation, step, text):
            var object: [String: Any] = [
                "schemaVersion": 1, "provider": "antigravity", "launchGeneration": generation.uuidString,
                "hookEventName": event, "sessionID": "c-1", "invocation": invocation ?? "", "step": step ?? "",
            ]
            object["text"] = text
            let raw = try JSONDecoder().decode(AgentRawProviderEvent.self, from: JSONSerialization.data(withJSONObject: object))
            let meaning = try #require(AntigravityProvider.hookEvents[event])
            return meaning(raw).map { provider($0) }
        }
    }

    struct Outcome {
        var state: AgentRuntimeSnapshot
        var completions: Int
    }

    static func run(_ items: [Item], from start: AgentRuntimeSnapshot, viewed: Bool) throws -> Outcome {
        var state = start
        var completions = 0
        for item in items {
            for event in try events(of: item, viewed: viewed) {
                let reduced = AgentStateReducer.reduce(state, event: event, rules: rules, at: Date(timeIntervalSinceReferenceDate: 0))
                state = reduced.state
                completions += reduced.effects.filter { $0 == .completed }.count
            }
        }
        return Outcome(state: state, completions: completions)
    }

    /// What is wrong with `outcome` for `turns`, or nothing.
    static func faults(_ outcome: Outcome, turns: [Turn], viewed: Bool, startedUnread: Bool, prompts before: [String] = []) -> [String] {
        var faults: [String] = []
        let record = outcome.state.record
        let state = outcome.state
        let expectedPrompts = before + turns.compactMap(\.prompt)
        if record.prompts.map(\.text) != expectedPrompts { faults.append("prompts \(record.prompts.map(\.text))") }
        if record.prompts.contains(where: \.queued) { faults.append("a prompt is queued") }
        let completed = turns.filter { $0.reply != nil }.count
        if outcome.completions != completed { faults.append("\(outcome.completions) completions for \(completed)") }
        let last = turns[turns.count - 1]
        if record.state != .finished { faults.append("state \(record.state)") }
        if let reply = last.reply {
            if record.lastMessage != reply { faults.append("last reply \(record.lastMessage ?? "nil")") }
            if record.interrupted { faults.append("interrupted after a completed turn") }
            if record.unread != !viewed { faults.append("unread \(record.unread)") }
        } else {
            if !record.interrupted { faults.append("not interrupted") }
            if record.unread { faults.append("unread after an interrupt") }
        }
        if state.turnState != .inactive { faults.append("turn \(state.turnState)") }
        if state.promptAwaitsTurn { faults.append("promptAwaitsTurn") }
        if state.stateBeforeStartDialog != nil || state.completedBehindDialog != nil { faults.append("start dialog left") }
        if state.endedBeforeItsPrompt != nil { faults.append("endedBeforeItsPrompt") }
        if state.pendingMessage != nil { faults.append("pendingMessage") }
        if !state.promptsDue.isEmpty { faults.append("promptsDue \(state.promptsDue)") }
        if !state.sentWhileWorking.isEmpty { faults.append("sentWhileWorking") }
        if state.hiddenTurn { faults.append("hiddenTurn") }
        _ = startedUnread
        return faults
    }

    /// Every case, every merge, from a finished agent read and unread,
    /// viewed and not; the number of merges and the failures, each with
    /// its order.
    static func allFaults() throws -> (runs: Int, generated: Int, failures: [String]) {
        var cases: [[Turn]] = kinds.map { [$0(1)] }
        for first in kinds { for second in kinds { cases.append([first(1), second(2)]) } }
        var count = 0
        var generated = 0
        var failures: [String] = []
        for turns in cases {
            let reports = turns.flatMap(\.reports)
            let records = turns.flatMap(\.records)
            for order in merges(reports, records) {
                generated += 1
                guard possible(order, turns: turns) else { continue }
                for startedUnread in [false, true] {
                    for viewed in [false, true] {
                        count += 1
                        let outcome = try run(order, from: finishedAgent(unread: startedUnread), viewed: viewed)
                        let found = faults(outcome, turns: turns, viewed: viewed, startedUnread: startedUnread)
                        if !found.isEmpty {
                            failures.append("\(turns.map(\.name)) unread \(startedUnread) viewed \(viewed) \(order): \(found)")
                        }
                    }
                }
            }
        }
        // A first prompt behind the start dialog: launched with it, the trust
        // report, then SessionStart, its record and its Stop behind the
        // dialog, and `idle` when the person accepts.
        for order in merges([.trust, .idle], [.sessionStart, .prompt("first task"), .stop("First.")]) {
            generated += 1
            guard let trust = order.firstIndex(of: .trust), let stop = order.firstIndex(of: .stop("First.")), stop > trust
            else { continue }
            for viewed in [false, true] {
                count += 1
                var start = AgentRuntimeSnapshot(
                    surfaceState: .open, processState: .launching, activityState: .unknown, telemetryHealth: .awaiting,
                    launchGeneration: generation, record: AgentRecord())
                start = AgentStateReducer.reduce(start, event: .launchRequested(generation: generation, prompted: true), rules: rules).state
                start = AgentStateReducer.reduce(start, event: .sent(prompt: "first task", by: .person), rules: rules).state
                let outcome = try run(order, from: start, viewed: viewed)
                let behind = Turn(name: "behind the dialog", reports: [], records: [], prompt: "first task", reply: "First.")
                let found = faults(outcome, turns: [behind], viewed: viewed, startedUnread: false)
                if !found.isEmpty { failures.append("behind the dialog viewed \(viewed) \(order): \(found)") }
            }
        }
        return (count, generated, failures)
    }

    @Test func everyMergeOfReportsAndRecords() throws {
        let (runs, generated, failures) = try Self.allFaults()
        #expect(failures.isEmpty, "\(failures.count) of \(runs) runs fail (\(generated) merges generated); first: \(failures.prefix(2))")
        // 1978 merges generated, 1048 possible (the rule above), each run
        // from a read and an unread agent, viewed and not (the start-dialog
        // case: viewed and not).
        #expect(generated == 1978 && runs == 4174)
    }

    /// Review of the fixes 2, trigger A: a wake-up turn of its own, its
    /// `done` before its records. Two turns, two completions.
    @Test func aWakeUpTurnsDoneBeforeItsRecords() throws {
        let order: [Item] = [.working, .prompt("sleep, then say slept"), .stop("Waiting."), .done("Waiting."),
                             .working, .done("slept"), .selfStart, .stop("slept")]
        let outcome = try Self.run(order, from: Self.finishedAgent(unread: false), viewed: false)
        #expect(outcome.completions == 2)
        #expect(Self.faults(outcome, turns: [Self.normal(1), Self.wakeUp(2)].map {
            var turn = $0; turn.prompt = $0.prompt.map { _ in "sleep, then say slept" }; turn.reply = turn.reply.map { _ in "slept" }; return turn
        }, viewed: false, startedUnread: false).isEmpty)
    }

    /// Review of the fixes 2, trigger B: the wake-up inside the turn
    /// (probe `stage5/wake2`), `done` before the wake-up's records. One turn,
    /// one completion, the last reply the wake-up's.
    @Test func aWakeUpInsideTheTurnDoneBeforeItsRecords() throws {
        let order: [Item] = [.working, .prompt("sleep, then say slept"), .stop("Waiting."), .done("slept"),
                             .selfStart, .stop("slept")]
        let outcome = try Self.run(order, from: Self.finishedAgent(unread: false), viewed: false)
        #expect(outcome.completions == 1)
        let turn = Turn(name: "in-turn wake-up", reports: [], records: [], prompt: "sleep, then say slept", reply: "slept")
        #expect(Self.faults(outcome, turns: [turn], viewed: false, startedUnread: false).isEmpty)
        // The next turn is unharmed: its record before its `working`.
        let next = try Self.run([.prompt("next"), .working, .stop("Next."), .done("Next.")], from: outcome.state, viewed: false)
        #expect(next.completions == 1)
        #expect(Self.faults(next, turns: [Self.normal(9)].map {
            var t = $0; t.prompt = "next"; t.reply = "Next."; return t
        }, viewed: false, startedUnread: true, prompts: ["sleep, then say slept"]).isEmpty)
    }
}
