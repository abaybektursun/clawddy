import AppKit

/// Runs `read` now and again after any observed value it read changes, on
/// the next turn of the main run loop, so changes made together are seen
/// together. Values are observed through Swift's Observation: an agent's
/// runtime and name, the configuration's projects, the workspace model.
@MainActor
final class AgentObserver {
    private let read: @MainActor () -> Void
    private var cancelled = false

    init(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        run()
    }

    private func run() {
        guard !cancelled else { return }
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.run() }
        }
    }

    func cancel() { cancelled = true }
}

/// A flipped view that draws nothing: the list's document.
class AgentFlippedView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }
}

/// One agent's row beside a terminal (native-look.md 3.6): its mark, its
/// name on the first line and its sentence on the second, 48 pt tall. The
/// row is built once and follows its own agent: a change of state, name or
/// sentence sets the layers it changes, in place, and touches no other row
/// and no frame.
final class AgentListRowView: AgentButton, AgentNameHost {
    /// The pitch rows are laid out on; each row is 2 pt shorter, so two
    /// filled rows never touch.
    static let height: CGFloat = 48

    let agentID: UUID
    private weak var agent: AgentInstance?
    private let mark = AgentMarkLayer()
    private let name = AgentTextLayer()
    private let sentence = AgentTextLayer()
    /// The row's fill and, picked up, its shadows: layers of its own, which
    /// AppKit leaves alone.
    private let surface = AgentLayer()
    private let under = AgentLayer()
    private var observer: AgentObserver?
    /// Layout passes, for the tests that no row is laid out again when
    /// another agent changes.
    private(set) var layouts = 0

    var palette: ClawddyPalette = .prototype {
        didSet { if palette != oldValue { refresh() } }
    }
    /// The row of the agent shown inside.
    var isCurrent = false {
        didSet { if isCurrent != oldValue { refresh() } }
    }

    init(agent: AgentInstance, palette: ClawddyPalette) {
        agentID = agent.id
        self.agent = agent
        self.palette = palette
        super.init(frame: .zero)
        fills = (0, 0.04, 0.08)
        layer?.masksToBounds = false
        for part in [under, surface] {
            part.cornerRadius = 8
            part.cornerCurve = .continuous
            part.shadowColor = CGColor(gray: 0, alpha: 1)
            part.shadowOpacity = 0
        }
        fillLayer = surface
        for part in [under, surface, mark, name, sentence] as [CALayer] { layer?.addSublayer(part) }
        observer = AgentObserver { [weak self] in self?.refresh() }
    }

    /// Lifted by a drag: the raised surface and the two shadows of a picked
    /// up tile (native-look.md 2.6).
    func setLifted(_ lifted: Bool) {
        base = lifted ? palette.raised : (isCurrent ? palette.raised : nil)
        // Its shadow fades in over 150 ms, and out as it lands, as a tile's
        // does (motion review ruling 5).
        let fade = AgentMotion.duration(.move(AgentMotion.small), in: self)
        for (part, opacity, radius, offset) in [(surface, 0.45, 17.0, 14.0), (under, 0.30, 3.0, 2.0)] {
            AgentMotion.animate(part, "shadowOpacity", to: lifted ? Float(opacity) : 0, duration: fade)
            part.shadowRadius = radius
            part.shadowOffset = CGSize(width: 0, height: offset)
            part.shadowPath = CGPath.continuousRoundedRect(bounds, radius: 8)
        }
    }

    /// Whether its list is shown: its mark turns only then.
    var onScreen: Bool {
        get { mark.onScreen }
        set { mark.onScreen = newValue }
    }

    var nameFrame: CGRect { name.frame }
    var nameFont: NSFont { name.text?.font ?? AgentMetrics.bodyMedium }
    /// The row's sentence starts right under the name: the halo keeps 2 pt
    /// clear of its letters (final review ruling 9).
    var nameHalo: CGFloat { 2 }
    /// Where the sentence's tallest letters begin, from the row's top.
    var sentenceGlyphTop: CGFloat {
        let font = sentence.text?.font ?? AgentMetrics.small
        return sentence.frame.minY + AgentMetrics.baseline(font, lineHeight: 17) - font.capHeight
    }

    /// The name is being edited over its place.
    var editsName = false {
        didSet { name.isHidden = editsName }
    }

    /// How many times its name and sentence have been drawn.
    var draws: Int { name.draws + sentence.draws }

    override func layout() {
        super.layout()
        layouts += 1
        let width = bounds.width
        surface.frame = bounds
        under.frame = bounds
        // Name 13/18 from 5 pt of the 46 pt row, sentence 12/17 under it; the
        // mark's centre on the name's cap centre.
        let baseline = 5 + AgentMetrics.baseline(AgentMetrics.bodySemibold, lineHeight: 18)
        mark.frame = CGRect(x: 8, y: baseline - AgentMetrics.markLift - 7, width: 14, height: 14)
        name.frame = CGRect(x: 32, y: 5, width: max(0, width - 40), height: 18)
        nameField?.place(name.frame)
        sentence.frame = CGRect(x: 32, y: 23, width: max(0, width - 40), height: 17)
    }

    /// Sets what changed, from the agent as it is now: its state, name and
    /// sentence, all read from its record.
    private func refresh() {
        guard let agent else { return }
        let state = agent.shownState
        let waiting = agent.record.isWaitingOnYou
        let said = agent.sentence
        let strong = isCurrent || waiting
        mark.palette = palette
        mark.state = state
        name.text = AgentText(
            string: agent.name,
            font: strong ? AgentMetrics.bodySemibold : AgentMetrics.bodyMedium,
            color: (strong ? palette.ink : palette.text2).cgColor())
        let font = said.isAppWritten ? AgentMetrics.italic(AgentMetrics.small) : AgentMetrics.small
        sentence.text = AgentText(
            string: said.text,
            font: font,
            color: (waiting ? palette.ink : isCurrent ? palette.text2 : palette.text3).cgColor(),
            lineHeight: 17)
        base = isCurrent ? palette.raised : nil
        setAccessibilityLabel("\(agent.name), \(state.name). \(said.text)")
        toolTip = "\(agent.name)\n\(said.text)"
    }
}

/// The fixed list of the project's agents beside a terminal (native-look.md
/// 3.6): 252 pt wide, the back row "All of <project>" at its top with a
/// hairline under it, then one row per agent in the project's order. Rows
/// keep their order and one height; a row is made once per agent and kept
/// while the agent is in the list. It is never keyboard-focusable: it is
/// clicked.
final class AgentListView: NSScrollView, AgentActivationClickSafeRegion {
    static let width: CGFloat = 252
    /// Rows run from x 12 to 244.
    static let rowInset: CGFloat = 12
    static let backHeight: CGFloat = 42
    /// Where the first row starts under the back row and its hairline.
    static let rowsTop: CGFloat = 48

    private let document = AgentFlippedView()
    let back = AgentButton()
    private let backChevron = AgentSymbolLayer()
    private let backLabel = AgentTextLayer()
    private let backKey = AgentKeyCap()
    private let hairline = AgentLayer()
    private(set) var rows: [UUID: AgentListRowView] = [:]
    /// The agents shown, in the project's order.
    private(set) var order: [UUID] = []
    private var project = ""
    private var showsBack = true
    private var palette: ClawddyPalette = .prototype

    /// A click on a row.
    var onEnter: ((UUID) -> Void)?
    /// A click on "All of <project>".
    var onBack: (() -> Void)?
    /// A row's menu (right-click), for its agent.
    var menuForAgent: ((UUID) -> NSMenu)?
    /// The rows in a new order, dragged (flows.md 3.5).
    var onReorder: (([UUID]) -> Void)?
    private var drag: (lead: UUID, grab: CGFloat, gap: Int)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .allowed
        contentView.drawsBackground = false
        focusRingType = .none
        documentView = document
        document.wantsLayer = true
        document.layer?.addSublayer(hairline)
        document.addSubview(back)
        back.fills = (0, 0, 0.08)
        for part in [backChevron, backLabel, backKey] as [CALayer] { back.layer?.addSublayer(part) }
        back.onPhase = { [weak self] _ in self?.styleBack() }
        back.onPress = { [weak self] in self?.onBack?() }
        back.setAccessibilityHelp("Back to all agents")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { false }

    /// Shows `agents`, in their order, the `current` one raised. Rows are
    /// reused by agent; only a row that comes or goes, or whose place
    /// changes, is touched.
    func show(agents: [AgentInstance], current: UUID?, project: String, showsBack: Bool, palette: ClawddyPalette) {
        self.palette = palette
        if self.project != project || self.showsBack != showsBack {
            self.project = project
            self.showsBack = showsBack
            styleBack()
        }
        back.isHidden = !showsBack
        hairline.isHidden = !showsBack
        hairline.backgroundColor = ClawddyPalette.white(0.05)
        let ids = agents.map(\.id)
        // A row moved by the pointer when the rows change (it settled, went,
        // or another came) goes back at once: the drag ends, and the keys
        // are no longer taken for it (last review ruling 9).
        if drag != nil, ids != order { cancelDrag() }
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        for agent in agents where rows[agent.id] == nil {
            let row = AgentListRowView(agent: agent, palette: palette)
            row.onScreen = !isHidden
            let id = agent.id
            row.onPress = { [weak self] in self?.onEnter?(id) }
            row.onDrag = { [weak self] event, pressedAt in self?.dragged(id, event, pressedAt: pressedAt) }
            row.onDrop = { [weak self] in self?.dropped() }
            row.onRightClick = { [weak self, weak row] event in
                guard let self, let row, let menu = self.menuForAgent?(id) else { return }
                NSMenu.popUpContextMenu(menu, with: event, for: row)
            }
            document.addSubview(row)
            rows[id] = row
        }
        // The same rows in a new order (a drop): they glide into place.
        let reordered = Set(ids) == Set(order) && ids != order
        order = ids
        let top = showsBack ? Self.rowsTop : 0
        for (index, id) in ids.enumerated() {
            guard let row = rows[id] else { continue }
            row.palette = palette
            row.isCurrent = id == current
            let frame = NSRect(
                x: Self.rowInset, y: top + CGFloat(index) * AgentListRowView.height + 1,
                width: Self.width - Self.rowInset - 8, height: AgentListRowView.height - 2)
            // A new order (a drop) glides into place; anything else at once.
            if reordered, row.frame.size == frame.size {
                glide(row, to: frame.minY)
            } else if row.frame != frame {
                row.frame = frame
            }
        }
        let height = top + CGFloat(ids.count) * AgentListRowView.height + 14
        let size = NSSize(width: Self.width, height: max(height, contentView.bounds.height))
        if document.frame.size != size { document.setFrameSize(size) }
        let backFrame = NSRect(x: Self.rowInset, y: 0, width: Self.width - Self.rowInset - 8, height: Self.backHeight)
        if back.frame != backFrame {
            back.frame = backFrame
            layoutBack()
        }
        // 3 pt from the back row and 3 pt from the first row's fill.
        hairline.frame = CGRect(x: Self.rowInset + 8, y: 45, width: Self.width - Self.rowInset - 8 - 16, height: 1)
        if let current { reveal(current) }
    }

    /// A row moved by the pointer follows it, vertically only; the others
    /// make room; release drops it in the gap. The agent shown does not
    /// change.
    private func dragged(_ id: UUID, _ event: NSEvent, pressedAt: NSPoint) {
        guard let row = rows[id] else { return }
        let y = document.convert(event.locationInWindow, from: nil).y
        let top = showsBack ? Self.rowsTop : 0
        if drag == nil {
            // Held where it was pressed, however far the first move went.
            drag = (id, document.convert(pressedAt, from: nil).y - row.frame.minY, order.firstIndex(of: id) ?? 0)
            document.addSubview(row, positioned: .above, relativeTo: nil)
            row.setLifted(true)
        }
        guard var drag else { return }
        document.autoscroll(with: event)
        let rest = order.filter { $0 != id }
        drag.gap = Int(((y - top) / AgentListRowView.height).rounded(.down)).clamped(to: 0...rest.count)
        self.drag = drag
        var preview = rest
        preview.insert(id, at: drag.gap)
        for (index, other) in preview.enumerated() where other != id {
            if let row = rows[other] { glide(row, to: top + CGFloat(index) * AgentListRowView.height + 1) }
        }
        // The lifted row follows the pointer exactly.
        row.frame.origin.y = (y - drag.grab).clamped(to: top...(top + CGFloat(rest.count) * AgentListRowView.height + 1))
    }

    /// Moves `row` to `y`, gliding there in 150 ms from where it is on
    /// screen, on the one curve (a tile's glide; at once under Reduce
    /// Motion or unseen).
    private func glide(_ row: AgentListRowView, to y: CGFloat) {
        guard row.frame.origin.y != y, let layer = row.layer else { return }
        let duration = AgentMotion.duration(.move(AgentMotion.small), in: self)
        let before = layer.position
        row.frame.origin.y = y
        guard duration > 0 else { return }
        AgentMotion.animate(layer, "position", to: NSValue(point: layer.position), duration: duration, from: NSValue(point: before))
    }

    /// Every row back at its place in the order, gliding.
    private func glideHome() {
        for (index, id) in order.enumerated() {
            if let row = rows[id] { glide(row, to: (showsBack ? Self.rowsTop : 0) + CGFloat(index) * AgentListRowView.height + 1) }
        }
    }

    /// A row is being moved by the pointer.
    var isDragging: Bool { drag != nil }

    /// Escape during a drag: every row back where it was.
    func cancelDrag() {
        guard let drag else { return }
        self.drag = nil
        rows[drag.lead]?.setLifted(false)
        rows[drag.lead]?.endDrag()
        glideHome()
    }

    /// The list is shown: its rows' marks turn.
    override var isHidden: Bool {
        didSet { if isHidden != oldValue { rows.values.forEach { $0.onScreen = !isHidden } } }
    }

    private func dropped() {
        guard let drag else { return }
        self.drag = nil
        rows[drag.lead]?.setLifted(false)
        var moved = order.filter { $0 != drag.lead }
        moved.insert(drag.lead, at: drag.gap)
        if moved != order {
            onReorder?(moved)
        } else {
            glideHome()
        }
    }

    /// Keeps the agent's row in view, at once.
    func reveal(_ id: UUID) {
        guard let row = rows[id] else { return }
        document.scrollToVisible(row.frame)
    }

    /// The row of an agent shown in the list, for tests and the harness.
    func row(of id: UUID) -> AgentListRowView? { rows[id] }

    private func styleBack() {
        let color = back.phase == .rest ? palette.text3 : palette.text2
        backLabel.text = AgentText(string: "All of \(project)", font: AgentMetrics.body, color: color.cgColor())
        backChevron.symbol = .init(name: "chevron.left", pointSize: 11, weight: .medium, color: color, box: 14, scale: AgentMetrics.scale)
        backKey.show("⌘⎋", color: palette.text3.cgColor(), fill: ClawddyPalette.white(0.07))
        back.setAccessibilityLabel("All of \(project)")
        layoutBack()
    }

    private func layoutBack() {
        let height = back.bounds.height
        let lineTop = ((height - 18) / 2).rounded()
        let baseline = lineTop + AgentMetrics.baseline(AgentMetrics.body, lineHeight: 18)
        // In the rows' mark column, 6 pt before the words.
        backChevron.frame = CGRect(x: 8, y: baseline - AgentMetrics.markLift - 7, width: 14, height: 14)
        let keyWidth = backKey.bounds.width
        backKey.frame = CGRect(x: back.bounds.width - 8 - keyWidth, y: baseline - AgentMetrics.markLift - 8, width: keyWidth, height: 16)
        backLabel.frame = CGRect(x: 28, y: lineTop, width: max(0, backKey.frame.minX - 8 - 28), height: 18)
    }
}
