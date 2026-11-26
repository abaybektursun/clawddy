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
/// What may come before what (`Record.after`, `Report.afterRecords`): a
/// record only once the reports written before it have come: a Stop after
/// its turn's last report but `done` (for a failed turn, after its
/// `working`: the Stop at 0.9 s before the `error`, probe
/// `stage6/midturn2`; behind the start dialog, after the trust report:
/// `stage5/trustprompt`); a prompt sent from the app, or typed after the
/// first key's `idle`, after that. A prompt record may come before its
/// turn's `working` and before the previous turn's `done`
/// (`stage5/queue2`). A turn's `done` comes after its start record (its
/// prompt, or agy's own start): agy runs the PreInvocation hook, which
/// writes it, before it calls the model, and a reply takes longer than the
/// record's quarter second. An exit or a terminal death during a turn comes
/// after its prompt's record.
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
        /// The person closes agy's terminal.
        case close

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
    /// replies it may show (nil: as before it).
    struct Shown {
        var state: AgentRecord.State?
        var replies: [String?]?
    }

    struct Report {
        var item: Item
        var shows: Shown
        /// The items of the records channel that come before it.
        var afterRecords = 0
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
            /// Its terminal died or agy exited failing: the agent stops with
            /// the problem, and a reply completed before stays unread.
            case stopped
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
                name: "\(name), \(next.name)",
                reports: reports + next.reports.map {
                    Report(item: $0.item, shows: $0.shows, afterRecords: $0.afterRecords == 0 ? 0 : $0.afterRecords + records.count)
                },
                records: records + next.records.map { Record(item: $0.item, after: $0.after + reports.count) },
                prompts: prompts + next.prompts, completions: completions + next.completions, end: next.end)
        }
    }

    static let works = Shown(state: .working, replies: [nil])
    static let asks = Shown(state: .asks, replies: [nil])
    static let unchanged = Shown(state: nil, replies: nil)
    static func finished(_ done: String, _ reply: String) -> Shown { Shown(state: .finished, replies: [done, reply]) }

    /// A typed turn: `working`, `done` with the reply's first line, its
    /// prompt and Stop.
    static func typed(_ name: String, _ n: Int, done: String, reply: String) -> Case {
        Case(
            name: name,
            reports: [Report(item: .working, shows: works), Report(item: .done(done), shows: finished(done, reply), afterRecords: 1)],
            records: [Record(item: .prompt("task \(n)"), after: 0), Record(item: .stop(reply), after: 1)],
            prompts: ["task \(n)"], completions: 1, end: .completed(reply: reply))
    }

    static func normal(_ n: Int) -> Case { typed("normal", n, done: "Reply \(n).", reply: "Reply \(n).\nIts second line.") }

    /// The `idle` agy reports at the first key after a `done`, then a typed
    /// turn.
    static func afterKey(_ n: Int) -> Case {
        let reply = "Keyed \(n).\nIts second line."
        return Case(
            name: "first key",
            reports: [
                Report(item: .idle, shows: unchanged), Report(item: .working, shows: works),
                Report(item: .done("Keyed \(n)."), shows: finished("Keyed \(n).", reply), afterRecords: 1),
            ],
            records: [Record(item: .prompt("task \(n)"), after: 1), Record(item: .stop(reply), after: 2)],
            prompts: ["task \(n)"], completions: 1, end: .completed(reply: reply))
    }

    /// A turn agy starts itself when a background command ends.
    static func wakeUp(_ n: Int) -> Case {
        let reply = "Woke \(n).\nThe command ended."
        return Case(
            name: "wake-up",
            reports: [Report(item: .working, shows: works), Report(item: .done("Woke \(n)."), shows: finished("Woke \(n).", reply), afterRecords: 1)],
            records: [Record(item: .selfStart, after: 0), Record(item: .stop(reply), after: 1)],
            prompts: [], completions: 1, end: .completed(reply: reply))
    }

    /// The wake-up inside one turn (probe `stage5/wake2`): two Stops in one
    /// `working`..`done`, the first an earlier step's.
    static func wakeInTurn(_ n: Int) -> Case {
        let reply = "Slept \(n).\nThe command ended."
        return Case(
            name: "wake-up in the turn",
            reports: [
                Report(item: .working, shows: works),
                Report(item: .done("Slept \(n)."), shows: finished("Slept \(n).", reply), afterRecords: 3),
            ],
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
                Report(item: .done(done), shows: finished(done, reply), afterRecords: 1),
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
                Report(item: .done("**Picked \(n).**"), shows: finished("**Picked \(n).**", reply), afterRecords: 1),
            ],
            records: [Record(item: .prompt("task \(n)"), after: 0), Record(item: .stop(reply), after: 3)],
            prompts: ["task \(n)"], completions: 1, end: .completed(reply: reply))
    }

    /// A failure before any model call, the stage 1 shape (a closed proxy
    /// port): `error` 10 ms after Return with no `working`, and no record at
    /// all, so a prompt typed in the terminal is in none.
    static func failedAtOnce(_ n: Int) -> Case {
        Case(
            name: "failed at once",
            reports: [Report(item: .error("Failed \(n)."), shows: Shown(state: .problem, replies: nil))],
            records: [], prompts: [], completions: 0, end: .failed(text: "Failed \(n)."))
    }

    /// The same failure as the app saw it, a `working` before the `error`.
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
                Report(item: .working, shows: works),
                Report(item: .done("Sent \(n)."), shows: finished("Sent \(n).", reply), afterRecords: 1),
            ],
            records: [Record(item: .prompt("task \(n)"), after: 1), Record(item: .stop(reply), after: 3)],
            prompts: ["task \(n)"], completions: 1, end: .completed(reply: reply))
    }

    static let kinds: [(Int) -> Case] = [
        normal, afterKey, wakeUp, wakeInTurn, interrupted, permission, question, failedAtOnce, failedEarly, failedLate, sent,
    ]

    /// Turns after which the agent's process is gone: only last.
    static func diesMidTurn(_ n: Int) -> Case {
        Case(
            name: "dies mid-turn",
            reports: [Report(item: .working, shows: works), Report(item: .death, shows: Shown(state: .problem, replies: [nil]), afterRecords: 1)],
            records: [Record(item: .prompt("task \(n)"), after: 0)],
            prompts: ["task \(n)"], completions: 0, end: .stopped)
    }

    static func exitsMidTurn(_ n: Int) -> Case {
        Case(
            name: "exits mid-turn",
            reports: [Report(item: .working, shows: works), Report(item: .exit(0), shows: Shown(state: .finished, replies: [nil]), afterRecords: 1)],
            records: [Record(item: .prompt("task \(n)"), after: 0)],
            prompts: ["task \(n)"], completions: 0, end: .interrupted)
    }

    /// agy ended, by Control-D or its terminal dying, just after `done`, its
    /// Stop still to come.
    static func exitsAfterDone(_ n: Int) -> Case {
        var turn = typed("exits after done", n, done: "Last \(n).", reply: "Last \(n).\nIts second line.")
        turn.reports.append(Report(item: .exit(0), shows: unchanged))
        return turn
    }

    static func diesAfterDone(_ n: Int) -> Case {
        var turn = typed("dies after done", n, done: "Last \(n).", reply: "Last \(n).\nIts second line.")
        turn.reports.append(Report(item: .death, shows: Shown(state: .problem, replies: nil)))
        turn.end = .stopped
        return turn
    }

    static let lastKinds: [(Int) -> Case] = [diesMidTurn, exitsMidTurn, exitsAfterDone, diesAfterDone]

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
                Report(item: .done("Reply 1."), shows: finished("Reply 1.", first), afterRecords: 1), Report(item: .working, shows: works),
                Report(item: .done("Both."), shows: finished("Both.", both), afterRecords: 3),
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

    /// Consecutive turns whose replies share a first line, and a short
    /// first line that begins the turn before's (review of the pairing 2,
    /// note 1).
    static let sharedLines: [Case] = [
        typed("same line", 1, done: "Done.", reply: "Done.\nUpdated the parser.")
            .then(typed("same line", 2, done: "Done.", reply: "Done.\nUpdated the tests.")),
        typed("long line", 1, done: "No, the tests failed.", reply: "No, the tests failed.\nSee the log.")
            .then(typed("its beginning", 2, done: "No", reply: "No\nNothing to change.")),
    ]

    /// Every merge of the case's two channels that keeps each one's order
    /// and what may come before what.
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
            if reports < c.reports.count && c.reports[reports].afterRecords <= records {
                walk(reports + 1, records, path + [.report(reports)])
            }
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
        case .close:
            return [.surfaceDied(generation: generation, byUser: true, isViewed: viewed)]
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
                shown = Shown(state: c.reports[r].shows.state ?? shown.state, replies: c.reports[r].shows.replies ?? shown.replies)
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
            if record.state != shown.state { found.append("shows \(record.state), not \(String(describing: shown.state))") }
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
            // A failure with no `working` leaves the reply before it as it
            // was, read or not; one after a `working` read it.
            if record.unread && !c.name.hasSuffix("failed at once") { found.append("unread under a problem") }
        case .stopped:
            if record.problem?.kind != .exited { found.append("problem \(String(describing: record.problem))") }
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
        case accepted, acceptedThenTurn, declined, closedByPerson, exitedFailing, terminalDied, failed

        static let reply = "First.\nMore."
        static let nextReply = "Reply 2.\nMore."

        /// After the trust report.
        var reports: [Report] {
            func shown(_ item: Item) -> Report { Report(item: item, shows: works) }
            switch self {
            case .accepted: return [shown(.idle)]
            // The next turn starts once the reply behind the dialog is in
            // (a prompt typed while that turn ran would queue behind it: not
            // generated), and its `done` after its prompt's record.
            case .acceptedThenTurn:
                return [shown(.idle), Report(item: .working, shows: works, afterRecords: 3),
                        Report(item: .done("Reply 2."), shows: works, afterRecords: 4)]
            // "No, exit": `idle`, exit status 0, `idle` (`stage5/trustprompt`).
            case .declined: return [shown(.idle), shown(.exit(0)), shown(.idle)]
            case .closedByPerson: return [shown(.close)]
            case .exitedFailing: return [shown(.exit(1))]
            case .terminalDied: return [shown(.death)]
            case .failed: return [shown(.error("Broke."))]
            }
        }

        /// SessionStart and the prompt may come before the trust report
        /// (0.16 s); the Stop comes after it (5.1 s); a next prompt after the
        /// person accepted.
        var records: [Record] {
            var records = [
                Record(item: .sessionStart, after: 0), Record(item: .prompt("first task"), after: 0),
                Record(item: .stop(Self.reply), after: 1),
            ]
            if self == .acceptedThenTurn {
                records += [Record(item: .prompt("task 2"), after: 2), Record(item: .stop(Self.nextReply), after: 3)]
            }
            return records
        }

        /// What the tile shows after `reportsSeen` reports (the trust report
        /// first), the Stop behind the dialog seen or not.
        func shows(after reportsSeen: Int, stopSeen: Bool) -> AgentRecord.State {
            switch (self, reportsSeen) {
            case (_, 0): return .working
            case (_, 1): return .asks
            case (.accepted, _), (.declined, 2), (.acceptedThenTurn, 2): return stopSeen ? .finished : .working
            case (.acceptedThenTurn, 3): return .working
            case (.acceptedThenTurn, _), (.declined, _), (.closedByPerson, _): return .finished
            case (.exitedFailing, _), (.terminalDied, _), (.failed, _): return .problem
            }
        }

        /// The turns completed, when the Stop came after `stopAfter` reports:
        /// a Stop before the launch ends completes the turn; after it, the
        /// turn ended with its launch and the Stop only brings its reply.
        func completions(stopAfter: Int) -> Int {
            switch self {
            case .accepted: return 1
            case .acceptedThenTurn: return 2
            case .declined: return stopAfter < 3 ? 1 : 0
            case .closedByPerson: return stopAfter < 2 ? 1 : 0
            case .exitedFailing, .terminalDied, .failed: return 0
            }
        }
    }

    /// The first prompt's turn behind the start dialog, the dialog ending
    /// `end`, in `order`.
    static func dialogFaults(_ end: DialogEnd, _ order: [Step], viewed: Bool) throws -> [String] {
        let reports = [Report(item: .trust, shows: works)] + end.reports
        let records = end.records
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
                item = reports[r].item
                reportsSeen += 1
            case .record(let k):
                item = records[k].item
                if item == .stop(DialogEnd.reply) { stopAfter = reportsSeen }
            }
            let before = state.record.state
            let (after, completed) = try reduce(state, item, viewed: viewed)
            state = after
            completions += completed
            let record = state.record
            let expected = end.shows(after: reportsSeen, stopSeen: stopAfter != nil)
            let replies: [String?] = end == .acceptedThenTurn && reportsSeen >= 3
                ? (reportsSeen == 3 ? [nil] : ["Reply 2.", DialogEnd.nextReply]) : [nil, DialogEnd.reply]
            var found: [String] = []
            if completed > 0 && (record.lastMessage == nil || !replies.contains(record.lastMessage)) {
                found.append("notified \(record.lastMessage ?? "nil")")
            }
            if record.state == .finished && record.problem != nil { found.append("finished with a problem") }
            if case .record = step, before == .problem, record.state == .finished { found.append("a record turned a problem into finished") }
            if record.state != expected { found.append("shows \(record.state), not \(expected)") }
            if !replies.contains(record.lastMessage) { found.append("reply \(record.lastMessage ?? "nil")") }
            if !found.isEmpty { return ["step \(index) (\(item))"] + found }
        }
        let expected = end.completions(stopAfter: stopAfter ?? reports.count)
        var found: [String] = []
        let record = state.record
        if completions != expected { found.append("\(completions) completions") }
        let last = end == .acceptedThenTurn ? DialogEnd.nextReply : DialogEnd.reply
        if record.lastMessage != last { found.append("last reply \(record.lastMessage ?? "nil")") }
        if record.unread != (expected > 0 && !viewed) { found.append("unread \(record.unread)") }
        let prompts = end == .acceptedThenTurn ? ["first task", "task 2"] : ["first task"]
        if record.prompts.map(\.text) != prompts { found.append("prompts \(record.prompts.map(\.text))") }
        if state.stateBeforeStartDialog != nil || state.completedBehindDialog != nil { found.append("start dialog left") }
        if state.hiddenTurn { found.append("hiddenTurn") }
        if state.pendingMessage != nil, record.state != .problem { found.append("pendingMessage") }
        return found
    }

    /// Every case and every merge; the runs, and each failure with its order.
    /// Not generated, as named tests cover them: the dialog with no first
    /// prompt (`theTrustDialogAtStartIsNoTurn`), the sign-in report
    /// (`aSignIn…`, `heldKeysDoNotGoIntoTheSignIn`), a resumed conversation
    /// (`aResumeChecksTheConversationAndItsLock`), `PreInvocation` 1
    /// (`preInvocation…`).
    static func allFaults() throws -> (runs: Int, failures: [String]) {
        var cases: [Case] = kinds.map { $0(1) } + lastKinds.map { $0(1) } + queued + sharedLines
        for first in kinds { for second in kinds + lastKinds { cases.append(first(1).then(second(2))) } }
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
        for end in DialogEnd.allCases {
            let dialog = Case(
                name: "\(end)", reports: [Report(item: .trust, shows: works)] + end.reports, records: end.records,
                prompts: [], completions: 0, end: .interrupted)
            for order in orders(dialog) {
                for viewed in [false, true] {
                    runs += 1
                    let found = try dialogFaults(end, order, viewed: viewed)
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
    static let expectedRuns = 22470

    /// Review of the fixes 2, trigger A: a wake-up turn of its own, its
    /// `done` before its Stop. Two turns, two completions.
    @Test func aWakeUpTurnsDoneBeforeItsRecords() throws {
        let order: [Item] = [.working, .prompt("sleep, then say slept"), .stop("Waiting.\nThe command runs."), .done("Waiting."),
                             .working, .selfStart, .done("slept"), .stop("slept\nThe command ended.")]
        var state = Self.finishedAgent(unread: false)
        var completions = 0
        for item in order { let r = try Self.reduce(state, item, viewed: false); state = r.0; completions += r.1 }
        #expect(completions == 2)
        #expect(state.record.lastMessage == "slept\nThe command ended.")
        #expect(state.record.prompts.map(\.text) == ["sleep, then say slept"])
    }

    /// Review of the pairing, fault 2: the Stop of the turn before comes
    /// once the next turn works (before that turn's prompt record: the hook
    /// channel keeps its order), and that turn's `done` before its own
    /// Stop. The completion notifies the turn's own reply.
    @Test func theTurnBeforesStopDuringTheNextTurn() throws {
        let order: [Item] = [.working, .prompt("task 1"), .done("Reply 1."), .working, .stop("Reply 1.\nMore."),
                             .prompt("task 2"), .done("Reply 2.")]
        var state = Self.finishedAgent(unread: false)
        var completions = 0
        for item in order { let r = try Self.reduce(state, item, viewed: false); state = r.0; completions += r.1 }
        #expect(completions == 2)
        #expect(state.record.lastMessage == "Reply 2.")
        (state, _) = try Self.reduce(state, .stop("Reply 2.\nMore."), viewed: false)
        #expect(state.record.lastMessage == "Reply 2.\nMore.")
    }

    /// Review of the pairing 2, note 1: two turns whose replies start with
    /// the same line, the first turn's Stop late. The next turn's prompt
    /// record ends its claim: the completion notifies the turn's own line.
    @Test func aLateStopWithTheSameFirstLineIsNotTheNextTurns() throws {
        let order: [Item] = [.working, .prompt("task 1"), .done("Done."), .working, .stop("Done.\nUpdated the parser."),
                             .prompt("task 2"), .done("Done.")]
        var state = Self.finishedAgent(unread: false)
        for item in order { state = try Self.reduce(state, item, viewed: false).0 }
        #expect(state.record.lastMessage == "Done.")
        state = try Self.reduce(state, .stop("Done.\nUpdated the tests."), viewed: false).0
        #expect(state.record.lastMessage == "Done.\nUpdated the tests.")
    }

    /// Review of the pairing 2, note 1: an uncut `done` line is a whole
    /// first line; "No" is not the beginning of "No, the tests failed.".
    @Test func anUncutLineMatchesOnlyAWholeFirstLine() throws {
        var state = Self.finishedAgent(unread: false)
        for item in [Item.working, .prompt("task 1"), .done("No")] { state = try Self.reduce(state, item, viewed: false).0 }
        state = try Self.reduce(state, .stop("No, the tests failed.\nSee the log."), viewed: false).0
        #expect(state.record.lastMessage == "No")
        state = try Self.reduce(state, .stop("No\nNothing to change."), viewed: false).0
        #expect(state.record.lastMessage == "No\nNothing to change.")
    }

    /// Review of the pairing, fault 2 (`stage5/wake2`): the wake-up's
    /// `done` before its Stop; the notified reply is the wake-up's, not the
    /// step before it.
    @Test func aWakeUpInsideTheTurnDoneBeforeItsRecords() throws {
        let order: [Item] = [.working, .prompt("sleep, then say slept"), .stop("Waiting."), .selfStart, .done("slept")]
        var state = Self.finishedAgent(unread: false)
        var completions = 0
        for item in order { let r = try Self.reduce(state, item, viewed: false); state = r.0; completions += r.1 }
        #expect(completions == 1)
        #expect(state.record.lastMessage == "slept")
        state = try Self.reduce(state, .stop("slept\nThe command ended."), viewed: false).0
        #expect(state.record.lastMessage == "slept\nThe command ended.")
        #expect(state.pendingMessage == nil)
    }

    /// Review of the pairing, fault 1: the Stop of the turn behind the
    /// dialog comes after the launch ended in a failure. The agent stays
    /// stopped with the problem, not finished, and nothing is notified;
    /// the reply is kept.
    @Test func aLateStopAfterTheDialogEndedInAFailure() throws {
        var state = Self.launchedWithAPrompt()
        for item in [Item.trust, .prompt("first task"), .exit(1)] { state = try Self.reduce(state, item, viewed: false).0 }
        #expect(state.record.state == .problem)
        let (after, completions) = try Self.reduce(state, .stop("First."), viewed: false)
        #expect(completions == 0)
        #expect(after.record.state == .problem)
        #expect(!after.record.unread)
        #expect(after.record.lastMessage == "First.")
    }

    /// Review of the pairing 2, note 3: a failure of the report channel
    /// stops the agent after the turn behind the dialog ended and before
    /// the person answers. The answer does not turn the problem into
    /// finished; the reply is kept.
    @Test func aStopBehindTheDialogStaysAProblemWhenItIsAnswered() throws {
        var state = Self.launchedWithAPrompt()
        for item in [Item.trust, .prompt("first task"), .stop("First.")] { state = try Self.reduce(state, item, viewed: false).0 }
        state = AgentStateReducer.reduce(state, event: .reportFailed, rules: Self.rules).state
        let (after, completions) = try Self.reduce(state, .idle, viewed: false)
        #expect(completions == 0)
        #expect(after.record.state == .problem && after.record.problem?.kind == .reportFailed)
        #expect(after.record.lastMessage == "First.")
    }

    static func launchedWithAPrompt() -> AgentRuntimeSnapshot {
        var state = AgentRuntimeSnapshot(
            surfaceState: .open, processState: .launching, activityState: .unknown, telemetryHealth: .awaiting,
            launchGeneration: generation, record: AgentRecord())
        state = AgentStateReducer.reduce(state, event: .launchRequested(generation: generation, prompted: true), rules: rules).state
        return AgentStateReducer.reduce(state, event: .sent(prompt: "first task", by: .person), rules: rules).state
    }
}
