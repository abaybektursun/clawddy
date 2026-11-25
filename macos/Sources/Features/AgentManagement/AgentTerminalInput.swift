import Foundation

/// What the app puts into an agent's terminal: a paste, or one key.
enum AgentTerminalInput: Equatable, Sendable {
    case paste(String)
    case enter
    case escape
    /// Control-C.
    case interrupt
}

/// How a send ended (`AgentBridge.send`).
enum AgentSendResult: Equatable, Sendable {
    case sent
    /// Its input line holds text the person typed; nothing was sent.
    case holdsText
    /// It is asking a question or showing another menu; nothing was sent.
    case menu
    /// Its CLI has not reported that it reads its input yet, or does not run.
    case notReady
    /// A later interrupting send to the same agent took its place.
    case replaced
}

/// What an agent's input line holds, read from its terminal's text
/// (probes.md, P2 "Line parse", Claude Code 2.1.331 and Codex 0.169.0;
/// cli-facts.md, agy 1.5.17, "Screens").
enum AgentInputLine: Equatable, Sendable {
    case empty
    case holdsText(String)
    /// No input line on screen: a menu, a dialog, or the CLI is not drawn.
    case none

    /// The input line on `screen`, the terminal's viewport text.
    /// `prompted` when a prompt was submitted in this launch: Claude's dim
    /// hint before the first prompt reads like text, and counts as empty only
    /// before one.
    static func read(_ screen: String, provider: AgentProviderID, prompted: Bool) -> AgentInputLine {
        let rows = screen.components(separatedBy: "\n").map { row in
            String(row.unicodeScalars.filter { !(0x2800...0x28FF).contains($0.value) }.map(Character.init))
                .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }
        switch provider {
        case .claudeCode: return claude(rows, prompted: prompted)
        case .codex: return codex(rows)
        case .antigravity: return antigravity(rows)
        }
    }

    /// agy's input box (`AgentTail.antigravityBox`). It is empty when the
    /// text after ">" is, or is the mode's hint: it ends "(shift+tab to
    /// cycle)", or, in a terminal too narrow for it, it is cut to the box
    /// and ends "..." ("Auto mode: edits & safe commands auto-...", probed
    /// at 44 columns). A question, a permission or the folder-trust dialog
    /// takes the box's place: no box.
    private static func antigravity(_ rows: [String]) -> AgentInputLine {
        guard let box = AgentTail.antigravityBox(rows) else { return .none }
        let text = ([String(rows[box.lowerBound].dropFirst())] + rows[(box.lowerBound + 1)..<box.upperBound])
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if flat.isEmpty || flat.hasSuffix("(shift+tab to cycle)")
            || flat.range(of: #"^[A-Za-z-]+ mode: .*\.\.\.$"#, options: .regularExpression) != nil {
            return .empty
        }
        return .holdsText(text)
    }

    /// Claude's input sits between the last two full-width rules, its first
    /// row "❯", then a no-break space before any text or hint.
    private static func claude(_ rows: [String], prompted: Bool) -> AgentInputLine {
        let rules = rows.indices.filter { isRule(rows[$0]) }
        guard rules.count >= 2 else { return .none }
        let top = rules[rules.count - 2], bottom = rules[rules.count - 1]
        let input = rows[(top + 1)..<bottom]
        guard let first = input.first, first.hasPrefix("❯") else { return .none }
        let text = ([String(first.dropFirst())] + input.dropFirst().map { String($0) })
            .joined(separator: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \u{00A0}\n"))
        if text.isEmpty || text == "Press up to edit queued messages" { return .empty }
        if !prompted, first.hasPrefix("❯\u{00A0}Try \"") { return .empty }
        return .holdsText(text)
    }

    /// A row of box-drawing rule, as wide as the terminal, possibly with a
    /// session name set into it ("─── Real ─").
    private static func isRule(_ row: String) -> Bool {
        let rules = row.filter { $0 == "─" }.count
        return rules >= 20 && rules * 10 >= row.count * 9 - 40
    }

    /// Codex's composer is the last row starting with "› "; its placeholder
    /// is no text. Its update dialog marks its choice the same way.
    private static func codex(_ rows: [String]) -> AgentInputLine {
        guard let row = rows.last(where: { $0.hasPrefix("›") }) else { return .none }
        let text = row.dropFirst().trimmingCharacters(in: .whitespaces)
        if text.range(of: #"^\d+\. "#, options: .regularExpression) != nil { return .none }
        if text.isEmpty || text == "Ask Codex to do anything" { return .empty }
        return .holdsText(text)
    }
}
