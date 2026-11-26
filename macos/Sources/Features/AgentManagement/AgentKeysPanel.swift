import AppKit

/// The keys panel under the Keys button (native-look.md 3.10, words.md
/// "Keys panel"): an opaque raised surface listing the keys in three groups,
/// scrolling when taller than the window. It never takes the keyboard; a
/// click anywhere outside it, the Keys button again, or ⌘? closes it.
final class AgentKeysPanel: NSView, AgentActivationClickSafeRegion {
    static let width: CGFloat = 370

    /// Each row's keys, one cap per chord, and what they do.
    static let groups: [(title: String, rows: [(keys: [String], text: String)])] = [
        ("Move", [
            (["← ↑ → ↓"], "Move between tiles. Shift selects a range"),
            (["⌘J"], "Walk everyone waiting on you, one press each, then return"),
            (["⌘⎋"], "Back to all agents. Pinching together does the same"),
            (["⌘1 … 9"], "Open the agent in that place. Hold ⌘ to see numbers"),
            (["⌘[", "⌘]"], "Previous and next agent"),
            (["⇧⌘[", "⇧⌘]"], "Previous and next project"),
            (["⌘P"], "Find an agent or run a command"),
        ]),
        ("Agents", [
            (["type"], "On one selected tile: replies in its terminal. With none: starts a new agent"),
            (["↩"], "On a tile: open its terminal. In the line: start or send"),
            (["⌘N"], "New agent: a floating line, at home and inside a terminal"),
            (["⇥"], "In a new-agent line: change the CLI. Shift goes back"),
            (["⌘D"], "Settle. During a walk, settles and moves to the next"),
            (["⌘Z"], "Undo settle or project removal. In an empty line, cancels a start"),
            (["⌘U"], "Mark as unread"),
            (["F2"], "Rename"),
            (["⌘C"], "Copy the selected agents' sentences"),
            (["⌘O"], "Add a project folder"),
        ]),
        ("Grid", [
            (["⌘−"], "Smaller tiles"),
            (["⌘+"], "Larger tiles"),
            (["⌘0"], "Default tile size"),
            (["⌥←", "⌥→"], "Move the selected tile earlier or later. Dragging does the same"),
        ]),
    ]
    static let closing = "Inside a terminal, every key without ⌘ goes to the terminal. With several tiles selected, typing writes one instruction for all of them."

    /// The rounded, opaque surface; it clips what scrolls inside it.
    private let surface = AgentFlippedView()
    private let scroll = NSScrollView()
    private let document = AgentFlippedView()
    private let topLight = AgentLayer()
    private var headings: [AgentTextLayer] = []
    private var caps: [[AgentKeyCap]] = []
    private var texts: [AgentTextLayer] = []
    private let closingText = AgentTextLayer()
    private var palette: ClawddyPalette = .prototype
    /// The height its content wants.
    private(set) var contentHeight: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = CGColor(gray: 0, alpha: 1)
        layer?.shadowOpacity = 0.55
        layer?.shadowRadius = 35
        layer?.shadowOffset = CGSize(width: 0, height: 24)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        surface.layer?.masksToBounds = true
        addSubview(surface)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        scroll.documentView = document
        surface.addSubview(scroll)
        document.wantsLayer = true
        for group in Self.groups {
            let heading = AgentTextLayer()
            headings.append(heading)
            document.layer?.addSublayer(heading)
            for row in group.rows {
                let rowCaps = row.keys.map { _ in AgentKeyCap() }
                let text = AgentTextLayer()
                caps.append(rowCaps)
                texts.append(text)
                for cap in rowCaps { document.layer?.addSublayer(cap) }
                document.layer?.addSublayer(text)
            }
        }
        document.layer?.addSublayer(closingText)
        // Inside the clip, so it follows the continuous corners.
        surface.layer?.addSublayer(topLight)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Keys")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }
    override var acceptsFirstResponder: Bool { false }

    func apply(_ palette: ClawddyPalette) {
        self.palette = palette
        surface.layer?.backgroundColor = palette.pop.cgColor()
        surface.layer?.borderColor = ClawddyPalette.white(0.11)
        topLight.backgroundColor = ClawddyPalette.white(0.06)
        var index = 0
        let description = AgentText(string: "", font: AgentMetrics.body, color: palette.text2.cgColor(), maxLines: 3)
        for (groupIndex, group) in Self.groups.enumerated() {
            headings[groupIndex].text = AgentText(string: group.title, font: AgentMetrics.bodySemibold, color: palette.ink.cgColor())
            for row in group.rows {
                for (cap, keys) in zip(caps[index], row.keys) {
                    cap.show(keys, color: palette.text2.cgColor(), fill: ClawddyPalette.white(0.07))
                }
                var text = description
                text.string = row.text
                texts[index].text = text
                index += 1
            }
        }
        var closing = description
        closing.string = Self.closing
        closing.maxLines = 4
        closingText.text = closing
        layoutContent()
    }

    /// Lays the groups out down the panel: padding 12 15, headings 5 pt
    /// above their rows and 11 pt below the group before, rows 4 pt apart,
    /// key caps in one column 12 pt before the descriptions, centred on
    /// their description's lines, a row's caps 4 pt apart.
    private func layoutContent() {
        let inner = Self.width - 30
        let capColumn = caps.map { row in row.map(\.bounds.width).reduce(0, +) + CGFloat(max(0, row.count - 1)) * 4 }.max() ?? 0
        let textX = 15 + capColumn + 12
        let textWidth = Self.width - 15 - textX
        var y: CGFloat = 12
        var index = 0
        for (groupIndex, group) in Self.groups.enumerated() {
            if groupIndex > 0 { y += 11 }
            headings[groupIndex].frame = CGRect(x: 15, y: y, width: inner, height: 18)
            y += 18 + 5
            for _ in group.rows {
                let lines = texts[index].text.map { AgentTextLayer.lines(of: $0, width: textWidth).count } ?? 1
                let height = CGFloat(lines) * 18
                texts[index].frame = CGRect(x: textX, y: y, width: textWidth, height: height)
                var capX: CGFloat = 15
                for cap in caps[index] {
                    cap.frame.origin = CGPoint(x: capX, y: y + ((height - 16) / 2).rounded())
                    capX += cap.bounds.width + 4
                }
                y += height + 4
                index += 1
            }
        }
        y += 4
        let closingLines = closingText.text.map { AgentTextLayer.lines(of: $0, width: inner).count } ?? 1
        closingText.frame = CGRect(x: 15, y: y, width: inner, height: CGFloat(closingLines) * 18)
        y += CGFloat(closingLines) * 18 + 12
        contentHeight = y
        document.setFrameSize(NSSize(width: Self.width, height: y))
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        scroll.frame = surface.bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        // A 1 pt line of light just inside the rim, along the top edge.
        topLight.frame = CGRect(x: 0, y: 1, width: bounds.width, height: 1)
    }

    /// Shows or hides the panel: in over 150 ms, out over 100 ms.
    func setShown(_ shown: Bool) {
        guard shown == isHidden || layer?.opacity == 0 else { return }
        if shown {
            // Opened again while it fades out: back from what is on screen.
            if isHidden { layer?.opacity = 0 }
            isHidden = false
            AgentMotion.fade(layer!, to: 1, duration: AgentMotion.small, in: self)
        } else {
            AgentMotion.run({
                AgentMotion.fade(layer!, to: 0, duration: AgentMotion.gone, in: self)
            }, then: { [weak self] in
                guard let self, self.layer?.opacity == 0 else { return }
                self.isHidden = true
            })
        }
    }

    var isShown: Bool { !isHidden && layer?.opacity != 0 }
}
