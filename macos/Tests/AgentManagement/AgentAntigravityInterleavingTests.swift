import Foundation
import Testing
@testable import Ghostty

/// agy's two channels, merged every way (coordinator, after the reviews of
/// the pairing code). Its terminal reports arrive at once, its hook records
/// up to about a quarter of a second later, each channel in its own order.
/// For each case every merge of the two that keeps each channel's order is
/// applied to the reducer with agy's rules, and checked at every step, not
/// only at the end:
/// - the tile shows what the reports so far give: records never change it,
///   except the Stop that ends the turn behind the start dialog;
/// - the reply shown is that turn's: what its `done` reported or the whole
///   reply its Stop brought, never an earlier turn's or an earlier step's,
///   and nothing while a turn works, after an interrupt or a failure;
/// - a completion notifies that turn's reply; finished never carries a
///   problem; a problem never turns into finished by a late record.
/// At the end: each real prompt recorded once and never queued, one
/// completion per completed turn, the last reply the whole of the last
/// completed turn's, unread exactly when that turn was not viewed, and the
/// fields that pair records with reports at rest.
///
/// `done` carries the first line of the reply, cut to 199 characters and
/// "…" past 200; the Stop the whole reply (cli-facts, "`done` and its Stop").
///
/// A record comes only once the reports written before it have come
/// (`Record.after`): a Stop after its turn's last report but `done` (for a
/// failed turn, after its `working`: the Stop at 0.9 s before the `error`,
/// probe `stage6/midturn2`; behind the start dialog, after the trust
/// report: `stage5/trustprompt`); a prompt sent from the app after the send.
/// A prompt record may come before its turn's `working` and before the
/// previous turn's `done` (`stage5/queue2`).
@MainActor
struct AgentAntigravityInterleavingTests {
    private static let rules = AntigravityProvider(
        root: AgentDataRoot(url: URL(fileURLWithPath: "/nonexistent")),
        dataFolder: URL(fileURLWithPath: "/nonexistent")).entry.reports
    private static let generation = UUID()

    /// One item of either channel, or what the app or the terminal does.
    enum Item: Equatable {
        case report(state: String, kind: String?, message: String?)
        case record(event: String, invocation: String?, step: String?, text: String?)
        /// The person sends a prompt from the app's line.
        case send(String)
        /// agy's exit, with its status.
        case exit(Int)
        /// The terminal dies under agy.
        case death

        static let working = Item.report(state: "working", kind: nil, message: nil)
        static let idle = Item.report(state: "idle", kind: nil, message: nil)
        static let trust = Item.report(state: "blocked", kind: "permission", message: "Trust this folder?")
        static let approve = Item.report(state: "blocked", kind: "permission", message: "Approve Bash: make")
        static let question = Item.report(state: "blocked", kind: "question", message: "Which file?")
        static func done(_ firstLine: String) -> Item { .report(state: "done", kind: nil, message: firstLine) }
        static func error(_ text: String) -> Item { .report(state: "error", kind: nil, message: text) }
        static func prompt(_ text: String) -> Item { .record(event: "PreInvocation", invocation: "0", step: "USER_INPUT", text: text) }
        static let selfStart = Item.record(event: "PreInvocation", invocation: "0", step: "PLANNER_RESPONSE", text: "earlier words")
        /// A Stop; a failed turn's has no reply.
        static func stop(_ reply: String?) -> Item { .record(event: "Stop", invocation: nil, step: nil, text: reply) }
        static let sessionStart = Item.record(event: "SessionStart", invocation: nil, step: nil, text: nil)
    }

    /// What the tile shows once a report has come: its state, and the
    /// replies it may show (nil: the ones it might show before).
    struct Shown {
        var state: AgentRecord.State
        var replies: [String?]?
    }

    struct Report {
        var item: Item
        var shows: Shown
    }

    /// A record, which comes once `after` items of the reports channel have.
    struct Record {
        var item: Item
        var after: Int
    }

    /// One or more turns: both channels, and what must hold at the end.
    struct Case {
        enum End: Equatable {
            case completed(reply: String)
            case interrupted
            case failed(text: String)
        }

        var name: String
        var reports: [Report]
        var records: [Record]
        /// Each real prompt, recorded once.
        var prompts: [String]
        var completions: Int
        var end: End

        /// This case, then `next`.
        func then(_ next: Case) -> Case {
            Case(
                name: "\(name), \(next.name)", reports: reports + next.reports,
                records: records + next.records.map { Record(item: $0.item, after: $0.after + reports.count) },
                prompts: prompts + next.prompts, completions: completions + next.completions, end: next.end)
        }
    }

    static let works = Shown(state: .working, replies: [nil])
    static let asks = Shown(state: .asks, replies: [nil])
    static func finished(_ done: String, _ reply: String) -> Shown { Shown(state: .finished, replies: [done, reply]) }

    static func normal(_ n: Int) -> Case {
        let reply = "Reply \(n).\nIts second line."
        return Case(
            name: "normal",
            reports: [Report(item: .working, shows: works), Report(item: .done("Reply \(n)."), shows: finished("Reply \(n).", reply))],
            records: [Record(item: .prompt("task \(n)"), after: 0), Record(item: .stop(reply), after: 1)],
            prompts: ["task \(n)"], completions: 1, end: .completed(reply: reply))
    }

    /// A turn agy starts itself when a background command ends.
    static func wakeUp(_ n: Int) -> Case {
        let reply = "Woke \(n).\nThe command ended."
        return Case(
            name: "wake-up",
            reports: [Report(item: .working, shows: works), Report(item: .done("Woke \(n)."), shows: finished("Woke \(n).", reply))],
            records: [Record(item: .selfStart, after: 0), Record(item: .stop(reply), after: 1)],
            prompts: [], completions: 1, end: .completed(reply: reply))
    }

    /// The wake-up inside one turn (probe `stage5/wake2`): two Stops in one
    /// `working`..`done`, the first an earlier step's.
    static func wakeInTurn(_ n: Int) -> Case {
        let reply = "Slept \(n).\nThe command ended."
        return Case(
            name: "wake-up in the turn",
            reports: [Report(item: .working, shows: works), Report(item: .done("Slept \(n)."), shows: finished("Slept \(n).", reply))],
            records: [
                Record(item: .prompt("task \(n)"), after: 0), Record(item: .stop("Waiting for sleep \(n)."), after: 1),
                Record(item: .selfStart, after: 1), Record(item: .stop(reply), after: 1),
            ],
            prompts: ["task \(n)"], completions: 1, end: .completed(reply: reply))
    }

    static func interrupted(_ n: Int) -> Case {
        Case(
            name: "interrupted",
            reports: [Report(item: .working, shows: works), Report(item: .idle, shows: Shown(state: .finished, replies: [nil]))],
            records: [Record(item: .prompt("task \(n)"), after: 0)],
            prompts: ["task \(n)"], completions: 0, end: .interrupted)
    }

    /// A permission asked, and a first line longer than 200 characters.
    static func permission(_ n: Int) -> Case {
        let firstLine = "Ran \(n): " + String(repeating: "the build passed and every check is green ", count: 6)
        let reply = firstLine + "\nDetails follow."
        let done = String(firstLine.prefix(199)) + "…"
        return Case(
            name: "permission",
            reports: [
                Report(item: .working, shows: works), Report(item: .approve, shows: asks), Report(item: .working, shows: works),
                Report(item: .done(done), shows: finished(done, reply)),
            ],
            records: [Record(item: .prompt("task \(n)"), after: 0), Record(item: .stop(reply), after: 3)],
            prompts: ["task \(n)"], completions: 1, end: .completed(reply: reply))
    }

    static func question(_ n: Int) -> Case {
        let reply = "**Picked \(n).**\nThe first file."
        return Case(
            name: "question",
            reports: [
                Report(item: .working, shows: works), Report(item: .question, shows: asks), Report(item: .working, shows: works),
                Report(item: .done("**Picked \(n).**"), shows: finished("**Picked \(n).**", reply)),
            ],
            records: [Record(item: .prompt("task \(n)"), after: 0), Record(item: .stop(reply), after: 3)],
            prompts: ["task \(n)"], completions: 1, end: .completed(reply: reply))
    }

    /// A failure before any model call (stage 6, a closed proxy port): no
    /// record at all, so a prompt typed in the terminal is in none.
    static func failedEarly(_ n: Int) -> Case {
        Case(
            name: "failed early",
            reports: [Report(item: .working, shows: works), Report(item: .error("Failed \(n)."), shows: Shown(state: .problem, replies: [nil]))],
            records: [], prompts: [], completions: 0, end: .failed(text: "Failed \(n)."))
    }

    /// A failure during a turn (probe `stage6/midturn2`): its Stop has no
    /// reply and comes before the `error`, or after; Escape then `idle`.
    static func failedLate(_ n: Int) -> Case {
        let problem = Shown(state: .problem, replies: [nil])
        return Case(
            name: "failed late",
            reports: [
                Report(item: .working, shows: works), Report(item: .error("Network \(n)."), shows: problem),
                Report(item: .idle, shows: problem),
            ],
            records: [Record(item: .prompt("task \(n)"), after: 0), Record(item: .stop(nil), after: 1)],
            prompts: ["task \(n)"], completions: 0, end: .failed(text: "Network \(n)."))
    }

    /// Sent from the app's line: the send, the `idle` agy reports at the
    /// first key after a `done`, then the turn.
    static func sent(_ n: Int) -> Case {
        let reply = "Sent \(n).\nIts second line."
        let pending = Shown(state: .working, replies: nil)
        return Case(
            name: "sent",
            reports: [
                Report(item: .send("task \(n)"), shows: pending), Report(item: .idle, shows: pending),
                Report(item: .working, shows: works), Report(item: .done("Sent \(n)."), shows: finished("Sent \(n).", reply)),
            ],
            records: [Record(item: .prompt("task \(n)"), after: 1), Record(item: .stop(reply), after: 3)],
            prompts: ["task \(n)"], completions: 1, end: .completed(reply: reply))
    }

    static let kinds: [(Int) -> Case] = [normal, wakeUp, wakeInTurn, interrupted, permission, question, failedEarly, failedLate, sent]

    /// Two prompts sent while a turn works: agy runs them joined by a
    /// newline as its next turn (`stage5/queue2`), or an interrupt gives
    /// them back.
    static let queued: [Case] = {
        let first = "Reply 1.\nIts second line."
        let both = "Both.\nDone with one and two."
        let waiting = Shown(state: .working, replies: [nil])
        let joined = Case(
            name: "queued, joined",
            reports: [
                Report(item: .working, shows: works), Report(item: .send("one"), shows: waiting), Report(item: .send("two"), shows: waiting),
                Report(item: .done("Reply 1."), shows: finished("Reply 1.", first)), Report(item: .working, shows: works),
                Report(item: .done("Both."), shows: finished("Both.", both)),
            ],
            records: [
                Record(item: .prompt("task 1"), after: 0), Record(item: .stop(first), after: 1),
                Record(item: .prompt("one\ntwo"), after: 3), Record(item: .stop(both), after: 5),
            ],
            prompts: ["task 1", "one", "two"], completions: 2, end: .completed(reply: both))
        let givenBack = Case(
            name: "queued, given back",
            reports: [
                Report(item: .working, shows: works), Report(item: .send("one"), shows: waiting), Report(item: .send("two"), shows: waiting),
                Report(item: .idle, shows: Shown(state: .finished, replies: [nil])),
            ],
            records: [Record(item: .prompt("task 1"), after: 0)],
            prompts: ["task 1"], completions: 0, end: .interrupted)
        return [joined, givenBack]
    }()

    /// Every merge of the case's two channels in which each record comes
    /// after the reports it needs.
    enum Step {
        case report(Int)
        case record(Int)
    }

    static func orders(_ c: Case) -> [[Step]] {
        var all: [[Step]] = []
        func walk(_ reports: Int, _ records: Int, _ path: [Step]) {
            if reports == c.reports.count && records == c.records.count {
                all.append(path)
                return
            }
            if reports < c.reports.count { walk(reports + 1, records, path + [.report(reports)]) }
            if records < c.records.count && c.records[records].after <= reports { walk(reports, records + 1, path + [.record(records)]) }
        }
        walk(0, 0, [])
        return all
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

    /// What the reducer is given for `item`.
    static func events(of item: Item, viewed: Bool) throws -> [AgentRuntimeEvent] {
        func provider(_ event: AgentDomainEvent) -> AgentRuntimeEvent {
            .provider(generation: generation, provider: .antigravity, eventID: UUID().uuidString, event: event, isViewed: viewed)
        }
        switch item {
        case let .report(state, kind, message):
            let states: [String: Ghostty.Action.ProgramStatus.State] = [
                "idle": .idle, "working": .working, "done": .done, "blocked": .blocked, "error": .error,
            ]
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
        case .send(let text):
            return [.sent(prompt: text, by: .person)]
        case .exit(let status):
            return [provider(.providerExited(status: status))]
        case .death:
            return [.surfaceDied(generation: generation, byUser: false, isViewed: viewed)]
        }
    }

    static func reduce(_ state: AgentRuntimeSnapshot, _ item: Item, viewed: Bool) throws -> (AgentRuntimeSnapshot, completions: Int) {
        var state = state
        var completions = 0
        for event in try events(of: item, viewed: viewed) {
            let reduced = AgentStateReducer.reduce(state, event: event, rules: rules, at: Date(timeIntervalSinceReferenceDate: 0))
            state = reduced.state
            completions += reduced.effects.filter { $0 == .completed }.count
        }
        return (state, completions)
    }

    /// What goes wrong in `order` of `c`: the first step that breaks a rule,
    /// or what is wrong at the end; nothing when all holds.
    static func faults(_ c: Case, _ order: [Step], startedUnread: Bool, viewed: Bool) throws -> [String] {
        var state = finishedAgent(unread: startedUnread)
        var shown = Shown(state: .finished, replies: ["Before."])
        var completions = 0
        for (index, step) in order.enumerated() {
            let item: Item
            let isRecord: Bool
            switch step {
            case .report(let r):
                item = c.reports[r].item
                isRecord = false
                shown = Shown(state: c.reports[r].shows.state, replies: c.reports[r].shows.replies ?? shown.replies)
            case .record(let k):
                item = c.records[k].item
                isRecord = true
            }
            let before = state.record.state
            let (after, completed) = try reduce(state, item, viewed: viewed)
            state = after
            completions += completed
            let record = state.record
            let replies = shown.replies ?? []
            var found: [String] = []
            if completed > 0 && !replies.contains(record.lastMessage) { found.append("notified \(record.lastMessage ?? "nil")") }
            if record.state == .finished && record.problem != nil { found.append("finished with a problem") }
            if isRecord && before == .problem && record.state == .finished { found.append("a record turned a problem into finished") }
            if record.state != shown.state { found.append("shows \(record.state), not \(shown.state)") }
            if !replies.contains(record.lastMessage) { found.append("reply \(record.lastMessage ?? "nil")") }
            if !found.isEmpty { return ["step \(index) (\(item))"] + found }
        }
        var found: [String] = []
        let record = state.record
        if record.prompts.map(\.text).sorted() != c.prompts.sorted() { found.append("prompts \(record.prompts.map(\.text))") }
        if record.prompts.contains(where: \.queued) { found.append("a prompt is queued") }
        if completions != c.completions { found.append("\(completions) completions for \(c.completions)") }
        switch c.end {
        case .completed(let reply):
            if record.lastMessage != reply { found.append("last reply \(record.lastMessage ?? "nil")") }
            if record.interrupted { found.append("interrupted after a completed turn") }
            if record.unread != !viewed { found.append("unread \(record.unread)") }
        case .interrupted:
            if !record.interrupted { found.append("not interrupted") }
            if record.unread { found.append("unread after an interrupt") }
        case .failed(let text):
            if record.problem?.text != text { found.append("problem \(String(describing: record.problem))") }
            if record.unread { found.append("unread under a problem") }
        }
        if state.turnState != .inactive { found.append("turn \(state.turnState)") }
        if state.promptAwaitsTurn { found.append("promptAwaitsTurn") }
        if state.stateBeforeStartDialog != nil || state.completedBehindDialog != nil { found.append("start dialog left") }
        if state.endedBeforeItsPrompt != nil { found.append("endedBeforeItsPrompt") }
        // After a failure a reply on its way waits for nothing: the next
        // turn's start drops it, and nothing applies it before.
        if state.pendingMessage != nil, record.state != .problem { found.append("pendingMessage") }
        if !state.promptsDue.isEmpty { found.append("promptsDue \(state.promptsDue)") }
        if !state.sentWhileWorking.isEmpty { found.append("sentWhileWorking") }
        if state.hiddenTurn { found.append("hiddenTurn") }
        return found
    }

    /// How the start dialog ends, with the first prompt's turn behind it.
    enum DialogEnd: CaseIterable {
        case accepted, declined, exitedFailing, terminalDied, failed

        var reports: [Item] {
            switch self {
            case .accepted: [.idle]
            // "No, exit": `idle`, exit status 0, `idle` (`stage5/trustprompt`).
            case .declined: [.idle, .exit(0), .idle]
            case .exitedFailing: [.exit(1)]
            case .terminalDied: [.death]
            case .failed: [.error("Broke.")]
            }
        }
    }

    /// The first prompt's turn behind the start dialog, the dialog ending
    /// `end`, in `order` (reports: the trust report, then `end`'s). The
    /// turn completes when its Stop has come and the dialog has been
    /// answered, unless the launch ends first; ended with a failure, the
    /// agent stops with a problem; its reply is kept on every path.
    static func dialogFaults(_ end: DialogEnd, _ order: [Step], records: [Item], viewed: Bool) throws -> [String] {
        let reply = "First.\nMore."
        let reports: [Item] = [.trust] + end.reports
        var state = AgentRuntimeSnapshot(
            surfaceState: .open, processState: .launching, activityState: .unknown, telemetryHealth: .awaiting,
            launchGeneration: generation, record: AgentRecord())
        state = AgentStateReducer.reduce(state, event: .launchRequested(generation: generation, prompted: true), rules: rules).state
        state = AgentStateReducer.reduce(state, event: .sent(prompt: "first task", by: .person), rules: rules).state
        var reportsSeen = 0
        var stopAfter: Int?
        var completions = 0
        for (index, step) in order.enumerated() {
            let item: Item
            switch step {
            case .report(let r):
                item = reports[r]
                reportsSeen += 1
            case .record(let k):
                item = records[k]
                if item == .stop(reply) { stopAfter = reportsSeen }
            }
            let before = state.record.state
            let (after, completed) = try reduce(state, item, viewed: viewed)
            state = after
            completions += completed
            let record = state.record
            let expected: AgentRecord.State
            switch (end, reportsSeen) {
            case (_, 0): expected = .working
            case (_, 1): expected = .asks
            case (.accepted, _), (.declined, 2): expected = stopAfter == nil ? .working : .finished
            case (.declined, _): expected = .finished
            case (.exitedFailing, _), (.terminalDied, _), (.failed, _): expected = .problem
            }
            var found: [String] = []
            if completed > 0 && record.lastMessage != reply { found.append("notified \(record.lastMessage ?? "nil")") }
            if record.state == .finished && record.problem != nil { found.append("finished with a problem") }
            if case .record = step, before == .problem, record.state == .finished { found.append("a record turned a problem into finished") }
            if record.state != expected { found.append("shows \(record.state), not \(expected)") }
            if record.lastMessage != nil && record.lastMessage != reply { found.append("reply \(record.lastMessage ?? "nil")") }
            if !found.isEmpty { return ["step \(index) (\(item))"] + found }
        }
        let completes: Bool
        switch end {
        case .accepted: completes = true
        // The Stop before the exit completes the turn; after it, the turn
        // ended with its launch, and the Stop only brings its reply.
        case .declined: completes = (stopAfter ?? 3) < 3
        case .exitedFailing, .terminalDied, .failed: completes = false
        }
        var found: [String] = []
        let record = state.record
        if completions != (completes ? 1 : 0) { found.append("\(completions) completions") }
        if record.lastMessage != reply { found.append("last reply \(record.lastMessage ?? "nil")") }
        if record.unread != (completes && !viewed) { found.append("unread \(record.unread)") }
        if record.prompts.map(\.text) != ["first task"] { found.append("prompts \(record.prompts.map(\.text))") }
        if state.stateBeforeStartDialog != nil || state.completedBehindDialog != nil { found.append("start dialog left") }
        if state.hiddenTurn { found.append("hiddenTurn") }
        if state.pendingMessage != nil, record.state != .problem { found.append("pendingMessage") }
        return found
    }

    /// Every case and every merge; the runs, and each failure with its order.
    static func allFaults() throws -> (runs: Int, failures: [String]) {
        var cases: [Case] = kinds.map { $0(1) } + queued
        for first in kinds { for second in kinds { cases.append(first(1).then(second(2))) } }
        var runs = 0
        var failures: [String] = []
        for c in cases {
            for order in orders(c) {
                for startedUnread in [false, true] {
                    for viewed in [false, true] {
                        runs += 1
                        let found = try faults(c, order, startedUnread: startedUnread, viewed: viewed)
                        if !found.isEmpty {
                            failures.append("\(c.name) unread \(startedUnread) viewed \(viewed) \(order): \(found)")
                        }
                    }
                }
            }
        }
        // SessionStart and the prompt may come before the trust report
        // (0.16 s); the Stop comes after it (5.1 s).
        let records: [Item] = [.sessionStart, .prompt("first task"), .stop("First.\nMore.")]
        for end in DialogEnd.allCases {
            let dialog = Case(
                name: "\(end)", reports: ([.trust] + end.reports).map { Report(item: $0, shows: works) },
                records: [Record(item: records[0], after: 0), Record(item: records[1], after: 0), Record(item: records[2], after: 1)],
                prompts: [], completions: 0, end: .interrupted)
            for order in orders(dialog) {
                for viewed in [false, true] {
                    runs += 1
                    let found = try dialogFaults(end, order, records: records, viewed: viewed)
                    if !found.isEmpty { failures.append("behind the dialog, \(end), viewed \(viewed) \(order): \(found)") }
                }
            }
        }
        return (runs, failures)
    }

    @Test func everyMergeOfReportsAndRecords() throws {
        let (runs, failures) = try Self.allFaults()
        // Each failure's case and what broke, without the order, counted.
        var kinds: [String: Int] = [:]
        for failure in failures {
            let name = String(failure.prefix { $0 != "[" })
                .replacingOccurrences(of: #" (unread|viewed) (true|false)"#, with: "", options: .regularExpression)
            let what = failure.components(separatedBy: ")\", \"").dropFirst().first ?? String(failure.suffix(80))
            kinds["\(name)| \(what)", default: 0] += 1
        }
        let summary = kinds.sorted { $0.value > $1.value }.prefix(12).map { "\($0.value)× \($0.key)" }
        #expect(failures.count == 0, "of \(runs) runs; \(summary); first: \(failures.prefix(1))")
        #expect(runs == Self.expectedRuns, "\(runs) runs")
    }

    /// The number of runs `allFaults` makes, so a change to the cases shows.
    static let expectedRuns = 32940

    /// Review of the fixes 2, trigger A: a wake-up turn of its own, its
    /// `done` before its records. Two turns, two completions.
    @Test func aWakeUpTurnsDoneBeforeItsRecords() throws {
        let order: [Item] = [.working, .prompt("sleep, then say slept"), .stop("Waiting.\nThe command runs."), .done("Waiting."),
                             .working, .done("slept"), .selfStart, .stop("slept\nThe command ended.")]
        var state = Self.finishedAgent(unread: false)
        var completions = 0
        for item in order { let r = try Self.reduce(state, item, viewed: false); state = r.0; completions += r.1 }
        #expect(completions == 2)
        #expect(state.record.lastMessage == "slept\nThe command ended.")
        #expect(state.record.prompts.map(\.text) == ["sleep, then say slept"])
    }

    /// Review of the pairing, fault 2: the Stop of the turn before comes
    /// once the next turn works, and that turn's `done` before its own
    /// Stop. The completion notifies the turn's own reply.
    @Test func theTurnBeforesStopDuringTheNextTurn() throws {
        let order: [Item] = [.working, .prompt("task 1"), .done("Reply 1."), .working, .prompt("task 2"),
                             .stop("Reply 1.\nMore."), .done("Reply 2.")]
        var state = Self.finishedAgent(unread: false)
        var completions = 0
        for item in order { let r = try Self.reduce(state, item, viewed: false); state = r.0; completions += r.1 }
        #expect(completions == 2)
        #expect(state.record.lastMessage == "Reply 2.")
        (state, _) = try Self.reduce(state, .stop("Reply 2.\nMore."), viewed: false)
        #expect(state.record.lastMessage == "Reply 2.\nMore.")
    }

    /// Review of the pairing, fault 2 (`stage5/wake2`): the wake-up's
    /// `done` before its Stop; the notified reply is the wake-up's, not the
    /// step before it.
    @Test func aWakeUpInsideTheTurnDoneBeforeItsRecords() throws {
        let order: [Item] = [.working, .prompt("sleep, then say slept"), .stop("Waiting."), .done("slept")]
        var state = Self.finishedAgent(unread: false)
        var completions = 0
        for item in order { let r = try Self.reduce(state, item, viewed: false); state = r.0; completions += r.1 }
        #expect(completions == 1)
        #expect(state.record.lastMessage == "slept")
        for item in [Item.selfStart, .stop("slept\nThe command ended.")] { state = try Self.reduce(state, item, viewed: false).0 }
        #expect(state.record.lastMessage == "slept\nThe command ended.")
        #expect(state.pendingMessage == nil)
    }

    /// Review of the pairing, fault 1: the Stop of the turn behind the
    /// dialog comes after the launch ended in a failure. The agent stays
    /// stopped with the problem, not finished, and nothing is notified;
    /// the reply is kept.
    @Test func aLateStopAfterTheDialogEndedInAFailure() throws {
        var state = AgentRuntimeSnapshot(
            surfaceState: .open, processState: .launching, activityState: .unknown, telemetryHealth: .awaiting,
            launchGeneration: Self.generation, record: AgentRecord())
        state = AgentStateReducer.reduce(state, event: .launchRequested(generation: Self.generation, prompted: true), rules: Self.rules).state
        state = AgentStateReducer.reduce(state, event: .sent(prompt: "first task", by: .person), rules: Self.rules).state
        for item in [Item.trust, .prompt("first task"), .exit(1)] { state = try Self.reduce(state, item, viewed: false).0 }
        #expect(state.record.state == .problem)
        let (after, completions) = try Self.reduce(state, .stop("First."), viewed: false)
        #expect(completions == 0)
        #expect(after.record.state == .problem)
        #expect(!after.record.unread)
        #expect(after.record.lastMessage == "First.")
    }
}
