import Foundation

/// The one sentence shown for an agent on its tile and in its row
/// (`docs/clawddy-design/flows.md` 4.2): the CLI's own words when it gave
/// any, otherwise the app's sentence from `words.md`, which the interface
/// sets in italic.
struct AgentSentence: Equatable, Sendable {
    var text: String
    var isAppWritten: Bool

    /// The CLI's words, made safe for a label (`label`).
    static func cli(_ text: String) -> Self { Self(text: label(text), isAppWritten: false) }
    static func app(_ text: String) -> Self { Self(text: text, isAppWritten: true) }

    /// Text from a CLI as one label line: ANSI escape sequences, control
    /// characters and bidirectional controls removed, whitespace collapsed,
    /// at most `limit` characters. A CLI's words can never colour, reorder
    /// or spoof what a label shows.
    static func label(_ text: String, limit: Int = AgentSentence.limit) -> String {
        let withoutEscapes = text.replacingOccurrences(
            of: #"\x{1B}(\[[0-?]*[ -/]*[@-~]|\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)?|[@-Z\\-_])"#,
            with: "",
            options: .regularExpression)
        let kept = withoutEscapes.unicodeScalars.filter { scalar in
            let value = scalar.value
            if value < 0x20 { return value == 0x09 || value == 0x0A }
            if (0x7F...0x9F).contains(value) { return false }
            if (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value) { return false }
            if value == 0x200E || value == 0x200F || value == 0x061C { return false }
            return true
        }
        return cut(oneLine(String(String.UnicodeScalarView(kept))), to: limit)
    }
}

extension AgentRecord {
    /// The sentence, a function of the record alone. `provider` is the CLI
    /// app-written sentences name; `time` writes a reset time ("3:00 pm").
    func sentence(cli provider: AgentProviderID, time: (Date) -> String = AgentSentence.shortTime) -> AgentSentence {
        let cli = provider.displayName
        switch state {
        case .working:
            var base: AgentSentence
            if cutOff && continuedInARow > 0 {
                base = .app("Continuing after a restart (\(continuedInARow) of 3)")
            } else if let activity, !AgentSentence.label(activity).isEmpty {
                // The step its CLI reports now.
                base = .cli(activity)
            } else if let instruction = prompts.last(where: { $0.text != queued })?.text ?? firstInstruction,
                      !AgentSentence.label(instruction).isEmpty {
                // Else what it was last told to do, as written; a message
                // still queued is not what it does now.
                base = .cli(instruction)
            } else {
                base = .app("Working")
            }
            if let queued { base.text += " " + AgentSentence.label("You sent: \(queued)") }
            return base
        case .asks:
            return question.map { .cli(AgentSentence.oneLine($0)) } ?? .app("Has a question")
        case .problem:
            return problemSentence(provider)
        case .finished:
            if interrupted { return .app("You interrupted it.") }
            guard let lastMessage, let sentence = AgentSentence.summary(of: lastMessage) else {
                return .app("No output yet")
            }
            return .cli(sentence)
        case .paused:
            let resets = limit?.resetsAt.map(time)
            if let message = limit?.message.map(AgentSentence.oneLine), !message.isEmpty {
                guard let resets, message.range(of: "reset", options: .caseInsensitive) == nil else {
                    return .cli(message)
                }
                return .cli("\(message) Resets at \(resets).")
            }
            return .app(resets.map { "Paused at the usage limit, which resets at \($0)." }
                ?? "Paused at the usage limit. \(cli) gave no reset time.")
        case .limitReset:
            return .app("Usage limit reset. Open it to continue.")
        }
    }

    private func problemSentence(_ provider: AgentProviderID) -> AgentSentence {
        let cli = provider.displayName
        let text = problem?.text.map { AgentSentence.label($0) }.flatMap { $0.isEmpty ? nil : $0 }
        switch problem?.kind {
        case .error, nil:
            return text.map(AgentSentence.cli)
                ?? .app("Stopped with an error. Open it to see why.")
        case .loginExpired:
            // The CLI's own text ("API Error: 401 · OAuth token has…") stays
            // in its terminal.
            return .app("Login expired. Open it and \(provider.signInStep).")
        case .exited:
            let how = problem?.status.map { $0 > 128 ? " (signal \($0 - 128))" : " (status \($0))" } ?? ""
            return .app("\(cli) stopped\(how). Type here to continue.")
        case .cutOffTooOften:
            return .app("Cut off by three restarts. Open it to continue.")
        case .launch:
            return .app(text ?? "\(cli) could not be started.")
        case .notInstalled:
            return .app("\(cli) is not installed. Install it, then type to start.")
        case .conversationMissing:
            return .app("\(cli) cannot find this conversation. Type to start fresh.")
        case .reportFailed:
            return .app("Could not read \(cli) status. Open it to check.")
        case .didNotStart:
            return .app("\(cli) did not start in 30 s. Type here to try again.")
        case .openElsewhere:
            return .app("Open in another terminal. Close it there to continue.")
        }
    }
}

extension AgentSentence {
    /// "3:00 pm", in the system's short time format.
    static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// The longest sentence kept, in characters; the tile cuts it further.
    static let limit = 300

    /// What a finished agent said, as one line: its first paragraph of prose
    /// (not a heading, a code block, a table or a rule), Markdown marks
    /// removed and whitespace collapsed; when the message ends with a
    /// question in a later paragraph, that question follows, since it is what
    /// the agent waits for. Nil when the message holds no prose.
    static func summary(of message: String) -> String? {
        let paragraphs = proseParagraphs(of: message)
        guard var sentence = paragraphs.first else {
            // Only code or a table: its first line, as plain text.
            return message.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("~~~") && !isRule($0) && !$0.allSatisfy { "|-: ".contains($0) } }
                .map { plain($0).trimmingCharacters(in: CharacterSet(charactersIn: "| ")) }
                .map { cut($0, to: limit) }
        }
        // "Done:" says nothing without the list it introduces.
        var used = 1
        while sentence.hasSuffix(":"), used < paragraphs.count {
            sentence += " " + paragraphs[used]
            used += 1
        }
        if let last = paragraphs.last, paragraphs.count > used, last.hasSuffix("?") {
            sentence += " " + last
        }
        return cut(sentence, to: limit)
    }

    /// The message's paragraphs that are prose or list items, each as one
    /// line without Markdown marks.
    private static func proseParagraphs(of message: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        var inFence = false
        var lastWasItem = false
        func flush() {
            let text = oneLine(current.joined(separator: " ")).replacingOccurrences(of: " ; ", with: "; ")
            if !text.isEmpty { paragraphs.append(text) }
            current = []
            lastWasItem = false
        }
        for rawLine in message.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if line.isEmpty || isHeading(line) || isRule(line) || line.hasPrefix("|") {
                flush()
                continue
            }
            // List items run on, one after another, joined by semicolons.
            let isItem = line.range(of: #"^([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil
            current.append(isItem && lastWasItem ? "; " + plain(line) : plain(line))
            lastWasItem = isItem
        }
        flush()
        return paragraphs
    }

    private static func isHeading(_ line: String) -> Bool {
        line.range(of: #"^#{1,6}(\s|$)"#, options: .regularExpression) != nil
    }

    private static func isRule(_ line: String) -> Bool {
        line.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil
    }

    /// One line of Markdown without its marks: quote and list markers, emphasis,
    /// inline code ticks, and links reduced to their text.
    private static func plain(_ line: String) -> String {
        var text = line
        let rules: [(String, String)] = [
            (#"^(>\s*)+"#, ""),
            (#"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, ""),
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"(\*\*|__)(.+?)\1"#, "$2"),
            (#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "$1"),
            (#"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, "$1"),
            (#"~~(.+?)~~"#, "$1"),
            (#"`+([^`]*)`+"#, "$1"),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }

    /// The text on one line: every run of whitespace, newlines included, one
    /// space.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// At most `limit` characters, cut at a word with "…".
    private static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let end = head.lastIndex(of: " ") ?? head.endIndex
        return head[..<end].trimmingCharacters(in: .whitespaces) + "…"
    }
}
