import AppKit

/// One row of find's results (flows.md 6.8): an agent, with the line that
/// matched, or a command with its key.
enum AgentPaletteRow: Equatable {
    case agent(AgentSearchHit, state: AgentShownState, age: String)
    case command(title: String, key: String?, marks: [NSRange])

    /// The group heading over it.
    var group: String {
        switch self {
        case .agent(let hit, _, _): hit.settled ? "Settled" : "Agents"
        case .command: "Commands"
        }
    }

    var height: CGFloat {
        switch self {
        case .agent: AgentPaletteList.agentRow
        case .command: AgentPaletteList.commandRow
        }
    }
}

/// The floating panel over the window (native-look.md 3.9, flows.md "The
/// palette"): an opaque raised surface with a rim, a line of light on top
/// and a shadow, over a veil that dims the window. In find mode, its field
/// "Find an agent or run a command" and under it the results, grouped
/// Agents, Settled, Commands, or "Nothing matches." with the key that starts
/// an agent from the text. In new-agent mode (the floating new-agent line,
/// at home and inside a terminal), the chip naming where the agent starts,
/// the field "Describe the task", and the hints "↩ Start another" and "⎋
/// Back to terminal" (at home "⎋ Close").
///
/// It decides nothing: what its keys and rows do is the controller's.
final class AgentPaletteView: NSView, AgentActivationClickSafeRegion {
    static let maxWidth: CGFloat = 640

    enum Mode { case find, new }

    let textView = AgentTextView(font: .systemFont(ofSize: 17, weight: .regular), lineHeight: 24, maxLines: 6, inset: .zero)
    let list = AgentPaletteList()
    private let scroll = NSScrollView()
    private let listScroll = NSScrollView()
    private let surface = AgentLayer()
    private let topLight = AgentShapeLayer()
    let chip = AgentChip()
    /// A press on the new-agent chip: the controller shows the CLIs' menu.
    var onChip: ((NSView) -> Void)?
    private let divider = AgentLayer()
    private let hints: [(AgentKeyCap, AgentTextLayer)] = [(AgentKeyCap(), AgentTextLayer()), (AgentKeyCap(), AgentTextLayer())]
    private var palette = ClawddyPalette.prototype
    private(set) var mode = Mode.new
    private(set) var chipText = ""
    /// The field's placeholder starting a new agent, as the line's.
    static let newPlaceholder = "Describe the task, or Tab to change the CLI"
    /// The tallest the results may be: 46 % of the window's content.
    var listLimit: CGFloat = 400 { didSet { if listLimit != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        surface.cornerRadius = 12
        surface.cornerCurve = .continuous
        surface.borderWidth = 1
        surface.shadowColor = CGColor(gray: 0, alpha: 1)
        surface.shadowOpacity = 0.6
        surface.shadowRadius = 45
        surface.shadowOffset = CGSize(width: 0, height: 30)
        topLight.fillColor = nil
        topLight.lineWidth = 1
        topLight.masksToBounds = true
        for part in [surface, topLight, divider] as [CALayer] { layer?.addSublayer(part) }
        for (key, label) in hints {
            layer?.addSublayer(key)
            layer?.addSublayer(label)
        }
        for view in [scroll, listScroll] {
            view.drawsBackground = false
            view.borderType = .noBorder
            view.hasVerticalScroller = true
            view.autohidesScrollers = true
            view.scrollerStyle = .overlay
            view.focusRingType = .none
            view.contentView.drawsBackground = false
            view.contentView.focusRingType = .none
            addSubview(view)
        }
        scroll.documentView = textView
        listScroll.documentView = list
        addSubview(chip)
        chip.onPress = { [weak self] in
            guard let self else { return }
            self.onChip?(self.chip)
        }
        textView.onChange = { [weak self] in self?.needsLayout = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    /// New-agent mode: the chip and the field, empty; `back` is what
    /// Escape does, in words.
    func showNew(chip text: String, cli: String, accessibility: String, back: String, palette: ClawddyPalette) {
        mode = .new
        chipText = text
        apply(palette)
        textView.placeholder = Self.newPlaceholder
        textView.setAccessibilityLabel(accessibility)
        textView.setAccessibilityPlaceholderValue(Self.newPlaceholder)
        chip.show(text, many: false, cli: cli, palette: palette)
        for ((key, label), (keys, words)) in zip(hints, [("↩", "Start another"), ("⎋", back)]) {
            key.show(keys, color: palette.text2.cgColor(), fill: ClawddyPalette.white(0.07))
            label.text = AgentText(string: words, font: AgentMetrics.body, color: palette.text2.cgColor())
        }
        list.show([], highlighted: 0, palette: palette)
        needsLayout = true
    }

    /// Find mode, the field holding `text`.
    func showFind(text: String, palette: ClawddyPalette) {
        mode = .find
        chipText = ""
        apply(palette)
        textView.placeholder = "Find an agent or run a command"
        textView.setAccessibilityLabel("Find an agent or run a command")
        textView.setAccessibilityPlaceholderValue("Find an agent or run a command")
        textView.setText(text)
        needsLayout = true
    }

    /// Find's rows for the text in the field, the highlighted one in view;
    /// with none, "Nothing matches." and the key that starts an agent.
    func showResults(_ rows: [AgentPaletteRow], highlighted: Int) {
        list.show(rows, highlighted: highlighted, palette: palette)
        let empty = rows.isEmpty
        for ((key, label), (keys, words)) in zip(hints, [("", "Nothing matches."), ("⌘↩", "start an agent with this text")]) {
            key.isHidden = !empty || keys.isEmpty
            label.isHidden = !empty
            if empty {
                key.show(keys, color: palette.text2.cgColor(), fill: ClawddyPalette.white(0.07))
                label.text = AgentText(string: words, font: AgentMetrics.body, color: palette.text2.cgColor())
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        list.scrollToHighlight()
    }

    private func apply(_ palette: ClawddyPalette) {
        self.palette = palette
        textView.apply(palette)
        surface.backgroundColor = palette.pop.cgColor()
        surface.borderColor = ClawddyPalette.white(0.14)
        topLight.strokeColor = ClawddyPalette.white(0.08)
        divider.backgroundColor = ClawddyPalette.white(0.07)
    }

    /// The results' height: the list's, at most `listLimit`, ending on a
    /// whole row when it scrolls.
    private var listHeight: CGFloat {
        guard list.contentHeight > listLimit else { return list.contentHeight }
        return list.rowFrames.map(\.maxY).filter { $0 <= listLimit }.max() ?? listLimit
    }

    /// Its height for its text: the field row, the divider, then the hints
    /// or the results.
    var preferredHeight: CGFloat {
        let field = 14 + textView.textHeight + 12 + 1
        if mode == .find, !list.rows.isEmpty { return field + listHeight }
        return field + 12 + 18 + 14
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        surface.frame = bounds
        surface.shadowPath = CGPath.continuousRoundedRect(bounds, radius: 12)
        // Inside the 1 pt rim, so the two never fuse into one line.
        topLight.frame = CGRect(x: 0, y: 0, width: width, height: 12)
        topLight.path = CGPath.topLight(bounds.size, radius: 12, inset: 1)

        // The field row: in new-agent mode the chip on the field's first
        // baseline.
        chip.isHidden = mode == .find
        var textX: CGFloat = 16
        if mode == .new {
            let baseline = 14 + textView.firstBaseline
            let chipWidth = chip.fittingWidth
            chip.frame = NSRect(
                x: 16, y: AgentMetrics.snap(baseline - 3 - AgentMetrics.baseline(AgentMetrics.bodyMedium, lineHeight: 18)),
                width: chipWidth, height: 24)
            textX = 16 + chipWidth + 10
        }
        let textHeight = textView.textHeight
        let frame = NSRect(x: textX, y: 14, width: max(40, width - 16 - textX), height: textHeight)
        if scroll.frame != frame { scroll.frame = frame }
        if textView.frame.width != frame.width { textView.frame.size.width = frame.width }

        let dividerY = 14 + textHeight + 12
        divider.frame = CGRect(x: 0, y: dividerY, width: width, height: 1)
        let showsList = mode == .find && !list.rows.isEmpty
        listScroll.isHidden = !showsList
        if showsList {
            let listFrame = NSRect(x: 0, y: dividerY + 1, width: width, height: listHeight)
            if listScroll.frame != listFrame { listScroll.frame = listFrame }
            list.setFrameSize(NSSize(width: width, height: list.contentHeight))
        }
        // The hints (new-agent mode) or "Nothing matches." (find).
        var x: CGFloat = 18
        let hintTop = dividerY + 1 + 12
        for (key, label) in hints where !label.isHidden {
            if !key.isHidden {
                let keyWidth = key.bounds.width
                key.frame = CGRect(x: x, y: hintTop + 1, width: keyWidth, height: 16)
                x += keyWidth + 7
            }
            let labelWidth = label.text?.width ?? 0
            label.frame = CGRect(x: x, y: hintTop, width: labelWidth, height: 18)
            x += labelWidth + 18
        }
        if textView.lineCount > textView.maxLines { textView.scrollRangeToVisible(textView.selectedRange()) }
    }

    /// The pointer moved to `point` (window coordinates), from the window's
    /// one authority for hover: over a row, it becomes the highlighted one.
    func pointerMoved(to point: NSPoint) {
        guard mode == .find, !listScroll.isHidden else { return }
        list.pointerMoved(to: point)
    }
}

/// Find's results: group headings and rows, drawn into layers the list owns
/// and reuses, so a key redraws only the text that changed. The highlighted
/// row has a 8 % fill and its name in ink. The pointer highlights a row only
/// when it moves (`pointerMoved`), so a resting pointer never takes the
/// highlight from the arrows; a click runs the row on release.
final class AgentPaletteList: AgentFlippedView {
    static let agentRow: CGFloat = 7 + 18 + 17 + 7
    static let commandRow: CGFloat = 7 + 18 + 7
    static let heading: CGFloat = 8 + 16 + 4
    static let padding: CGFloat = 6

    private(set) var rows: [AgentPaletteRow] = []
    private(set) var highlighted = 0
    private var palette = ClawddyPalette.prototype
    private var rowLayers: [AgentPaletteRowLayer] = []
    private var headingLayers: [AgentTextLayer] = []
    /// Each row's rectangle, in the list.
    private(set) var rowFrames: [CGRect] = []
    private var lastPointer: NSPoint?
    private var pressedRow: Int?
    /// The pointer made `index` the highlighted row.
    var onHighlight: ((Int) -> Void)?
    /// A click on a row.
    var onRun: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var contentHeight: CGFloat { (rowFrames.last?.maxY ?? 0) + Self.padding }

    func show(_ rows: [AgentPaletteRow], highlighted: Int, palette: ClawddyPalette) {
        self.rows = rows
        self.highlighted = highlighted
        self.palette = palette
        var y = Self.padding
        var headings: [(String, CGFloat)] = []
        var frames: [CGRect] = []
        var group: String?
        for row in rows {
            if row.group != group {
                group = row.group
                headings.append((row.group, y + 8))
                y += Self.heading
            }
            frames.append(CGRect(x: Self.padding, y: y, width: max(0, bounds.width - 2 * Self.padding), height: row.height))
            y += row.height
        }
        rowFrames = frames
        while rowLayers.count < rows.count {
            let layer = AgentPaletteRowLayer()
            self.layer?.addSublayer(layer)
            rowLayers.append(layer)
        }
        while headingLayers.count < headings.count {
            let layer = AgentTextLayer()
            self.layer?.addSublayer(layer)
            headingLayers.append(layer)
        }
        for (index, layer) in rowLayers.enumerated() {
            layer.isHidden = index >= rows.count
            guard index < rows.count else { continue }
            layer.show(rows[index], highlighted: index == highlighted, palette: palette)
        }
        for (index, layer) in headingLayers.enumerated() {
            layer.isHidden = index >= headings.count
            guard index < headings.count else { continue }
            layer.text = AgentText(
                string: headings[index].0, font: .systemFont(ofSize: 11, weight: .semibold),
                color: palette.text2.cgColor(), lineHeight: 16)
        }
        headingFrames = headings.map(\.1)
        needsLayout = true
    }

    private var headingFrames: [CGFloat] = []

    override func layout() {
        super.layout()
        for (index, frame) in rowFrames.enumerated() where index < rowLayers.count {
            let full = CGRect(x: Self.padding, y: frame.minY, width: max(0, bounds.width - 2 * Self.padding), height: frame.height)
            rowFrames[index] = full
            if rowLayers[index].frame != full { rowLayers[index].frame = full }
            rowLayers[index].layoutParts()
        }
        for (index, y) in headingFrames.enumerated() where index < headingLayers.count {
            headingLayers[index].frame = CGRect(x: Self.padding + 12, y: y, width: max(0, bounds.width - 2 * Self.padding - 24), height: 16)
        }
    }

    // MARK: Accessibility

    /// Each result as VoiceOver reads it (words.md "The palette"): a button
    /// whose Press runs it.
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Results" }
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityChildren() -> [Any]? {
        rows.indices.map { index in
            let element = AgentPaletteResult(index: index) { [weak self] in self?.onRun?(index) }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            switch rows[index] {
            case let .agent(hit, state, _):
                element.setAccessibilityLabel("\(hit.name), \(state.name), \(hit.project). \(hit.line)")
                element.setAccessibilityHelp("Press Return to open it.")
            case let .command(title, key, _):
                element.setAccessibilityLabel(key.map { "\(title), \($0)" } ?? title)
            }
            element.setAccessibilitySelected(index == highlighted)
            element.setAccessibilityFrameInParentSpace(rowFrames[index])
            return element
        }
    }

    /// Keeps the highlighted row in view, at once.
    func scrollToHighlight() {
        guard rowFrames.indices.contains(highlighted) else { return }
        let frame = rowFrames[highlighted]
        // The group heading above the first row comes into view with it.
        scrollToVisible(highlighted == 0 ? frame.union(CGRect(x: frame.minX, y: 0, width: 1, height: 1)) : frame)
    }

    /// The row under `point`, in the list.
    func row(at point: NSPoint) -> Int? { rowFrames.firstIndex { $0.contains(point) } }

    /// Where the pointer rests as the palette opens (window coordinates):
    /// only a move from there highlights a row, so a still pointer never
    /// takes the highlight.
    func primePointer(_ point: NSPoint) { lastPointer = point }

    /// The pointer at `point`, in window coordinates.
    func pointerMoved(to point: NSPoint) {
        defer { lastPointer = point }
        guard point != lastPointer, let index = row(at: convert(point, from: nil)), index != highlighted else { return }
        onHighlight?(index)
    }

    override func mouseDown(with event: NSEvent) {
        pressedRow = row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedRow = nil }
        guard let pressedRow, row(at: convert(event.locationInWindow, from: nil)) == pressedRow else { return }
        onRun?(pressedRow)
    }
}

/// A result row for VoiceOver.
final class AgentPaletteResult: NSAccessibilityElement {
    let index: Int
    private let run: () -> Void

    init(index: Int, run: @escaping () -> Void) {
        self.index = index
        self.run = run
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        run()
        return true
    }
}

/// One result row's layers: mark, name, the matching line, the project and
/// age or a command's key.
final class AgentPaletteRowLayer: AgentLayer {
    private let mark = AgentMarkLayer()
    private let title = AgentTextLayer()
    private let line = AgentTextLayer()
    private let right = AgentTextLayer()
    private let key = AgentKeyCap()
    private var row: AgentPaletteRow?

    override init() {
        super.init()
        cornerRadius = 8
        cornerCurve = .continuous
        mark.onScreen = false
        for part in [mark, title, line, right, key] as [CALayer] { addSublayer(part) }
    }

    override init(layer: Any) { super.init(layer: layer) }

    func show(_ row: AgentPaletteRow, highlighted: Bool, palette: ClawddyPalette) {
        self.row = row
        backgroundColor = highlighted ? ClawddyPalette.white(0.08) : nil
        let nameColor = (highlighted ? palette.ink : palette.text2).cgColor()
        let markFont = AgentMetrics.bodySemibold
        switch row {
        case let .agent(hit, state, age):
            mark.isHidden = false
            mark.palette = palette
            mark.state = state
            var heading = AgentText(string: hit.name, font: AgentMetrics.body, color: nameColor)
            heading.marks = hit.nameMatches.map { .init(range: $0, font: markFont, color: palette.ink.cgColor()) }
            title.text = heading
            var under = AgentText(string: hit.line, font: AgentMetrics.small, color: palette.text2.cgColor(), lineHeight: 17)
            under.marks = hit.lineMatches.map {
                .init(range: $0, font: .systemFont(ofSize: 12, weight: .semibold), color: palette.ink.cgColor())
            }
            line.text = under
            line.isHidden = false
            var side = AgentText(
                string: "\(hit.project)  \(age)", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                color: palette.text2.cgColor(), lineHeight: 18, alignment: .right)
            side.baseline = AgentMetrics.baseline(AgentMetrics.body, lineHeight: 18)
            right.text = side
            right.isHidden = false
            key.isHidden = true
        case let .command(words, shortcut, marks):
            mark.isHidden = true
            var heading = AgentText(string: words, font: AgentMetrics.body, color: nameColor)
            heading.marks = marks.map { .init(range: $0, font: markFont, color: palette.ink.cgColor()) }
            title.text = heading
            line.isHidden = true
            right.isHidden = true
            key.isHidden = shortcut == nil
            if let shortcut { key.show(shortcut, color: palette.text2.cgColor(), fill: ClawddyPalette.white(0.07)) }
        }
    }

    /// Columns 14 | text | right, gap 10, padding 7 12.
    func layoutParts() {
        let width = bounds.width
        let lineTop: CGFloat = 7
        switch row {
        case .agent?:
            let rightWidth = min(right.text?.width ?? 0, width * 0.4)
            right.frame = CGRect(x: width - 12 - rightWidth, y: lineTop + 9, width: rightWidth, height: 18)
            let textWidth = max(0, width - 12 - rightWidth - 10 - 36)
            let baseline = lineTop + AgentMetrics.baseline(AgentMetrics.body, lineHeight: 18)
            mark.frame = CGRect(x: 12, y: baseline - AgentMetrics.markLift - 7, width: 14, height: 14)
            title.frame = CGRect(x: 36, y: lineTop, width: textWidth, height: 18)
            line.frame = CGRect(x: 36, y: lineTop + 18, width: textWidth, height: 17)
        case .command?:
            let keyWidth = key.isHidden ? 0 : key.bounds.width
            key.frame = CGRect(x: width - 12 - keyWidth, y: lineTop + 1, width: keyWidth, height: 16)
            // Commands have no mark: their words start at the row's inset.
            title.frame = CGRect(x: 12, y: lineTop, width: max(0, width - 12 - keyWidth - 10 - 12), height: 18)
        case nil:
            break
        }
    }
}

/// The veil behind the palette: the window dimmed (native-look.md 2.1,
/// veil at 55 %); a click on it closes the palette.
final class AgentVeilView: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    func apply(_ palette: ClawddyPalette) {
        layer?.backgroundColor = palette.veil.cgColor(alpha: ClawddyPalette.veilAlpha)
    }
}
