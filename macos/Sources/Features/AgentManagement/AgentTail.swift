import AppKit
import CoreText
import GhosttyKit

/// The last lines of an agent's terminal as its tile shows them
/// (`docs/clawddy-design/flows.md` 4.1): the terminal's own text, cut above
/// the CLI's input box and footer, blank rows dropped, one colour: the
/// blank rows a CLI leaves between its steps would take a third of a small
/// tile.
/// Plan risk R5: when a CLI changes its look and nothing here recognises its
/// input box, the raw last rows show.
enum AgentTail {
    /// The rows of `screen`, a terminal's viewport text, above the CLI's
    /// input box and footer. `sentence` is the agent's sentence when it is
    /// not working: the row that repeats it word for word is left out.
    static func lines(_ screen: String, provider: AgentProviderID, sentence: String? = nil) -> [String] {
        var rows = screen.split(separator: "\n", omittingEmptySubsequences: false).map(clean)
        if let cut = inputBoxTop(rows, provider: provider) { rows = Array(rows[..<cut]) }
        if let sentence, !sentence.isEmpty {
            rows.removeAll { row in
                row.trimmingCharacters(in: CharacterSet(charactersIn: "⏺●• \u{00A0}")) == sentence
            }
        }
        rows.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        return rows
    }

    /// A row without Codex's braille spinner characters and trailing blanks.
    private static func clean(_ row: Substring) -> String {
        var scalars = row.unicodeScalars[...]
        if scalars.contains(where: { (0x2800...0x28FF).contains($0.value) }) {
            scalars = String.UnicodeScalarView(scalars.filter { !(0x2800...0x28FF).contains($0.value) })[...]
        }
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Where the CLI's input box starts, or nil when there is none on the
    /// screen: Claude's is between its last two full-width rules, the first
    /// of its rows "❯"; while it asks, its question and menu sit under its
    /// last rule (the tile's sentence says the question). Codex's composer is
    /// the last row starting with "›", with the blank row above it and its
    /// footer under it. agy's box sits between its last two rules
    /// (`antigravityBox`); while it asks, its menu's title row and rule
    /// take the box's place.
    static func inputBoxTop(_ rows: [String], provider: AgentProviderID) -> Int? {
        switch provider {
        case .antigravity:
            if let box = antigravityBox(rows) { return box.lowerBound - 1 }
            guard let rule = rows.lastIndex(where: isAntigravityRule) else { return nil }
            return rule > 0 && !rows[rule - 1].isEmpty ? rule - 1 : rule
        case .claudeCode:
            let rules = rows.indices.filter { isRule(rows[$0]) }
            guard let last = rules.last else { return nil }
            if rules.count >= 2, rows.indices.contains(rules[rules.count - 2] + 1),
               rows[rules[rules.count - 2] + 1].hasPrefix("❯") {
                return rules[rules.count - 2]
            }
            return last
        case .codex:
            guard let composer = rows.lastIndex(where: { $0.hasPrefix("›") }),
                  rows[composer].dropFirst().trimmingCharacters(in: .whitespaces)
                    .range(of: #"^\d+\. "#, options: .regularExpression) == nil
            else { return nil }
            var top = composer
            while top > 0, rows[top - 1].trimmingCharacters(in: .whitespaces).isEmpty { top -= 1 }
            return top
        }
    }

    /// A row of box-drawing rule, as wide as the terminal, possibly with a
    /// session name set into it ("─── Real ─").
    static func isRule(_ row: String) -> Bool {
        guard row.unicodeScalars.first == "─" || row.unicodeScalars.dropFirst().first == "─" else { return false }
        let rules = row.filter { $0 == "─" }.count
        return rules >= 20 && rules * 10 >= row.count * 9 - 40
    }

    /// The rows of agy's input box (cli-facts.md, agy 1.5.17, "Screens"):
    /// between two rules of the same length, the second with at most the
    /// footer under it, the first row starting with ">". Each prompt's echo
    /// above is a rule too, of 60 cells, then "> " and the prompt, so the
    /// box's top rule must match its bottom one, which spans the terminal;
    /// a question or permission menu has one rule, with its options under
    /// it. Nil when no such box is on screen.
    static func antigravityBox(_ rows: [String]) -> Range<Int>? {
        guard let bottom = rows.lastIndex(where: isAntigravityRule),
              rows[(bottom + 1)...].filter({ !$0.isEmpty }).count <= 1,
              let top = rows[..<bottom].lastIndex(where: { isAntigravityRule($0) && $0.count == rows[bottom].count }),
              top + 1 < bottom, rows[top + 1].hasPrefix(">")
        else { return nil }
        return (top + 1)..<bottom
    }

    /// A row of agy's rule: nothing but "─".
    private static func isAntigravityRule(_ row: String) -> Bool {
        row.count >= 20 && row.allSatisfy { $0 == "─" }
    }

    /// The file that keeps an agent's last screen when its CLI ends, and at
    /// quit: what its tile and its terminal area show while it does not run.
    static func savedScreenURL(_ id: UUID, _ statusDir: URL) -> URL {
        statusDir.appendingPathComponent("\(id.uuidString).screen.txt")
    }
}

/// The terminal's font, at 11 pt, and its line pitch scaled as the terminal
/// spaces its rows (native-look.md 2.4): what a tile's screen draws its text
/// in. Read from the first live surface; SF Mono 11/17 until one exists.
struct AgentTerminalFont: Equatable {
    var font: NSFont
    var pitch: CGFloat

    static let fallback = AgentTerminalFont(font: .monospacedSystemFont(ofSize: 11, weight: .regular), pitch: 17)

    /// The font of `surface` at 11 pt, its pitch from the surface's cell
    /// height.
    @MainActor
    static func of(_ surface: Ghostty.SurfaceView) -> AgentTerminalFont? {
        guard let cSurface = surface.surface, let raw = ghostty_surface_quicklook_font(cSurface) else { return nil }
        // A copy of the surface's CTFont, released as SurfaceView releases it.
        let unmanaged = Unmanaged<CTFont>.fromOpaque(raw)
        let terminalFont = unmanaged.takeUnretainedValue()
        defer { unmanaged.release() }
        let size = CTFontGetSize(terminalFont)
        let scale = surface.window?.backingScaleFactor ?? AgentMetrics.scale
        let cell = CGFloat(ghostty_surface_size(cSurface).cell_height_px) / scale
        guard size > 0, cell > 0 else { return nil }
        let small = CTFontCreateCopyWithAttributes(terminalFont, 11, nil, nil) as NSFont
        return AgentTerminalFont(font: small, pitch: 11 * cell / size)
    }
}
