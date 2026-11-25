import AppKit

/// The 44 pt bar along the top of the agent window (native-look.md 3.5,
/// flows.md 1): after the window's own buttons, the projects with the
/// number of their agents waiting on the person; the status line in the
/// middle; at the right the waiting count, Find, New agent and Keys. Every
/// item is centred on the window buttons. Its empty part moves the window
/// as a title bar does.
final class AgentTopBar: NSView, AgentActivationClickSafeRegion {
    static let height: CGFloat = 44

    /// One project as the bar shows it.
    struct Project: Equatable {
        var id: UUID
        var name: String
        var agents: Int
        var waiting: Int
        var isCurrent: Bool
    }

    /// The project buttons, one per project, kept by project: a new order
    /// moves the same buttons.
    private var projectButtons: [UUID: AgentProjectButton] = [:]
    private let more = AgentButton()
    private let moreLabel = AgentTextLayer()
    private let status = AgentTextLayer()
    /// Undo after the status line, on a project's removal and a settle during
    /// a walk (flows.md 6.2, 6.6).
    let undo = AgentUndoButton()
    private let waiting = AgentButton()
    private let waitingDot = AgentLayer()
    private let waitingLabel = AgentTextLayer()
    private let find = AgentButton()
    private let new = AgentButton()
    private let keys = AgentButton()
    private var icons: [(AgentButton, AgentSymbolLayer, String)] = []
    private var statusEnd: DispatchWorkItem?
    /// Each line said or ended bumps it: an older fade's end does nothing.
    private var statusMotion = 0
    /// A sentence that stays in the status line while what it says holds
    /// (a change that could not be saved, last review ruling 1); a passing
    /// line replaces it for its time, and it comes back after.
    private(set) var notice: String?
    /// Undo acts: the line showing it has not ended. What takes the pointer
    /// follows this at once, also while Undo fades out.
    private var undoActs = false

    private var projects: [Project] = []
    /// The projects the bar shows, after those that do not fit went into
    /// "N more".
    private(set) var shownProjects: [Project] = []
    private var overflow: [Project] = []
    private(set) var waitingCount = 0
    private var walkPosition: String?
    private(set) var palette: ClawddyPalette = .prototype

    var onProject: ((UUID) -> Void)?
    /// A project's menu, for a right-click or Control-click on its name and
    /// for its entry in "N more" (ruling 33, 34).
    var menuForProject: ((UUID) -> NSMenu)?
    /// The menu of the bar's empty part: Add a project folder….
    var barMenu: (() -> NSMenu)?
    /// A project dragged along the bar and dropped: its new place in the
    /// projects' order.
    var onMoveProject: ((UUID, Int) -> Void)?
    /// Shows a menu where the person clicked (the system's own); with no
    /// event, under `view`. A harness run records it instead: a menu would
    /// hold the run and could show on the person's screen.
    var showMenu: (NSMenu, NSEvent?, NSView) -> Void = { menu, event, view in
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
        }
    }
    var onWaiting: (() -> Void)?
    var onFind: (() -> Void)?
    var onNew: (() -> Void)?
    var onKeys: (() -> Void)?
    var onUndo: (() -> Void)?
    /// The 1 pt hairline along the bar's bottom, shown while home is
    /// scrolled down (native-look.md 3.5).
    private let edge = AgentLayer()
    var showsEdge = false { didSet { edge.isHidden = !showsEdge } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(status)
        status.opacity = 0
        edge.backgroundColor = ClawddyPalette.white(0.07)
        edge.isHidden = true
        layer?.addSublayer(edge)
        addSubview(undo)
        undo.isHidden = true
        undo.onPress = { [weak self] in self?.onUndo?() }
        addSubview(more)
        more.fills = (0, 0.04, 0.08)
        more.layer?.addSublayer(moreLabel)
        more.onPhase = { [weak self] _ in self?.styleMore() }
        more.onPress = { [weak self] in self?.showMore() }
        addSubview(waiting)
        waiting.fills = (0, 0.05, 0.10)
        waitingDot.cornerRadius = 3.5
        for part in [waitingDot, waitingLabel] as [CALayer] { waiting.layer?.addSublayer(part) }
        waiting.onPress = { [weak self] in self?.onWaiting?() }
        icons = [(find, AgentSymbolLayer(), "magnifyingglass"), (new, AgentSymbolLayer(), "plus"), (keys, AgentSymbolLayer(), "questionmark")]
        for (button, symbol, _) in icons {
            addSubview(button)
            button.fills = (0, 0.05, 0.10)
            button.layer?.addSublayer(symbol)
        }
        find.onPress = { [weak self] in self?.onFind?() }
        new.onPress = { [weak self] in self?.onNew?() }
        keys.onPress = { [weak self] in self?.onKeys?() }
        find.toolTip = "Find an agent or run a command (⌘P)"
        new.toolTip = "New agent (⌘N)"
        keys.toolTip = "Keys (⌘?)"
        find.setAccessibilityLabel("Find")
        new.setAccessibilityLabel("New agent")
        keys.setAccessibilityLabel("Keys")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The empty part of the bar is where the title bar would be: it moves
    /// the window, and a double-click does what the person set for a title
    /// bar's (System Settings › Desktop & Dock).
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }

    /// A right-click on the bar's empty part: Add a project folder….
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = barMenu?() else { return }
        showMenu(menu, event, self)
    }

    /// Shows the projects and the waiting count; `walk` is the walk's
    /// position ("2 of 6 waiting") while one is under way.
    func show(projects: [Project], waiting count: Int, walk: String? = nil, palette: ClawddyPalette) {
        guard projects != self.projects || count != waitingCount || walk != walkPosition || palette != self.palette else { return }
        let ids = projects.map(\.id)
        // A new order of the same projects (a drop, Move left or right):
        // the buttons glide to their places.
        glidesToOrder = ids != self.projects.map(\.id) && Set(ids) == Set(self.projects.map(\.id))
        // A project that came or went during a drag ends it.
        if drag != nil, Set(ids) != Set(self.projects.map(\.id)) { cancelDrag() }
        self.projects = projects
        waitingCount = count
        walkPosition = walk
        self.palette = palette
        for (id, button) in projectButtons where !ids.contains(id) {
            button.removeFromSuperview()
            projectButtons[id] = nil
        }
        for id in ids where projectButtons[id] == nil {
            let button = AgentProjectButton()
            // The current project's name is not a button to switch: it
            // shows no hover or press, and a click on it does nothing.
            button.onPress = { [weak self] in
                guard let self, self.projects.first(where: { $0.id == id })?.isCurrent == false else { return }
                self.onProject?(id)
            }
            button.onRightClick = { [weak self, weak button] event in
                guard let self, let button, let menu = self.menuForProject?(id) else { return }
                self.showMenu(menu, event, button)
            }
            button.onShowMenu = { [weak self, weak button] in
                guard let self, let button, let menu = self.menuForProject?(id) else { return }
                self.showMenu(menu, nil, button)
            }
            button.projectMenu = { [weak self] in self?.menuForProject?(id) }
            button.onDrag = { [weak self] event, pressedAt in self?.dragged(id, event, pressedAt: pressedAt) }
            button.onDrop = { [weak self] in self?.dropped() }
            addSubview(button, positioned: .below, relativeTo: more)
            projectButtons[id] = button
        }
        let hasProjects = !projects.isEmpty
        waiting.isHidden = !hasProjects
        find.isHidden = !hasProjects
        let waitingColor = count > 0 || walk != nil ? palette.signal : palette.text3
        waitingDot.backgroundColor = (count > 0 || walk != nil ? palette.signal : palette.text4).cgColor()
        waitingLabel.text = AgentText(
            string: walk ?? AgentWaitingWords.count(count), font: AgentMetrics.digits13, color: waitingColor.cgColor())
        // With no one waiting and no walk it can do nothing: drawn as not a
        // button (ruling 32).
        let acts = count > 0 || walk != nil
        waiting.isEnabled = acts
        waiting.toolTip = acts ? "Go to the next agent waiting on you (⌘J)" : nil
        waiting.setAccessibilityHelp(acts ? "Goes to the next agent waiting on you" : nil)
        // While walking VoiceOver hears the position, and the total too.
        waiting.setAccessibilityLabel(walk ?? AgentWaitingWords.count(count))
        waiting.setAccessibilityValue(walk == nil ? nil : AgentWaitingWords.count(count))
        for (button, symbol, name) in icons {
            symbol.symbol = .init(name: name, pointSize: 13, weight: .medium, color: palette.text2, box: 28, scale: AgentMetrics.scale)
            _ = button
        }
        needsLayout = true
    }

    /// Says `text` in the middle of the bar for `seconds`: it fades in over
    /// 150 ms, holds, and fades out over 200 ms; a new line replaces it at
    /// once. VoiceOver announces it.
    func say(_ text: String, for seconds: TimeInterval = 1.8, undoable: Bool = false) {
        statusEnd?.cancel()
        let replacing = status.opacity > 0
        status.text = AgentText(string: text, font: AgentMetrics.body, color: palette.text2.cgColor(), alignment: .center)
        undo.show(palette: palette)
        undo.isHidden = !undoable
        for layer in [status, undo.layer].compactMap({ $0 }) {
            if replacing {
                layer.removeAnimation(forKey: "opacity")
                layer.opacity = 1
            } else {
                AgentMotion.fade(layer, to: 1, duration: AgentMotion.small, in: self)
            }
        }
        statusMotion += 1
        undoActs = undoable
        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statusEnd = nil
            // Undo takes no pointer from now (motion review ruling 1); it is
            // hidden as its fade ends, unless a newer line came meanwhile.
            self.undoActs = false
            if self.notice != nil { return self.showNoticeNow() }
            self.statusMotion += 1
            let motion = self.statusMotion
            AgentMotion.run({
                AgentMotion.fade(self.status, to: 0, duration: AgentMotion.big, in: self)
                if let layer = self.undo.layer { AgentMotion.fade(layer, to: 0, duration: AgentMotion.big, in: self) }
            }, then: { [weak self] in
                guard let self, self.statusMotion == motion else { return }
                self.undo.isHidden = true
            })
        }
        statusEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: end)
        NSAccessibility.post(
            element: NSApp.mainWindow as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        needsLayout = true
    }

    /// Keeps `text` in the status line until it is set to nil.
    func showNotice(_ text: String?) {
        guard text != notice else { return }
        notice = text
        // A passing line keeps its time; the notice follows it.
        guard statusEnd == nil else { return }
        if text != nil {
            showNoticeNow()
        } else {
            statusMotion += 1
            AgentMotion.fade(status, to: 0, duration: AgentMotion.big, in: self)
        }
    }

    private func showNoticeNow() {
        guard let notice else { return }
        statusMotion += 1
        undo.isHidden = true
        status.text = AgentText(string: notice, font: AgentMetrics.body, color: palette.text2.cgColor(), alignment: .center)
        if status.opacity < 1 { AgentMotion.fade(status, to: 1, duration: AgentMotion.small, in: self) }
        needsLayout = true
    }

    /// Where the Keys button is, in the bar.
    var keysButtonFrame: NSRect? { keys.isHidden ? nil : keys.frame }
    /// Where the New agent button is, for tests and the harness.
    var newButtonFrame: NSRect? { new.isHidden ? nil : new.frame }
    /// Where the Find button is, for tests and the harness.
    var findButtonFrame: NSRect? { find.isHidden ? nil : find.frame }

    /// What the waiting count says: "N waiting on you", or the walk's
    /// position.
    var waitingWords: String { waitingLabel.text?.string ?? "" }

    /// What the status line says now, while it shows.
    var statusLine: String? { status.opacity > 0 ? status.text?.string : nil }
    /// The status line shows its Undo.
    var showsUndo: Bool { !undo.isHidden && undoActs }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        if !undoActs, let view, view === undo || view.isDescendant(of: undo) { return self }
        return view
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        edge.frame = CGRect(x: 0, y: Self.height - 1, width: width, height: 1)
        let controls = windowControlsFrame
        let centre = controls?.midY ?? Self.height / 2
        let lineTop = AgentMetrics.snap(centre - 9)

        // The right group, from the right edge: Keys, New agent, Find, the
        // waiting count, 6 pt apart.
        var right = width - 12
        for button in [keys, new, find] where !button.isHidden {
            let frame = NSRect(x: right - 28, y: AgentMetrics.snap(centre - 14), width: 28, height: 28)
            if button.frame != frame { button.frame = frame }
            icons.first { $0.0 === button }?.1.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
            right = frame.minX - 6
        }
        if !waiting.isHidden {
            let textWidth = waitingLabel.text?.width ?? 0
            let buttonWidth = 10 + 7 + 7 + textWidth + 10
            let frame = NSRect(x: right - buttonWidth, y: AgentMetrics.snap(centre - 13), width: buttonWidth, height: 26)
            if waiting.frame != frame { waiting.frame = frame }
            let baseline = lineTop - frame.minY + AgentMetrics.baseline(AgentMetrics.digits13, lineHeight: 18)
            waitingDot.frame = CGRect(x: 10, y: AgentMetrics.snap(baseline - AgentMetrics.markLift - 3.5), width: 7, height: 7)
            waitingLabel.frame = CGRect(x: 24, y: lineTop - frame.minY, width: textWidth, height: 18)
            right = frame.minX - 6
        }

        // The projects, from after the window buttons, 2 pt apart; those
        // that do not fit go into "N more", the current one always shown.
        let left = (controls.map { $0.maxX + 18 } ?? 12).rounded()
        let room = max(0, right - 24 - left)
        layoutProjects(left: left, room: room, centre: centre, lineTop: lineTop)
        let projectsEnd = ([more] + Array(projectButtons.values)).filter { !$0.isHidden }.map(\.frame.maxX).max() ?? left

        // The status line in the middle, with its Undo 10 pt after it,
        // shortened with "…" between the projects and the right group.
        let undoWidth = undo.isHidden ? 0 : undo.width + 10
        let statusWidth = status.text?.width ?? 0
        let lowest = projectsEnd + 12
        let highest = right - 12 - undoWidth
        var statusFrame = CGRect(x: ((width - statusWidth - undoWidth) / 2).rounded(), y: lineTop, width: statusWidth, height: 18)
        if statusFrame.minX < lowest { statusFrame.origin.x = lowest }
        if statusFrame.maxX > highest { statusFrame.size.width = max(0, highest - statusFrame.minX) }
        status.frame = statusFrame
        if !undo.isHidden {
            let frame = NSRect(x: statusFrame.maxX + 10, y: AgentMetrics.snap(centre - AgentUndoButton.height / 2), width: undo.width, height: AgentUndoButton.height)
            if undo.frame != frame { undo.frame = frame }
        }
    }

    private func layoutProjects(left: CGFloat, room: CGFloat, centre: CGFloat, lineTop: CGFloat) {
        let widths = projects.map { AgentProjectButton.width(of: $0) }
        var fitting = projects.count
        var total = widths.reduce(0, +) + CGFloat(max(0, projects.count - 1)) * 2
        if total > room {
            // Leave room for "N more" and keep the current project in view.
            fitting = 0
            total = 0
            let moreWidth: CGFloat = 80
            for width in widths {
                if total + width + 2 + moreWidth > room { break }
                total += width + 2
                fitting += 1
            }
        }
        var shown = Array(projects.prefix(fitting))
        overflow = Array(projects.dropFirst(fitting))
        if let current = overflow.firstIndex(where: \.isCurrent), !shown.isEmpty {
            overflow.append(shown.removeLast())
            shown.append(overflow.remove(at: current))
        }
        shownProjects = shown
        projectsLeft = left
        projectsTop = AgentMetrics.snap(centre - 13)
        let shownIDs = Set(shown.map(\.id))
        for project in projects {
            guard let button = projectButtons[project.id] else { continue }
            button.isHidden = !shownIDs.contains(project.id)
            guard !button.isHidden else { continue }
            button.show(project, palette: palette)
            let size = NSSize(width: AgentProjectButton.width(of: project), height: 26)
            if button.frame.size != size { button.frame.size = size }
            button.layoutContent(lineTop: lineTop - projectsTop)
        }
        // While a project is dragged its place and the others' follow the
        // pointer, not the order.
        if drag == nil { placeProjects(shown.map(\.id), gliding: glidesToOrder) }
        glidesToOrder = false
        more.isHidden = overflow.isEmpty
        if !overflow.isEmpty {
            styleMore()
            let width = (moreLabel.text?.width ?? 0) + 20
            let x = slots(shown.map(\.id)).last.map { $0.maxX + 2 } ?? left
            let frame = NSRect(x: x, y: projectsTop, width: width, height: 26)
            if more.frame != frame { more.frame = frame }
            moreLabel.frame = CGRect(x: 10, y: lineTop - frame.minY, width: width - 20, height: 18)
        }
    }

    /// Where each of `ids` sits, in that order from the left, 2 pt apart.
    private func slots(_ ids: [UUID]) -> [NSRect] {
        var x = projectsLeft
        return ids.map { id in
            let width = projectButtons[id]?.frame.width ?? 0
            defer { x += width + 2 }
            return NSRect(x: x, y: projectsTop, width: width, height: 26)
        }
    }

    /// Puts each of `ids` at its place in that order, gliding there from
    /// where it is on screen (150 ms on the one curve, retargeting; at once
    /// under Reduce Motion or unseen) or at once.
    private func placeProjects(_ ids: [UUID], gliding: Bool, except lifted: UUID? = nil) {
        for (id, slot) in zip(ids, slots(ids)) where id != lifted {
            guard let button = projectButtons[id], button.frame.origin != slot.origin else { continue }
            glide(button, to: slot.origin, animated: gliding)
        }
    }

    private func glide(_ button: AgentProjectButton, to origin: NSPoint, animated: Bool) {
        guard let layer = button.layer else { return }
        let duration = animated ? AgentMotion.duration(.move(AgentMotion.small), in: self) : 0
        let before = layer.position
        button.frame.origin = origin
        guard duration > 0 else { return }
        AgentMotion.animate(layer, "position", to: NSValue(point: layer.position), duration: duration, from: NSValue(point: before))
    }

    // MARK: Moving a project by the pointer (ruling 33)

    /// The project moved by the pointer: where on it the pointer took it,
    /// and the place among the other shown projects it would land in.
    private var drag: (id: UUID, grab: CGFloat, gap: Int)?
    private var glidesToOrder = false
    private var projectsLeft: CGFloat = 0
    private var projectsTop: CGFloat = 0

    /// A project is being moved by the pointer.
    var isDragging: Bool { drag != nil }

    /// The dragged project follows the pointer exactly, along the bar; the
    /// others glide to make room, the gap where its centre passes theirs.
    private func dragged(_ id: UUID, _ event: NSEvent, pressedAt: NSPoint) {
        let shownIDs = shownProjects.map(\.id)
        guard let button = projectButtons[id], shownIDs.contains(id) else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if drag == nil {
            // Held where it was pressed, however far the first move went:
            // it follows the pointer exactly.
            drag = (id, convert(pressedAt, from: nil).x - button.frame.minX, shownIDs.firstIndex(of: id) ?? 0)
            addSubview(button, positioned: .above, relativeTo: nil)
            button.setLifted(true)
        }
        guard var drag else { return }
        let rest = shownIDs.filter { $0 != id }
        let width = button.frame.width
        let span = slots(shownIDs).last.map { $0.maxX } ?? projectsLeft
        let minX = (x - drag.grab).clamped(to: projectsLeft...max(projectsLeft, span - width))
        let centre = minX + width / 2
        drag.gap = zip(rest, slots(rest)).filter { $0.1.midX + (width + 2) / 2 < centre }.count
        self.drag = drag
        var preview = rest
        preview.insert(id, at: drag.gap)
        placeProjects(preview, gliding: true, except: id)
        button.frame.origin = NSPoint(x: minX, y: projectsTop)
    }

    /// Released: the project lands in the gap, the order is saved at once
    /// (`onMoveProject`), and every project glides to its place.
    private func dropped() {
        guard let drag else { return }
        self.drag = nil
        projectButtons[drag.id]?.setLifted(false)
        let rest = shownProjects.map(\.id).filter { $0 != drag.id }
        // It lands right after the name now on its left (before the first
        // when it is first), also when the current project stands in for
        // one in "N more".
        var order = projects.map(\.id).filter { $0 != drag.id }
        if drag.gap > 0, let after = order.firstIndex(of: rest[drag.gap - 1]) {
            order.insert(drag.id, at: after + 1)
        } else if let first = rest.first, let before = order.firstIndex(of: first) {
            order.insert(drag.id, at: before)
        } else {
            order = projects.map(\.id)
        }
        if order != projects.map(\.id), let index = order.firstIndex(of: drag.id) {
            onMoveProject?(drag.id, index)
        } else {
            placeProjects(shownProjects.map(\.id), gliding: true)
        }
    }

    /// Escape during a drag: every project glides back to its place.
    func cancelDrag() {
        guard let drag else { return }
        self.drag = nil
        projectButtons[drag.id]?.setLifted(false)
        projectButtons[drag.id]?.endDrag()
        placeProjects(shownProjects.map(\.id), gliding: true)
    }

    /// The button of a project shown in the bar, for tests and the harness.
    func button(of id: UUID) -> AgentProjectButton? {
        projectButtons[id].flatMap { $0.isHidden ? nil : $0 }
    }

    /// Where the "N more" button is, in the bar, when it shows.
    var moreButtonFrame: NSRect? { more.isHidden ? nil : more.frame }

    private func styleMore() {
        let color = more.phase == .rest ? palette.text3 : palette.text2
        moreLabel.text = AgentText(string: "\(overflow.count) more", font: AgentMetrics.body, color: color.cgColor())
        more.setAccessibilityLabel("\(overflow.count) more projects")
    }

    /// The projects that do not fit, as a menu with their counts. Each
    /// entry's submenu goes to the project and holds its menu (ruling 34).
    func moreMenu() -> NSMenu {
        let menu = NSMenu()
        for project in overflow {
            let title = project.waiting > 0 ? "\(project.name)  \(project.waiting)" : project.name
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = menuForProject?(project.id) ?? NSMenu()
            submenu.insertItem(NSMenuItem(title: "Go to \(project.name)") { [weak self] in self?.onProject?(project.id) }, at: 0)
            submenu.insertItem(.separator(), at: 1)
            entry.submenu = submenu
            menu.addItem(entry)
        }
        return menu
    }

    private func showMore() {
        showMenu(moreMenu(), nil, more)
    }
}

/// A project's name in the bar, with its number of agents waiting on the
/// person when it has any.
final class AgentProjectButton: AgentButton {
    private let name = AgentTextLayer()
    private let count = AgentTextLayer()
    /// The fill and, picked up, its shadows: layers of its own, which
    /// AppKit leaves alone.
    private let surface = AgentLayer()
    private let under = AgentLayer()
    private(set) var project: AgentTopBar.Project?
    private var palette: ClawddyPalette = .prototype
    /// The project's menu, for VoiceOver's actions; `onShowMenu` shows it.
    var projectMenu: (() -> NSMenu?)?
    var onShowMenu: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        fills = (0, 0.04, 0.08)
        layer?.masksToBounds = false
        for part in [under, surface] {
            part.cornerRadius = 8
            part.cornerCurve = .continuous
            part.shadowColor = CGColor(gray: 0, alpha: 1)
            part.shadowOpacity = 0
        }
        fillLayer = surface
        for part in [under, surface, name, count] as [CALayer] { layer?.addSublayer(part) }
        onPhase = { [weak self] _ in self?.style() }
    }

    override func layout() {
        super.layout()
        for part in [under, surface] where part.frame != bounds { part.frame = bounds }
    }

    /// Picked up by a drag: the raised surface and the two shadows of a
    /// picked up tile (native-look.md 2.6), the shadow fading in over 150 ms
    /// and out as it lands.
    func setLifted(_ lifted: Bool) {
        base = lifted ? palette.raised : nil
        let fade = AgentMotion.duration(.move(AgentMotion.small), in: self)
        for (part, opacity, radius, offset) in [(surface, 0.45, 17.0, 14.0), (under, 0.30, 3.0, 2.0)] {
            AgentMotion.animate(part, "shadowOpacity", to: lifted ? Float(opacity) : 0, duration: fade)
            part.shadowRadius = radius
            part.shadowOffset = CGSize(width: 0, height: offset)
            part.shadowPath = CGPath.continuousRoundedRect(bounds, radius: 8)
        }
    }

    /// It is picked up: on its raised surface.
    var isLifted: Bool { base != nil }

    /// VoiceOver's "show menu" opens the project's menu under the name.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let onShowMenu else { return false }
        onShowMenu()
        return true
    }

    /// The menu's enabled items as VoiceOver actions, so each is reachable
    /// without the menu (ruling 33).
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let menu = projectMenu?() else { return nil }
        return menu.items.enumerated().compactMap { index, item in
            guard !item.isSeparatorItem, item.isEnabled else { return nil }
            return NSAccessibilityCustomAction(name: item.title) {
                menu.performActionForItem(at: index)
                return true
            }
        }
    }

    /// The name, cut with "…" after 24 characters.
    static func title(_ name: String) -> String {
        name.count > 24 ? String(name.prefix(24)) + "…" : name
    }

    static func nameText(_ project: AgentTopBar.Project, color: CGColor) -> AgentText {
        AgentText(
            string: title(project.name),
            font: project.isCurrent ? AgentMetrics.bodySemibold : AgentMetrics.body,
            color: color)
    }

    static func countText(_ project: AgentTopBar.Project, color: CGColor) -> AgentText? {
        guard project.waiting > 0 else { return nil }
        // On the name's baseline.
        var text = AgentText(string: "\(project.waiting)", font: AgentMetrics.digits11Medium, color: color)
        text.baseline = AgentMetrics.baseline(AgentMetrics.body, lineHeight: 18)
        return text
    }

    /// Its width: padding 4 10, the name, and the count's slot: 7 pt then
    /// two digits of the count's font, empty while nothing waits. The name
    /// is measured in its semibold weight whether or not the project is
    /// current, so no project moves when another becomes current, and the
    /// slot is kept at zero, so none moves when a count appears, changes or
    /// goes (a count of three digits takes what it needs).
    static func width(of project: AgentTopBar.Project) -> CGFloat {
        let black = CGColor(gray: 0, alpha: 1)
        var current = project
        current.isCurrent = true
        let slot = AgentText(string: "00", font: AgentMetrics.digits11Medium, color: black).width
        let count = max(slot, countText(project, color: black)?.width ?? 0)
        return 10 + nameText(current, color: black).width + 7 + count + 10
    }

    func show(_ project: AgentTopBar.Project, palette: ClawddyPalette) {
        self.project = project
        self.palette = palette
        // The current project shows no fill of its own.
        fills = project.isCurrent ? (0, 0, 0) : (0, 0.04, 0.08)
        style()
        let agents = project.agents == 1 ? "1 agent" : "\(project.agents) agents"
        let waiting = project.waiting > 0 ? ", \(project.waiting) waiting" : ""
        toolTip = "\(project.name), \(agents)\(waiting)"
        setAccessibilityLabel(project.name)
        setAccessibilityValue([project.isCurrent ? "current" : nil, agents, project.waiting > 0 ? "\(project.waiting) waiting" : nil]
            .compactMap { $0 }.joined(separator: ", "))
    }

    private func style() {
        guard let project else { return }
        let color = project.isCurrent ? palette.ink : phase == .rest ? palette.text3 : palette.text2
        name.text = Self.nameText(project, color: color.cgColor())
        count.text = Self.countText(project, color: palette.text2.cgColor())
    }

    /// The name and the count on one baseline, `lineTop` down from the
    /// button's top.
    func layoutContent(lineTop: CGFloat) {
        let nameWidth = name.text?.width ?? 0
        name.frame = CGRect(x: 10, y: lineTop, width: nameWidth, height: 18)
        let countWidth = count.text?.width ?? 0
        count.frame = CGRect(x: 10 + nameWidth + 7, y: lineTop, width: countWidth, height: 18)
    }
}
