import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

/// The keyboard (`docs/clawddy-design/shortcuts.md`): the chord table
/// (`AgentChords`) checked against the document and against the keys that
/// type or edit text, and the Agent menu built from it.
@MainActor
struct AgentCommandTests {
    /// Records the commands the menu sends.
    private final class Recorder: NSObject {
        var performed: [AgentCommand] = []
        @objc func record(_ item: NSMenuItem) {
            if let command = item.representedObject as? AgentCommand { performed.append(command) }
        }
    }

    private let recorder = Recorder()
    private let menu: NSMenu

    init() {
        menu = AgentCommand.menu(target: recorder, action: #selector(Recorder.record(_:)))
    }

    /// A key press as AppKit makes it from the hardware: the key code and
    /// the modifiers, with the characters from the keyboard layout. It is
    /// never posted.
    static func key(_ code: CGKeyCode, _ modifiers: CGEventFlags = []) throws -> NSEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
        event.flags = modifiers
        return try #require(NSEvent(cgEvent: event))
    }

    private static func command(_ code: CGKeyCode, _ modifiers: CGEventFlags, in context: AgentKeyContext) throws -> AgentCommand? {
        let chord = try #require(AgentChord(event: try key(code, modifiers)), "key \(code)")
        return AgentChords.command(for: chord, in: context)
    }

    private static let cmd = CGEventFlags.maskCommand
    private static let shiftCmd: CGEventFlags = [.maskCommand, .maskShift]
    private static let arrow: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]

    @Test func theMenuHasEveryCommandInItsGroups() {
        // words.md "Agent menu", in its order; the controller adds the CLI
        // and notification settings after these.
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        #expect(titles == [
            "Show agents", "—",
            "New agent", "New Claude Code agent", "New Codex agent", "Add a project folder…", "—",
            "Smaller tiles", "Larger tiles", "Default tile size", "—",
            "Find or run a command…", "Move earlier", "Move later", "Next waiting agent", "Back to all agents",
            "Previous agent", "Next agent", "Previous project", "Next project", "Open agent", "—",
            "Settle", "Mark as unread", "Rename", "Select every working agent here", "—",
            "Remove project",
        ])
        let places = menu.items.first { $0.title == "Open agent" }?.submenu?.items ?? []
        #expect(places.map { $0.representedObject as? AgentCommand } == (1...9).map { .agentAt($0) })
        #expect(places.map(\.keyEquivalent) == (1...9).map { "\($0)" })
        let move = menu.items.filter { $0.title.hasPrefix("Move ") }
        #expect(move.allSatisfy { $0.keyEquivalentModifierMask == .option })
        #expect(menu.items.first { $0.title == "Rename" }?.keyEquivalent == "")
    }

    /// The menu shows each command's chord from the table, and only those.
    @Test func theMenuShowsTheTablesChords() throws {
        let shown = menu.items.compactMap { item -> String? in
            guard let command = item.representedObject as? AgentCommand, !item.keyEquivalent.isEmpty,
                  item.keyEquivalentModifierMask.contains(.command)
            else { return nil }
            return "\(command.title) \(AgentChord(.character(item.keyEquivalent), item.keyEquivalentModifierMask))"
        }
        #expect(shown == [
            "New agent ⌘N", "Add a project folder… ⌘O", "Smaller tiles ⌘-", "Larger tiles ⌘=", "Default tile size ⌘0",
            "Find or run a command… ⌘P", "Next waiting agent ⌘J",
            "Back to all agents ⌘\u{1B}", "Previous agent ⌘[", "Next agent ⌘]",
            "Previous project ⇧⌘[", "Next project ⇧⌘]", "Settle ⌘D", "Mark as unread ⌘U",
        ])
    }

    /// Every chord of `shortcuts.md`'s table, as the keyboard makes it, names
    /// its command exactly where the document says it acts.
    @Test func everyChordOfTheDocumentIsInTheTable() throws {
        let home: Set<AgentKeyContext> = [.homeTiles, .homeLine]
        let homeAndInside = home.union([.inside])
        // swiftlint:disable:next large_tuple
        var expected: [(CGKeyCode, CGEventFlags, AgentCommand, Set<AgentKeyContext>)] = [
            (38, Self.cmd, .nextWaiting, homeAndInside),
            (33, Self.cmd, .previousAgent, [.inside]),
            (30, Self.cmd, .nextAgent, [.inside]),
            (33, Self.shiftCmd, .previousProject, homeAndInside),
            (30, Self.shiftCmd, .nextProject, homeAndInside),
            (45, Self.cmd, .newAgent, homeAndInside),
            (35, Self.cmd, .findAgent, homeAndInside.union([.palette])),
            (53, Self.cmd, .backToAllAgents, [.inside]),
            (6, Self.cmd, .undo, homeAndInside.union([.palette])),
            (2, Self.cmd, .settle, homeAndInside),
            (32, Self.cmd, .markUnread, homeAndInside),
            (31, Self.cmd, .addProject, homeAndInside),
            (27, Self.cmd, .smallerTiles, home),
            (24, Self.cmd, .largerTiles, home),
            (24, Self.shiftCmd, .largerTiles, home),
            (29, Self.cmd, .defaultTiles, home),
            (44, Self.shiftCmd, .keys, homeAndInside),
            (0, Self.cmd, .selectAll, [.homeTiles]),
            (8, Self.cmd, .copy, [.homeTiles]),
            (36, Self.cmd, .interruptAndSend, [.homeLine]),
            (36, Self.cmd, .startFromFind, [.palette]),
            // Ghostty's full screen never fires in the agent window.
            (36, Self.cmd, .nothing, [.homeTiles, .inside, .textField]),
            // The inside-only keys do nothing at home; F2 types nothing in
            // the line; ⌘P does nothing in a name field.
            (33, Self.cmd, .nothing, home),
            (30, Self.cmd, .nothing, home),
            (53, Self.cmd, .nothing, home),
            (120, [], .nothing, [.homeLine]),
            (35, Self.cmd, .nothing, [.textField]),
            (13, Self.cmd, .closeWindow, homeAndInside.union([.palette, .textField])),
            (13, Self.shiftCmd, .closeWindow, homeAndInside.union([.palette, .textField])),
            (120, [], .rename, [.homeTiles]),
            // Ghostty's tab and split keys, which do nothing here.
            (17, Self.cmd, .nothing, homeAndInside),
            (2, Self.shiftCmd, .nothing, homeAndInside),
            (35, Self.shiftCmd, .nothing, homeAndInside),
            (36, Self.shiftCmd, .nothing, homeAndInside),
            (13, [.maskCommand, .maskAlternate], .nothing, homeAndInside),
            (24, [.maskCommand, .maskControl], .nothing, homeAndInside),
        ]
        for (place, code) in zip(1...9, [18, 19, 20, 21, 23, 22, 26, 28, 25] as [CGKeyCode]) {
            expected.append((code, Self.cmd, .agentAt(place), homeAndInside))
        }
        for code: CGKeyCode in [123, 124, 125, 126] {
            expected.append((code, Self.arrow.union([.maskCommand, .maskAlternate]), .nothing, homeAndInside))
            expected.append((code, Self.arrow.union([.maskCommand, .maskControl]), .nothing, homeAndInside))
        }
        // While the palette or a text field has the keys, every chord but
        // these does nothing (claimed, so no Ghostty menu item opens a
        // terminal window or tab); these are the field's or the palette's own.
        let ownInFields: Set<AgentCommand> = [.findAgent, .closeWindow, .undo, .selectAll, .copy, .interruptAndSend, .startFromFind]
        var wanted: [AgentChord: [AgentKeyContext: AgentCommand]] = [:]
        for (code, modifiers, command, contexts) in expected {
            let chord = try #require(AgentChord(event: try Self.key(code, modifiers)))
            for context in contexts { wanted[chord, default: [:]][context] = command }
        }
        for (code, modifiers, command, _) in expected where !ownInFields.contains(command) {
            let chord = try #require(AgentChord(event: try Self.key(code, modifiers)))
            for context in [AgentKeyContext.palette, .textField] where wanted[chord]?[context] == nil {
                wanted[chord, default: [:]][context] = .nothing
            }
        }
        // Exactly these, and nothing else: every chord the table has, but
        // Ghostty's keys the document does not name (`AgentFinalReviewTests`).
        let ghostty = Set(AgentChords.ghosttyTerminalKeys + AgentChords.ghosttyWindowKeys)
        let chords = Set(wanted.keys).union(AgentChords.table.flatMap(\.chords)).subtracting(ghostty)
        for chord in chords {
            for context in AgentKeyContext.allCases {
                #expect(AgentChords.command(for: chord, in: context) == wanted[chord]?[context], "\(chord) in \(context)")
            }
        }
    }

    /// No chord types or edits text in a terminal: each of these keys is no
    /// command inside, and those that edit text anywhere, or are the
    /// system's, are no command anywhere.
    @Test func noChordTypesOrEditsText() throws {
        // Ghostty's terminal chords (⌘K, ⌘V, ⌘F, the ⌘ arrows…) do nothing
        // at home and in fields: `AgentFinalReviewTests`.
        let editing: [(CGKeyCode, CGEventFlags)] = [
            (51, Self.cmd),
            (115, Self.cmd), (119, Self.cmd), (116, Self.cmd), (121, Self.cmd),
            (123, Self.arrow.union(.maskAlternate)), (124, Self.arrow.union(.maskAlternate)),
            (126, Self.arrow.union(.maskAlternate)), (125, Self.arrow.union(.maskAlternate)),
            (123, Self.arrow), (126, Self.arrow), (53, []), (36, []), (48, []), (48, .maskShift), (51, []),
            (8, .maskControl), (2, .maskControl), (32, .maskControl), (15, .maskControl), (35, .maskAlternate),
            (0, []), (6, []),
        ]
        let system: [(CGKeyCode, CGEventFlags)] = [
            (48, Self.cmd), (50, Self.cmd), (12, Self.cmd), (4, Self.cmd), (4, [.maskCommand, .maskAlternate]),
            (46, Self.cmd), (49, Self.cmd), (43, Self.cmd),
        ]
        for (code, modifiers) in editing + system {
            for context in AgentKeyContext.allCases {
                guard let chord = AgentChord(event: try Self.key(code, modifiers)) else { continue }
                #expect(AgentChords.command(for: chord, in: context) == nil, "key \(code) \(modifiers) in \(context)")
            }
        }
        // Copy, select all and the font sizes are the terminal's inside it,
        // as in Ghostty.
        for (code, modifiers) in [(8, Self.cmd), (0, Self.cmd), (27, Self.cmd), (24, Self.cmd), (29, Self.cmd)] as [(CGKeyCode, CGEventFlags)] {
            #expect(try Self.command(code, modifiers, in: .inside) == nil, "key \(code)")
        }
        // In a text field the app's chords only do nothing, or close the window.
        for entry in AgentChords.table where entry.contexts.contains(.textField) {
            #expect([.nothing, .closeWindow].contains(entry.command), "\(entry.command)")
        }
    }

    /// Inside a terminal every key without ⌘ is the terminal's; and a chord
    /// names one command in each context.
    @Test func everyChordInsideHasCommandAndNamesOneCommand() {
        for entry in AgentChords.table where entry.contexts.contains(.inside) {
            for chord in entry.chords {
                #expect(chord.modifiers.contains(.command), "\(chord)")
            }
        }
        for context in AgentKeyContext.allCases {
            let chords = AgentChords.table.filter { $0.contexts.contains(context) }.flatMap(\.chords)
            #expect(Set(chords).count == chords.count, "\(context)")
        }
    }

    /// Return is never a key equivalent of the window's views: with or
    /// without a terminal shown, it reaches the first responder.
    @Test func noViewClaimsReturn() async throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        h.providers.prepareLaunch = { _ in .failure(.executableMissing(.claudeCode)) }
        let id = try h.addAgent("agent")
        h.start()
        try h.activate(id)
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let terminals = AgentTerminalsController(ghostty: ghostty, bridge: h.bridge)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = terminals
        defer { window.close() }
        let agent = try h.agent(id)
        let returnKey = try Self.key(36)
        func settle() async throws {
            window.layoutIfNeeded()
            for _ in 0..<3 { try await Task.sleep(for: .milliseconds(50)) }
            window.layoutIfNeeded()
        }

        terminals.show(id)
        try await settle()
        #expect(!window.performKeyEquivalent(with: returnKey))

        var terminal = Ghostty.SurfaceConfiguration()
        terminal.command = "/bin/cat"
        #expect(terminals.showOrSwitch(agent: agent, focusTerminal: false, createConfig: { terminal }))
        defer { terminals.removeSurface(id: id) }
        try await settle()
        #expect(!window.performKeyEquivalent(with: returnKey))
    }
}
