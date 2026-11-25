import Foundation

/// The lasting record of one agent: what its tile, its row and find show,
/// across restarts (`docs/clawddy-design/flows.md` 2 and 4). It lives in
/// `status/<agent id>.record.json` (mode 0600), written atomically by the
/// bridge, queued in the turn of each reducer change that alters its
/// `durable` part (`AgentBridge.saveRecord`).
/// Its name, CLI and place in its project live in `agents.json`, and its
/// conversation's session in `<agent id>.session.json`; each has one home.
struct AgentRecord: Codable, Equatable, Sendable {
    /// The agent's state as `flows.md` 2.1 names it. Settled is `settledAt`,
    /// kept apart so that undoing a settle returns the state before it.
    enum State: String, Codable, Sendable {
        case working
        case asks
        case problem
        case finished
        case paused
        case limitReset
    }

    /// Where the agent's name came from. Only a name the person gave is
    /// never replaced (`flows.md` 4.3).
    enum NameSource: String, Codable, Sendable {
        /// Clawddy's own, as "agent 3".
        case app
        /// The CLI's title for the conversation.
        case cli
        /// The first words of the first instruction.
        case firstInstruction
        /// The person's rename.
        case person
    }

    struct Prompt: Codable, Equatable, Sendable {
        enum Sender: String, Codable, Sendable { case person, app }
        var text: String
        var at: Date
        var by: Sender
        /// Sent while a turn worked: the CLI holds it behind that turn,
        /// which it is not the instruction of. Cleared when that turn ends.
        var queued = false

        init(text: String, at: Date, by: Sender, queued: Bool = false) {
            self.text = text
            self.at = at
            self.by = by
            self.queued = queued
        }

        private enum CodingKeys: String, CodingKey { case text, at, by, queued }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            at = try container.decode(Date.self, forKey: .at)
            by = try container.decode(Sender.self, forKey: .by)
            queued = try container.decodeIfPresent(Bool.self, forKey: .queued) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            try container.encode(at, forKey: .at)
            try container.encode(by, forKey: .by)
            if queued { try container.encode(queued, forKey: .queued) }
        }
    }

    /// Why the agent stopped with a problem. The CLI's own words are `text`
    /// when it gave any; otherwise the app writes the sentence (`words.md`).
    struct Problem: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            /// The turn failed with an error.
            case error
            /// The session's sign-in no longer works.
            case loginExpired
            /// The CLI exited with a status other than 0, or its terminal
            /// closed under it (`status` nil).
            case exited
            /// A fourth continuation after restarts would have been sent.
            case cutOffTooOften
            /// The CLI could not be started; `text` says why, in the app's words.
            case launch
            case notInstalled
            case conversationMissing
            /// What its CLI reported could not be read or recorded.
            case reportFailed
            /// Its CLI reported no ready input within `AgentBridge.startLimit`.
            case didNotStart
            /// Its conversation runs in another terminal.
            case openElsewhere
        }

        var kind: Kind
        var text: String?
        var status: Int?
    }

    /// A usage limit the CLI reported: its own message, and when it resets
    /// if it said.
    struct UsageLimit: Codable, Equatable, Sendable {
        var message: String?
        var resetsAt: Date?
    }

    var state: State = .finished
    /// When `state` last changed: the turn's start while working.
    var changedAt: Date = .distantPast
    /// A finished turn the person has not opened since.
    var unread = false
    var settledAt: Date?
    /// Its turn was cut off by a quit or a crash and has not finished since.
    var cutOff = false
    /// Continuations the app sent in a row without a finished turn.
    var continuedInARow = 0
    /// At most three continuations in a row (flows.md 6.14).
    var mayContinue: Bool { continuedInARow < 3 }
    /// The person interrupted its last turn.
    var interrupted = false
    /// A name that predates records is the person's (`AgentStateFold`).
    var nameSource: NameSource = .person
    var firstInstruction: String?
    var firstInstructionAt: Date?
    /// The last `promptLimit` prompts sent to it, oldest first.
    var prompts: [Prompt] = []
    /// The last prompt sent while it worked, which its CLI holds behind
    /// the turn (`Prompt.queued`).
    var queued: String? { prompts.last(where: \.queued)?.text }
    var lastMessage: String?
    var lastMessageAt: Date?
    /// What it is doing now, as its CLI reports it while working.
    var activity: String?
    var question: String?
    var problem: Problem?
    var limit: UsageLimit?

    static let promptLimit = 20
    /// Characters of a message or prompt kept.
    static let textLimit = 16_384

    init() {}

    /// A name from a first instruction (flows.md 4.3): its first five
    /// words, the first letter capitalised, trailing punctuation removed, at
    /// most 60 characters.
    static func name(fromInstruction instruction: String) -> String {
        let words = instruction.split(whereSeparator: { $0.isWhitespace }).prefix(5).joined(separator: " ")
        var name = String(words.prefix(60)).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if let first = name.first { name = first.uppercased() + name.dropFirst() }
        return name.isEmpty ? "agent" : name
    }

    /// What of the record is kept on disk: all of it but `activity`, the
    /// step a working CLI reports many times a second, which a restart
    /// clears (`appStarted`) and nothing else reads back.
    var durable: AgentRecord {
        var record = self
        record.activity = nil
        return record
    }

    /// Whether find reads the same of `a` as of `b`: the words it searches
    /// (the last message, the question, the problem, the limit, the first
    /// instruction, the prompts) and what it sorts by (waiting, settled,
    /// when it last changed). The step a working CLI reports is not read.
    static func findsSame(_ a: AgentRecord, _ b: AgentRecord) -> Bool {
        a.changedAt == b.changedAt && a.settledAt == b.settledAt && a.isWaitingOnYou == b.isWaitingOnYou
            && a.lastMessageAt == b.lastMessageAt && a.lastMessage == b.lastMessage
            && a.firstInstructionAt == b.firstInstructionAt && a.firstInstruction == b.firstInstruction
            && a.prompts.count == b.prompts.count && a.prompts.last?.at == b.prompts.last?.at
            && a.question == b.question && a.problem?.text == b.problem?.text && a.limit?.message == b.limit?.message
    }

    /// Waiting on the person (`flows.md` 2.1): not settled, and asking, stopped
    /// with a problem, finished and unread, or past its usage limit's reset.
    var isWaitingOnYou: Bool {
        guard settledAt == nil else { return false }
        switch state {
        case .asks, .problem, .limitReset: return true
        case .finished: return unread
        case .working, .paused: return false
        }
    }
}

// MARK: - Coding

extension AgentRecord {
    private enum CodingKeys: String, CodingKey {
        case state, changedAt, unread, settledAt, cutOff, continuedInARow, interrupted
        case nameSource, firstInstruction, firstInstructionAt, prompts, lastMessage
        case lastMessageAt, activity, question, problem, limit
    }

    /// Every field is optional on disk, so a scene, or a record a later build
    /// wrote with fewer fields, reads with the defaults for the rest.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .finished
        changedAt = try container.decodeIfPresent(Date.self, forKey: .changedAt) ?? .distantPast
        unread = try container.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        settledAt = try container.decodeIfPresent(Date.self, forKey: .settledAt)
        cutOff = try container.decodeIfPresent(Bool.self, forKey: .cutOff) ?? false
        continuedInARow = try container.decodeIfPresent(Int.self, forKey: .continuedInARow) ?? 0
        interrupted = try container.decodeIfPresent(Bool.self, forKey: .interrupted) ?? false
        nameSource = try container.decodeIfPresent(NameSource.self, forKey: .nameSource) ?? .person
        firstInstruction = try container.decodeIfPresent(String.self, forKey: .firstInstruction)
        firstInstructionAt = try container.decodeIfPresent(Date.self, forKey: .firstInstructionAt)
        prompts = try container.decodeIfPresent([Prompt].self, forKey: .prompts) ?? []
        lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)
        lastMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        activity = try container.decodeIfPresent(String.self, forKey: .activity)
        question = try container.decodeIfPresent(String.self, forKey: .question)
        problem = try container.decodeIfPresent(Problem.self, forKey: .problem)
        limit = try container.decodeIfPresent(UsageLimit.self, forKey: .limit)
    }

    static func url(_ id: UUID, _ statusDir: URL) -> URL {
        statusDir.appendingPathComponent("\(id.uuidString).record.json")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The agent's record, or nil when it has none yet. Any other read or
    /// decoding failure throws.
    static func load(_ id: UUID, from statusDir: URL) throws -> AgentRecord? {
        let data: Data
        do {
            data = try Data(contentsOf: url(id, statusDir))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try decoder.decode(AgentRecord.self, from: data)
    }

    /// Replaces the record on disk in one step, readable only by its owner.
    static func save(_ record: AgentRecord, for id: UUID, in statusDir: URL) throws {
        let file = url(id, statusDir)
        try AgentConfig.atomicWrite(encoder.encode(record), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
