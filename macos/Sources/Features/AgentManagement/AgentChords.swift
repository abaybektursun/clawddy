import AppKit

/// Where the keyboard is in the agent window, as far as the app's chords go
/// (`docs/clawddy-design/shortcuts.md`, the columns of "The keys").
enum AgentKeyContext: Hashable, CaseIterable {
    /// Home, the tiles have the keys (S6).
    case homeTiles
    /// Home, the typing line has the keys (S7).
    case homeLine
    /// Inside an agent: its terminal, or the window where it has none.
    case inside
    /// The palette (find) has the keys.
    case palette
    /// A name is being edited, or any other text field has the keys: its
    /// ⌘ chords are text editing only; the app's chords do nothing.
    case textField
}

/// One key with its modifiers, as the table names it: a character as the
/// keyboard layout types it without modifiers, or a key that types none.
struct AgentChord: Hashable, CustomStringConvertible {
    enum Key: Hashable {
        case character(String)
        case escape, returnKey, f2, left, right, up, down
    }

    let key: Key
    /// Only ⌘, ⇧, ⌥ and ⌃ count.
    let modifiers: NSEvent.ModifierFlags

    static let counted: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    init(_ key: Key, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers.intersection(Self.counted)
    }

    /// ⌘ and a character.
    static func command(_ character: String, _ more: NSEvent.ModifierFlags = []) -> AgentChord {
        AgentChord(.character(character), more.union(.command))
    }

    private static let keys: [UInt16: Key] = [
        53: .escape, 36: .returnKey, 76: .returnKey, 120: .f2,
        123: .left, 124: .right, 125: .down, 126: .up,
    ]

    /// The chord a key-down event is, or nil for a key the table cannot
    /// name (another function key, Tab, Delete…).
    init?(event: NSEvent) {
        if let key = Self.keys[event.keyCode] {
            self.init(key, event.modifierFlags)
            return
        }
        // Keys with no character of their own (Tab, Delete, F-keys, Home…).
        guard ![48, 51, 117, 115, 119, 116, 121].contains(event.keyCode),
              !(event.charactersIgnoringModifiers ?? "").unicodeScalars.contains(where: { $0.value >= 0xF700 && $0.value <= 0xF8FF }),
              let characters = event.characters(byApplyingModifiers: []), !characters.isEmpty
        else { return nil }
        self.init(.character(characters.lowercased()), event.modifierFlags)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    /// For a menu item: its key equivalent and modifier mask.
    var menuKey: (equivalent: String, modifiers: NSEvent.ModifierFlags) {
        let equivalent: String = switch key {
        case .character(let character): character
        case .escape: "\u{1b}"
        case .returnKey: "\r"
        case .f2: String(Character(UnicodeScalar(NSF2FunctionKey)!))
        case .left: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case .right: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case .up: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case .down: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        }
        return (equivalent, modifiers)
    }

    var description: String {
        let marks: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let prefix = marks.filter { modifiers.contains($0.0) }.map(\.1).joined()
        let name: String = switch key {
        case .character(let character): character.uppercased()
        case .escape: "⎋"
        case .returnKey: "↩"
        case .f2: "F2"
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        }
        return prefix + name
    }
}

/// The one authority on the app's keys in the agent window: a pure table
/// from chord and context to command, `docs/clawddy-design/shortcuts.md`
/// written as data.
///
/// `AgentWorkspaceWindow.performKeyEquivalent` consults it before any view,
/// the focused terminal included, and before the main menu
/// (`ClawddyController.performChord`). A chord the table names for the
/// current context, whose command has an action, is claimed there: it never
/// reaches the terminal, Ghostty's binding for it or Ghostty's menu item.
/// Every other key goes on exactly as in Ghostty. A command whose action a
/// later stage has not built yet (`ClawddyController.action(for:in:)` gives
/// nil) claims nothing.
///
/// A chord whose command is `.nothing` is claimed and does nothing: Ghostty's
/// tab and split keys, and the app's chords where the palette or a text field
/// has the keys.
///
/// Rules the table keeps (and `AgentCommandTests` checks):
/// - every chord inside a terminal has ⌘: every key without ⌘ is the
///   terminal's;
/// - no chord types or edits text in a terminal or a text field (⌘⌫, ⌘K,
///   ⌘←, ⌘→, ⌘↑, ⌘↓, ⌘C, ⌘V, ⌘A inside, ⌥ arrows…), and no system chord;
/// - one command per chord in each context.
enum AgentChords {
    struct Entry {
        let command: AgentCommand
        let chords: [AgentChord]
        let contexts: Set<AgentKeyContext>
    }

    private static let home: Set<AgentKeyContext> = [.homeTiles, .homeLine]
    private static let homeAndInside: Set<AgentKeyContext> = [.homeTiles, .homeLine, .inside]

    /// Ghostty's tab, split and palette keys, which do nothing in the agent
    /// window, since it has none of them.
    private static let ghosttyTabAndSplitKeys: [AgentChord] = [
        .command("t"), .command("d", .shift), .command("p", .shift),
        AgentChord(.returnKey, [.command, .shift]), .command("w", .option), .command("=", .control),
    ] + [AgentChord.Key.left, .right, .up, .down].flatMap { arrow in
        [AgentChord(arrow, [.command, .option]), AgentChord(arrow, [.command, .control])]
    }

    /// Ghostty's default ⌘ chords that type, scroll or search in a terminal
    /// (shortcuts.md rule 2 and "What each chord does"): the terminal's
    /// inside it; nothing at home; a field's own text editing where it has
    /// one (`fieldEditingKeys`), else nothing (final review ruling 13).
    static let ghosttyTerminalKeys: [AgentChord] = [
        .command("k"), .command("v"), .command("v", .shift), .command("f"), .command("e"), .command("f", .shift),
        .command("g"), .command("g", .shift), .command("j", .shift),
    ] + [AgentChord.Key.left, .right, .up, .down].map { AgentChord($0, .command) }
        + [AgentChord(.up, [.command, .shift]), AgentChord(.down, [.command, .shift])]

    /// Ghostty's other default ⌘ chords that shortcuts.md does not name,
    /// which the agent window has no use for: redo and reopening a closed
    /// tab, closing every window, two forms of writing the screen to a file,
    /// moving between and resizing splits, the inspector. They do nothing
    /// anywhere in it (final review ruling 13). (⌘Q, ⌘, and ⇧⌘, are the
    /// app's own and ⌃⌘F the system's full screen: never taken.)
    static let ghosttyWindowKeys: [AgentChord] = [
        .command("z", .shift), .command("t", .shift), .command("w", [.shift, .option]),
        .command("j", [.shift, .control]), .command("j", [.shift, .option]),
        .command("[", .control), .command("]", .control), .command("i", .option),
    ] + [AgentChord.Key.left, .right, .up, .down].map { AgentChord($0, [.command, .control, .shift]) }

    /// What a text field edits with: its own, wherever a field has the keys.
    static let fieldEditingKeys = Set([.command("v"), .command("z", .shift)]
        + [AgentChord.Key.left, .right, .up, .down].flatMap { [AgentChord($0, .command), AgentChord($0, [.command, .shift])] })

    /// While the palette or a text field has the keys, the app's other
    /// chords do nothing (`shortcuts.md`, "Palette open" and "Name being
    /// edited"), and neither do Ghostty's keys for the same chords, whose menu
    /// items would otherwise open a terminal window or tab.
    private static let doNothingInFields: [AgentChord] = [
        .command("j"), .command("["), .command("]"), .command("[", .shift), .command("]", .shift),
    ] + (1...9).map { AgentChord.command("\($0)") } + [
        .command("n"), AgentChord(.escape, .command), .command("d"), .command("u"), .command("o"),
        .command("-"), .command("="), .command("=", .shift), .command("0"), .command("/", .shift),
        AgentChord(.f2, []),
    ] + ghosttyTabAndSplitKeys

    /// Chords of the table that, in a context, deliberately go on past the
    /// app: inside a terminal Ghostty's select all, copy and font sizes, and
    /// F2 to the terminal (shortcuts.md rule 1); in a field its own text
    /// editing. Every other listed chord has an outcome in every context
    /// (`AgentCommandTests`), so no key reaches a Ghostty binding by
    /// omission.
    static let passesOn: [AgentKeyContext: Set<AgentChord>] = [
        .inside: Set(ghosttyTerminalKeys + [.command("a"), .command("c"), .command("-"), .command("="), .command("=", .shift),
                                            .command("0"), AgentChord(.f2, [])]),
        .homeLine: fieldEditingKeys.union([.command("a"), .command("c")]),
        .palette: fieldEditingKeys.union([.command("a"), .command("c")]),
        .textField: fieldEditingKeys.union([.command("a"), .command("c"), .command("z")]),
    ]

    static let table: [Entry] = [
        Entry(command: .nextWaiting, chords: [.command("j")], contexts: homeAndInside),
        Entry(command: .previousAgent, chords: [.command("[")], contexts: [.inside]),
        Entry(command: .nextAgent, chords: [.command("]")], contexts: [.inside]),
        Entry(command: .previousProject, chords: [.command("[", .shift)], contexts: homeAndInside),
        Entry(command: .nextProject, chords: [.command("]", .shift)], contexts: homeAndInside),
    ] + (1...9).map { place in
        Entry(command: .agentAt(place), chords: [.command("\(place)")], contexts: homeAndInside)
    } + [
        Entry(command: .newAgent, chords: [.command("n")], contexts: homeAndInside),
        Entry(command: .findAgent, chords: [.command("p")], contexts: homeAndInside.union([.palette])),
        Entry(command: .backToAllAgents, chords: [AgentChord(.escape, .command)], contexts: [.inside]),
        Entry(command: .undo, chords: [.command("z")], contexts: homeAndInside.union([.palette])),
        Entry(command: .settle, chords: [.command("d")], contexts: homeAndInside),
        Entry(command: .markUnread, chords: [.command("u")], contexts: homeAndInside),
        Entry(command: .addProject, chords: [.command("o")], contexts: homeAndInside),
        Entry(command: .smallerTiles, chords: [.command("-")], contexts: home),
        Entry(command: .largerTiles, chords: [.command("="), .command("=", .shift)], contexts: home),
        Entry(command: .defaultTiles, chords: [.command("0")], contexts: home),
        Entry(command: .keys, chords: [.command("/", .shift)], contexts: homeAndInside),
        Entry(command: .selectAll, chords: [.command("a")], contexts: [.homeTiles]),
        Entry(command: .copy, chords: [.command("c")], contexts: [.homeTiles]),
        Entry(command: .interruptAndSend, chords: [AgentChord(.returnKey, .command)], contexts: [.homeLine]),
        Entry(command: .closeWindow, chords: [.command("w"), .command("w", .shift)],
              contexts: homeAndInside.union([.palette, .textField])),
        Entry(command: .rename, chords: [AgentChord(.f2, [])], contexts: [.homeTiles]),
        Entry(command: .startFromFind, chords: [AgentChord(.returnKey, .command)], contexts: [.palette]),
        Entry(command: .nothing, chords: ghosttyTabAndSplitKeys, contexts: homeAndInside),
        // At home the inside-only keys do nothing (shortcuts.md, "Nothing").
        Entry(command: .nothing, chords: [.command("["), .command("]"), AgentChord(.escape, .command)], contexts: home),
        // ⌘↩ is Ghostty's full screen: never in the agent window (S7 review
        // ruling 3); F2 types nothing in the line.
        Entry(command: .nothing, chords: [AgentChord(.returnKey, .command)], contexts: [.homeTiles, .inside, .textField]),
        Entry(command: .nothing, chords: [AgentChord(.f2, [])], contexts: [.homeLine]),
        Entry(command: .nothing, chords: [.command("p")], contexts: [.textField]),
        Entry(command: .nothing, chords: doNothingInFields, contexts: [.palette, .textField]),
        // Ghostty's keys shortcuts.md does not name (final review ruling 13).
        Entry(command: .nothing, chords: ghosttyWindowKeys.filter { !fieldEditingKeys.contains($0) }, contexts: AgentChords.everywhere),
        Entry(command: .nothing, chords: [.command("z", .shift)], contexts: [.homeTiles, .inside]),
        Entry(command: .nothing, chords: ghosttyTerminalKeys, contexts: [.homeTiles]),
        Entry(command: .nothing, chords: ghosttyTerminalKeys.filter { !fieldEditingKeys.contains($0) },
              contexts: [.homeLine, .palette, .textField]),
    ]

    private static let everywhere = Set(AgentKeyContext.allCases)

    /// The command `chord` names in `context`, if any.
    static func command(for chord: AgentChord, in context: AgentKeyContext) -> AgentCommand? {
        table.first { $0.contexts.contains(context) && $0.chords.contains(chord) }?.command
    }

    /// The chord the menu shows for `command`: its first.
    /// (`.nothing` is on no menu.)
    static func chord(for command: AgentCommand) -> AgentChord? {
        table.first { $0.command == command }?.chords.first
    }

    /// Where `command` has a chord.
    static func contexts(of command: AgentCommand) -> Set<AgentKeyContext> {
        table.filter { $0.command == command }.reduce(into: []) { $0.formUnion($1.contexts) }
    }
}
