import Foundation

/// One agent as find sees it: its name and project, how often what find
/// reads of it has changed, its stored record, read only when that changed
/// (a key never copies every record), and its current sentence (the
/// tile's), made only for an agent that is listed: summarising every
/// agent's last message at each key would cost a frame.
struct AgentSearchSource {
    var id: UUID
    var name: String
    var project: String
    var projectID: UUID
    /// `AgentInstance.searchVersion`.
    var version: Int
    var record: () -> AgentRecord
    var sentence: () -> String
}

/// An agent find lists: the line shown under its name, and where each typed
/// word is in the name and in that line, to be marked.
struct AgentSearchHit: Equatable {
    var id: UUID
    var name: String
    var project: String
    var settled: Bool
    var changedAt: Date
    var nameMatches: [NSRange]
    var line: String
    var lineMatches: [NSRange]
}

/// Find over the agents' stored records only (flows.md 6.8, brief answer 9,
/// S8 review ruling 3): the name, the last message, the question, the
/// problem's text, the limit message, the first instruction and the prompts
/// sent, in every project, settled agents too; never a terminal's output or
/// a CLI's transcript. Matching is by words: every typed word appears
/// somewhere in the agent's words, in any order, case and accents folded,
/// composed and decomposed forms equal.
///
/// Each agent's words are kept folded as bytes and searched with `memmem`,
/// so a key costs a scan of bytes already in memory; an agent's words are
/// folded again only when its record or name changed. Everything runs on
/// the main thread, in the key's turn, so the results shown are always those
/// of the text in the field.
final class AgentSearchIndex {
    /// An agent's words, folded, with what they were made from.
    private struct Entry {
        var version: Int
        var waiting: Bool
        var settled: Bool
        var changedAt: Date
        var name: [UInt8]
        /// The record's words in the order a line is chosen from.
        var fields: [String]
        var folded: [[UInt8]]
    }

    private var entries: [UUID: Entry] = [:]

    /// A found agent: its place in the sources, the typed words its name
    /// lacks (which choose the line shown), and what it sorts by.
    private struct Found {
        var index: Int
        var outsideName: [Int]
        var waiting: Bool
        var settled: Bool
        var changedAt: Date
    }

    /// How many agents' words were folded again, for the tests.
    private(set) var rebuilt = 0

    /// Text as find compares it: case and accents folded, composed and
    /// decomposed forms the same.
    static func fold(_ text: String) -> String {
        text.decomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    /// The typed words, and whether the text asks for the current project's
    /// settled agents: "settled" as a whole first word.
    static func words(of query: String) -> (words: [String], settledOnly: Bool) {
        var words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let settledOnly = words.first.map { fold($0) == "settled" } ?? false
        if settledOnly { words.removeFirst() }
        return (words, settledOnly)
    }

    /// The rows for `query`: up to 8 agents (5 for an empty field) ordered
    /// waiting on the person, then not settled, then settled, then the most
    /// recently changed. "settled" as the first word lists only the current
    /// project's settled agents, the other words filtering them.
    func search(_ query: String, in sources: [AgentSearchSource], currentProject: UUID?) -> [AgentSearchHit] {
        let (words, settledOnly) = Self.words(of: query)
        let needles = words.map { Array(Self.fold($0).utf8) }
        // What each found agent sorts by, read once: the records are not
        // copied again while sorting.
        var found: [Found] = []
        var seen = Set<UUID>()
        for (index, source) in sources.enumerated() {
            seen.insert(source.id)
            let entry = self.entry(for: source)
            if settledOnly, !entry.settled || source.projectID != currentProject { continue }
            // Every word somewhere; the words the name lacks choose the line.
            let outsideName = needles.indices.filter { !Self.contains(entry.name, needles[$0]) }
            guard outsideName.allSatisfy({ word in entry.folded.contains { Self.contains($0, needles[word]) } }) else { continue }
            found.append(Found(
                index: index, outsideName: outsideName, waiting: entry.waiting, settled: entry.settled,
                changedAt: entry.changedAt))
        }
        // Agents that are gone take their words with them.
        if entries.count > seen.count { entries = entries.filter { seen.contains($0.key) } }
        found.sort { a, b in
            if a.waiting != b.waiting { return a.waiting }
            if a.settled != b.settled { return !a.settled }
            return a.changedAt > b.changedAt
        }
        // The line is chosen only for the agents listed.
        return found.prefix(words.isEmpty && !settledOnly ? 5 : 8).map { item in
            let source = sources[item.index]
            let field = entries[source.id].flatMap { Self.line(of: $0, holding: item.outsideName, needles: needles) }
            return Self.hit(source, field: field, words: words, settled: item.settled, changedAt: item.changedAt)
        }
    }

    /// The field that holds the most of the words a name lacks, the first
    /// of those; nil when the name holds every word.
    private static func line(of entry: Entry, holding words: [Int], needles: [[UInt8]]) -> String? {
        guard !words.isEmpty else { return nil }
        var best: (field: Int, count: Int)?
        for (index, field) in entry.folded.enumerated() {
            let count = words.filter { contains(field, needles[$0]) }.count
            if count > (best?.count ?? 0) { best = (index, count) }
            if count == words.count { break }
        }
        return best.map { entry.fields[$0.field] }
    }

    /// The commands whose titles hold every typed word, with where each word
    /// is: up to 4 for typed text, 5 for an empty field, none while
    /// "settled" lists settled agents.
    static func commands(_ titles: [String], matching query: String) -> [(index: Int, marks: [NSRange])] {
        let (words, settledOnly) = words(of: query)
        guard !settledOnly else { return [] }
        let matching = titles.indices.compactMap { index -> (index: Int, marks: [NSRange])? in
            let marks = ranges(of: words, in: titles[index])
            return marks.count == words.count ? (index, marks) : nil
        }
        return Array(matching.prefix(words.isEmpty ? 5 : 4))
    }

    private func entry(for source: AgentSearchSource) -> Entry {
        if let entry = entries[source.id], entry.version == source.version { return entry }
        let record = source.record()
        let fields = ([record.lastMessage, record.question, record.problem?.text, record.limit?.message, record.firstInstruction]
            + record.prompts.reversed().map(\.text))
            .compactMap { $0 }.filter { !$0.isEmpty }
        let entry = Entry(
            version: source.version, waiting: record.isWaitingOnYou, settled: record.settledAt != nil,
            changedAt: record.changedAt, name: Array(Self.fold(source.name).utf8),
            fields: fields, folded: fields.map { Array(Self.fold($0).utf8) })
        entries[source.id] = entry
        rebuilt += 1
        return entry
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        return haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin in
                memmem(hay.baseAddress, hay.count, pin.baseAddress, pin.count) != nil
            }
        }
    }

    /// Where each of `words` first is in `text`, case and accents folded;
    /// words not in it are left out.
    static func ranges(of words: [String], in text: String) -> [NSRange] {
        let all = text as NSString
        return words.compactMap { word in
            let found = all.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
            return found.location == NSNotFound ? nil : found
        }
    }

    /// The row of an agent: the line of the field that matched, cut to
    /// start a little before the first match; when the text is empty or
    /// only the name matched, its current sentence (so an asking agent shows
    /// its question).
    private static func hit(
        _ source: AgentSearchSource, field: String?, words: [String], settled: Bool, changedAt: Date
    ) -> AgentSearchHit {
        let (line, marks) = excerpt(field ?? source.sentence(), words: field == nil ? [] : words)
        return AgentSearchHit(
            id: source.id, name: source.name, project: source.project, settled: settled,
            changedAt: changedAt, nameMatches: ranges(of: words, in: source.name),
            line: line, lineMatches: marks)
    }

    /// The line of `text` that holds the first of `words` (its first line
    /// when none is in it), whitespace at its ends dropped; when that match
    /// starts more than 40 characters in, the line starts at a word about 30
    /// characters before it, after "…". Each word in the line is marked.
    static func excerpt(_ text: String, words: [String]) -> (String, [NSRange]) {
        let all = text as NSString
        let first = ranges(of: words, in: text).min { $0.location < $1.location }
        let lineRange = all.lineRange(for: NSRange(location: first?.location ?? 0, length: 0))
        var line = all.substring(with: lineRange)
        line = String(line.drop { $0.isWhitespace })
        while let last = line.last, last.isWhitespace { line.removeLast() }
        guard let first else { return (line, []) }
        let offset = ranges(of: [all.substring(with: first)], in: line).first?.location ?? 0
        if offset > 40 {
            let nsLine = line as NSString
            let space = nsLine.range(of: " ", options: .backwards, range: NSRange(location: 0, length: offset - 30))
            let cut = space.location == NSNotFound ? offset - 30 : space.location + 1
            line = "…" + nsLine.substring(from: cut)
        }
        return (line, ranges(of: words, in: line))
    }
}
