import AppKit
import Observation

/// Where a project was left: at home, or inside one of its agents
/// (`docs/clawddy-design/flows.md` 3.3, 6.10).
enum AgentProjectView: Equatable, Sendable {
    case home
    case inside(UUID)
}

/// A name being edited in place: whose, where, the name it had, and a title
/// its CLI gave meanwhile, which waits (flows.md 4.3).
struct AgentRenaming: Equatable {
    enum Place: Equatable { case tile, row, header }
    let agent: UUID
    let place: Place
    let original: String
    var waitingTitle: String?
}

/// What the agent window shows, kept for the next start: the current
/// project, and for each project whether it was left at home or inside an
/// agent, which switching back to it restores. The controller is its one
/// writer; the window reads it.
@Observable
@MainActor
final class AgentWorkspaceModel {
    static let currentProjectKey = "clawddy.workspace.currentProject"
    static let viewsKey = "clawddy.workspace.views"
    static let newAgentProviderKey = "clawddy.newAgent.provider"
    static let densitiesKey = "clawddy.workspace.densities"
    static let draftsKey = "clawddy.workspace.drafts"

    /// The project the window shows.
    private(set) var currentProjectID: UUID?
    /// Each project's view as it was left.
    private(set) var views: [UUID: AgentProjectView]
    /// The agent the person is looking at: the shown agent once they enter
    /// it, until another is shown or they go home. This is the one record of
    /// viewing; whether a completion counts as seen also takes what
    /// `viewedAgent` checks.
    private(set) var viewedAgentID: UUID?
    /// Each project's selection at home, for this run: none at launch, and
    /// none when switching to a project whose view is home (ruling 2).
    private(set) var selections: [UUID: AgentTileSelection] = [:]
    /// Each project's density: rows more or fewer than the default, kept for
    /// the next start, so a window resize recomputes the default and keeps
    /// the choice.
    private(set) var densities: [UUID: Int]
    /// Each project's draft in the line (flows.md "The line", ruling 12):
    /// kept across project switches, entering terminals and quitting; only
    /// sending empties it.
    @ObservationIgnored private(set) var drafts: [UUID: String]
    /// The CLI the line is set to by "New <CLI> agent", until it loses the
    /// keys; nil: the default.
    var lineProvider: AgentProviderID?
    /// The session's undoable actions (flows.md 3.4): settles, project
    /// removals and starts, newest last.
    var undo = AgentUndoList()
    /// The walk through the agents waiting on the person, while one is under
    /// way (flows.md 6.6): its one owner. The top bar shows its position.
    var walk: AgentWalk? {
        didSet { if (walk == nil) != (oldValue == nil) { save() } }
    }
    /// The agent whose name is being edited in place, and where (flows.md
    /// 6.9); nil when none is.
    var renaming: AgentRenaming?
    /// The settled agents whose places stay at home until the person leaves
    /// home (flows.md 6.7): entering a terminal or switching project closes
    /// them.
    private(set) var settledPlaces: Set<UUID> = []

    func addSettledPlaces(_ ids: [UUID]) { settledPlaces.formUnion(ids) }

    /// The places at home of `project`, in its order: its agents not
    /// settled, and the settled agents whose places stay until the person
    /// leaves home. The one order the grid shows and ⌘1–9 and the Agent
    /// menu count (final review ruling 13).
    func places(of project: AgentProject, agents: [UUID: AgentInstance]) -> [AgentInstance] {
        project.agents.compactMap { agents[$0.id] }.filter { !$0.isSettled || settledPlaces.contains($0.id) }
    }

    func closeSettledPlace(_ id: UUID) { settledPlaces.remove(id) }
    let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        currentProjectID = defaults?.string(forKey: Self.currentProjectKey).flatMap(UUID.init(uuidString:))
        views = (defaults?.dictionary(forKey: Self.viewsKey) as? [String: String] ?? [:])
            .reduce(into: [:]) { views, pair in
                guard let project = UUID(uuidString: pair.key) else { return }
                views[project] = UUID(uuidString: pair.value).map(AgentProjectView.inside) ?? .home
            }
        densities = (defaults?.dictionary(forKey: Self.densitiesKey) as? [String: Int] ?? [:])
            .reduce(into: [:]) { densities, pair in
                guard let project = UUID(uuidString: pair.key) else { return }
                densities[project] = pair.value
            }
        drafts = (defaults?.dictionary(forKey: Self.draftsKey) as? [String: String] ?? [:])
            .reduce(into: [:]) { drafts, pair in
                guard let project = UUID(uuidString: pair.key) else { return }
                drafts[project] = pair.value
            }
        saved = views
    }

    func draft(in project: UUID) -> String { drafts[project] ?? "" }

    func setDraft(_ draft: String, in project: UUID) {
        guard drafts[project, default: ""] != draft else { return }
        drafts[project] = draft.isEmpty ? nil : draft
        defaults?.set(
            drafts.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value },
            forKey: Self.draftsKey)
    }

    func selection(in project: UUID) -> AgentTileSelection { selections[project] ?? AgentTileSelection() }

    func setSelection(_ selection: AgentTileSelection, in project: UUID) {
        if selections[project] != selection { selections[project] = selection }
    }

    func density(in project: UUID) -> Int { densities[project] ?? 0 }

    func setDensity(_ density: Int, in project: UUID) {
        guard densities[project, default: 0] != density else { return }
        densities[project] = density == 0 ? nil : density
        defaults?.set(
            densities.reduce(into: [String: Int]()) { $0[$1.key.uuidString] = $1.value },
            forKey: Self.densitiesKey)
    }

    /// The current project's view.
    var view: AgentProjectView { currentProjectID.flatMap { views[$0] } ?? .home }

    /// The agent shown inside; nil at home.
    var shownAgentID: UUID? {
        if case .inside(let id) = view { return id }
        return nil
    }

    /// Shows `view` in `project`, which becomes current. Viewing ends when
    /// the shown agent changes.
    func show(_ view: AgentProjectView, in project: UUID) {
        let before = shownAgentID
        if currentProjectID != project {
            if !settledPlaces.isEmpty { settledPlaces = [] }
            currentProjectID = project
            defaults?.set(project.uuidString, forKey: Self.currentProjectKey)
        }
        if views[project] != view { views[project] = view }
        save()
        if view != .home, !settledPlaces.isEmpty { settledPlaces = [] }
        if shownAgentID != before { viewedAgentID = nil }
    }

    /// A project's view as it was left (undo of its removal), without
    /// making it current.
    func setView(_ view: AgentProjectView, in project: UUID) {
        guard views[project] != view else { return }
        views[project] = view
        save()
    }

    /// Makes `project` current as it was left, or the first project's view
    /// when nil is given.
    func switchTo(_ project: UUID?) {
        let before = shownAgentID
        guard currentProjectID != project else { return }
        if !settledPlaces.isEmpty { settledPlaces = [] }
        currentProjectID = project
        defaults?.set(project?.uuidString, forKey: Self.currentProjectKey)
        save()
        if shownAgentID != before { viewedAgentID = nil }
    }

    /// The views as last saved for the next start.
    @ObservationIgnored private var saved: [UUID: AgentProjectView] = [:]

    /// Saves the views for the next start. During a walk every project but
    /// the one the person is in keeps the view it had before the walk:
    /// stepping through agents changes no project's view, only where the
    /// person ends up counts (final review ruling 7).
    private func save() {
        var kept = views
        if let walk {
            for project in views.keys where project != currentProjectID { kept[project] = walk.origin.views[project] }
        }
        guard kept != saved else { return }
        saved = kept
        defaults?.set(
            kept.reduce(into: [String: String]()) { out, pair in
                switch pair.value {
                case .home: out[pair.key.uuidString] = "home"
                case .inside(let id): out[pair.key.uuidString] = id.uuidString
                }
            },
            forKey: Self.viewsKey)
    }

    /// Whether the person is looking at the shown agent.
    func setViewingShownAgent(_ viewing: Bool) {
        let viewed = viewing ? shownAgentID : nil
        if viewedAgentID != viewed { viewedAgentID = viewed }
    }

    /// The agent that counts as read now, by `AgentViewingPolicy`. The
    /// caller reads the screen, the window and the app as they are now.
    func viewedAgent(
        presentedAgentID: UUID?,
        personCanSee: Bool,
        windowIsVisible: Bool,
        windowIsKey: Bool,
        windowIsMiniaturized: Bool
    ) -> UUID? {
        AgentViewingPolicy.viewedAgentID(in: AgentViewingContext(
            explicitAgentID: viewedAgentID,
            selectedAgentID: shownAgentID,
            presentedAgentID: presentedAgentID,
            personCanSee: personCanSee,
            windowIsVisible: windowIsVisible,
            windowIsKey: windowIsKey,
            windowIsMiniaturized: windowIsMiniaturized))
    }

    /// "Notify when an agent is waiting" (flows.md 6.11): off until the
    /// person turns it on in the Agent menu.
    var notifiesWhenWaiting: Bool {
        get { defaults?.bool(forKey: Self.notifyKey) ?? false }
        set { defaults?.set(newValue, forKey: Self.notifyKey) }
    }
    static let notifyKey = "clawddy.notifyWhenWaiting"

    /// The CLI "New agent" starts: the one last chosen, Claude Code until
    /// then.
    var newAgentProvider: AgentProviderID {
        get {
            defaults?.string(forKey: Self.newAgentProviderKey)
                .flatMap(AgentProviderID.init(rawValue:)) ?? .claudeCode
        }
        set { defaults?.set(newValue.rawValue, forKey: Self.newAgentProviderKey) }
    }

    /// Forgets what the configuration no longer has: a project's view inside
    /// an agent that is gone, or settled, becomes home; a project that is
    /// gone has no view; with no current project, or one that is gone, the
    /// first project becomes current.
    func reconcile(with config: AgentConfig, isShown: (UUID) -> Bool) {
        let before = shownAgentID
        var kept: [UUID: AgentProjectView] = [:]
        for project in config.projects {
            switch views[project.id] {
            case .inside(let id) where project.agents.contains(where: { $0.id == id }) && isShown(id):
                kept[project.id] = .inside(id)
            case .some:
                kept[project.id] = .home
            case nil:
                break
            }
        }
        if kept != views {
            views = kept
            save()
        }
        if !config.projects.contains(where: { $0.id == currentProjectID }) {
            currentProjectID = config.projects.first?.id
            defaults?.set(currentProjectID?.uuidString, forKey: Self.currentProjectKey)
        }
        if shownAgentID != before { viewedAgentID = nil }
    }
}
