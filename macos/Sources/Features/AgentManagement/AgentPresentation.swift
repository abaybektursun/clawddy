import Foundation

/// The seven states the window shows (`docs/clawddy-design/flows.md` 2.1), a
/// function of the agent's record alone: its mark, and the words that name
/// it (`words.md`, "Agent states"). Settled is not one of them: a settled
/// agent is not shown. Whether an agent waits on the person is the record's
/// `isWaitingOnYou`, and its sentence the record's `sentence`; nothing in the
/// interface decides either again.
enum AgentShownState: CaseIterable, Sendable {
    case working
    case asks
    case problem
    case finishedUnread
    case finished
    case paused
    case limitReset

    init(_ record: AgentRecord) {
        switch record.state {
        case .working: self = .working
        case .asks: self = .asks
        case .problem: self = .problem
        case .finished: self = record.unread ? .finishedUnread : .finished
        case .paused: self = .paused
        case .limitReset: self = .limitReset
        }
    }

    /// The mark find shows for an agent in `state`: a settled agent's is
    /// the finished check in the third text tone whatever its state, so
    /// amber in find means only an agent waiting on the person.
    static func inFind(_ state: AgentShownState, settled: Bool) -> AgentShownState {
        settled ? .finished : state
    }

    /// What VoiceOver says for the mark.
    var name: String {
        switch self {
        case .working: "Working"
        case .asks: "Has a question"
        case .problem: "Stopped with a problem"
        case .finishedUnread: "Finished, unread"
        case .finished: "Finished"
        case .paused: "Paused at its usage limit"
        case .limitReset: "Usage limit reset"
        }
    }

    /// How long it has been in this state, as VoiceOver says it: "working
    /// for 4 minutes", "asked just now".
    func agePhrase(_ age: TimeInterval) -> String {
        let span = AgentAge.spoken(age)
        if self == .working { return age < 45 ? "working just now" : "working for \(span)" }
        let verb = switch self {
        case .working: "working"
        case .asks: "asked"
        case .problem: "stopped"
        case .finishedUnread, .finished: "finished"
        case .paused: "paused"
        case .limitReset: "reset"
        }
        return age < 45 ? "\(verb) just now" : "\(verb) \(span) ago"
    }
}

/// An agent's age as the window writes it (`words.md`): the time since its
/// turn started while working, otherwise since its state last changed, both
/// the record's `changedAt`.
enum AgentAge {
    /// On a tile: "now" under 45 s, then "4m", "3h", "2d".
    static func short(_ age: TimeInterval) -> String {
        guard age >= 45 else { return "now" }
        let minutes = max(1, Int((age / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
    }

    /// At the right of the header: "working 2m" ("working now" in its first
    /// 45 s), "just now", "4m ago".
    static func header(_ state: AgentShownState, age: TimeInterval) -> String {
        if state == .working { return "working " + short(age) }
        return age < 45 ? "just now" : short(age) + " ago"
    }

    /// "4 minutes", "1 hour", "2 days".
    static func spoken(_ age: TimeInterval) -> String {
        let minutes = max(1, Int((age / 60).rounded()))
        func count(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(value == 1 ? "" : "s")" }
        if minutes < 60 { return count(minutes, "minute") }
        if minutes < 24 * 60 { return count(minutes / 60, "hour") }
        return count(minutes / (24 * 60), "day")
    }
}

extension AgentInstance {
    /// The state the window shows (`AgentShownState`).
    var shownState: AgentShownState { AgentShownState(record) }

    /// The sentence the window shows (`AgentRecord.sentence`), or, while its
    /// launch waits its turn, the app's words saying so.
    var sentence: AgentSentence {
        waitsToStart ? .app(Self.waitingToStart) : record.sentence(cli: provider)
    }

    /// words.md, "Sentences the app writes on a tile".
    static let waitingToStart = "Waiting to start. \(AgentBridge.startConcurrency) agents start at a time."
}

/// The words the window says about waiting agents (`words.md`, "Top bar").
enum AgentWaitingWords {
    /// "3 waiting on you", or "No one is waiting".
    static func count(_ count: Int) -> String {
        count > 0 ? "\(count) waiting on you" : "No one is waiting"
    }
}

/// The status line after a send to several (words.md, "Status line"): "Sent
/// to 3 agents"; "Sent to 2. Skipped Feeds: it is asking a question.";
/// "Nothing sent. Skipped …", one sentence per reason, names joined.
enum AgentSendReport {
    enum Reason: Equatable {
        case typed, asking, menu, notReady

        func words(_ many: Bool) -> String {
            switch self {
            case .typed: many ? "their terminals hold text you typed" : "its terminal holds text you typed"
            case .asking: many ? "they are asking questions" : "it is asking a question"
            case .menu: many ? "their terminals are showing a menu" : "its terminal is showing a menu"
            case .notReady: many ? "they were not ready" : "it was not ready"
            }
        }
    }

    static func words(sent: Int, skipped: [(Reason, [String])]) -> (text: String, seconds: TimeInterval) {
        let reasons = skipped.map { "Skipped \($0.1.joined(separator: ", ")): \($0.0.words($0.1.count > 1))." }.joined(separator: " ")
        if reasons.isEmpty { return (sent == 1 ? "Sent to 1 agent" : "Sent to \(sent) agents", 1.8) }
        return (sent == 0 ? "Nothing sent. " + reasons : "Sent to \(sent). " + reasons, 6)
    }
}
