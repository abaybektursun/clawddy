import AppKit

/// The typing line at the bottom of home (native-look.md 3.8, flows.md "The
/// line"): a raised slab, at most 960 pt wide, holding the chip that names
/// where typing goes, the text (`AgentTextView`, 14/22), and the end
/// controls: "N settled" and ⌘N while empty, the send disk while it holds
/// text, with "⌘↩ interrupt them and send" before it when several agents are
/// selected. It grows upward a line at a time to six lines, then scrolls;
/// the text stays where it is while the slab's top edge rises.
///
/// It decides nothing: what typing does, and where the keys go, is the
/// controller's (`AgentLineActions`).
final class AgentLineView: NSView, AgentActivationClickSafeRegion {
    static let maxWidth: CGFloat = 960
    /// From the window's bottom to the slab's.
    static let bottom: CGFloat = 18
    /// The space home gives up at its bottom for the line at rest.
    static let reserved: CGFloat = 62
    /// The tallest row of the slab at rest: the end controls.
    static let restRow: CGFloat = 26

    let textView = AgentTextView(font: .systemFont(ofSize: 14, weight: .regular), lineHeight: 22, maxLines: 6, inset: NSSize(width: 0, height: 1))
    private let scroll = NSScrollView()
    /// The lift shadow of the focused line, on a layer of its own behind
    /// the edge, so the shadow never darkens the edge's lower side.
    private let lift = AgentLayer()
    private let edge = AgentLayer()
    private let slab = AgentLayer()
    private let topLight = AgentShapeLayer()
    let chip = AgentChip()
    let settled = AgentButton()
    private let settledLabel = AgentTextLayer()
    private let newKey = AgentKeyCap()
    private let interruptKey = AgentKeyCap()
    private let interruptLabel = AgentTextLayer()
    let send = AgentButton()
    private let disk = AgentLayer()
    private let arrow = AgentSymbolLayer()
    private let reveal = AgentLayer()

    private var palette = ClawddyPalette.prototype
    private(set) var chipText = ""
    private(set) var many = false
    private(set) var settledCount = 0
    /// The line has the keys: its edge brightens and it casts a shadow.
    private(set) var isFocused = false

    /// Return or the send disk; `interrupting` for ⌘↩.
    var onSubmit: ((Bool) -> Void)?
    /// "N settled".
    var onSettled: (() -> Void)?
    /// A click on the slab outside the text and its controls.
    var onClick: (() -> Void)?
    /// The slab's height changed: the window places it again.
    var onHeight: (() -> Void)?
    /// The text changed (the project's draft follows).
    var onText: ((String) -> Void)?
    /// A press on the chip while it offers the CLI: the controller shows its
    /// menu under it.
    var onChip: ((NSView) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        edge.cornerRadius = 13
        edge.cornerCurve = .continuous
        edge.borderWidth = 1
        slab.name = "slab"
        slab.cornerRadius = 12
        slab.cornerCurve = .continuous
        lift.shadowColor = CGColor(gray: 0, alpha: 1)
        lift.shadowOffset = CGSize(width: 0, height: 4)
        lift.shadowRadius = 12
        lift.shadowOpacity = 0
        topLight.fillColor = nil
        topLight.lineWidth = 1
        topLight.masksToBounds = true
        for part in [lift, edge, slab, topLight] as [CALayer] { layer?.addSublayer(part) }

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.focusRingType = .none
        scroll.contentView.drawsBackground = false
        scroll.contentView.focusRingType = .none
        scroll.documentView = textView
        scroll.wantsLayer = true
        // The rising top edge reveals the lines above (`grow`).
        reveal.backgroundColor = CGColor(gray: 0, alpha: 1)
        scroll.layer?.mask = reveal
        addSubview(scroll)
        textView.onChange = { [weak self] in self?.textChanged() }

        addSubview(chip)
        chip.onPress = { [weak self] in
            guard let self else { return }
            self.onChip?(self.chip)
        }
        addSubview(settled)
        settled.fills = (0, 0.05, 0.10)
        settled.layer?.addSublayer(settledLabel)
        settled.onPhase = { [weak self] _ in self?.styleSettled() }
        settled.onPress = { [weak self] in self?.onSettled?() }
        layer?.addSublayer(newKey)
        layer?.addSublayer(interruptKey)
        layer?.addSublayer(interruptLabel)

        addSubview(send)
        send.layer?.cornerRadius = 13
        send.fills = (0, 0, 0)
        disk.cornerRadius = 13
        send.layer?.addSublayer(disk)
        disk.addSublayer(arrow)
        send.onPhase = { [weak self] phase in self?.pressDisk(phase == .pressed) }
        send.onPress = { [weak self] in self?.onSubmit?(false) }
        send.setAccessibilityLabel("Start")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A click on the slab that is not on the text or a control puts the
    /// caret in the text.
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    // MARK: What it shows

    /// Where typing goes, in words (words.md, "The line").
    struct Words: Equatable {
        /// The chip; `many` sets it brighter ("To N agents").
        var chip: String
        var many = false
        /// The CLI a new agent uses: the chip then changes it.
        var cli: String?
        var placeholder: String
        /// The text's VoiceOver label, and the send disk's.
        var accessibility: String
        var sendLabel = "Start"
    }

    /// The words, the project's settled count, the colours.
    func show(_ words: Words, settled count: Int, palette: ClawddyPalette) {
        let text = words.chip, many = words.many, placeholder = words.placeholder
        let accessibility = words.accessibility, sendLabel = words.sendLabel
        let restyle = palette != self.palette || text != chipText || many != self.many || count != settledCount
            || words.cli != chip.cli
        self.palette = palette
        chipText = text
        self.many = many
        settledCount = count
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(accessibility)
        textView.setAccessibilityPlaceholderValue(placeholder)
        send.setAccessibilityLabel(sendLabel)
        guard restyle else { return }
        textView.apply(palette)
        chip.show(text, many: many, cli: words.cli, palette: palette)
        slab.backgroundColor = palette.raised.cgColor()
        disk.backgroundColor = palette.ink.cgColor()
        arrow.symbol = .init(name: "arrow.up", pointSize: 12, weight: .bold, color: palette.canvas, box: 26, scale: AgentMetrics.scale)
        newKey.show("⌘N", color: palette.text3.cgColor(), fill: nil)
        interruptKey.show("⌘↩", color: palette.text3.cgColor(), fill: nil)
        interruptLabel.text = AgentText(string: "interrupt them and send", font: AgentMetrics.body, color: palette.text3.cgColor())
        styleSettled()
        applyFocusLook()
        needsLayout = true
    }

    /// Whether the line has the keys, which only its text view's becoming
    /// and leaving first responder say: set at once, never animated.
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        applyFocusLook()
    }

    private func applyFocusLook() {
        edge.borderColor = isFocused ? palette.ink.cgColor(alpha: 0.32) : ClawddyPalette.white(0.07)
        topLight.strokeColor = ClawddyPalette.white(isFocused ? 0.10 : 0.06)
        lift.shadowOpacity = isFocused ? 0.28 : 0
    }

    private func styleSettled() {
        let color = settled.phase == .rest ? palette.text3 : palette.text2
        settledLabel.text = AgentText(string: "\(settledCount) settled", font: AgentMetrics.body, color: color.cgColor())
        settled.setAccessibilityLabel("\(settledCount) settled")
    }

    /// The send disk pressed: 92 % at once, back over 100 ms (Reduce
    /// Motion: 80 % opacity instead).
    private func pressDisk(_ pressed: Bool) {
        if AgentMotion.reduced {
            disk.opacity = pressed ? 0.8 : 1
            return
        }
        let scale = CATransform3DMakeScale(pressed ? 0.92 : 1, pressed ? 0.92 : 1, 1)
        if pressed {
            disk.removeAnimation(forKey: "transform")
            disk.transform = scale
        } else {
            AgentMotion.animate(disk, "transform", to: scale, duration: AgentMotion.duration(.move(AgentMotion.gone), in: self))
        }
    }

    // MARK: Size

    /// The slab's height: 9 pt above the text and 11 below it, so one line
    /// sits on the controls' 26 pt row (44 in all, as the prototype) and the
    /// line holding the caret stays where it was as the text grows.
    var slabHeight: CGFloat { textView.textHeight + 20 }

    private var hasText: Bool { !textView.string.isEmpty || textView.hasMarkedText() }

    private var lastHeight: CGFloat = 0

    /// Text typed, pasted, undone or composed: the ends follow, and the slab
    /// grows or shrinks with its top edge, the text staying where it is.
    private func textChanged() {
        // Text an input method has not committed is not a draft yet.
        if !textView.hasMarkedText() { onText?(textView.string) }
        let height = slabHeight
        if height != lastHeight {
            let before = lastHeight
            lastHeight = height
            onHeight?()
            if before > 0 { grow(from: before, to: height) }
        }
        needsLayout = true
    }

    /// Every final frame is already set; only the slab's background layers
    /// and the text's reveal move, from the old top to the new, over 150 ms.
    private func grow(from old: CGFloat, to new: CGFloat) {
        let duration = AgentMotion.duration(.move(AgentMotion.small), in: self)
        guard duration > 0 else { return }
        layoutSubtreeIfNeeded()
        let shift = new - old
        for part in [lift, slab, edge] as [CALayer] {
            let to = part.position
            let from = CGPoint(x: to.x, y: to.y + shift / 2)
            let toBounds = part.bounds
            let fromBounds = CGRect(origin: toBounds.origin, size: CGSize(width: toBounds.width, height: max(0, toBounds.height - shift)))
            AgentMotion.animate(part, "position", to: NSValue(point: to), duration: duration, from: NSValue(point: from))
            AgentMotion.animate(part, "bounds", to: NSValue(rect: toBounds), duration: duration, from: NSValue(rect: fromBounds))
            if part === lift {
                // The shadow follows the slab as it grows.
                AgentMotion.animate(
                    lift, "shadowPath", to: CGPath.continuousRoundedRect(toBounds, radius: 12), duration: duration,
                    from: CGPath.continuousRoundedRect(fromBounds, radius: 12))
            }
        }
        // The top light rides on the slab's top edge.
        let lightTo = topLight.position
        AgentMotion.animate(topLight, "position", to: NSValue(point: lightTo), duration: duration,
                            from: NSValue(point: CGPoint(x: lightTo.x, y: lightTo.y + shift)))
        let to = reveal.frame
        let from = CGRect(x: to.minX, y: to.minY + max(0, shift), width: to.width, height: max(0, to.height - max(0, shift)))
        AgentMotion.animate(reveal, "position", to: NSValue(point: CGPoint(x: to.midX, y: to.midY)), duration: duration,
                            from: NSValue(point: CGPoint(x: from.midX, y: from.midY)))
        AgentMotion.animate(reveal, "bounds", to: NSValue(rect: CGRect(origin: .zero, size: to.size)), duration: duration,
                            from: NSValue(rect: CGRect(origin: .zero, size: from.size)))
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        lastHeight = height
        edge.frame = bounds.insetBy(dx: -1, dy: -1)
        slab.frame = bounds
        lift.frame = bounds
        lift.shadowPath = CGPath.continuousRoundedRect(bounds, radius: 12)
        topLight.frame = CGRect(x: 0, y: 0, width: width, height: 12)
        topLight.path = CGPath.topLight(bounds.size, radius: 12, inset: 0)

        // The ends, from the right, on the bottom of the row.
        let endsTop = height - 9 - Self.restRow
        var right = width - 10
        let typed = hasText
        send.isHidden = !typed
        settled.isHidden = typed || settledCount == 0
        newKey.isHidden = typed
        interruptKey.isHidden = !(typed && many)
        interruptLabel.isHidden = interruptKey.isHidden
        if typed {
            send.frame = NSRect(x: right - 26, y: endsTop, width: 26, height: 26)
            disk.frame = send.bounds
            arrow.frame = disk.bounds
            right -= 26
            if many {
                right -= 12
                let labelWidth = interruptLabel.text?.width ?? 0
                interruptLabel.frame = CGRect(x: right - labelWidth, y: endsTop + 4, width: labelWidth, height: 18)
                right -= labelWidth + 6
                let keyWidth = interruptKey.bounds.width
                interruptKey.frame = CGRect(x: right - keyWidth, y: endsTop + 5, width: keyWidth, height: 16)
                right -= keyWidth
            }
        } else {
            let keyWidth = newKey.bounds.width
            newKey.frame = CGRect(x: right - keyWidth, y: endsTop + 5, width: keyWidth, height: 16)
            right -= keyWidth
            if settledCount > 0 {
                right -= 12
                let labelWidth = settledLabel.text?.width ?? 0
                settled.frame = NSRect(x: right - labelWidth - 16, y: endsTop + 1, width: labelWidth + 16, height: 24)
                settledLabel.frame = CGRect(x: 8, y: 3, width: labelWidth, height: 18)
                right = settled.frame.minX
            }
        }

        // The chip, on the first text line's baseline.
        let textTop: CGFloat = 9
        let baseline = textTop + textView.firstBaseline
        let chipWidth = chip.fittingWidth
        let chipTop = AgentMetrics.snap(baseline - 3 - AgentMetrics.baseline(AgentMetrics.bodyMedium, lineHeight: 18))
        chip.frame = NSRect(x: 10, y: chipTop, width: chipWidth, height: 24)

        // The text between, as tall as its lines.
        let textX = 10 + chipWidth + 10
        let textWidth = max(40, right - 10 - textX)
        // The text's height at the width it has now, whatever changed that
        // width (typing, the chip, the window): measured after it is set.
        if textView.frame.width != textWidth { textView.frame.size.width = textWidth }
        let textHeight = textView.textHeight
        let frame = NSRect(x: textX, y: textTop, width: textWidth, height: textHeight)
        if scroll.frame != frame { scroll.frame = frame }
        reveal.frame = CGRect(origin: .zero, size: frame.size)
        if textView.lineCount > textView.maxLines { textView.scrollRangeToVisible(textView.selectedRange()) }
        // The slab follows its text: a host that sized it for other text
        // places it again, at once, and the slab is laid out at its new
        // height in this same pass.
        if slabHeight != height {
            onHeight?()
            if bounds.height != height { layout() }
        }
    }

    // MARK: For the harness and tests

    /// The slab drawn, which must be as tall as the view.
    var slabFrame: CGRect { slab.frame }

    /// The baselines of the chip's words and of the text's first line, in
    /// the window's coordinates from its top: equal to the pixel.
    var baselines: (chip: CGFloat, text: CGFloat) {
        let chipBaseline = chip.frame.minY + 3 + AgentMetrics.baseline(AgentMetrics.bodyMedium, lineHeight: 18)
        let textBaseline = scroll.frame.minY + textView.firstBaseline
        return (convert(NSPoint(x: 0, y: chipBaseline), to: nil).y, convert(NSPoint(x: 0, y: textBaseline), to: nil).y)
    }
}
