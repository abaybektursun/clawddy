import AppKit

/// Clawddy's commands: the Agent menu's, in its order, and those only a
/// chord reaches (`AgentChords`). What each does is
/// `ClawddyController.action(for:in:)`; a command a later stage builds has
/// no action yet. Keys live only in `AgentChords`; the menu shows a
/// command's chord and leaves the key to the window's table.
enum AgentCommand: Hashable {
    /// Brings the agent window back as it was, from anywhere (flows.md
    /// 6.13).
    case showAgents
    case newAgent
    /// A new agent with that CLI, whatever the default: the line (or the
    /// floating new-agent line) set to it until it loses the keys. One per
    /// CLI, in `AgentProviderID.allCases` order (`newAgentWithEachCLI`).
    case newAgentWith(AgentProviderID)
    case addProject
    case nextWaiting
    case previousAgent
    case nextAgent
    case previousProject
    case nextProject
    case findAgent
    /// The selected tiles one place earlier or later (⌥← ⌥→, home only).
    case moveEarlier
    case moveLater
    /// Takes the current project off the bar, its agents settled, with undo
    /// (flows.md 6.2).
    case removeProject
    /// Selects every working agent of the project at home, the line with
    /// the keys (flows.md 6.5).
    case selectWorking
    /// ⌘↩ in find with no match: an agent started with the typed text
    /// (flows.md 6.8).
    case startFromFind
    /// Enters the agent in this row of the project's list, from 1 to 9.
    case agentAt(Int)
    case backToAllAgents
    case undo
    case settle
    case markUnread
    case smallerTiles
    case largerTiles
    case defaultTiles
    case keys
    case selectAll
    case copy
    case interruptAndSend
    case closeWindow
    case rename
    /// A Ghostty tab or split key, which does nothing in the agent window.
    case nothing

    /// The Agent menu's title for the submenu of the first nine places.
    static let openAgentTitle = "Open agent"

    /// "New <CLI> agent" for every CLI.
    static let newAgentWithEachCLI = AgentProviderID.allCases.map(newAgentWith)

    /// The Agent menu's groups (words.md "Agent menu"), with a line between
    /// each; `agentAt` places go in the "Open agent" submenu. The CLI and
    /// notification settings follow, made by the controller.
    static let menuGroups: [[AgentCommand]] = [
        [.showAgents],
        [.newAgent] + newAgentWithEachCLI + [.addProject],
        [.smallerTiles, .largerTiles, .defaultTiles],
        [.findAgent, .moveEarlier, .moveLater, .nextWaiting, .backToAllAgents, .previousAgent, .nextAgent,
         .previousProject, .nextProject] + (1...9).map(agentAt),
        [.settle, .markUnread, .rename, .selectWorking],
        [.removeProject],
    ]

    /// The commands find lists (flows.md 6.8), in its order; each shows only
    /// where it has an action. "Go to <project>" follows, one per project.
    static let paletteCommands: [AgentCommand] = [.newAgent] + newAgentWithEachCLI + [
        .addProject, .settle, .markUnread, .rename, .selectWorking, .removeProject, .smallerTiles, .largerTiles,
        .defaultTiles, .keys,
    ]

    /// The commands that act while the agent window is closed or another
    /// window is main, opening the window first (final review ruling 1).
    static let opensWindow = Set<AgentCommand>(
        [.showAgents, .newAgent, .addProject, .findAgent, .nextWaiting, .keys] + newAgentWithEachCLI)

    /// What find matches the command by: its title, and for "New <CLI>
    /// agent" the CLI's program name too ("agy" finds "New Antigravity
    /// agent").
    var searchText: String {
        switch self {
        case .newAgentWith(let provider): "\(title) \(provider.executableName)"
        default: title
        }
    }

    /// The menu's title; a project's item takes the project's name when
    /// the menu is shown.
    var title: String {
        switch self {
        case .showAgents: "Show agents"
        case .newAgent: "New agent"
        case .newAgentWith(let provider): "New \(provider.displayName) agent"
        case .addProject: "Add a project folder…"
        case .nextWaiting: "Next waiting agent"
        case .previousAgent: "Previous agent"
        case .nextAgent: "Next agent"
        case .previousProject: "Previous project"
        case .nextProject: "Next project"
        case .findAgent: "Find or run a command…"
        case .moveEarlier: "Move earlier"
        case .moveLater: "Move later"
        case .removeProject: "Remove project"
        case .selectWorking: "Select every working agent here"
        case .startFromFind: "Start an agent with this text"
        case .agentAt(let place): "Agent \(place)"
        case .backToAllAgents: "Back to all agents"
        case .undo: "Undo"
        case .settle: "Settle"
        case .markUnread: "Mark as unread"
        case .smallerTiles: "Smaller tiles"
        case .largerTiles: "Larger tiles"
        case .defaultTiles: "Default tile size"
        case .keys: "Keys"
        case .selectAll: "Select every agent here"
        case .copy: "Copy"
        case .interruptAndSend: "Interrupt them and send"
        case .closeWindow: "Close window"
        case .rename: "Rename"
        case .nothing: ""
        }
    }

    /// The Agent menu: one item per command, carrying the command as its
    /// `representedObject`, each sending `action` to `target`, showing its
    /// chord. The item is enabled only where the chord acts
    /// (`ClawddyController.validateMenuItem`), so outside the agent window
    /// the key stays Ghostty's.
    @MainActor static func menu(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Agent")
        let places = NSMenu(title: openAgentTitle)
        for (index, group) in menuGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for command in group {
                let item = NSMenuItem(title: command.title, action: action, keyEquivalent: "")
                if let key = command.menuKey {
                    item.keyEquivalent = key.equivalent
                    item.keyEquivalentModifierMask = key.modifiers
                }
                item.target = target
                item.representedObject = command
                if case .agentAt = command { places.addItem(item) } else { menu.addItem(item) }
            }
            if group.contains(.agentAt(1)) {
                let open = NSMenuItem(title: openAgentTitle, action: nil, keyEquivalent: "")
                open.submenu = places
                menu.addItem(open)
            }
        }
        return menu
    }

    /// The key the Agent menu shows: the command's chord, ⌥← ⌥→ for moving
    /// tiles (the grid's own keys), none for Rename, whose F2 acts only on a
    /// tile (words.md).
    var menuKey: (equivalent: String, modifiers: NSEvent.ModifierFlags)? {
        switch self {
        case .moveEarlier: (String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), .option)
        case .moveLater: (String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), .option)
        case .rename: nil
        default: AgentChords.chord(for: self)?.menuKey
        }
    }
}

/// Keys AppKit's text editing owns.
enum AgentKeyEventRoutingPolicy {
    /// A field editor is an NSTextView temporarily owned by NSWindow, not the
    /// visible NSTextField. These events must stay in AppKit's responder chain
    /// even when a sheet or auxiliary panel temporarily leaves mainWindow nil.
    static func isTextEditingResponder(_ responder: NSResponder?) -> Bool {
        guard let textView = responder as? NSTextView else { return false }
        return textView.isFieldEditor || textView.isEditable
    }
}
