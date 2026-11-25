import AppKit

/// What the agent window's controls ask of the controller.
@MainActor
struct AgentWindowActions {
    /// Opens an agent on purpose: a row, the news.
    var enter: (UUID) -> Void = { _ in }
    /// "All of <project>".
    var home: () -> Void = {}
    var project: (UUID) -> Void = { _ in }
    /// A project's menu (right-click or Control-click on its name, its
    /// entry in "N more"); the bar's empty part's menu; a project dragged to
    /// a new place in the order.
    var projectMenu: (UUID) -> NSMenu = { _ in NSMenu() }
    var barMenu: () -> NSMenu = { NSMenu() }
    var moveProject: (UUID, Int) -> Void = { _, _ in }
    var nextWaiting: () -> Void = {}
    var find: () -> Void = {}
    var newAgent: () -> Void = {}
    var chooseFolder: () -> Void = {}
    /// A row's menu.
    var rowMenu: (UUID) -> NSMenu = { _ in NSMenu() }
    /// A printable key on the tiles.
    var typeOnTiles: (NSEvent) -> Void = { _ in }
    /// The selection at home changed.
    var select: (AgentTileSelection) -> Void = { _ in }
    /// The agents shown, tiles or rows, in a new order.
    var reorder: ([UUID]) -> Void = { _ in }
    /// Return or the send disk in the line; true for ⌘↩.
    var lineSubmit: (Bool) -> Void = { _ in }
    /// A key command in the line's text: true when it was taken.
    var lineCommand: (Selector) -> Bool = { _ in false }
    /// The line's text changed: the project's draft.
    var draft: (String) -> Void = { _ in }
    /// "N settled" in the line.
    var showSettled: () -> Void = {}
    /// Return with several tiles selected.
    var toLine: () -> Void = {}
    /// A key command in the floating new-agent line.
    var paletteCommand: (Selector) -> Bool = { _ in false }
    /// A click on the veil behind the palette.
    var closePalette: () -> Void = {}
    /// Undo on a settled place or in the status line.
    var undo: () -> Void = {}
    /// The agents of the latest settle, whose places show Undo.
    var latestSettle: () -> Set<UUID> = { [] }
    /// Folders dropped on the window; only files dropped.
    var dropFolders: ([URL]) -> Void = { _ in }
    var dropFiles: () -> Void = {}
    /// Find's text changed; the pointer highlighted a row; a row clicked.
    var findChanged: () -> Void = {}
    /// The floating new-agent line's text changed.
    var newAgentTextChanged: (String) -> Void = { _ in }
    var findHighlight: (Int) -> Void = { _ in }
    var findRun: (Int) -> Void = { _ in }
    /// A key command in a name being edited; the field gave up the keys; its
    /// text changed.
    var nameCommand: (Selector) -> Bool = { _ in false }
    var nameResigned: () -> Void = {}
    var nameChanged: () -> Void = {}
    /// A click outside the name being edited: it is kept, and the click goes
    /// on to what it landed on.
    var nameClickedAway: () -> Void = {}
    /// The name being edited no longer shows: its tile or row was settled,
    /// went, or left the screen; the edit is cancelled.
    var nameGone: () -> Void = {}
    /// A double-click on the header's name.
    var renameShown: () -> Void = {}
    /// Edit ▸ Copy on the tiles.
    var copy: () -> Void = {}
    /// A pinch: apart (true) or together.
    var pinch: (Bool) -> Void = { _ in }
}

/// Who has the keyboard in the agent window (flows.md 5): exactly one, the
/// window's first responder, which only `AgentWindowController.focus` and a
/// click into a field set.
enum AgentFocus: Equatable {
    case tiles, line, palette, terminal
    /// A name being edited in place.
    case name
}

/// The agent window's content (native-look.md 1.2): the top bar, the list
/// of the project's agents, the header and the screen with the shown
/// agent's terminal, and the keys panel, each placed by arithmetic in
/// `AgentWindowView.layout()`. Everything it shows is read from the
/// workspace model, the configuration and the agents' records; the views
/// follow those through Observation and change only what changed.
final class AgentWindowController: NSViewController {
    let terminals: AgentTerminalsController
    let windowView = AgentWindowView()
    private let config: AgentConfig
    private let bridge: AgentBridge
    private let model: AgentWorkspaceModel
    var actions = AgentWindowActions()
    private(set) var palette = ClawddyPalette.prototype
    private var structure: AgentObserver?
    private var waitingWatch: AgentObserver?
    private var noticeWatch: AgentObserver?
    private var shownWatch: AgentObserver?
    private weak var watchedShown: AgentInstance?
    private var waiting: Set<UUID>?
    private var clock: Timer?
    private var observers: [NSObjectProtocol] = []

    var topBar: AgentTopBar { windowView.topBar }
    var list: AgentListView { windowView.list }
    var header: AgentPaneHeader { windowView.header }
    var keysPanel: AgentKeysPanel { windowView.keysPanel }
    var grid: AgentHomeGrid { windowView.home.grid }
    var line: AgentLineView { windowView.line }
    var palettePanel: AgentPaletteView { windowView.paletteView }
    /// The one field a name is edited in, on a tile, a row or the header.
    let nameField = AgentNameField()
    /// The project whose draft the line shows.
    private var lineProject: UUID?
    /// The project and the agent the last render showed, for the motion
    /// between them.
    private var shownProject: UUID?
    private var lastShown: UUID?
    /// What refreshing tiles' text has cost on the main thread.
    private(set) var tailCost = AgentTailCost()
    private var tailClock: Timer?
    private var tailTurn = 0

    init(terminals: AgentTerminalsController, config: AgentConfig, bridge: AgentBridge, model: AgentWorkspaceModel) {
        self.terminals = terminals
        self.config = config
        self.bridge = bridge
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        windowView.install(screen: terminals.view)
        windowView.onRegionsSet = { [weak self] in self?.keepFocusOwner() }
        terminals.stack.terminalOwnsKeys = { [weak self] id in
            guard let self else { return false }
            return self.model.shownAgentID == id && !self.paletteShown
        }
        view = windowView
        topBar.onProject = { [weak self] in self?.actions.project($0) }
        topBar.menuForProject = { [weak self] in self?.actions.projectMenu($0) ?? NSMenu() }
        topBar.barMenu = { [weak self] in self?.actions.barMenu() ?? NSMenu() }
        topBar.onMoveProject = { [weak self] in self?.actions.moveProject($0, $1) }
        topBar.onWaiting = { [weak self] in self?.actions.nextWaiting() }
        topBar.onFind = { [weak self] in self?.actions.find() }
        topBar.onNew = { [weak self] in self?.actions.newAgent() }
        topBar.onKeys = { [weak self] in self?.toggleKeys() }
        list.onEnter = { [weak self] in self?.actions.enter($0) }
        list.onBack = { [weak self] in self?.actions.home() }
        list.menuForAgent = { [weak self] in self?.actions.rowMenu($0) ?? NSMenu() }
        list.onReorder = { [weak self] in self?.actions.reorder($0) }
        windowView.home.onScroll = { [weak self] in self?.homeScrolled() }
        for pill in [windowView.pillAbove, windowView.pillBelow] {
            pill.onPress = { [weak self, weak pill] in
                guard let self, let pill else { return }
                self.revealWaiting(above: pill === self.windowView.pillAbove)
            }
        }
        header.onNews = { [weak self] in self?.actions.enter($0) }
        header.onRename = { [weak self] in self?.actions.renameShown() }
        nameField.command = { [weak self] in self?.actions.nameCommand($0) ?? false }
        nameField.onResign = { [weak self] in self?.actions.nameResigned() }
        nameField.onChange = { [weak self] in self?.actions.nameChanged() }
        grid.actions = AgentHomeActions(
            enter: { [weak self] in self?.actions.enter($0) },
            type: { [weak self] in self?.actions.typeOnTiles($0) },
            select: { [weak self] in self?.actions.select($0) },
            selection: { [weak self] in
                guard let self, let project = self.model.currentProjectID else { return AgentTileSelection() }
                return self.model.selection(in: project)
            },
            screen: { [weak self] in self?.terminals.screen(id: $0) },
            reorder: { [weak self] in self?.actions.reorder($0) },
            menu: { [weak self] in self?.actions.rowMenu($0) ?? NSMenu() })
        grid.actions.toLine = { [weak self] in self?.actions.toLine() }
        grid.actions.undo = { [weak self] in self?.actions.undo() }
        grid.actions.copy = { [weak self] in self?.actions.copy() }
        grid.actions.takeKeys = { [weak self] in self?.focus(.tiles) }
        line.onSubmit = { [weak self] in self?.actions.lineSubmit($0) }
        line.onSettled = { [weak self] in self?.actions.showSettled() }
        line.onClick = { [weak self] in self?.focus(.line) }
        line.onHeight = { [weak self] in self?.windowView.placeLine() }
        line.textView.command = { [weak self] in self?.actions.lineCommand($0) ?? false }
        line.onText = { [weak self] in self?.actions.draft($0) }
        palettePanel.textView.command = { [weak self] in self?.actions.paletteCommand($0) ?? false }
        palettePanel.textView.onChange = { [weak self] in
            guard let self else { return }
            if self.palettePanel.mode == .find {
                self.actions.findChanged()
            } else {
                self.actions.newAgentTextChanged(self.palettePanel.textView.string)
            }
            self.windowView.needsLayout = true
            self.palettePanel.needsLayout = true
        }
        palettePanel.list.onHighlight = { [weak self] in self?.actions.findHighlight($0) }
        palettePanel.list.onRun = { [weak self] in self?.actions.findRun($0) }
        topBar.onUndo = { [weak self] in self?.actions.undo() }
        windowView.onDropFolders = { [weak self] in self?.actions.dropFolders($0) }
        windowView.onPinch = { [weak self] in self?.actions.pinch($0) }
        windowView.onDropFiles = { [weak self] in self?.actions.dropFiles() }
        windowView.veil.onClick = { [weak self] in self?.actions.closePalette() }
        windowView.firstLaunch.choose.onPress = { [weak self] in self?.actions.chooseFolder() }
        terminals.onPresentationChanged = { [weak self] in self?.refreshQuietLine() }
        setPalette(palette)
    }

    /// Starts following the model, the configuration and the agents.
    func start() {
        _ = view
        structure = AgentObserver { [weak self] in self?.renderStructure() }
        waitingWatch = AgentObserver { [weak self] in self?.renderWaiting() }
        noticeWatch = AgentObserver { [weak self] in self?.renderNotice() }
        // The header's time moves on.
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.header.refresh()
                self?.grid.tiles.values.forEach { $0.tick() }
            }
        }
        // Working marks turn only while the window can be seen, and never
        // under Reduce Motion.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: view.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncTurning() }
            },
            // The window closing ends any motion at once (motion review
            // ruling 2).
            center.addObserver(forName: NSWindow.willCloseNotification, object: view.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowView.stopZoom() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncTurning() }
            },
        ]
        syncTurning()
    }

    func syncTurning() {
        let seen = view.window?.occlusionState.contains(.visible) ?? false
        AgentMarkLayer.setTurning(seen && !AgentMotion.reduced)
        // A quarter of the visible working tiles read their terminal every
        // 62.5 ms: each at 4 Hz (native-look.md 5); while the window cannot
        // be seen (closed, covered, hidden) the clock does not run at all.
        if seen, tailClock == nil {
            tailClock = Timer.scheduledTimer(withTimeInterval: 0.0625, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTails() }
            }
        } else if !seen {
            tailClock?.invalidate()
            tailClock = nil
        }
        // Tiles of a window no one sees draw nothing; they catch up when it
        // can be seen again.
        grid.updateOnScreen()
    }

    /// The tile refresh clock runs: only while the window can be seen.
    var refreshes: Bool { tailClock != nil }

    func stop() {
        structure?.cancel()
        waitingWatch?.cancel()
        noticeWatch?.cancel()
        shownWatch?.cancel()
        clock?.invalidate()
        tailClock?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func setPalette(_ palette: ClawddyPalette) {
        self.palette = palette
        view.window?.backgroundColor = palette.canvas.nsColor
        windowView.apply(palette)
        terminals.screen.palette = palette
        keysPanel.apply(palette)
        windowView.veil.apply(palette)
        if structure != nil {
            renderStructure()
            renderWaiting()
        }
    }

    /// The current project's agents as the list shows them: those not
    /// settled, in the project's order.
    func listedAgents(of project: AgentProject) -> [AgentInstance] {
        project.agents.compactMap { bridge.agents[$0.id] }.filter { !$0.isSettled }
    }

    /// The places at home: the agents not settled, and the settled agents
    /// whose places stay until the person leaves home, in the project's
    /// order.
    func homePlaces(of project: AgentProject) -> [AgentInstance] {
        model.places(of: project, agents: bridge.agents)
    }

    /// Lays out what the model shows: home or inside an agent of the
    /// current project.
    private func renderStructure() {
        let project = config.projects.first { $0.id == model.currentProjectID }
        let agents = project.map(listedAgents(of:)) ?? []
        let places = project.map(homePlaces(of:)) ?? []
        let shownID = model.shownAgentID
        let shown = shownID.flatMap { bridge.agents[$0] }
        let inside = shown != nil
        // A settle shrinking into its place that was undone ends at once:
        // the tile shows the agent as the model has it, not a blank tile
        // until the motion would have ended (last review ruling 9).
        if let zooming = windowView.zoomState.agent, windowView.zoomState.settling, bridge.agents[zooming]?.isSettled == false {
            windowView.stopZoom()
        }
        // The terminal shows at once; leaving hides it once it has shrunk.
        if let shownID, terminals.activeID != shownID { terminals.show(shownID) }
        // Entering, the list and header fade in after 50 ms: they are filled
        // after the key's frame is committed (`afterThisFrame`), which then
        // carries only the terminal and the motion.
        let entering = inside && !windowView.isInside && !config.projects.isEmpty
        let listAndHeader = { [weak self] in
            guard let self else { return }
            self.list.show(agents: agents, current: shownID, project: project?.name ?? "", showsBack: true, palette: self.palette)
            if let shown { self.header.show(shown, palette: self.palette) }
        }
        if entering {
            AgentMotion.afterThisFrame { [weak self] in
                guard let self, self.model.shownAgentID == shownID else { return }
                listAndHeader()
            }
        } else {
            listAndHeader()
        }
        if let project {
            // The selection forgets agents that left home.
            var selection = model.selection(in: project.id)
            selection.keep(agents.map(\.id))
            if selection != model.selection(in: project.id) { actions.select(selection) }
            grid.show(
                agents: places, settled: Set(places.filter(\.isSettled).map(\.id)), undoable: actions.latestSettle(),
                density: model.density(in: project.id), palette: palette,
                ghosts: project.id == shownProject && !windowView.home.isHidden)
        }
        let hasProjects = !config.projects.isEmpty
        // Another project (switched, or the one shown removed): a tile
        // growing or shrinking ends at once and takes its content back;
        // nothing floats over the new project (motion review ruling 2).
        // Arriving at another project's home, no terminal fades over it:
        // the views change at once and its tiles fade up from 40 %.
        let otherProject = project?.id != shownProject
        if otherProject { windowView.stopZoom() }
        windowView.show(
            inside: inside,
            hasProjects: hasProjects,
            empty: project.flatMap { places.isEmpty ? "No active agents in \($0.name). Describe a task below." : nil },
            motion: otherProject && !inside ? .none : regionMotion(inside: inside, shownID: shownID, hasProjects: hasProjects))
        if shownID == nil, terminals.activeID != nil, windowView.zoomState.agent == nil { terminals.show(nil) }
        // Another project: inside, its list fades from 40 %; at home, its
        // tiles (flows.md 7).
        if let project, let shownProject, project.id != shownProject, windowView.zoomState.agent == nil {
            let region = inside ? list.layer : windowView.home.layer
            if let region {
                AgentMotion.animate(
                    region, "opacity", to: Float(1), duration: AgentMotion.duration(.fade(AgentMotion.small), in: windowView),
                    from: Float(0.4))
            }
        }
        shownProject = project?.id
        lastShown = shownID
        homeScrolled()
        // Leaving, the header keeps what it showed while it fades out.
        if !inside || header.newsAgentID == shownID { header.endNews() }
        // The line fades out entering: it follows after the key's frame.
        if entering {
            AgentMotion.afterThisFrame { [weak self] in
                guard let self else { return }
                self.renderLine(project: self.config.projects.first { $0.id == self.model.currentProjectID })
            }
        } else {
            renderLine(project: project)
        }
        if watchedShown !== shown {
            watchedShown = shown
            shownWatch?.cancel()
            shownWatch = shown.map { _ in AgentObserver { [weak self] in self?.refreshQuietLine() } }
            refreshQuietLine()
        }
        // A name edited where it no longer shows is not kept: its tile or row
        // was settled, went, or left the screen (final review ruling 8).
        if let renaming = model.renaming, !showsName(of: renaming) { actions.nameGone() }
        // The title (Mission Control, the Window menu) costs a few
        // milliseconds to set: after the frame of the key, never in it.
        let title = [project?.name, shown?.name].compactMap { $0 }.joined(separator: " — ")
        if view.window?.title != title {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.view.window?.title = title }
        }
    }

    /// Lays out what the model shows now, in the frame of the key.
    func render() { renderStructure() }

    /// How the views move between home and inside (flows.md 7): entering
    /// grows the terminal from the agent's tile when home shows it;
    /// leaving shrinks it into the tile of the agent left, scrolled into
    /// view first, and hides the terminal once it has shrunk; settling
    /// inside shrinks it into its settled place.
    private func regionMotion(inside: Bool, shownID: UUID?, hasProjects: Bool) -> AgentRegionMotion {
        guard inside != windowView.isInside, hasProjects else { return .none }
        if inside, let shownID {
            return .zoom(agent: shownID, tile: windowView.home.isHidden ? nil : grid.tiles[shownID], settling: false, done: {})
        }
        let hide: () -> Void = { [weak self] in
            guard let self, self.model.shownAgentID == nil, self.terminals.activeID != nil else { return }
            self.terminals.show(nil)
        }
        guard let left = lastShown, let tile = grid.tiles[left] else {
            return .zoom(agent: UUID(), tile: nil, settling: false, done: hide)
        }
        windowView.home.layoutSubtreeIfNeeded()
        grid.scrollToVisible(tile.frame.insetBy(dx: 0, dy: -AgentHomeLayout.top))
        return .zoom(agent: left, tile: tile, settling: bridge.agents[left]?.isSettled == true, done: hide)
    }

    /// The top bar keeps saying that a change could not be saved while any
    /// write of `agents.json`, a record or a last screen has failed and no
    /// later one succeeded (last review ruling 1).
    private func renderNotice() {
        let unsaved = config.unsaved || !bridge.unsavedFiles.isEmpty
        topBar.showNotice(unsaved ? AgentNotices.unsaved : nil)
    }

    /// The top bar's counts, from every agent's record, and the news of an
    /// agent that came to wait on the person while another is shown.
    private func renderWaiting() {
        var total = 0
        var projects: [AgentTopBar.Project] = []
        var now: Set<UUID> = []
        for project in config.projects {
            let agents = project.agents.compactMap { bridge.agents[$0.id] }
            let waitingHere = agents.filter(\.isWaiting)
            now.formUnion(waitingHere.map(\.id))
            total += waitingHere.count
            projects.append(AgentTopBar.Project(
                id: project.id, name: project.name,
                agents: agents.filter { !$0.isSettled }.count,
                waiting: waitingHere.count,
                isCurrent: project.id == model.currentProjectID))
        }
        let walk = model.walk.map { walk in
            walk.words(waiting: AgentWaitingOrder.agents(
                projects: config.projects, agents: bridge.agents, currentProject: walk.origin.project))
        }
        topBar.show(projects: projects, waiting: total, walk: walk, palette: palette)
        updatePills()
        defer { waiting = now }
        guard let before = waiting, let shown = model.shownAgentID else { return }
        let arrived = config.allAgentEntries.map(\.id).filter { now.contains($0) && !before.contains($0) && $0 != shown }
        if let latest = arrived.last, let agent = bridge.agents[latest] { header.showNews(agent) }
    }

    // MARK: The line

    /// The keys go to `target`: the one way the controller moves them
    /// (flows.md 5). The terminal gets them through the terminal stack's
    /// one function.
    func focus(_ target: AgentFocus) {
        guard let window = view.window else { return }
        switch target {
        case .tiles: window.makeFirstResponder(grid)
        case .line: window.makeFirstResponder(line.textView)
        case .palette: window.makeFirstResponder(palettePanel.textView)
        case .terminal: terminals.focusTerminal()
        case .name: window.makeFirstResponder(nameField.textView)
        }
    }

    /// The window's first responder is the one the model names: the open
    /// palette's field; a name being edited; inside, the shown agent's
    /// terminal (or a view in its pane, Ghostty's search field), else the
    /// window itself, which holds keys for an agent whose CLI does not run;
    /// at home, the tiles or the line, never the window, a terminal or a
    /// hidden view. With no project, anything.
    var focusOwnerHolds: Bool {
        guard let window = view.window else { return true }
        let responder = window.firstResponder
        if paletteShown { return responder === palettePanel.textView }
        if model.renaming != nil, !nameField.isHidden { return responder === nameField.textView }
        if let shown = model.shownAgentID {
            let stack = terminals.stack
            if stack.presentedID == shown, let surface = stack.presentedSurface {
                return responder === surface || ((responder as? NSView)?.isDescendant(of: stack) ?? false)
            }
            return responder === window
        }
        guard model.currentProjectID != nil else { return true }
        return responder === grid || responder === line.textView
    }

    /// The keys go back to the owner the model names when they sit where
    /// no one can type: at home on the window itself, a terminal or a hidden
    /// view (the tiles then; the line keeps them when it has them); inside
    /// on a view of home (the shown terminal then). Runs after every change
    /// of first responder and of what is shown: the one place this is
    /// decided. The palette and a name being edited move the keys
    /// themselves.
    func keepFocusOwner() {
        guard let window = view.window, !focusOwnerHolds, !paletteShown, model.renaming == nil else { return }
        let responder = window.firstResponder
        if model.shownAgentID == nil {
            guard model.currentProjectID != nil else { return }
            focusRepairs += 1
            focus(.tiles)
        } else if responder === grid || responder === line.textView {
            focusRepairs += 1
            focus(.terminal)
        }
    }

    /// Times `keepFocusOwner` gave the keys back, for the harness.
    private(set) var focusRepairs = 0

    /// Who has the keys now, read from the window's first responder.
    var focused: AgentFocus? {
        let responder = view.window?.firstResponder
        if responder === grid { return .tiles }
        if responder === line.textView { return .line }
        if responder === palettePanel.textView { return .palette }
        if responder === nameField.textView { return .name }
        if responder is Ghostty.SurfaceView { return .terminal }
        return nil
    }

    /// The window's first responder changed: the line's edge, the tiles'
    /// rings and dimming, and the chip follow at once; the line goes back to
    /// the default CLI when it loses the keys.
    func focusChanged() {
        keepFocusOwner()
        // The terminal took the keys, or a terminal grows or shrinks: the
        // line and the tiles are hidden, fading out, or at opacity 0 for
        // the first 50 ms, so they follow after the key's frame is
        // committed, from who has the keys then. The keys themselves have
        // moved already.
        guard focused != .terminal, windowView.zoomState.agent == nil else {
            AgentMotion.afterThisFrame { [weak self] in self?.followFocus() }
            return
        }
        followFocus()
    }

    private func followFocus() {
        let focus = focused
        line.setFocused(focus == .line)
        grid.lineHasKeys = focus == .line
        grid.syncSelection()
        if focus != .line, focus != .palette, model.lineProvider != nil { model.lineProvider = nil }
        renderLine(project: config.projects.first { $0.id == model.currentProjectID })
    }

    /// The chip, placeholder and words of the line, from the selection and
    /// who has the keys (rulings 1 to 3); the project's draft when the
    /// project changed.
    private func renderLine(project: AgentProject?) {
        guard let project else { return }
        if lineProject != project.id {
            // Text an input method still composes belongs to the project it
            // was typed in: committed there before the next draft shows.
            if let old = lineProject, line.textView.hasMarkedText() {
                line.textView.unmarkText()
                model.setDraft(line.textView.string, in: old)
            }
            lineProject = project.id
            line.textView.setText(model.draft(in: project.id))
        }
        let selection = model.selection(in: project.id)
        let count = selection.selected.count
        let cli = model.lineProvider.flatMap { $0 == model.newAgentProvider ? nil : $0.displayName + " " } ?? ""
        let settled = project.agents.compactMap { bridge.agents[$0.id] }.filter(\.isSettled).count
        let words: AgentLineView.Words
        if count > 1 {
            words = .init(
                chip: "To \(count) agents", many: true, placeholder: "One instruction for all \(count)",
                accessibility: "Instruction for \(count) agents", sendLabel: "Send to \(count) agents")
        } else if count == 1, grid.hasKeys, let cursor = selection.cursor, let agent = bridge.agents[cursor] {
            words = .init(
                chip: "Reply to \(agent.name)", placeholder: "Type to reply, or ⌘N for a new agent",
                accessibility: "Reply to \(agent.name)")
        } else {
            words = .init(
                chip: "New \(cli)agent in \(project.name)", placeholder: "Describe the task",
                accessibility: "Task for a new \(cli)agent in \(project.name)")
        }
        line.show(words, settled: settled, palette: palette)
    }

    /// Keeps a new agent's tile in view, at once.
    func reveal(agent id: UUID) {
        renderStructure()
        if let tile = grid.tiles[id] { grid.scrollToVisible(tile.frame.insetBy(dx: 0, dy: -AgentHomeLayout.top)) }
        grid.appear(id)
    }

    // MARK: A name edited in place

    /// Where `id`'s name shows in `place` now, if it shows there.
    func nameHost(of id: UUID, at place: AgentRenaming.Place) -> AgentNameHost? {
        switch place {
        case .tile: model.shownAgentID == nil ? grid.tiles[id] : nil
        case .row: model.shownAgentID == nil ? nil : list.row(of: id)
        case .header: model.shownAgentID == id ? header : nil
        }
    }

    /// The name being edited still shows where it is edited: its host is on
    /// screen with the field in it, and its agent is not settled.
    private func showsName(of renaming: AgentRenaming) -> Bool {
        guard let host = nameHost(of: renaming.agent, at: renaming.place) else { return false }
        return nameField.superview === host && bridge.agents[renaming.agent]?.isSettled == false
    }

    /// The field over `id`'s name in `place`, `name` in it, all selected,
    /// with the keys; false when the name does not show there. A tile is
    /// scrolled into view first.
    func beginRename(_ id: UUID, at place: AgentRenaming.Place, name: String) -> Bool {
        guard let host = nameHost(of: id, at: place) else { return false }
        if let tile = host as? AgentTileView {
            grid.scrollToVisible(tile.frame.insetBy(dx: 0, dy: -AgentHomeLayout.top))
        }
        if let row = host as? AgentListRowView { list.reveal(row.agentID) }
        host.layoutSubtreeIfNeeded()
        (nameField.superview as? AgentNameHost)?.editsName = false
        host.editsName = true
        nameField.show(name, font: host.nameFont, over: host.nameFrame, halo: host.nameHalo, in: host, palette: palette)
        focus(.name)
        return true
    }

    /// The field goes; its place shows the name again. The caller has moved
    /// the keys first.
    func endRename() {
        (nameField.superview as? AgentNameHost)?.editsName = false
        nameField.isHidden = true
    }

    // MARK: Home's scroll

    /// How far home is scrolled down.
    var homeScroll: CGFloat { windowView.home.contentView.bounds.minY }

    /// Scrolls home to `y` at once (the walk's return), within its content.
    func scrollHome(to y: CGFloat) {
        let clip = windowView.home.contentView
        let most = max(0, (windowView.home.documentView?.frame.height ?? 0) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), most)))
        windowView.home.reflectScrolledClipView(clip)
        homeScrolled()
    }

    // MARK: The floating new-agent line

    var paletteShown: Bool { !windowView.paletteView.isHidden && windowView.paletteView.layer?.opacity != 0 }

    /// Opens the floating new-agent line over the terminal or the tiles,
    /// its field with the keys from the first frame (flows.md 6.3, 7);
    /// already open, it turns to new-agent mode, empty.
    func showNewAgentPalette(chip: String, accessibility: String) {
        let opening = !paletteShown
        let back = model.shownAgentID == nil ? "Close" : "Back to terminal"
        palettePanel.showNew(chip: chip, accessibility: accessibility, back: back, palette: palette)
        palettePanel.textView.setText("")
        if opening { windowView.setPalette(shown: true) } else { windowView.needsLayout = true }
        focus(.palette)
    }

    /// Opens find with `text` in its field and the keys there from the
    /// first frame (flows.md 6.8).
    func showFind(text: String) {
        palettePanel.showFind(text: text, palette: palette)
        windowView.setPalette(shown: true)
        if let window = view.window {
            palettePanel.list.primePointer(window.mouseLocationOutsideOfEventStream)
        }
        focus(.palette)
    }

    /// Find's rows for the text in its field.
    func showFindResults(_ rows: [AgentPaletteRow], highlighted: Int) {
        palettePanel.showResults(rows, highlighted: highlighted)
        windowView.needsLayout = true
        windowView.layoutSubtreeIfNeeded()
    }

    /// Closes it; the caller gives the keys back.
    func hidePalette() {
        windowView.setPalette(shown: false)
    }

    /// The screen's quiet line while the shown agent has no terminal.
    private func refreshQuietLine() {
        guard let agent = watchedShown, !terminals.hasSurface(id: agent.id) else {
            terminals.screen.showQuietLine(nil)
            return
        }
        terminals.screen.showQuietLine(
            agent.waitsToStart ? AgentInstance.waitingToStart
                : agent.surfaceState == .opening ? "Starting \(agent.provider.displayName)…"
                : "Type to continue this conversation.")
    }

    /// After a settle or its undo at home: the places as they are now and
    /// `selection` with its cursor in view, in the frame of the key; the
    /// keys stay where they are.
    func showSettled(selecting selection: AgentTileSelection) {
        renderStructure()
        grid.select(selection)
    }

    /// Home with `selection`, its cursor in view, the tiles with the keys;
    /// `revealing` (a settled place) in view first.
    func showHome(selecting selection: AgentTileSelection, revealing: UUID? = nil) {
        renderStructure()
        if let revealing, let tile = grid.tiles[revealing] {
            windowView.home.layoutSubtreeIfNeeded()
            grid.scrollToVisible(tile.frame.insetBy(dx: 0, dy: -AgentHomeLayout.top))
        }
        // Home's own size, for the cursor's place; the terminals lay out in
        // the display cycle, not here.
        windowView.home.layoutSubtreeIfNeeded()
        grid.select(selection)
        // Every tile shows what it showed when home was left, at once; the
        // agent just left shows its terminal as it is now, and the others
        // read theirs in the next ticks, a few a tick, never in this frame.
        grid.markScreensStale()
        // Its tile shows in the shrink's last 50 ms: read after the key's
        // frame is committed.
        if let cursor = selection.cursor {
            AgentMotion.afterThisFrame { [weak self] in self?.grid.tiles[cursor]?.refreshScreen() }
        }
        focus(.tiles)
        homeScrolled()
    }

    /// What follows home's scroll position: the pills and the top bar's
    /// hairline.
    private func homeScrolled() {
        updatePills()
        let scrolled = !windowView.home.isHidden && windowView.home.contentView.bounds.minY > 0
        topBar.showsEdge = scrolled
    }

    /// Reads the terminal text of a quarter of the visible working tiles
    /// with a terminal, in turn; nothing while home is not on screen.
    private func refreshTails() {
        // Nothing is drawn while home scrolls, a terminal grows or shrinks
        // over it, or tiles move (native-look.md 5: tile refresh pauses for
        // the motion).
        guard view.window?.occlusionState.contains(.visible) == true, !windowView.home.isScrolling,
              windowView.zoomState.agent == nil, !grid.isMoving
        else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        if grid.font == .fallback, let surface = grid.order.lazy.compactMap({ self.terminals.surface(id: $0) }).first,
           let font = AgentTerminalFont.of(surface) {
            grid.font = font
        }
        // Tiles that came into view or whose agent changed out of it; with
        // room left, one never drawn out of view draws once.
        grid.refreshStale(limit: 4)
        guard !windowView.home.isHidden else { return }
        let working = grid.visibleTiles.filter { tile in
            bridge.agents[tile.agentID]?.record.state == .working && terminals.hasSurface(id: tile.agentID)
        }
        tailTurn += 1
        for (index, tile) in working.enumerated() where index % 4 == tailTurn % 4 { tile.refreshScreen() }
        tailCost.add(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, tiles: working.count)
    }

    // MARK: Waiting tiles out of view

    /// The waiting tiles above and below what home shows: those of which
    /// less than 28 pt is in view.
    private func waitingOutOfView() -> (above: [AgentTileView], below: [AgentTileView]) {
        let visible = grid.visibleRect
        let waiting = grid.order.compactMap { id in
            bridge.agents[id]?.isWaiting == true ? grid.tiles[id] : nil
        }
        return (waiting.filter { $0.frame.maxY < visible.minY + 28 }, waiting.filter { $0.frame.minY > visible.maxY - 28 })
    }

    /// "N waiting above" and "N waiting below", while waiting tiles sit
    /// scrolled out of view at home (ruling 13).
    func updatePills() {
        let (above, below) = waitingOutOfView()
        let counts = (windowView.pillAbove.count, windowView.pillBelow.count)
        windowView.pillAbove.show(count: above.count, below: false, palette: palette)
        windowView.pillBelow.show(count: below.count, below: true, palette: palette)
        windowView.showHomeParts()
        if counts != (windowView.pillAbove.count, windowView.pillBelow.count) { windowView.needsLayout = true }
    }

    /// Scrolls the nearest waiting tile out of view into view.
    private func revealWaiting(above: Bool) {
        let (over, under) = waitingOutOfView()
        guard let tile = above ? over.last : under.first else { return }
        grid.scrollToVisible(tile.frame.insetBy(dx: 0, dy: -AgentHomeLayout.top))
        updatePills()
    }

    // MARK: Keys during a drag

    /// The Escape that ended the last drag, which the window may offer
    /// twice (as a key equivalent, then as a key).
    private var dragEndedAt: TimeInterval?

    /// While a tile, a row or a project is moved by the pointer, every key
    /// is taken: Escape puts everything back, no other key acts (flows.md
    /// 3.5, ruling 33).
    func keyDuringDrag(_ event: NSEvent) -> Bool {
        if event.timestamp == dragEndedAt { return true }
        guard grid.isDragging || list.isDragging || topBar.isDragging else { return false }
        if event.type == .keyDown, event.keyCode == 53 {
            grid.cancelDrag()
            list.cancelDrag()
            topBar.cancelDrag()
            dragEndedAt = event.timestamp
        }
        return true
    }

    // MARK: Keys panel

    func toggleKeys() {
        keysPanel.setShown(!keysPanel.isShown)
        windowView.needsLayout = true
    }

    /// A mouse-down anywhere outside the name being edited keeps the name
    /// (final review ruling 8): on a control, the control then acts; on a
    /// tile, a drag starts after it; on empty space nothing else happens.
    /// One outside the keys panel and its button closes the panel.
    func windowMouseDown(_ event: NSEvent) {
        if model.renaming != nil, !nameField.isHidden,
           !nameField.bounds.insetBy(dx: -4, dy: -4).contains(nameField.convert(event.locationInWindow, from: nil)) {
            actions.nameClickedAway()
        }
        guard keysPanel.isShown else { return }
        let point = windowView.convert(event.locationInWindow, from: nil)
        let inPanel = keysPanel.frame.contains(point)
        let onButton = windowView.topBar.keysButtonFrame.map { windowView.convert($0, from: windowView.topBar).contains(point) } ?? false
        if !inPanel && !onButton { keysPanel.setShown(false) }
    }
}

/// What refreshing tiles' text costs on the main thread, per tick.
struct AgentTailCost {
    private(set) var ticks = 0
    private(set) var totalMs = 0.0
    private(set) var maxMs = 0.0
    private(set) var tiles = 0

    mutating func add(_ ms: Double, tiles: Int) {
        ticks += 1
        totalMs += ms
        maxMs = max(maxMs, ms)
        self.tiles = tiles
    }
}

/// Lays out every region of the agent window by arithmetic (native-look.md
/// 1.2) and owns the pointer: it sends the pointer only to the regions the
/// view shows, and it alone decides which control shows the pointer over it.
final class AgentWindowView: NSView {
    let topBar = AgentTopBar()
    let home = AgentHomeView()
    let list = AgentListView()
    let header = AgentPaneHeader()
    let keysPanel = AgentKeysPanel()
    let firstLaunch = AgentFirstLaunchView()
    let pillAbove = AgentEdgePill()
    let pillBelow = AgentEdgePill()
    let line = AgentLineView()
    let veil = AgentVeilView()
    let paletteView = AgentPaletteView()
    let dropOutline = AgentDropOutline()
    /// Holds the tile's snapshot over the screen while the terminal grows or
    /// shrinks; draws nothing itself and takes no pointer.
    let zoomCover = AgentZoomCover()
    /// Folders dropped on the window, in the dropped order (flows.md 6.2).
    var onDropFolders: (([URL]) -> Void)?
    /// A pinch apart (true) or together, once per gesture (flows.md 3.3).
    var onPinch: ((Bool) -> Void)?
    private var pinchAmount: CGFloat = 0
    private var pinchActed = false
    /// Only files were dropped.
    var onDropFiles: (() -> Void)?
    private var dragHoldsOnlyFiles = false
    private let empty = AgentTextLayer()
    private(set) var screen = NSView()
    private(set) var isInside = false
    private(set) var hasProjects = true
    /// The regions have been set once.
    private var regionsKnown = false
    private var palette = ClawddyPalette.prototype
    /// The enter or leave motion under way (`AgentZoom.swift`).
    var zoomState = AgentZoomState()
    private weak var hovered: (NSView & AgentHoverable)?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(empty)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }

    /// Puts every region in, back to front.
    func install(screen: NSView) {
        self.screen = screen
        for view in [home, list, header, screen, zoomCover, firstLaunch, line, topBar, pillAbove, pillBelow, keysPanel, veil, paletteView, dropOutline] {
            addSubview(view)
        }
        veil.isHidden = true
        paletteView.isHidden = true
        dropOutline.isHidden = true
        // Names the harness finds the moving layers by.
        for (view, name) in [(screen, "screen"), (list, "list"), (header, "header"), (home, "home"), (line, "line"),
                             (paletteView, "palette"), (veil, "veil"), (home.grid, "grid")] as [(NSView, String)] {
            view.layer?.name = name
        }
    }

    func apply(_ palette: ClawddyPalette) {
        self.palette = palette
        layer?.backgroundColor = palette.canvas.cgColor()
        firstLaunch.apply(palette)
    }

    /// Home or inside: inside, the header and the screen show; at home they
    /// sit at opacity 0 and take no pointer. No region is ever removed. A
    /// change between the two moves as `motion` says (`AgentZoom.swift`);
    /// without one, at once.
    func show(inside: Bool, hasProjects: Bool, empty sentence: String?, motion: AgentRegionMotion = .none) {
        let changed = !regionsKnown || inside != isInside || hasProjects != self.hasProjects
        // The frames depend on whether there are projects, never on home or
        // inside: entering and leaving lay out nothing here.
        if !regionsKnown || hasProjects != self.hasProjects { needsLayout = true }
        regionsKnown = true
        isInside = inside
        self.hasProjects = hasProjects
        // At home VoiceOver does not read the header it cannot see.
        header.setAccessibilityElement(inside)
        firstLaunch.isHidden = hasProjects
        empty.text = sentence.flatMap { inside ? nil : $0 }.map {
            AgentText(string: $0, font: AgentMetrics.empty, color: palette.text3.cgColor(), lineHeight: 20, maxLines: 2, alignment: .center)
        }
        if changed, hasProjects, case let .zoom(agent, tile, settling, done) = motion {
            zoom(inward: inside, agent: agent, tile: tile, settling: settling, done: done)
        } else if changed {
            stopZoom()
            setRegions(inside: inside)
            if case let .zoom(_, _, _, done) = motion { done() }
        }
    }

    /// Every region as it rests, home or inside: the one place that says
    /// what shows. Home's regions are home, the line and the edge pills;
    /// inside's are the list, the header and the screen. A region that does
    /// not show is hidden (the screen, whose terminals stay attached, sits
    /// at opacity 0 at home with no terminal shown).
    func setRegions(inside: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in ([header, screen, list, home, line] + homeParts).compactMap(\.layer) {
            layer.removeAnimation(forKey: "opacity")
            layer.opacity = 1
        }
        screen.layer?.opacity = inside ? 1 : 0
        CATransaction.commit()
        list.isHidden = !hasProjects || !inside
        header.isHidden = !hasProjects || !inside
        home.isHidden = !hasProjects || inside
        line.isHidden = !hasProjects || inside
        showHomeParts()
        onRegionsSet?()
    }

    /// What is shown changed (`setRegions`): the keys follow
    /// (`AgentWindowController.keepFocusOwner`).
    var onRegionsSet: (() -> Void)?

    /// Home's parts outside home's own view: the edge pills.
    var homeParts: [NSView] { [pillAbove, pillBelow] }

    /// Each edge pill shows while home shows and agents wait out of its
    /// view; it goes with home and comes back with it.
    func showHomeParts() {
        for pill in [pillAbove, pillBelow] { pill.isHidden = pill.count == 0 || home.isHidden }
    }

    /// The regions that show, by name: not hidden and not at opacity 0 in
    /// the model (what is on screen once the motion ends). For tests and
    /// the harness.
    var shownRegions: [String] {
        let named: [(String, NSView)] = [
            ("home", home), ("line", line), ("pillAbove", pillAbove), ("pillBelow", pillBelow), ("list", list),
            ("header", header), ("screen", screen), ("dropOutline", dropOutline), ("palette", paletteView),
        ]
        return named.filter { !$0.1.isHidden && ($0.1.layer?.opacity ?? 1) > 0 }.map(\.0)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let bar = AgentTopBar.height
        set(topBar, NSRect(x: 0, y: 0, width: width, height: bar))
        // Home gives the line its space whether or not it shows, so no tile
        // changes size between home and inside.
        let reserved = hasProjects ? AgentLineView.reserved : 0
        set(home, NSRect(x: 0, y: bar, width: width, height: max(0, height - bar - reserved)))
        placeLine()
        set(list, NSRect(x: 0, y: bar, width: AgentListView.width, height: height - bar))
        let paneX = AgentListView.width + 4
        let paneWidth = max(0, width - paneX - 14)
        set(header, NSRect(x: paneX, y: bar, width: paneWidth, height: AgentPaneHeader.height))
        let screenTop = bar + AgentPaneHeader.height
        set(screen, NSRect(x: paneX, y: screenTop, width: paneWidth, height: max(0, height - screenTop - 14)))
        let panelHeight = min(keysPanel.contentHeight, height - 64)
        set(keysPanel, NSRect(x: width - 12 - AgentKeysPanel.width, y: bar + 2, width: AgentKeysPanel.width, height: panelHeight))
        // Above: across the top bar's lower edge, over the top margin of the
        // first row in view, never a name. Below: 10 pt over the line
        // (`placeLine`).
        set(pillAbove, NSRect(
            x: ((bounds.width - pillAbove.width) / 2).rounded(), y: bar - AgentEdgePill.height / 2,
            width: pillAbove.width, height: AgentEdgePill.height))
        // The palette and its dim layer belong to the stage, under the top
        // bar: the bar is never dimmed; the palette's top is the bar's bottom
        // plus 13 % of the stage, its list at most 46 % of the stage.
        let stage = max(0, height - bar)
        veil.frame = NSRect(x: 0, y: bar, width: width, height: stage)
        dropOutline.frame = bounds
        zoomCover.frame = bounds
        paletteView.listLimit = (stage * 0.46).rounded()
        let paletteWidth = min(AgentPaletteView.maxWidth, (width * 0.88).rounded())
        set(paletteView, NSRect(
            x: ((width - paletteWidth) / 2).rounded(), y: bar + (stage * 0.13).rounded(),
            width: paletteWidth, height: paletteView.preferredHeight))
        let launch = AgentFirstLaunchView.size
        set(firstLaunch, NSRect(
            x: ((width - launch.width) / 2).rounded(), y: (bar + (height - bar - launch.height) / 2).rounded(),
            width: launch.width, height: launch.height))
        empty.frame = CGRect(x: 24, y: (bar + (height - bar) / 2 - 20).rounded(), width: max(0, width - 48), height: 40)
    }

    private func set(_ view: NSView, _ frame: NSRect) {
        if view.frame != frame { view.frame = frame }
    }

    /// The line: centred, at most 960 wide and 24 from each side, its bottom
    /// 18 from the window's, as tall as its text; set at once as it grows.
    func placeLine() {
        let width = min(bounds.width - 48, AgentLineView.maxWidth)
        let height = line.slabHeight
        set(line, NSRect(
            x: ((bounds.width - width) / 2).rounded(), y: bounds.height - AgentLineView.bottom - height,
            width: width, height: height))
        // The pill for waiting agents below rides 10 pt over the line's top
        // edge, at any height of the line.
        set(pillBelow, NSRect(
            x: ((bounds.width - pillBelow.width) / 2).rounded(), y: line.frame.minY - 10 - AgentEdgePill.height,
            width: pillBelow.width, height: AgentEdgePill.height))
    }

    /// The palette and its veil: the veil reaches full opacity in 75 ms, the
    /// panel fades in and scales from 98 % about its top centre in 150 ms;
    /// closing fades both out in 100 ms (flows.md 7). Reduce Motion: fades
    /// of 100 ms, no scale.
    func setPalette(shown: Bool) {
        guard let veilLayer = veil.layer, let panelLayer = paletteView.layer else { return }
        if shown {
            // Opened again while it fades out: back from what is on screen.
            let fresh = paletteView.isHidden
            veil.isHidden = false
            paletteView.isHidden = false
            needsLayout = true
            layoutSubtreeIfNeeded()
            if fresh {
                veilLayer.opacity = 0
                panelLayer.opacity = 0
            }
            AgentMotion.animate(
                veilLayer, "opacity", to: Float(1), duration: AgentMotion.duration(.fade(AgentMotion.veilIn), in: self))
            // Fully opaque by 55 % of the time, as it rises.
            AgentMotion.animate(
                panelLayer, "opacity", to: Float(1), duration: AgentMotion.duration(.fade(AgentMotion.small), in: self),
                hold: AgentMotion.reduced ? [] : [(0.55, Float(1))])
            let rise = AgentMotion.duration(.move(AgentMotion.small), in: self)
            if fresh {
                let bounds = paletteView.bounds
                var start = CATransform3DMakeTranslation(bounds.width / 2, 0, 0)
                start = CATransform3DScale(start, 0.98, 0.98, 1)
                start = CATransform3DTranslate(start, -bounds.width / 2, 0, 0)
                AgentMotion.animate(panelLayer, "sublayerTransform", to: CATransform3DIdentity, duration: rise, from: start)
            } else {
                AgentMotion.animate(panelLayer, "sublayerTransform", to: CATransform3DIdentity, duration: rise)
            }
        } else {
            let duration = AgentMotion.duration(.fade(AgentMotion.gone), in: self)
            AgentMotion.run({
                AgentMotion.animate(veilLayer, "opacity", to: Float(0), duration: duration)
                AgentMotion.animate(panelLayer, "opacity", to: Float(0), duration: duration)
            }, then: { [weak self] in
                guard let self, self.paletteView.layer?.opacity == 0 else { return }
                self.veil.isHidden = true
                self.paletteView.isHidden = true
            })
        }
    }

    /// Whether `region` takes part in the pointer: the one place that says
    /// which regions the view shows. At home the header and the screen sit
    /// at opacity 0 (the screen is never hidden: its terminals stay attached,
    /// S1) and take no pointer; inside, home and its pills take none; a
    /// hidden region takes none.
    private func takesPointer(_ region: NSView) -> Bool {
        if region.isHidden { return false }
        if region === header || region === screen { return isInside }
        if region === keysPanel { return keysPanel.isShown }
        if region === veil || region === paletteView { return paletteView.layer?.opacity != 0 && !paletteView.isHidden }
        if region === dropOutline || region === zoomCover { return false }
        if region === line { return !isInside && hasProjects }
        if region === home || region is AgentEdgePill { return !isInside }
        return true
    }

    /// The pointer goes to the frontmost region that takes it and holds the
    /// point; a region that does not take it is passed through, so what lies
    /// under it gets the pointer.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return nil }
        for region in subviews.reversed() where takesPointer(region) {
            if let view = region.hitTest(local) { return view }
        }
        return self
    }

    /// The display's scale: every text, mark and symbol layer draws at it,
    /// and every frame snaps to its pixels.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor, scale != AgentMetrics.scale else { return }
        AgentMetrics.scale = scale
        func apply(_ layer: CALayer) {
            if layer is AgentTextLayer || layer is AgentMarkLayer || layer is AgentSymbolLayer {
                layer.contentsScale = scale
            }
            layer.sublayers?.forEach(apply)
        }
        if let layer { apply(layer) }
        func relayout(_ view: NSView) {
            view.needsLayout = true
            view.subviews.forEach(relayout)
        }
        relayout(self)
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved(to: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        pointerMoved(to: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        pointerMoved(to: nil)
    }

    /// The pointer is at `point`, in the window's coordinates, or has left
    /// the window: the control under it shows it, the one before does not.
    func pointerMoved(to point: NSPoint?) {
        var next: (NSView & AgentHoverable)?
        if let point, let superview {
            var view = hitTest(superview.convert(point, from: nil))
            while let candidate = view {
                if let hoverable = candidate as? NSView & AgentHoverable {
                    next = hoverable
                    break
                }
                view = candidate.superview
            }
        }
        if let point, !paletteView.isHidden { paletteView.pointerMoved(to: point) }
        guard next !== hovered else { return }
        hovered?.isHovered = false
        next?.isHovered = true
        hovered = next
    }

    /// The control the pointer is over, for the harness.
    var hoveredView: NSView? { hovered }

    // MARK: Pinching

    /// The trackpad's pinch reaches the window from any region (no view
    /// under it takes it, the terminal included): apart enters the cursor
    /// tile at home, together goes back to all agents, once per gesture.
    override func magnify(with event: NSEvent) {
        if event.phase.contains(.began) { pinchAmount = 0; pinchActed = false }
        pinched(by: event.magnification)
    }

    /// `amount` more of the gesture under way; past 0.2 either way it acts.
    func pinched(by amount: CGFloat) {
        pinchAmount += amount
        guard !pinchActed, abs(pinchAmount) > 0.2 else { return }
        pinchActed = true
        onPinch?(pinchAmount > 0)
    }

    /// A new gesture begins (for tests, which cannot make one).
    func beginPinch() { pinchAmount = 0; pinchActed = false }

    // MARK: Folders dropped on the window

    /// The folders and the files a drag carries.
    static func dragged(_ pasteboard: NSPasteboard) -> (folders: [URL], files: Int) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let folders = urls.filter { url in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
        }
        return (folders, urls.count - folders.count)
    }

    /// A drag over the window, not over a field or the terminal shown
    /// (they take their own drops, deeper in the window): with folders, the
    /// 2 pt outline and "Add <folder> as a project"; with only files, the
    /// pointer says no and nothing shows.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let (folders, files) = Self.dragged(sender.draggingPasteboard)
        // Over the open palette nothing is added, and nothing is said.
        dragHoldsOnlyFiles = paletteView.isHidden && folders.isEmpty && files > 0
        guard !folders.isEmpty, paletteView.isHidden else {
            showOutline(nil)
            return []
        }
        showOutline(folders.count == 1 ? "Add \(folders[0].lastPathComponent) as a project" : "Add \(folders.count) folders as projects")
        return .copy
    }

    /// The outline with `words`, or none. On the first-launch screen it
    /// hides the words under it while it shows.
    private func showOutline(_ words: String?) {
        if let words { dropOutline.show(words, palette: palette) }
        dropOutline.setShown(words != nil)
        firstLaunch.isHidden = hasProjects || words != nil
    }

    /// The drag left, or was let go over the window and refused (AppKit
    /// says so here, with the button up): a drop of only files says it
    /// wanted a folder.
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        defer { dragHoldsOnlyFiles = false }
        showOutline(nil)
        guard dragHoldsOnlyFiles, NSEvent.pressedMouseButtons & 1 == 0, let sender,
              bounds.contains(convert(sender.draggingLocation, from: nil))
        else { return }
        onDropFiles?()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        showOutline(nil)
        let (folders, _) = Self.dragged(sender.draggingPasteboard)
        guard !folders.isEmpty else { return false }
        onDropFolders?(folders)
        return true
    }
}

/// Folders dragged over the window (native-look.md 3.11): a 2 pt ring at
/// ink 60 % 6 pt inside the window's edge, and, centred, the words on an
/// opaque raised label. It takes no pointer; it fades in over 150 ms.
final class AgentDropOutline: NSView {
    private let ring = AgentLayer()
    private let label = AgentLayer()
    private let words = AgentTextLayer()
    private(set) var text = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.borderWidth = 2
        ring.cornerRadius = 10
        ring.cornerCurve = .continuous
        label.cornerRadius = 12
        label.cornerCurve = .continuous
        label.borderWidth = 1
        label.addSublayer(words)
        layer?.addSublayer(ring)
        layer?.addSublayer(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, palette: ClawddyPalette) {
        self.text = text
        ring.borderColor = palette.ink.cgColor(alpha: 0.6)
        label.backgroundColor = palette.pop.cgColor()
        label.borderColor = ClawddyPalette.white(0.13)
        words.text = AgentText(string: text, font: AgentMetrics.empty, color: palette.ink.cgColor(), lineHeight: 20)
        needsLayout = true
    }

    /// The outline shows, or fades in.
    private(set) var isShown = false

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown, isHidden {
            isHidden = false
            layer?.opacity = 0
        }
        AgentMotion.run({
            AgentMotion.fade(layer!, to: shown ? 1 : 0, duration: AgentMotion.small, in: self)
        }, then: { [weak self] in
            guard let self, !self.isShown else { return }
            self.isHidden = true
        })
    }

    override func layout() {
        super.layout()
        ring.frame = bounds.insetBy(dx: 6, dy: 6)
        let width = (words.text?.width ?? 0) + 28
        let height: CGFloat = 20 + 16
        label.frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        words.frame = CGRect(x: 14, y: 8, width: width - 28, height: 20)
    }
}

/// What the window shows with no project (native-look.md 3.11): a framed
/// dashed drop area with the invitation and one solid primary button.
final class AgentFirstLaunchView: NSView {
    static let size = NSSize(width: 440, height: 190)

    private let dashes = AgentShapeLayer()
    private let words = AgentTextLayer()
    let choose = AgentButton()
    private let chooseLabel = AgentTextLayer()
    private let chooseKey = AgentKeyCap()
    private var palette = ClawddyPalette.prototype

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(dashes)
        layer?.addSublayer(words)
        addSubview(choose)
        choose.layer?.addSublayer(chooseLabel)
        choose.layer?.addSublayer(chooseKey)
        choose.setAccessibilityLabel("Choose a folder…")
        // Solid ink: 15 % lighter on hover, back over 150 ms on release.
        choose.fills = (0, 0.15, 0)
        dashes.fillColor = nil
        dashes.lineWidth = 1
        dashes.lineDashPattern = [4, 4]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }

    func apply(_ palette: ClawddyPalette) {
        self.palette = palette
        dashes.strokeColor = ClawddyPalette.white(0.09)
        words.text = AgentText(
            string: "Add a project to start. Drop its folder on this window, or choose one.",
            font: AgentMetrics.empty, color: palette.text3.cgColor(), lineHeight: 22, maxLines: 2, alignment: .center)
        chooseLabel.text = AgentText(string: "Choose a folder…", font: AgentMetrics.bodySemibold, color: palette.canvas.cgColor())
        chooseKey.show("⌘O", color: palette.canvas.cgColor(), fill: palette.canvas.cgColor(alpha: 0.14))
        choose.base = palette.ink
        needsLayout = true
    }

    override func layout() {
        super.layout()
        dashes.frame = bounds
        dashes.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 16, cornerHeight: 16, transform: nil)
        let textWidth = bounds.width - 60
        let lines = words.text.map { AgentTextLayer.lines(of: $0, width: textWidth).count } ?? 1
        let textHeight = CGFloat(lines) * 22
        let labelWidth = chooseLabel.text?.width ?? 0
        let keyWidth = chooseKey.bounds.width
        let buttonWidth = 14 + labelWidth + 8 + keyWidth + 14
        let buttonHeight: CGFloat = 18 + 14
        let total = textHeight + 16 + buttonHeight
        let top = ((bounds.height - total) / 2).rounded()
        words.frame = CGRect(x: 30, y: top, width: textWidth, height: textHeight)
        choose.frame = NSRect(x: ((bounds.width - buttonWidth) / 2).rounded(), y: top + textHeight + 16, width: buttonWidth, height: buttonHeight)
        chooseLabel.frame = CGRect(x: 14, y: 7, width: labelWidth, height: 18)
        let baseline = 7 + AgentMetrics.baseline(AgentMetrics.bodySemibold, lineHeight: 18)
        chooseKey.frame.origin = CGPoint(x: 14 + labelWidth + 8, y: baseline - AgentMetrics.markLift - 8)
    }
}

/// The opaque capsule at home's top or bottom edge saying how many agents
/// waiting on the person sit scrolled out of view there (ruling 13); a
/// click scrolls the nearest into view.
final class AgentEdgePill: AgentButton {
    static let height: CGFloat = 26
    /// The capsule: its fill, rim and shadow, on a layer of its own (AppKit
    /// resets a backing layer's shadow).
    private let surface = AgentLayer()
    private let dot = AgentLayer()
    private let label = AgentTextLayer()
    private(set) var count = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = false
        surface.cornerRadius = Self.height / 2
        surface.borderWidth = 1
        surface.shadowColor = CGColor(gray: 0, alpha: 1)
        surface.shadowOpacity = 0.45
        surface.shadowRadius = 7
        surface.shadowOffset = CGSize(width: 0, height: 4)
        fillLayer = surface
        dot.cornerRadius = 3
        for part in [surface, dot, label] as [CALayer] { layer?.addSublayer(part) }
        isHidden = true
    }

    /// Its width: padding 10, the dot, 6 pt, the words.
    var width: CGFloat { 10 + 6 + 6 + (label.text?.width ?? 0) + 12 }

    func show(count: Int, below: Bool, palette: ClawddyPalette) {
        self.count = count
        guard count > 0 else { return }
        base = palette.pop
        fills = (0, 0.05, 0.10)
        surface.borderColor = palette.signal.cgColor(alpha: 0.28)
        dot.backgroundColor = palette.signal.cgColor()
        let words = "\(count) waiting \(below ? "below" : "above")"
        label.text = AgentText(string: words, font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), color: palette.signal.cgColor())
        setAccessibilityLabel(words)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        surface.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.height / 2, cornerHeight: Self.height / 2, transform: nil)
        dot.frame = CGRect(x: 10, y: (bounds.height - 6) / 2, width: 6, height: 6)
        label.frame = CGRect(x: 22, y: (bounds.height - 18) / 2, width: max(0, bounds.width - 22 - 12), height: 18)
    }
}
