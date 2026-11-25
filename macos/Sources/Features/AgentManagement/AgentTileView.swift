import AppKit

/// One agent at home (native-look.md 3.3, flows.md "A tile"): its mark,
/// name and age; its sentence; and its screen, the last lines of its
/// terminal as plain text in the terminal's font. The screen is off (dim)
/// unless the agent waits on the person; then it is lit with the theme's own
/// background, and a question or a problem adds a 2 pt line along the top
/// edge.
///
/// The tile is built once: a change of its agent sets the layers it changes,
/// in place; its frame is the grid's alone. Its content sits in one layer,
/// `content`, which S10's enter motion hides while the terminal grows from
/// the tile's rectangle.
final class AgentTileView: NSView, AgentActivationClickSafeRegion, AgentHoverable, AgentNameHost {
    let agentID: UUID
    private weak var agent: AgentInstance?
    /// Everything the tile shows over its background.
    let content = AgentLayer()
    private let ring = AgentLayer()
    /// The tile's surface: its background, its 1 pt rim and, picked up, its
    /// first shadow; under its content, so the rim never draws over the top
    /// edge. Its second shadow is `under`'s.
    private let surface = AgentLayer()
    private let under = AgentLayer()
    private let seam = AgentShapeLayer()
    private let screen = AgentLayer()
    private let body = AgentTextLayer()
    private let head = AgentTextLayer()
    private let mark = AgentMarkLayer()
    private let title = AgentTextLayer()
    private let age = AgentTextLayer()
    private let say = AgentTextLayer()
    private let badge = AgentLayer()
    private let badgeNumber = AgentTextLayer()
    private var observer: AgentObserver?
    /// Over the tile while its agent is settled and its place stays at home
    /// (native-look.md 3.4); made when first needed.
    private(set) var settledPlace: AgentSettledPlaceView?
    /// The Undo of a settled place.
    var onUndo: (() -> Void)?

    var palette: ClawddyPalette { didSet { if palette != oldValue { update(force: true) } } }
    var font: AgentTerminalFont {
        didSet {
            guard font != oldValue else { return }
            // The newest three lines' height follows the pitch.
            needsLayout = true
            screenStale = true
            if isOnScreen { refreshScreen() }
        }
    }
    /// Home is scrolling: the tile sets nothing now, so every frame of the
    /// scroll is only the scroll; the tick brings it up to date after.
    var holdsStill: () -> Bool = { false }
    /// The live terminal's text, when the agent has a terminal.
    var screenText: (UUID) -> String? = { _ in nil }
    /// Mouse-down: the grid selects.
    var onPress: ((UUID, NSEvent) -> Void)?
    /// Released without moving: the grid enters.
    var onClick: ((UUID) -> Void)?
    /// Moved more than 4 pt while pressed: the grid moves the tile; with
    /// where the press was, in the window.
    var onDrag: ((UUID, NSEvent, NSPoint) -> Void)?
    /// Released after moving.
    var onDrop: (() -> Void)?
    var onRightClick: ((UUID, NSEvent) -> Void)?
    private var dragging = false
    var now: () -> Date = Date.init

    private(set) var isSelected = false
    private(set) var isCursor = false
    private(set) var tilesHaveKeys = false
    var isHovered = false { didSet { if isHovered != oldValue { applyBackground(animated: !isHovered) } } }
    private var isPressed = false { didSet { if isPressed != oldValue { applyBackground(animated: !isPressed) } } }
    private var pressedAt: NSPoint?

    /// What the tile shows of its agent, compared before anything is set.
    private struct Shown: Equatable {
        var name: String
        var state: AgentShownState
        var waiting: Bool
        var sentence: AgentSentence
        var changedAt: Date
    }
    private var shown: Shown?
    private var lines: [String] = []
    /// Layout passes, for the tests that a change of state lays out nothing
    /// but the tile's own parts.
    private(set) var layouts = 0
    /// How many times its text layers have drawn.
    var draws: Int { [body, head, title, age, say].map(\.draws).reduce(0, +) }

    init(agent: AgentInstance, palette: ClawddyPalette, font: AgentTerminalFont) {
        agentID = agent.id
        self.agent = agent
        self.palette = palette
        self.font = font
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        // Its top left is its place, so a held picture of it (a density
        // change) stays where its lines begin.
        say.anchorPoint = .zero
        ring.cornerCurve = .continuous
        for part in [surface, under] {
            part.cornerRadius = 12
            part.cornerCurve = .continuous
            part.shadowColor = CGColor(gray: 0, alpha: 1)
            part.shadowOpacity = 0
        }
        surface.borderWidth = 1
        for part in [ring, under, surface, content] { layer?.addSublayer(part) }
        mark.onScreen = false
        screen.cornerRadius = 8
        screen.cornerCurve = .continuous
        for part in [body, head] as [CALayer] {
            // The text is typeset here and rasterised off the main thread.
            part.drawsAsynchronously = true
            screen.addSublayer(part)
        }
        seam.fillRule = .evenOdd
        seam.masksToBounds = true
        for part in [seam, screen, mark, title, age, say, badge] as [CALayer] { content.addSublayer(part) }
        badge.cornerRadius = 4
        badge.cornerCurve = .continuous
        badge.borderWidth = 1
        badge.addSublayer(badgeNumber)
        badge.opacity = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Press Return to open its terminal, or type to reply.")
        observer = AgentObserver { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: The agent

    /// Follows the agent (its observer): on screen, sets what changed at
    /// once; off screen, or while home is hidden, does nothing but note that
    /// it is out of date, for the grid to bring it up to date later
    /// (`update`), never in the frame of a scroll.
    func refresh() {
        guard let agent else { return }
        // Read on every change, so the observer keeps following all of it.
        let next = shownNow(agent)
        _ = agent.savedScreen
        guard isOnScreen, !holdsStill() else {
            if next != shown { agentStale = true }
            screenStale = true
            return
        }
        // The screen is read again once per change of state; a working
        // agent's screen follows its terminal on the 4 Hz tick, not each
        // report of its activity (native-look.md 5).
        let stateChanged = next.state != shown?.state || next.waiting != shown?.waiting
        apply(next, force: false)
        if stateChanged { refreshScreen() }
    }

    private func shownNow(_ agent: AgentInstance) -> Shown {
        Shown(
            name: agent.name, state: agent.shownState, waiting: agent.record.isWaitingOnYou,
            sentence: agent.sentence, changedAt: agent.record.changedAt)
    }

    /// Sets what changed of the agent; `force` sets everything (a palette).
    private func apply(_ next: Shown, force: Bool) {
        agentStale = false
        let changed = next != shown
        let before = shown
        let lit = Lit(screen: screen.backgroundColor, body: body.opacity, head: head.opacity, seam: seam.opacity)
        shown = next
        guard changed || force else { return }
        applyAgent()
        needsLayout = true
        if let before, before.waiting != next.waiting || (before.state != next.state && seam.opacity != lit.seam) {
            light(from: lit, lighting: next.waiting && !before.waiting, changesScreen: before.waiting != next.waiting)
        }
    }

    /// The screen lights (the agent came to wait on the person) over
    /// 400 ms, or powers down over 200 ms; the top line fades in or out over
    /// 200 ms in its colour (flows.md 7). Only in view; 100 ms fades under
    /// Reduce Motion.
    private struct Lit {
        var screen: CGColor?
        var body: Float
        var head: Float
        var seam: Float
    }

    private func light(from old: Lit, lighting: Bool, changesScreen: Bool) {
        let visible = isOnScreen && (window?.occlusionState.contains(.visible) ?? false)
        let screenTime = AgentMotion.duration(.fade(lighting ? AgentMotion.light : AgentMotion.big), reduced: AgentMotion.reduced, visible: visible)
        let lineTime = AgentMotion.duration(.fade(AgentMotion.big), reduced: AgentMotion.reduced, visible: visible)
        if changesScreen {
            AgentMotion.animate(screen, "backgroundColor", to: screen.backgroundColor, duration: screenTime, from: old.screen)
            AgentMotion.animate(body, "opacity", to: body.opacity, duration: screenTime, from: old.body)
            AgentMotion.animate(head, "opacity", to: head.opacity, duration: screenTime, from: old.head)
        }
        AgentMotion.animate(seam, "opacity", to: seam.opacity, duration: lineTime, from: old.seam)
    }

    /// Brings everything it shows up to date: its agent and its screen.
    func update(force: Bool = false) {
        guard let agent else { return }
        apply(shownNow(agent), force: force)
        refreshScreen()
    }

    /// The tile is in the visible part of home, which the grid decides:
    /// only then does it follow its agent and its mark turn.
    var isOnScreen = false {
        didSet {
            guard isOnScreen != oldValue else { return }
            mark.onScreen = isOnScreen
        }
    }

    /// Its agent changed while it was out of view.
    private(set) var agentStale = true
    /// Its terminal text may have changed since it was last read.
    private(set) var screenStale = true
    var isStale: Bool { agentStale || screenStale }
    /// Its screen has been drawn at least once.
    private(set) var hasDrawnScreen = false

    /// Reads the terminal's last lines again: the live terminal's, or those
    /// saved when its CLI last ran. Draws only when they changed.
    func refreshScreen() {
        guard let agent else { return }
        guard let shown else { return update() }
        screenStale = false
        hasDrawnScreen = true
        let text = screenText(agentID) ?? agent.savedScreen
        let next = AgentTail.lines(text, provider: agent.provider, sentence: shown.state == .working ? nil : shown.sentence.text)
        guard next != lines || body.text?.font != font.font else { return }
        lines = next
        applyScreenText()
    }

    /// Everything it shows of its terminal is out of date: home was hidden.
    func markScreenStale() { screenStale = true }

    /// The age moves on.
    func tick() {
        if isOnScreen { applyAge() } else { agentStale = true }
    }

    func setSelection(selected: Bool, cursor: Bool, tilesHaveKeys: Bool) {
        guard selected != isSelected || cursor != isCursor || tilesHaveKeys != self.tilesHaveKeys else { return }
        isSelected = selected
        isCursor = cursor
        self.tilesHaveKeys = tilesHaveKeys
        applyBackground(animated: false)
        applyRing()
        applyScreenOpacity()
    }

    // MARK: Drawing

    private func applyAgent() {
        guard let shown else { return }
        mark.palette = palette
        mark.state = shown.state
        title.text = AgentText(
            string: shown.name, font: AgentMetrics.bodySemibold,
            color: (shown.waiting ? palette.ink : palette.text2).cgColor())
        // The app's own words are italic: primary on a waiting tile,
        // tertiary on the others (flows.md 4.2).
        let font = shown.sentence.isAppWritten ? AgentMetrics.italic(AgentMetrics.body) : AgentMetrics.body
        let sentenceColor = shown.waiting ? palette.ink : shown.sentence.isAppWritten ? palette.text3 : palette.text2
        say.text = AgentText(string: shown.sentence.text, font: font, color: sentenceColor.cgColor(), maxLines: sentenceLines)
        surface.borderColor = ClawddyPalette.white(palette.rimAlpha)
        screen.backgroundColor = (shown.waiting ? palette.screenLit : palette.screenOff).cgColor()
        let seamColor: ClawddyPalette.RGB? = switch shown.state {
        case .asks, .limitReset: palette.signal
        case .problem: palette.problem
        default: nil
        }
        // A top line fading out keeps its last colour.
        if let seamColor { seam.fillColor = seamColor.cgColor() }
        seam.opacity = seamColor == nil ? 0 : 1
        applyAge()
        applyBackground(animated: false)
        applyScreenOpacity()
        toolTip = "\(shown.name)\n\(shown.sentence.text)"
        // Names the harness finds its moving layers by.
        layer?.name = "tile:\(shown.name)"
        screen.name = "tileScreen:\(shown.name)"
        body.name = "tileBody:\(shown.name)"
        seam.name = "tileSeam:\(shown.name)"
        surface.name = "tileSurface:\(shown.name)"
        setAccessibilityLabel(shown.name)
        let ageSeconds = now().timeIntervalSince(shown.changedAt)
        setAccessibilityValue("\(shown.state.name), \(shown.state.agePhrase(ageSeconds)). \(shown.sentence.text)")
    }

    private func applyAge() {
        guard let shown else { return }
        let string = AgentAge.short(now().timeIntervalSince(shown.changedAt))
        let color = (shown.waiting ? palette.text2 : palette.text3).cgColor()
        // Unchanged words cost nothing, not even a measure.
        if let current = age.text, current.string == string, current.color == color { return }
        var text = AgentText(string: string, font: AgentMetrics.digits11, color: color, alignment: .right)
        // On the name's baseline.
        text.baseline = AgentMetrics.baseline(AgentMetrics.body, lineHeight: 18)
        let before = age.text?.width
        age.text = text
        if before != text.width { needsLayout = true }
    }

    private func applyScreenText() {
        let older = lines.dropLast(3).joined(separator: "\n")
        let newest = lines.suffix(3).joined(separator: "\n")
        let color = palette.tileText.cgColor()
        body.text = AgentText(string: older, font: font.font, color: color, lineHeight: font.pitch, terminalLines: true, fade: screenFade)
        head.text = AgentText(string: newest, font: font.font, color: color, lineHeight: font.pitch, terminalLines: true)
    }

    /// The screen's text tones, as contrast ratios the theme's foreground
    /// is dimmed to (`ClawddyPalette.TileTone`): lit, older lines 4.8:1 and
    /// the newest three 10:1; off, 3.8:1 on a selected tile, 2.3:1 while
    /// working, else 1.7:1 (the prototype's 62 %, 100 %, 50 %, 30 % and 20 %
    /// of #d7dae0).
    private func applyScreenOpacity() {
        guard let shown else { return }
        let (older, newest): (ClawddyPalette.TileTone, ClawddyPalette.TileTone) = if shown.waiting {
            (.litOlder, .litNewest)
        } else if isSelected {
            (.selected, .selected)
        } else if shown.state == .working {
            (.working, .working)
        } else {
            (.quiet, .quiet)
        }
        body.opacity = palette.tileTextOpacity(older)
        head.opacity = palette.tileTextOpacity(newest)
    }

    /// Panel at rest; raised when selected, except a waiting tile, whose lit
    /// screen keeps its edge; white 1.6 % over it on hover, 3.6 % pressed,
    /// set at once and back over 150 ms.
    private func applyBackground(animated: Bool) {
        guard let shown else { return }
        let layer = surface
        let base = isLifted || (isSelected && !shown.waiting) ? palette.raised : palette.panel
        let lift = isPressed ? 0.036 : isHovered ? 0.016 : 0
        let color = base.blended(with: .init(red: 1, green: 1, blue: 1), opacity: lift).cgColor()
        AgentMotion.animate(layer, "backgroundColor", to: color, duration: animated ? AgentMotion.duration(.fade(AgentMotion.small), in: self) : 0)
    }

    /// A new tile's background starts at `color` (two steps up, so it is
    /// not read as selected) and returns to its own over 1.4 s; kept under
    /// Reduce Motion, where colours fade in 100 ms.
    /// Fades in at its place (its own layers: AppKit owns its backing
    /// layer's opacity).
    func fadeIn(duration: CFTimeInterval) {
        for part in [surface, under, ring, content] {
            AgentMotion.animate(part, "opacity", to: Float(1), duration: duration, from: Float(0))
        }
    }

    func flash(from color: ClawddyPalette.RGB) {
        let duration = AgentMotion.duration(
            .fade(AgentMotion.flash), reduced: false, visible: window?.occlusionState.contains(.visible) ?? false)
        AgentMotion.animate(surface, "backgroundColor", to: surface.backgroundColor, duration: duration, from: color.cgColor())
    }

    /// The selection ring, 2 pt outside the tile, radius 14: 1.5 pt at 55 %
    /// ink on the cursor while the tiles have the keys, else 1 pt at 30 %.
    private func applyRing() {
        let strong = isCursor && tilesHaveKeys && !isLifted
        let width = strong ? AgentMetrics.snap(1.5) : 1
        ring.borderWidth = isSelected || isLifted ? width : 0
        ring.borderColor = palette.ink.cgColor(alpha: strong ? (palette.increasesContrast ? 0.7 : 0.55) : (palette.increasesContrast ? 0.5 : 0.3))
        let outset = 2 + width
        ring.frame = bounds.insetBy(dx: -outset, dy: -outset)
        ring.cornerRadius = 12 + outset
    }

    /// Unselected while the line has the keys with several selected: the
    /// whole tile at 55 %, set at once (ruling 15).
    func setDimmed(_ dimmed: Bool) {
        let alpha: CGFloat = dimmed ? 0.55 : 1
        if alphaValue != alpha { alphaValue = alpha }
    }
    var isDimmed: Bool { alphaValue < 1 }

    /// The number over the mark while ⌘ is held (ruling 24), or none.
    func setNumber(_ number: Int?) {
        // In and out over 100 ms, over the mark.
        let duration = AgentMotion.duration(.fade(AgentMotion.gone), in: self)
        AgentMotion.animate(badge, "opacity", to: Float(number == nil ? 0 : 1), duration: duration)
        AgentMotion.animate(mark, "opacity", to: Float(number == nil ? 1 : 0), duration: duration)
        guard let number else { return }
        badge.backgroundColor = palette.pop.cgColor()
        badge.borderColor = ClawddyPalette.white(0.13)
        badgeNumber.text = AgentText(
            string: "\(number)", font: .systemFont(ofSize: 11, weight: .semibold), color: palette.ink.cgColor(),
            lineHeight: 18, alignment: .center)
    }

    /// Lifted by a drag: the raised surface, the ring and a soft shadow.
    func setLifted(_ lifted: Bool) {
        isLifted = lifted
        applyBackground(animated: false)
        applyRing()
        // native-look.md 2.6: (0.45, 17, 14) and (0.30, 3, 2), on layers of
        // the tile's own.
        let fade = AgentMotion.duration(.move(AgentMotion.small), in: self)
        for (part, opacity, radius, offset) in [(surface, 0.45, 17.0, 14.0), (under, 0.30, 3.0, 2.0)] {
            // Its shadow fades in over 150 ms (none under Reduce Motion), and
            // out as it lands.
            AgentMotion.animate(part, "shadowOpacity", to: lifted ? Float(opacity) : 0, duration: fade)
            part.shadowRadius = radius
            part.shadowOffset = CGSize(width: 0, height: offset)
            part.shadowPath = CGPath.continuousRoundedRect(bounds, radius: 12)
        }
    }
    private(set) var isLifted = false

    /// The layers whose frames follow the tile's size, each with whether
    /// its size moves too (text keeps its drawn size and only moves).
    var glidingLayers: [(CALayer, Bool)] {
        [(surface, true), (under, true), (content, true), (ring, true), (screen, true), (seam, true),
         (body, false), (head, false), (say, false), (age, false), (title, false)]
            + (settledPlace?.layer.map { [($0, true)] } ?? [])
    }

    /// The sentence as drawn now, for `holdSentence`.
    var sentencePicture: (image: CGImage, bounds: CGRect)? {
        // A density change under way: the picture it holds is still the one
        // on screen, and a retarget goes on holding it.
        if let held = (say.animation(forKey: "hold contents") as? CABasicAnimation)?.fromValue,
           let bounds = ((say.animation(forKey: "hold bounds") as? CABasicAnimation)?.fromValue as? NSValue)?.rectValue {
            return (held as! CGImage, bounds) // swiftlint:disable:this force_cast
        }
        let scale = say.contentsScale, size = say.bounds.size
        guard size.width > 0, size.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)),
                bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The layer draws top down, as in its flipped view.
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        say.render(in: context)
        return context.makeImage().map { ($0, say.bounds) }
    }

    /// While a density change moves the tile, its sentence shows as it was
    /// drawn (`picture`), and its new lines show in the motion's last frame,
    /// not before and not after (motion review ruling 4): the picture is
    /// held on the render server for `duration`.
    func holdSentence(_ picture: (image: CGImage, bounds: CGRect)?, for duration: CFTimeInterval) {
        guard let picture, duration > 0, picture.bounds != say.bounds else { return }
        for (key, value) in [("contents", picture.image as Any), ("bounds", NSValue(rect: picture.bounds) as Any)] {
            let hold = CABasicAnimation(keyPath: key)
            hold.fromValue = value
            hold.toValue = value
            hold.duration = duration
            say.add(hold, forKey: "hold " + key)
        }
    }

    // MARK: Layout

    /// While the row height animates (a density change), the screen's text
    /// keeps its drawn size, held to the screen's bottom, and draws once at
    /// the end; the grid sets it for the motion and clears it as the motion
    /// ends. (The sentence takes its new lines at once, under a held picture
    /// of the old ones: `holdSentence`.)
    var holdsClamp = false {
        didSet { if !holdsClamp { needsLayout = true } }
    }
    /// The grid's newest glide of this tile.
    var glide = 0

    /// The sentence takes the lines that fit: one under a 200 pt row unless
    /// the agent waits, else up to two, or four while it waits; the screen
    /// keeps at least 30 pt (ruling 16).
    private var sentenceLines: Int {
        guard let shown else { return 1 }
        let height = bounds.height
        let fit = max(1, Int(((height - 85) / 18).rounded(.down)))
        if height < 200, !shown.waiting { return 1 }
        return min(shown.waiting ? 4 : 2, fit)
    }

    private var screenFade: AgentText.Fade? {
        let height = screen.bounds.height
        guard height >= 64 else { return nil }
        return AgentText.Fade(clear: min(6, height * 0.10), opaque: min(24, height * 0.35))
    }

    override func layout() {
        super.layout()
        layouts += 1
        let width = bounds.width, height = bounds.height
        content.frame = bounds
        surface.frame = bounds
        under.frame = bounds
        applyRing()
        // Row 1: mark, name and age on one baseline, from 11 pt.
        let baseline = 11 + AgentMetrics.baseline(AgentMetrics.bodySemibold, lineHeight: 18)
        mark.frame = CGRect(x: 12, y: baseline - AgentMetrics.markLift - 7, width: 14, height: 14)
        badge.frame = CGRect(x: 10, y: mark.frame.minY - 2, width: 18, height: 18)
        badgeNumber.frame = badge.bounds
        let ageWidth = age.text?.width ?? 0
        age.frame = CGRect(x: width - 12 - ageWidth, y: 11, width: ageWidth, height: 18)
        title.frame = CGRect(x: 36, y: 11, width: max(0, width - 12 - ageWidth - 10 - 36), height: 18)
        nameField?.place(title.frame)
        // Row 2: the sentence from the tile's left inset, 5 pt under row 1.
        if var text = say.text, text.maxLines != sentenceLines {
            text.maxLines = sentenceLines
            say.text = text
        }
        let sentenceWidth = max(0, width - 24)
        let lineCount = say.text.map { max(1, min(AgentTextLayer.lines(of: $0, width: sentenceWidth).count, sentenceLines)) } ?? 1
        say.frame = CGRect(x: 12, y: 34, width: sentenceWidth, height: CGFloat(lineCount) * 18)
        // Row 3: the screen fills the rest, at least 30 pt.
        let screenTop = min(34 + CGFloat(lineCount) * 18 + 9, height - 12 - 30)
        screen.frame = CGRect(x: 12, y: screenTop, width: sentenceWidth, height: max(30, height - 12 - screenTop))
        // Whole rows only: a screen shorter than one row shows no text.
        let textWidth = max(0, screen.bounds.width - 20)
        let bottom = max(0, screen.bounds.height - 7)
        let rows = Int((bottom / font.pitch + 0.001).rounded(.down))
        let headHeight = (CGFloat(min(3, rows)) * font.pitch).rounded(.up)
        // While a density change animates, the screen's text keeps its
        // drawn size, held to the screen's bottom, clipped by the screen,
        // and draws once at the end (native-look.md 3.3). Shrinking, it
        // draws at its new size at once, so its top keeps its fade through
        // the whole motion (motion review ruling 4).
        screen.masksToBounds = holdsClamp
        let holdsText = holdsClamp && max(0, bottom - headHeight) >= body.bounds.height
        if holdsText {
            head.frame.origin.y = bottom - head.bounds.height
            body.frame.origin.y = head.frame.minY - body.bounds.height
        } else {
            head.frame = CGRect(x: 10, y: max(0, bottom - headHeight), width: textWidth, height: min(bottom, headHeight))
            body.frame = CGRect(x: 10, y: 0, width: textWidth, height: max(0, bottom - headHeight))
        }
        // The screen's text draws once, at the motion's end.
        if !holdsText, body.text?.fade != screenFade { applyScreenText() }
        // The top edge: the tile's rounded outline less the same moved 2 pt
        // down, so it follows the corners and tapers to nothing.
        seam.frame = CGRect(x: 0, y: 0, width: width, height: 12)
        let path = CGMutablePath()
        path.addPath(.continuousRoundedRect(CGRect(x: 0, y: 0, width: width, height: height), radius: 12))
        path.addPath(.continuousRoundedRect(CGRect(x: 0, y: 2, width: width, height: height), radius: 12))
        seam.path = path
    }

    // MARK: The settled place

    /// The agent is settled and its place stays (flows.md 6.7): the place
    /// fades in over the tile in 150 ms, stacked "Settled", the name and,
    /// on the places of the latest settle, Undo ⌘Z. Undone, it fades out.
    func setSettled(_ settled: Bool, undo: Bool) {
        if settled, settledPlace == nil {
            let place = AgentSettledPlaceView()
            place.undo.onPress = { [weak self] in self?.onUndo?() }
            place.frame = bounds
            place.autoresizingMask = [.width, .height]
            place.layer?.opacity = 0
            addSubview(place)
            settledPlace = place
        }
        guard let place = settledPlace else { return }
        if settled {
            place.show(name: shown?.name ?? agent?.name ?? "", undo: undo, palette: palette)
            place.layer?.name = "place:\(shown?.name ?? "")"
        }
        guard settled != isSettledPlace else { return }
        isSettledPlace = settled
        ring.isHidden = settled
        // What takes the pointer and VoiceOver follows the state at once;
        // the fades are only the picture (motion review ruling 1).
        place.isActive = settled
        place.isHidden = false
        // The tile's content and the place cross-fade: the leaving one gone
        // by half-way, the arriving one from a quarter, so no frame is blank
        // and none shows both at full strength (motion review ruling 3).
        let duration = AgentMotion.duration(.fade(AgentMotion.small), in: self)
        placeMotion += 1
        let motion = placeMotion
        AgentMotion.run({
            AgentMotion.animate(content, "opacity", to: Float(settled ? 0 : 1), duration: duration,
                                hold: [(settled ? 0.5 : 0.25, Float(0))])
            AgentMotion.animate(place.layer!, "opacity", to: Float(settled ? 1 : 0), duration: duration,
                                hold: [(settled ? 0.25 : 0.5, Float(0))])
        }, then: { [weak self] in
            guard let self, self.placeMotion == motion, !self.isSettledPlace else { return }
            self.settledPlace?.isHidden = true
        })
        setAccessibilityLabel(settled ? "Settled \(shown?.name ?? "")" : shown?.name)
    }

    private(set) var isSettledPlace = false
    /// Each settle or undo bumps it: an end of an older fade does nothing.
    private var placeMotion = 0

    // MARK: Entering and leaving

    /// Its terminal grows from it or shrinks into it (`AgentZoom.swift`):
    /// its content hides from the first frame, under the snapshot.
    var isZoomed = false {
        didSet { content.isHidden = isZoomed }
    }

    /// Lends its content to a motion (the enter and leave cross-fade, a
    /// cancelled tile's fade): its content layer, live and drawn already,
    /// moves into a holder over a plain copy of its surface, so nothing is
    /// drawn again; `takeBackContent` returns it. Meanwhile the tile shows
    /// its surface without content.
    func lendContent() -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let holder = CALayer()
        holder.bounds = bounds
        let plate = CALayer()
        plate.frame = bounds
        plate.backgroundColor = surface.backgroundColor
        plate.cornerRadius = surface.cornerRadius
        plate.cornerCurve = surface.cornerCurve
        plate.borderWidth = surface.borderWidth
        plate.borderColor = surface.borderColor
        holder.addSublayer(plate)
        content.removeFromSuperlayer()
        content.isHidden = false
        holder.addSublayer(content)
        lendsContent = true
        return holder
    }

    func takeBackContent() {
        guard lendsContent else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.removeFromSuperlayer()
        layer?.insertSublayer(content, above: surface)
        content.isHidden = false
        CATransaction.commit()
        lendsContent = false
    }

    private(set) var lendsContent = false
    /// Its content's opacity as the state sets it (the end of any fade).
    var contentOpacity: Float { content.opacity }

    // MARK: Accessibility

    /// VoiceOver's Press opens the agent's terminal, as a click does.
    override func accessibilityPerformPress() -> Bool {
        guard !isSettledPlace else { return false }
        onClick?(agentID)
        return true
    }

    override func isAccessibilitySelected() -> Bool { isSelected }

    /// Its screen, read as "Last lines of its terminal" (words.md).
    private lazy var screenElement: NSAccessibilityElement = {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.staticText)
        element.setAccessibilityLabel("Last lines of its terminal")
        element.setAccessibilityParent(self)
        return element
    }()

    override func accessibilityChildren() -> [Any]? {
        guard !isSettledPlace else { return super.accessibilityChildren() }
        screenElement.setAccessibilityValue(lines.joined(separator: "\n"))
        screenElement.setAccessibilityFrameInParentSpace(screen.frame)
        return [screenElement] + (super.accessibilityChildren() ?? [])
    }

    // MARK: The name edited in place

    var nameFrame: CGRect { title.frame }
    var nameFont: NSFont { AgentMetrics.bodySemibold }

    /// The name is being edited over its place: the drawn name hides under
    /// the field, and nothing the agent does touches the field.
    var editsName = false {
        didSet { title.isHidden = editsName }
    }

    // MARK: The pointer

    override func mouseDown(with event: NSEvent) {
        // The second click of a double-click does nothing: the first entered.
        guard event.clickCount == 1, !isSettledPlace else { return }
        isPressed = true
        pressedAt = event.locationInWindow
        onPress?(agentID, event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedAt else { return }
        if dragging || hypot(event.locationInWindow.x - pressedAt.x, event.locationInWindow.y - pressedAt.y) > 4 {
            dragging = true
            isPressed = false
            onDrag?(agentID, event, pressedAt)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isSettledPlace else { return }
        onRightClick?(agentID, event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            isPressed = false
            pressedAt = nil
            dragging = false
        }
        if dragging {
            onDrop?()
            return
        }
        guard let pressedAt, event.clickCount <= 1,
              event.modifierFlags.isDisjoint(with: [.shift, .command]),
              hypot(event.locationInWindow.x - pressedAt.x, event.locationInWindow.y - pressedAt.y) <= 4,
              bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        onClick?(agentID)
    }
}

/// A settled agent's place at home (native-look.md 3.4): the canvas with
/// a 1 pt rim, and a centred column "Settled", the name and, on the places
/// of the latest settle, Undo ⌘Z. The place itself shows no hover; only its
/// Undo responds.
final class AgentSettledPlaceView: NSView, AgentHoverable {
    let undo = AgentUndoButton()
    private let label = AgentTextLayer()
    private let name = AgentTextLayer()
    var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.addSublayer(label)
        layer?.addSublayer(name)
        addSubview(undo)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    /// The place stands for a settled agent now: only then does it take
    /// the pointer and speak to VoiceOver, also while it fades.
    var isActive = false {
        didSet { setAccessibilityElement(isActive) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isActive ? super.hitTest(point) : nil }

    func show(name text: String, undo shows: Bool, palette: ClawddyPalette) {
        layer?.backgroundColor = palette.canvas.cgColor()
        layer?.borderColor = ClawddyPalette.white(palette.rimAlpha)
        label.text = AgentText(string: "Settled", font: AgentMetrics.small, color: palette.text3.cgColor(), alignment: .center)
        name.text = AgentText(string: text, font: AgentMetrics.bodyMedium, color: palette.text2.cgColor(), alignment: .center)
        undo.isHidden = !shows
        undo.show(palette: palette)
        setAccessibilityLabel("Settled \(text)")
        needsLayout = true
    }

    /// "Settled" 12 over the name 13, 4 pt apart, then Undo 12 pt below,
    /// the column centred.
    override func layout() {
        super.layout()
        let width = bounds.width
        let column = 18 + 4 + 18 + (undo.isHidden ? 0 : 12 + AgentUndoButton.height)
        let top = ((bounds.height - CGFloat(column)) / 2).rounded()
        label.frame = CGRect(x: 14, y: top, width: max(0, width - 28), height: 18)
        name.frame = CGRect(x: 14, y: top + 22, width: max(0, width - 28), height: 18)
        let undoWidth = undo.width
        undo.frame = NSRect(x: ((width - undoWidth) / 2).rounded(), y: top + 52, width: undoWidth, height: AgentUndoButton.height)
    }
}

/// "Undo ⌘Z" (native-look.md 3.4, 3.5): ink on a 7 % fill, hover 10 %,
/// pressed 13 %; on settled places and in the status line.
final class AgentUndoButton: AgentButton {
    static let height: CGFloat = 24
    private let label = AgentTextLayer()
    private let key = AgentKeyCap()

    override init(frame: NSRect) {
        super.init(frame: frame)
        fills = (0.07, 0.10, 0.13)
        layer?.cornerRadius = 8
        layer?.addSublayer(label)
        layer?.addSublayer(key)
        setAccessibilityLabel("Undo")
        setAccessibilityHelp("Brings it back")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Padding 3 8, the label, 8 pt, the key.
    var width: CGFloat { 8 + (label.text?.width ?? 0) + 8 + key.bounds.width + 8 }

    func show(palette: ClawddyPalette) {
        label.text = AgentText(string: "Undo", font: AgentMetrics.body, color: palette.ink.cgColor())
        key.show("⌘Z", color: palette.text2.cgColor(), fill: ClawddyPalette.white(0.07))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let labelWidth = label.text?.width ?? 0
        label.frame = CGRect(x: 8, y: 3, width: labelWidth, height: 18)
        key.frame.origin = CGPoint(x: 8 + labelWidth + 8, y: 4)
    }
}
