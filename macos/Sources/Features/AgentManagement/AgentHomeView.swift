import AppKit

/// Where home puts each tile (native-look.md 3.3 "Grid" and "Rows",
/// flows.md "Home"): columns from the width alone, rows of the visible height
/// from the density alone, never from how many agents there are; a tile's
/// frame is a function of its place and these. Rows that do not fit scroll.
struct AgentHomeLayout: Equatable {
    static let sides: CGFloat = 24
    static let top: CGFloat = 4
    /// As the gap between rows, so a row that does not fit starts exactly at
    /// the visible bottom and never peeks into view.
    static let bottom: CGFloat = 12
    static let gap: CGFloat = 12
    /// The least row height a density may give.
    static let leastRow: CGFloat = 132

    /// The grid's width, and the height of what scrolls into view.
    var width: CGFloat
    var visibleHeight: CGFloat
    /// The person's choice: rows more (positive) or fewer than the default.
    var density: Int
    var scale: CGFloat = AgentMetrics.scale

    var columns: Int { max(1, Int(((width - 2 * Self.sides + Self.gap) / 312).rounded(.down))) }
    var tileWidth: CGFloat {
        (width - 2 * Self.sides - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
    }
    /// The visible height tiles share.
    private var rowSpace: CGFloat { max(0, visibleHeight - Self.top - Self.bottom) }
    /// Chosen from the window's height below the top bar alone, the line's
    /// room included, so a point of rounding in what the line leaves never
    /// takes a row away (846 pt: 3 rows; flows.md 9).
    var defaultRows: Int { max(2, Int(((visibleHeight + AgentLineView.reserved) / 290).rounded())) }
    /// As many rows as keep each at least `leastRow` tall.
    var mostRows: Int { max(1, Int(((rowSpace + Self.gap) / (Self.leastRow + Self.gap)).rounded(.down))) }
    var rows: Int { min(max(defaultRows + density, 1), mostRows) }
    /// Rounded up: the rows that fit then reach at least the visible
    /// bottom less `bottom`, so the next row starts at or below the visible
    /// bottom and never peeks into view; the bottom margin gives up to a
    /// point a row.
    var rowHeight: CGFloat {
        ((rowSpace - Self.gap * CGFloat(rows - 1)) / CGFloat(rows)).rounded(.up)
    }

    /// The density clamped to the rows there can be.
    func clamped(_ density: Int) -> Int { min(max(defaultRows + density, 1), mostRows) - defaultRows }

    /// The tile at `index`, every edge on a device pixel; columns keep one
    /// pitch.
    func frame(at index: Int) -> CGRect {
        let column = index % columns
        let row = index / columns
        let left = AgentMetrics.snap(Self.sides + CGFloat(column) * (tileWidth + Self.gap), scale: scale)
        let right = AgentMetrics.snap(Self.sides + CGFloat(column) * (tileWidth + Self.gap) + tileWidth, scale: scale)
        return CGRect(x: left, y: Self.top + CGFloat(row) * (rowHeight + Self.gap), width: right - left, height: rowHeight)
    }

    /// The height of the grid with `count` tiles: at least what is visible.
    func contentHeight(count: Int) -> CGFloat {
        let rowsUsed = (count + columns - 1) / columns
        let used = Self.top + CGFloat(rowsUsed) * (rowHeight + Self.gap) - Self.gap + Self.bottom
        return max(visibleHeight, used)
    }
}

/// The selection at home (flows.md 3.1, rulings 1 to 4): a cursor, the
/// tiles selected with it, and the anchor of a Shift range. A pure value:
/// each move takes the project's tiles in their order.
struct AgentTileSelection: Equatable {
    enum Direction { case left, right, up, down }

    private(set) var cursor: UUID?
    private(set) var selected: Set<UUID> = []
    private(set) var anchor: UUID?

    var isEmpty: Bool { cursor == nil }

    /// Only `id` selected, the cursor and the anchor.
    static func only(_ id: UUID) -> Self {
        var selection = Self()
        selection.cursor = id
        selection.selected = [id]
        selection.anchor = id
        return selection
    }

    /// An arrow: the cursor one tile over, stepping over the places of
    /// settled agents (`skipping`), or with nothing selected the first tile
    /// (Down, Right) or the last (Up, Left); at an edge nothing. `extend`
    /// (Shift) selects the range from the anchor to the cursor, so moving
    /// back toward the anchor deselects.
    mutating func move(_ direction: Direction, extend: Bool, in ids: [UUID], columns: Int, skipping: Set<UUID> = []) {
        let live = ids.filter { !skipping.contains($0) }
        guard !live.isEmpty else { return }
        guard let cursor, let index = ids.firstIndex(of: cursor) else {
            self = .only(direction == .down || direction == .right ? live[0] : live[live.count - 1])
            return
        }
        let step = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columns
        case .down: columns
        }
        var target = index + step
        // No wrap at a row's ends.
        if direction == .left || direction == .right, target < 0 || target / columns != index / columns { return }
        while ids.indices.contains(target), skipping.contains(ids[target]) { target += step }
        guard ids.indices.contains(target) else { return }
        let next = ids[target]
        guard extend else {
            self = .only(next)
            return
        }
        let anchor = anchor.flatMap(ids.firstIndex(of:)) ?? index
        self.cursor = next
        self.anchor = ids[anchor]
        selected = Set(ids[min(anchor, target)...max(anchor, target)].filter { !skipping.contains($0) })
    }

    /// ⌘A: every tile, the cursor kept, or the first tile's.
    mutating func selectAll(_ ids: [UUID]) {
        guard let first = ids.first else { return }
        selected = Set(ids)
        cursor = cursor.flatMap { ids.contains($0) ? $0 : nil } ?? first
        anchor = cursor
    }

    /// Escape: several collapse to the cursor, then none; with none,
    /// nothing.
    mutating func escape() {
        guard let cursor else { return }
        self = selected.count > 1 ? .only(cursor) : Self()
    }

    /// A press on a tile: it becomes the cursor; a tile already in a
    /// selection of several keeps that selection. With `toggles` (⇧ or ⌘)
    /// it is added or removed; removing the cursor makes the first
    /// remaining selected tile the cursor, or clears the selection.
    mutating func press(_ id: UUID, toggles: Bool, in ids: [UUID]) {
        guard toggles else {
            if selected.contains(id), selected.count > 1 {
                cursor = id
            } else {
                self = .only(id)
            }
            return
        }
        if selected.contains(id) {
            selected.remove(id)
            if cursor == id {
                cursor = ids.first(where: selected.contains)
                anchor = cursor
            }
        } else {
            selected.insert(id)
            cursor = id
            anchor = id
        }
        if selected.isEmpty { self = Self() }
    }

    /// Forgets tiles that are no longer there.
    mutating func keep(_ ids: [UUID]) {
        let present = Set(ids)
        selected.formIntersection(present)
        if let cursor, !present.contains(cursor) { self.cursor = ids.first(where: selected.contains) }
        if let anchor, !present.contains(anchor) { self.anchor = self.cursor }
        if self.cursor == nil { self = Self() }
    }
}

/// What home asks of its owner.
@MainActor
struct AgentHomeActions {
    /// Opens the agent on purpose: Return, a click.
    var enter: (UUID) -> Void = { _ in }
    /// A printable key on the tiles, as typed.
    var type: (NSEvent) -> Void = { _ in }
    /// The selection changed.
    var select: (AgentTileSelection) -> Void = { _ in }
    /// Return with several tiles selected: the keys go to the line.
    var toLine: () -> Void = {}
    /// The selection as it is: the model's, its one home.
    var selection: () -> AgentTileSelection = { AgentTileSelection() }
    /// A tile's last screen lines: its live terminal's, else nil.
    var screen: (UUID) -> String? = { _ in nil }
    /// The project's agents in a new order (flows.md 3.5).
    var reorder: ([UUID]) -> Void = { _ in }
    /// A tile's menu.
    var menu: (UUID) -> NSMenu = { _ in NSMenu() }
    /// The Undo of a settled place.
    var undo: () -> Void = {}
    /// A press or a right-click gives the tiles the keys, through the
    /// window's one way of moving them.
    var takeKeys: () -> Void = {}
    /// Edit ▸ Copy with the tiles in focus: the selected agents' sentences.
    var copy: () -> Void = {}
}

/// The tiles of the current project, placed by `AgentHomeLayout`, and the
/// keyboard at home while the tiles have it (flows.md 3.1, 3.2). Tiles are
/// made once per agent and kept while the agent is home; a tile's frame is
/// set only when its place or the layout changes. It draws nothing itself.
final class AgentHomeGrid: AgentFlippedView {
    private(set) var tiles: [UUID: AgentTileView] = [:]
    /// Every place at home, in order: the agents, and the places settled
    /// agents leave until the person leaves home.
    private(set) var order: [UUID] = []
    /// The places of settled agents (flows.md 6.7).
    private(set) var settled: Set<UUID> = []
    /// The agents at home, without the settled places.
    var live: [UUID] { order.filter { !settled.contains($0) } }
    private(set) var layout = AgentHomeLayout(width: 0, visibleHeight: 0, density: 0)
    /// The selection, read from its one home (`AgentWorkspaceModel`).
    var selection: AgentTileSelection { actions.selection() }
    private(set) var palette = ClawddyPalette.prototype
    var font = AgentTerminalFont.fallback {
        didSet { if font != oldValue { tiles.values.forEach { $0.font = font } } }
    }
    var actions = AgentHomeActions()
    /// Layout passes, for the tests that a change of state lays out nothing.
    private(set) var layouts = 0

    override var acceptsFirstResponder: Bool { true }

    // MARK: Accessibility

    /// A list of the project's agents, its selection the selected tiles.
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Agents" }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilitySelectedChildren() -> [Any]? {
        order.filter(selection.selected.contains).compactMap { tiles[$0] }
    }
    override func becomeFirstResponder() -> Bool {
        defer { syncSelection() }
        return true
    }
    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.syncSelection() }
        return true
    }

    /// The tiles have the keyboard.
    var hasKeys: Bool { window?.firstResponder === self }

    private var density = 0

    /// The layout for the scroll view's size and the density.
    private var currentLayout: AgentHomeLayout {
        let size = enclosingScrollView?.bounds.size ?? .zero
        return AgentHomeLayout(width: size.width, visibleHeight: size.height, density: density)
    }

    /// Lays the tiles out again for the scroll view's size: a window resize.
    func relayout() {
        let next = currentLayout
        guard next != layout else { return }
        layout = next
        placeTiles()
        revealCursor()
    }

    /// Shows `agents` in their order, `settled` of them as settled places,
    /// those in `undoable` with Undo; tiles are reused by agent.
    func show(
        agents: [AgentInstance], settled: Set<UUID> = [], undoable: Set<UUID> = [], density: Int, palette: ClawddyPalette,
        ghosts: Bool = false
    ) {
        self.density = density
        let layout = currentLayout
        self.palette = palette
        let ids = agents.map(\.id)
        var newTiles: [AgentTileView] = []
        for (id, tile) in tiles where !ids.contains(id) {
            // A tile that goes from the home shown (a cancelled start) fades
            // where it was, in 100 ms.
            if ghosts, tile.isOnScreen { fadeAway(tile) }
            tile.removeFromSuperview()
            tiles[id] = nil
        }
        for agent in agents where tiles[agent.id] == nil {
            let tile = AgentTileView(agent: agent, palette: palette, font: font)
            tile.screenText = { [weak self] id in self?.actions.screen(id) }
            tile.holdsStill = { [weak self] in (self?.enclosingScrollView as? AgentHomeView)?.isScrolling ?? false }
            tile.onPress = { [weak self] id, event in self?.press(id, event) }
            tile.onClick = { [weak self] id in self?.actions.enter(id) }
            tile.onDrag = { [weak self] id, event, pressedAt in self?.dragged(id, event, pressedAt: pressedAt) }
            tile.onDrop = { [weak self] in self?.dropped() }
            tile.onRightClick = { [weak self] id, event in self?.rightClicked(id, event) }
            tile.onUndo = { [weak self] in self?.actions.undo() }
            addSubview(tile)
            tiles[agent.id] = tile
            newTiles.append(tile)
        }
        for tile in tiles.values { tile.palette = palette }
        let reordered = Set(ids) == Set(order) && ids != order
        let relaid = layout != self.layout
        // Only the person's density keys move rows; a resize does not.
        let densityChanged = relaid && layout.width == self.layout.width && layout.visibleHeight == self.layout.visibleHeight
        let moved = ids != order || relaid
        if moved, drag != nil { cancelDrag() }
        order = ids
        self.settled = settled
        for (id, tile) in tiles { tile.setSettled(settled.contains(id), undo: undoable.contains(id)) }
        self.layout = layout
        if moved { placeTiles(gliding: (reordered || densityChanged) && newTiles.isEmpty, resizing: densityChanged) }
        // A new tile in view shows its agent at once.
        for tile in newTiles where tile.isOnScreen { tile.update() }
        syncSelection()
        // A density change or a move keeps the cursor in view.
        if relaid || reordered { revealCursor() }
    }

    /// Sets every tile's frame from the layout, and the grid's height.
    /// `gliding`, each tile whose place changes glides there from where it
    /// is on screen in 150 ms; `resizing` (a density change), its size and
    /// parts move too, and its sentence keeps its lines until the end.
    private func placeTiles(gliding: Bool = false, resizing: Bool = false) {
        layouts += 1
        let height = layout.contentHeight(count: order.count)
        if frame.height != height || frame.width != layout.width {
            setFrameSize(NSSize(width: layout.width, height: height))
        }
        let duration = gliding ? AgentMotion.duration(.move(AgentMotion.small), in: self) : 0
        let visible = visibleRect
        // The tiles the person moves pass over the others (motion review
        // ruling 5), as a dragged tile does.
        if gliding, !resizing {
            for id in order where selection.selected.contains(id) {
                if let tile = tiles[id], subviews.last !== tile { addSubview(tile, positioned: .above, relativeTo: nil) }
            }
        }
        for (index, id) in order.enumerated() {
            guard let tile = tiles[id] else { continue }
            let frame = layout.frame(at: index)
            guard tile.frame != frame else { continue }
            // Only what can be seen glides; the rest takes its place at
            // once, its text redrawn later, a few a tick.
            let seen = tile.frame.intersects(visible) || frame.intersects(visible)
            if resizing, !seen { tile.holdsClamp = true }
            glide(tile, to: frame, duration: seen ? duration : 0, resizing: resizing)
        }
        updateOnScreen()
    }

    /// Moves `tile` to `frame`: at once, or gliding from where it is on
    /// screen, on the render server (its frame is set at once; its layers
    /// move from their old place).
    private func glide(_ tile: AgentTileView, to frame: CGRect, duration: CFTimeInterval, resizing: Bool) {
        guard duration > 0, let layer = tile.layer else {
            tile.frame = frame
            return
        }
        let parts = resizing ? tile.glidingLayers : []
        let before = (position: layer.position, bounds: layer.bounds)
        let partsBefore = parts.map { ($0.0.position, $0.0.bounds) }
        let sentence = resizing ? tile.sentencePicture : nil
        if resizing { tile.holdsClamp = true }
        tile.frame = frame
        tile.layoutSubtreeIfNeeded()
        tile.holdSentence(sentence, for: duration)
        glides += 1
        let motion = glides
        tile.glide = motion
        moving(for: duration)
        // A tile that grows shows its new screen lines in the motion's last
        // frames, not a frame after it ends (the end's completion comes too
        // late): its text takes its size two 120 Hz frames before the end.
        if resizing {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, duration - 2.0 / 120)) { [weak tile] in
                guard let tile, tile.glide == motion, tile.holdsClamp else { return }
                tile.holdsClamp = false
                tile.layoutSubtreeIfNeeded()
            }
        }
        AgentMotion.run({
            AgentMotion.animate(layer, "position", to: NSValue(point: layer.position), duration: duration, from: NSValue(point: before.position))
            if before.bounds != layer.bounds {
                AgentMotion.animate(layer, "bounds", to: NSValue(rect: layer.bounds), duration: duration, from: NSValue(rect: before.bounds))
            }
            for ((part, sized), (position, bounds)) in zip(parts, partsBefore) {
                if position != part.position {
                    AgentMotion.animate(part, "position", to: NSValue(point: part.position), duration: duration, from: NSValue(point: position))
                }
                if sized, bounds != part.bounds {
                    AgentMotion.animate(part, "bounds", to: NSValue(rect: part.bounds), duration: duration, from: NSValue(rect: bounds))
                }
            }
        }, then: { [weak tile] in
            // The screen's text takes its new size as the newest motion of
            // the tile ends, whichever kind it is: a reorder that interrupts
            // a density change ends the clamp too (motion review ruling 1,
            // last review ruling 9).
            guard let tile, tile.glide == motion, tile.holdsClamp else { return }
            tile.holdsClamp = false
            tile.layoutSubtreeIfNeeded()
        })
    }

    /// Each glide bumps it; a glide's end checks it is still the newest.
    private var glides = 0

    /// When the grid's last motion (a glide, a density change, a new tile)
    /// ends, on the render server's clock: tiles draw no new text until
    /// then, so the motion has every frame (native-look.md 5).
    private(set) var restsAt: CFTimeInterval = 0
    var isMoving: Bool { CACurrentMediaTime() < restsAt }

    private func moving(for duration: CFTimeInterval) {
        restsAt = max(restsAt, CACurrentMediaTime() + duration)
    }

    /// A tile leaving the home shown fades where it was (flows.md 7).
    private func fadeAway(_ tile: AgentTileView) {
        let duration = AgentMotion.duration(.fade(AgentMotion.gone), in: self)
        guard duration > 0, let layer = self.layer else { return }
        let ghost = tile.lendContent()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.name = "ghost"
        ghost.anchorPoint = .zero
        ghost.position = tile.frame.origin
        layer.addSublayer(ghost)
        CATransaction.commit()
        AgentMotion.run({
            AgentMotion.animate(ghost, "opacity", to: Float(0), duration: duration, from: Float(1))
        }, then: { ghost.removeFromSuperlayer() })
    }

    /// A new agent's tile, just started (flows.md 7): it fades in at its
    /// place in 150 ms (100 under Reduce Motion), its background starting
    /// at the popover surface and returning to its own over 1.4 s.
    func appear(_ id: UUID) {
        guard let tile = tiles[id] else { return }
        let duration = AgentMotion.duration(.fade(AgentMotion.small), in: self)
        moving(for: duration)
        tile.fadeIn(duration: duration)
        tile.flash(from: palette.pop)
    }

    /// The line has the keys: with two or more tiles selected, the others
    /// drop to 55 % (ruling 15).
    var lineHasKeys = false {
        didSet { if lineHasKeys != oldValue { syncSelection() } }
    }

    func syncSelection() {
        let focused = hasKeys
        let selection = selection
        let dims = lineHasKeys && selection.selected.count > 1
        for (id, tile) in tiles {
            tile.setSelection(
                selected: selection.selected.contains(id),
                cursor: selection.cursor == id,
                tilesHaveKeys: focused)
            tile.setDimmed(dims && !selection.selected.contains(id))
        }
    }

    /// Selects as `selection` says, in its one home, and keeps its cursor in
    /// view, at once.
    func select(_ selection: AgentTileSelection) {
        actions.select(selection)
        syncSelection()
        revealCursor()
    }

    /// Scrolls the least that puts the cursor in view, with the 2 pt ring
    /// outside it.
    private func revealCursor() {
        guard let cursor = selection.cursor, let tile = tiles[cursor] else { return }
        scrollToVisible(tile.frame.insetBy(dx: 0, dy: -AgentHomeLayout.top))
    }

    private func press(_ id: UUID, _ event: NSEvent) {
        actions.takeKeys()
        var next = selection
        next.press(id, toggles: !event.modifierFlags.isDisjoint(with: [.shift, .command]), in: order)
        select(next)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        hideNumbers()
        let shift = event.modifierFlags.contains(.shift)
        if event.modifierFlags.contains(.option), event.keyCode == 123 || event.keyCode == 124 {
            moveSelected(by: event.keyCode == 123 ? -1 : 1)
            return
        }
        var next = selection
        switch event.keyCode {
        case 123: next.move(.left, extend: shift, in: order, columns: layout.columns, skipping: settled)
        case 124: next.move(.right, extend: shift, in: order, columns: layout.columns, skipping: settled)
        case 125: next.move(.down, extend: shift, in: order, columns: layout.columns, skipping: settled)
        case 126: next.move(.up, extend: shift, in: order, columns: layout.columns, skipping: settled)
        case 53: next.escape()
        case 36, 76:
            // Return opens the cursor; with several selected it goes to the
            // line.
            if let cursor = selection.cursor, selection.selected.count == 1 {
                actions.enter(cursor)
            } else if selection.selected.count > 1 {
                actions.toLine()
            }
            return
        default:
            if Self.isPrintable(event) { actions.type(event) }
            return
        }
        if next != selection { select(next) }
    }

    /// A key that types a character, other than Space, without Control or
    /// Command.
    static func isPrintable(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.control, .command]),
              let characters = event.characters, let scalar = characters.unicodeScalars.first,
              characters != " "
        else { return false }
        return !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
    }

    // MARK: Holding ⌘

    private var numbersTimer: Timer?
    /// Whether the numbers 1 to 9 show over the first nine tiles.
    private(set) var showsNumbers = false

    /// Holding ⌘ alone for 200 ms shows the numbers 1 to 9 over the first
    /// nine tiles' marks; releasing it, or any other key, hides them
    /// (ruling 24).
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command else { return hideNumbers() }
        numbersTimer?.invalidate()
        numbersTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNumbers(true) }
        }
    }

    func hideNumbers() {
        numbersTimer?.invalidate()
        numbersTimer = nil
        setNumbers(false)
    }

    private func setNumbers(_ shown: Bool) {
        guard shown != showsNumbers else { return }
        showsNumbers = shown
        for (index, id) in order.enumerated() {
            tiles[id]?.setNumber(shown && index < 9 && !settled.contains(id) ? index + 1 : nil)
        }
    }

    // MARK: Moving tiles by the pointer

    private struct Drag {
        var lead: UUID
        /// The tiles that move, in the project's order.
        var moving: [UUID]
        /// Where the pointer took the lead tile, from its top left.
        var grab: CGPoint
        /// Where the moving tiles land, a place among the others.
        var gap: Int
    }
    private var drag: Drag?

    /// The pointer moved more than 4 pt with a tile pressed: it lifts and
    /// follows the pointer; the others make room (flows.md 3.5). Several
    /// selected tiles move together, the one under the pointer leading.
    private func dragged(_ id: UUID, _ event: NSEvent, pressedAt: NSPoint) {
        let point = convert(event.locationInWindow, from: nil)
        if drag == nil {
            guard let tile = tiles[id] else { return }
            let moving = selection.selected.contains(id) ? order.filter(selection.selected.contains) : [id]
            // Held where it was pressed, however far the first move went:
            // it follows the pointer exactly.
            let pressed = convert(pressedAt, from: nil)
            drag = Drag(
                lead: id, moving: moving,
                grab: CGPoint(x: pressed.x - tile.frame.minX, y: pressed.y - tile.frame.minY),
                gap: order.filter { !moving.contains($0) }.count)
            // Above the others, the lead on top.
            for moved in moving.filter({ $0 != id }).reversed() {
                if let other = tiles[moved] { addSubview(other, positioned: .above, relativeTo: nil) }
            }
            addSubview(tile, positioned: .above, relativeTo: nil)
            for moved in moving { tiles[moved]?.setLifted(true) }
        }
        guard var drag else { return }
        autoscroll(with: event)
        let lead = CGPoint(x: point.x - drag.grab.x, y: point.y - drag.grab.y)
        let rest = order.filter { !drag.moving.contains($0) }
        drag.gap = gap(at: point, among: rest.count + drag.moving.count) .clamped(to: 0...rest.count)
        self.drag = drag
        // The others make room around the gap.
        var preview = rest
        preview.insert(contentsOf: drag.moving, at: drag.gap)
        for (index, id) in preview.enumerated() where !drag.moving.contains(id) {
            let frame = layout.frame(at: index)
            // Each tile whose place changes glides there from wherever it
            // is, retargeting one already gliding.
            if let tile = tiles[id], tile.frame != frame {
                glide(tile, to: frame, duration: AgentMotion.duration(.move(AgentMotion.small), in: self), resizing: false)
            }
        }
        // The lead follows the pointer; the others stack behind it 6 pt apart.
        let size = layout.frame(at: 0).size
        for (depth, id) in ([drag.lead] + drag.moving.filter { $0 != drag.lead }).enumerated() {
            guard let tile = tiles[id] else { continue }
            let frame = CGRect(x: lead.x + CGFloat(depth) * 6, y: lead.y + CGFloat(depth) * 6, width: size.width, height: size.height)
            if depth == 0 {
                // The lead follows the pointer exactly: no lag, no easing.
                tile.layer?.removeAnimation(forKey: "position")
                tile.frame = frame
            } else {
                // The others follow it into a stack over 150 ms.
                glide(tile, to: frame, duration: AgentMotion.duration(.move(AgentMotion.small), in: self), resizing: false)
            }
        }
    }

    /// The place whose tile rectangle holds `point`, or the nearest.
    private func gap(at point: CGPoint, among count: Int) -> Int {
        let pitchX = layout.tileWidth + AgentHomeLayout.gap
        let pitchY = layout.rowHeight + AgentHomeLayout.gap
        let column = Int(((point.x - AgentHomeLayout.sides) / pitchX).rounded(.down)).clamped(to: 0...(layout.columns - 1))
        let row = max(0, Int(((point.y - AgentHomeLayout.top) / pitchY).rounded(.down)))
        return min(row * layout.columns + column, max(0, count - 1))
    }

    /// Release: the moving tiles land side by side in the gap.
    private func dropped() {
        guard let drag else { return }
        self.drag = nil
        for id in drag.moving { tiles[id]?.setLifted(false) }
        // The lifted tiles glide from under the pointer into the gap.
        if let moved = AgentReorder.drop(order, moving: Set(drag.moving), at: drag.gap) {
            actions.reorder(moved)
        } else {
            placeTiles(gliding: true)
        }
    }

    /// Escape during a drag: every tile back where it was.
    func cancelDrag() {
        guard let drag else { return }
        self.drag = nil
        for id in drag.moving { tiles[id]?.setLifted(false) }
        // Every tile glides back to its place from wherever it is.
        placeTiles(gliding: true)
    }

    /// A tile pressed and moving, for the harness and tests.
    var isDragging: Bool { drag != nil }

    // MARK: Menus

    /// A right-click: the tile becomes the cursor, keeping a selection that
    /// holds it, and its menu opens.
    private func rightClicked(_ id: UUID, _ event: NSEvent) {
        actions.takeKeys()
        if !selection.selected.contains(id) {
            select(.only(id))
        } else {
            var next = selection
            next.press(id, toggles: false, in: order)
            select(next)
        }
        guard let tile = tiles[id] else { return }
        NSMenu.popUpContextMenu(actions.menu(id), with: event, for: tile)
    }

    /// ⌘A.
    func selectAll() {
        var next = selection
        next.selectAll(live)
        select(next)
    }

    /// Edit ▸ Select All and Edit ▸ Copy reach the tiles too (words.md
    /// "Other menus").
    override func selectAll(_ sender: Any?) { selectAll() }
    @objc func copy(_ sender: Any?) { actions.copy() }

    /// ⌥← ⌥→ and Move earlier / Move later: the selected tiles one place
    /// earlier or later; at either end nothing.
    func moveSelected(by offset: Int) {
        if let moved = AgentReorder.step(live, moving: selection.selected, by: offset) {
            actions.reorder(moved)
        }
    }

    // MARK: Tiles on screen

    /// Which tiles are in view, which only those read their text and turn
    /// their marks; none while home is hidden or the window unseen.
    func updateOnScreen() {
        let shown = window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        let visible = visibleRect
        for tile in tiles.values { tile.isOnScreen = shown && tile.frame.intersects(visible) }
    }

    /// Every tile's text is out of date: home appears after being hidden.
    func markScreensStale() {
        tiles.values.forEach { $0.markScreenStale() }
        updateOnScreen()
    }

    /// Brings up to date up to `limit` tiles in view that are out of date;
    /// then, with room left, draws one tile out of view that has never been
    /// drawn, so scrolling finds every tile with its content. Called by the
    /// refresh tick, never in the frame of a scroll. A tile out of view that
    /// has been drawn does nothing until it comes into view.
    func refreshStale(limit: Int) {
        // Tiles out of view during a density change take their final size,
        // a few a tick, never in the frame of the key (those in view do as
        // their motion ends).
        let held = order.compactMap { tiles[$0] }.filter { $0.holdsClamp && $0.layer?.animation(forKey: "bounds") == nil }
        for tile in held.prefix(limit) { tile.holdsClamp = false }
        var left = limit
        for tile in visibleTiles where tile.isStale && left > 0 {
            tile.update()
            left -= 1
        }
        guard left > 0 else { return }
        order.lazy.compactMap { self.tiles[$0] }.first { !$0.isOnScreen && !$0.hasDrawnScreen }?.update()
    }

    /// The tiles on screen now, for the refresh of their text.
    var visibleTiles: [AgentTileView] {
        order.compactMap { tiles[$0] }.filter(\.isOnScreen)
    }
}

/// Home: the grid in a scroll view that draws nothing at rest (overlay
/// scrollers only).
final class AgentHomeView: NSScrollView, AgentActivationClickSafeRegion {
    let grid = AgentHomeGrid()

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        contentView.drawsBackground = false
        focusRingType = .none
        documentView = grid
        grid.wantsLayer = true
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
    }

    /// Runs when home scrolls, for what follows the visible rectangle.
    var onScroll: (() -> Void)?

    private func scrolled() {
        lastScroll = CACurrentMediaTime()
        grid.updateOnScreen()
        onScroll?()
    }

    private var lastScroll: CFTimeInterval = 0

    /// The person is scrolling home now (within the last 150 ms): tiles
    /// draw nothing meanwhile, so every frame of the scroll is only the
    /// scroll (native-look.md 5, "Grid scrolling").
    var isScrolling: Bool { CACurrentMediaTime() - lastScroll < 0.15 }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        grid.relayout()
        onScroll?()
    }

    /// Hidden while inside: no tile reads its text or turns its mark.
    override var isHidden: Bool {
        didSet { if isHidden != oldValue { grid.updateOnScreen() } }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
