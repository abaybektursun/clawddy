import Foundation

/// What an asynchronous launch is still allowed to do when it finishes.
/// Activation authorized preparation, but selection can move while it runs, so
/// completion re-derives its authority from the pane the detail controller
/// presents now. A newer selection must never be replaced, attached over, or
/// focused by an older launch.
struct AgentLaunchPresentation: Equatable, Sendable {
    /// The prepared pane is still the selected pane and must be attached.
    var presentsPane: Bool
    /// AppKit keyboard focus may move into the prepared pane.
    var focusesTerminal: Bool
}

enum AgentLaunchPresentationPolicy {
    /// Focus is subordinate to presentation: a pane that is not attached must
    /// not take first responder. Focus also requires a window that can show
    /// the pane; making a view first responder inside an invisible or
    /// minimized window would leave the activation intent stranded there
    /// instead of waiting for the next key transition. Another view keeps the
    /// keys while it has them, as the sidebar when the arrow keys chose the
    /// agent; the caller reads that from the window's real first responder.
    static func decide(
        agentID: UUID,
        selectedAgentID: UUID?,
        anotherViewHasKeys: Bool,
        windowIsVisible: Bool,
        windowIsMiniaturized: Bool
    ) -> AgentLaunchPresentation {
        let stillSelected = selectedAgentID == agentID
        return AgentLaunchPresentation(
            presentsPane: stillSelected,
            focusesTerminal: stillSelected && !anotherViewHasKeys && windowIsVisible && !windowIsMiniaturized)
    }
}

/// Everything that must still agree before an agent counts as read
/// (`docs/clawddy-design/flows.md` 3.3): the person entered it, it is the
/// selection and the pane presents it (its terminal, or its saved lines when
/// its CLI is not running), in a window that is key, visible, not covered and
/// not minimized, with the app active and the session unlocked. Anything less
/// stays unread.
struct AgentViewingContext: Equatable, Sendable {
    /// The user explicitly activated or inspected this agent: the
    /// workspace model's `viewedAgentID`.
    var explicitAgentID: UUID?
    /// The committed workspace selection.
    var selectedAgentID: UUID?
    /// The agent the detail pane currently displays, its terminal or its
    /// saved lines.
    var presentedAgentID: UUID?
    /// The app is active and the session unlocked.
    var personCanSee: Bool
    /// The window is on screen and not covered (`occlusionState` visible).
    var windowIsVisible: Bool
    var windowIsKey: Bool
    var windowIsMiniaturized: Bool
}

enum AgentViewingPolicy {
    static func viewedAgentID(in context: AgentViewingContext) -> UUID? {
        guard let explicitAgentID = context.explicitAgentID,
              explicitAgentID == context.selectedAgentID,
              explicitAgentID == context.presentedAgentID,
              context.personCanSee,
              context.windowIsVisible,
              context.windowIsKey,
              !context.windowIsMiniaturized
        else { return nil }
        return explicitAgentID
    }
}

/// What quitting says about agents (`docs/clawddy-design/flows.md` 11).
/// Their terminals are not terminal windows, so Ghostty's own quit
/// confirmation does not count them.
enum AgentQuitConfirmation {
    /// Every quit confirmation's title, Ghostty's for terminal windows too.
    static let title = "Quit Clawddy?"

    /// What quitting does to the `working` agents and those waiting their
    /// turn to start (words.md): the working ones stop and continue by
    /// themselves at the next start; the waiting ones do not start. Nil when
    /// there are none, and then the agents need no confirmation: the others
    /// come back as they were.
    static func notice(working: Int, waitingToStart: Int = 0) -> String? {
        let work: String? = switch working {
        case ...0: nil
        case 1: "1 agent is working. It stops now and continues by itself when Clawddy opens again."
        default: "\(working) agents are working. They stop now and continue by themselves when Clawddy opens again."
        }
        let wait: String? = switch waitingToStart {
        case ...0: nil
        case 1: "1 agent waiting its turn to start does not start."
        default: "\(waitingToStart) agents waiting their turn to start do not start."
        }
        let both = [work, wait].compactMap { $0 }
        return both.isEmpty ? nil : both.joined(separator: " ")
    }
}

/// What closing a running agent's terminal asks (design plan section 7):
/// what will happen.
struct AgentCloseConfirmation: Equatable {
    let title: String
    let message: String
    /// The button that agrees; Cancel is the other.
    static let confirm = "Close"

    init(name: String) {
        title = "Close \(name)?"
        message = "\(name) is running. Closing stops it; it continues when you come back to it."
    }
}

/// The name a provider's terminal title gives a conversation
/// (`docs/clawddy-design/flows.md` 5; `cli-facts.md`, flows 2 capture).
/// Claude titles its terminal "Claude Code" until the first prompt, then
/// with a few words about the conversation, which it keeps, and shows
/// "claude · resume" over its list of conversations; before the terminal
/// answers its status query it puts a status glyph first ("✳ Single word
/// reply"), and clears it as it exits, when Ghostty shows the working
/// directory instead. Codex titles it with the folder, a spinner first while
/// it works, then "<topic> | <folder>".
enum AgentConversationTitle {
    /// The longest name a title gives.
    static let maxLength = 40

    /// The conversation's name in `title`, from a terminal in `folder`:
    /// without leading glyphs and spinners, the product's own titles, a path
    /// and the folder, at most `maxLength` characters; nil when nothing is
    /// left.
    static func name(from title: String, folder: String?) -> String? {
        let trimmed = AgentSentence.label(title, limit: 200)
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        var text = String(trimmed.drop { !$0.isLetter && !$0.isNumber })
            .trimmingCharacters(in: .whitespaces)
        if let folder = folder.map({ URL(fileURLWithPath: $0).lastPathComponent }), !folder.isEmpty {
            if text == folder { return nil }
            if text.hasSuffix(" | \(folder)") { text = String(text.dropLast(folder.count + 3)) }
        }
        let lowered = text.lowercased()
        guard !text.isEmpty, lowered != "claude code", !lowered.hasPrefix("claude · ") else { return nil }
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// How a new agent runs: the saved defaults for its CLI.
struct AgentCreationDraft: Equatable, Sendable {
    var provider: AgentProviderID
    var modelID = ""
    var reasoningEffort: String?
    var startMode: AgentStartMode

    /// The saved defaults: `provider`, its default start mode, and its own
    /// default model and reasoning.
    init(provider: AgentProviderID, preferences: AgentPreferences) {
        self.provider = provider
        startMode = preferences.defaultStartMode(for: provider)
    }

    var launchProfile: AgentLaunchProfile {
        let normalizedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentLaunchProfile(
            modelID: normalizedModel.isEmpty ? nil : normalizedModel,
            reasoningEffort: reasoningEffort,
            startMode: startMode)
    }
}

/// Names that stay apart within a project.
enum AgentNames {
    /// `name`, or, when one of `agents` has it, ignoring case, `name` with
    /// the lowest number from 2 that none has: "review 2".
    static func free(_ name: String, among agents: [AgentEntry]) -> String {
        func isTaken(_ candidate: String) -> Bool {
            agents.contains { $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame }
        }
        guard isTaken(name) else { return name }
        var number = 2
        while isTaken("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }
}

@MainActor
enum AgentWorkspaceTransactions {
    /// Gives an agent whose name is Clawddy's the name `title` from its
    /// conversation, numbered when another agent of its project has it
    /// ("Fix login 2"), saved as a rename is; whose name it is stays the same.
    static func adoptTitle(_ title: String, of id: UUID, config: AgentConfig, bridge: AgentBridge) {
        guard let project = config.project(forAgent: id) else { return }
        let name = AgentNames.free(title, among: project.agents.filter { $0.id != id })
        guard config.renameAgent(id: id, newName: name) else { return }
        bridge.showName(id: id, name: name, source: .cli)
    }
}

/// The order in which the agents waiting on the person are walked
/// (`docs/clawddy-design/flows.md` 6.6): the current project's first, then
/// the other projects' in the bar's order; within a project questions, then
/// problems, then finished unread and reset limits; within those, the
/// longest waiting first. The menu bar item lists them in the same order.
@MainActor
/// What orders an agent among those waiting on the person (flows.md 6.6):
/// a question first, then a problem, then the rest, each oldest first.
struct AgentWaitingKey: Equatable, Comparable {
    var rank: Int
    var since: Date

    /// Its key while it waits on the person; nil otherwise.
    init?(_ record: AgentRecord) {
        guard record.isWaitingOnYou else { return nil }
        rank = switch record.state {
        case .asks: 0
        case .problem: 1
        case .finished, .limitReset, .working, .paused: 2
        }
        since = record.changedAt
    }

    static func < (a: Self, b: Self) -> Bool {
        a.rank != b.rank ? a.rank < b.rank : a.since < b.since
    }
}

@MainActor
enum AgentWaitingOrder {
    /// Every agent waiting on the person, the current project's first, then
    /// the bar's order, each project's by `AgentWaitingKey`. It reads only
    /// what transitions change, so an observer of it is not woken by
    /// activity.
    static func agents(projects: [AgentProject], agents: [UUID: AgentInstance], currentProject: UUID?) -> [AgentWalk.Waiting] {
        let ordered = projects.filter { $0.id == currentProject } + projects.filter { $0.id != currentProject }
        return ordered.flatMap { project in
            project.agents.compactMap { entry in agents[entry.id].flatMap { agent in agent.waitingKey.map { (agent.id, $0) } } }
                .sorted { $0.1 < $1.1 }
                .map { AgentWalk.Waiting(id: $0.0, since: $0.1.since) }
        }
    }
}

/// The top bar's sentences about the app's own files (words.md).
enum AgentNotices {
    /// A write failed; memory keeps the change (last review ruling 1).
    static let unsaved = "Could not save your changes. Check the disk; they are kept while Clawddy is open."
    /// An older build's `state.json` could not be read and was moved to the
    /// backups (last review ruling 2).
    static let movedStateFile = "The older Clawddy's state file could not be read. It was moved to the backups folder."
}
