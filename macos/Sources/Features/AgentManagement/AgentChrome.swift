import AppKit
import CoreText
import QuartzCore

// The parts every region of the agent window is built from
// (native-look.md 3.1): layers with no implicit animation, text drawn by
// CoreText into a layer's contents, one button, a key cap and the marks.

/// A layer with no implicit animation: rings and fills change in the frame
/// of the change. Anything that moves does so through `AgentMotion`.
class AgentLayer: CALayer {
    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func action(forKey event: String) -> CAAction? { nil }
}

final class AgentShapeLayer: CAShapeLayer {
    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func action(forKey event: String) -> CAAction? { nil }
}

/// Fonts, line heights and the baseline rule of the chrome (native-look.md
/// 2.4). Every baseline sits on a whole device pixel.
enum AgentMetrics {
    /// The window's backing scale, which `AgentWindowView` keeps up to date:
    /// 2 on Retina, 1 on a standard display.
    nonisolated(unsafe) static var scale: CGFloat = 2

    /// `value` on the nearest device pixel.
    static func snap(_ value: CGFloat, scale: CGFloat = scale) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// Where the baseline of `font` sits from the top of a line box
    /// `lineHeight` tall.
    static func baseline(_ font: NSFont, lineHeight: CGFloat, scale: CGFloat = scale) -> CGFloat {
        snap((lineHeight - (font.ascender - font.descender)) / 2 + font.ascender, scale: scale)
    }

    /// How far above the baseline a mark's centre sits: half the cap height
    /// of 13 pt text.
    static var markLift: CGFloat { snap(NSFont.systemFont(ofSize: 13).capHeight / 2) }

    static let body = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let bodySemibold = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let bodyMedium = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let digits13 = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    static let digits11 = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let digits11Medium = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let small = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let key = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let empty = NSFont.systemFont(ofSize: 15, weight: .regular)

    /// The role's font set in italic: an app-written sentence.
    static func italic(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        guard let italic = NSFont(descriptor: descriptor, size: font.pointSize) else {
            preconditionFailure("No italic of \(font)")
        }
        return italic
    }
}

/// One run of text as a text layer draws it: one font, one colour, up to
/// `maxLines` lines wrapped by word, the last ending in "…" when text
/// remains.
struct AgentText: Equatable {
    enum Alignment: Equatable { case left, right, center }

    /// The top of a tile's screen fades its text only (native-look.md 3.3):
    /// clear above `clear`, opaque below `opaque`, baked into the bitmap.
    struct Fade: Equatable {
        var clear: CGFloat
        var opaque: CGFloat
    }

    var string: String
    var font: NSFont
    var color: CGColor
    var lineHeight: CGFloat = 18
    var maxLines = 1
    var alignment: Alignment = .left
    /// Where the baseline sits from the top of the line box, when it must
    /// match text of another size beside it; by default the font's own
    /// (`AgentMetrics.baseline`).
    var baseline: CGFloat?
    /// Terminal lines: each line of the string is one line, cut with "…" at
    /// the right edge, never wrapped again, and the last lines are drawn
    /// against the bottom edge (a tile's screen).
    var terminalLines = false
    var fade: Fade?
    /// Parts set apart, as find marks the typed words (semibold ink).
    var marks: [Mark] = []

    struct Mark: Equatable {
        var range: NSRange
        var font: NSFont
        var color: CGColor
    }

    /// The width of the text on one line, untruncated, in points.
    var width: CGFloat {
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    var attributed: NSAttributedString {
        let color = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let text = NSMutableAttributedString(string: string, attributes: [.font: font, color: self.color])
        for mark in marks where NSMaxRange(mark.range) <= text.length {
            text.addAttributes([.font: mark.font, color: mark.color], range: mark.range)
        }
        return text
    }
}

/// Text drawn with CoreText into the layer's contents (native-look.md 3.1):
/// it redraws only when its text or its size changes, so a row whose agent
/// did not change draws nothing. `draws` counts its draws, for the tests of
/// that.
final class AgentTextLayer: AgentLayer {
    var text: AgentText? {
        didSet { if text != oldValue { setNeedsDisplay() } }
    }
    private(set) var draws = 0
    /// The wrapped lines of the last draw, by text and width.
    private var wrapCache: (text: AgentText, width: CGFloat, lines: [CTLine])?

    override init() {
        super.init()
        isOpaque = false
        needsDisplayOnBoundsChange = false
        contentsScale = AgentMetrics.scale
    }

    override init(layer: Any) { super.init(layer: layer) }

    override var bounds: CGRect {
        didSet { if bounds.size != oldValue.size { setNeedsDisplay() } }
    }

    override var contentsScale: CGFloat {
        didSet { if contentsScale != oldValue { setNeedsDisplay() } }
    }

    override func draw(in ctx: CGContext) {
        guard let text, !text.string.isEmpty, bounds.width > 0 else { return }
        draws += 1
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // From here on y grows downward from the top of the layer.
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let baseline = text.baseline ?? AgentMetrics.baseline(text.font, lineHeight: text.lineHeight, scale: contentsScale)
        if text.terminalLines {
            drawTerminalLines(text, baseline: baseline, in: ctx)
            return
        }
        if wrapCache?.text != text || wrapCache?.width != bounds.width {
            wrapCache = (text, bounds.width, Self.lines(of: text, width: bounds.width))
        }
        for (index, line) in (wrapCache?.lines ?? []).enumerated() {
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let x: CGFloat = switch text.alignment {
            case .left: 0
            case .right: AgentMetrics.snap(bounds.width - width, scale: contentsScale)
            case .center: AgentMetrics.snap((bounds.width - width) / 2, scale: contentsScale)
            }
            ctx.textPosition = CGPoint(x: x, y: CGFloat(index) * text.lineHeight + baseline)
            CTLineDraw(line, ctx)
        }
    }

    /// Clear to opaque, for the fade at the top of a tile's screen.
    private static let fadeGradient: CGGradient = {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray,
            locations: [0, 1])
        else { preconditionFailure("No gradient for the screen's fade") }
        return gradient
    }()

    /// Typeset rows of terminal text, each cut to the width, kept between
    /// draws: a screen that scrolled by one row typesets only the new one.
    private var rowCache: (key: RowCacheKey, lines: [String: CTLine])?
    private struct RowCacheKey: Equatable {
        var font: NSFont
        var color: CGColor
        var width: CGFloat
    }

    /// Terminal lines against the bottom edge, each baseline on a whole
    /// pixel, then the fade baked over the text. Without a fade only whole
    /// rows are drawn: none is cut at the top.
    private func drawTerminalLines(_ text: AgentText, baseline: CGFloat, in ctx: CGContext) {
        let room = bounds.height / text.lineHeight
        let fits = text.fade == nil ? Int((room + 0.001).rounded(.down)) : Int(room.rounded(.up)) + 1
        guard fits > 0 else { return }
        let rows = text.string.components(separatedBy: "\n").suffix(fits)
        let attributes = text.attributed.attributes(at: 0, effectiveRange: nil)
        let key = RowCacheKey(font: text.font, color: text.color, width: bounds.width)
        let cached = rowCache?.key == key ? rowCache?.lines ?? [:] : [:]
        var lines: [String: CTLine] = [:]
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        for (index, row) in rows.reversed().enumerated() {
            guard !row.isEmpty else { continue }
            let line = lines[row] ?? cached[row] ?? {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: row, attributes: attributes))
                guard CTLineGetTypographicBounds(line, nil, nil, nil) > Double(bounds.width) else { return line }
                return CTLineCreateTruncatedLine(line, Double(bounds.width), .end, token) ?? token
            }()
            lines[row] = line
            let top = bounds.height - CGFloat(index + 1) * text.lineHeight
            ctx.textPosition = CGPoint(x: 0, y: AgentMetrics.snap(top + baseline, scale: contentsScale))
            CTLineDraw(line, ctx)
        }
        rowCache = (key, lines)
        guard let fade = text.fade else { return }
        // Only the band of the fade: below it the text stays as drawn.
        ctx.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: fade.opaque))
        ctx.setBlendMode(.destinationIn)
        ctx.drawLinearGradient(
            Self.fadeGradient, start: CGPoint(x: 0, y: fade.clear), end: CGPoint(x: 0, y: fade.opaque),
            options: [.drawsBeforeStartLocation])
    }

    /// The lines `text` takes in `width`: wrapped by word, at most
    /// `maxLines`, the last cut with "…" when text remains or a word is
    /// wider than the line.
    static func lines(of text: AgentText, width: CGFloat) -> [CTLine] {
        let attributed = text.attributed
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributed.attributes(at: 0, effectiveRange: nil)))
        func fitted(_ line: CTLine) -> CTLine {
            guard CTLineGetTypographicBounds(line, nil, nil, nil) > Double(width) else { return line }
            return CTLineCreateTruncatedLine(line, Double(width), .end, token) ?? token
        }
        var lines: [CTLine] = []
        var start = 0
        let length = attributed.length
        while start < length, lines.count < text.maxLines {
            if lines.count == text.maxLines - 1 {
                lines.append(fitted(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))))
                break
            }
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            lines.append(fitted(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))))
            start += count
        }
        return lines
    }
}

// MARK: - The chip

/// The chip before a line's text, naming where typed text goes (flows.md
/// "The line"). While the line starts a new agent it names the CLI new
/// agents use and is the pop-up button that changes it; a reply or an
/// instruction to several names no CLI, and the chip is words only.
final class AgentChip: AgentButton {
    static let maxWidth: CGFloat = 260
    private let label = AgentTextLayer()
    private(set) var text = ""
    /// The CLI it offers to change, nil when it changes nothing.
    private(set) var cli: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = 6
        layer?.addSublayer(label)
        setAccessibilityLabel("CLI for new agents")
    }

    /// `many`: "To N agents", brighter. `cli`: the CLI a new agent uses,
    /// which a press offers to change.
    func show(_ text: String, many: Bool, cli: String?, palette: ClawddyPalette) {
        self.text = text
        self.cli = cli
        label.text = AgentText(string: text, font: AgentMetrics.bodyMedium, color: (many ? palette.ink : palette.text2).cgColor())
        fills = many ? (0.12, 0.12, 0.12) : cli == nil ? (0.06, 0.06, 0.06) : (0.06, 0.10, 0.14)
        isEnabled = cli != nil
        setAccessibilityElement(cli != nil)
        setAccessibilityRole(cli == nil ? .staticText : .popUpButton)
        setAccessibilityValue(cli)
        toolTip = cli == nil ? nil : "Change the CLI for new agents (Tab)"
        needsLayout = true
    }

    /// As wide as its words and its padding, at most 260 pt: past that the
    /// end of the words, the project's name, is cut.
    var fittingWidth: CGFloat { min(Self.maxWidth, (label.text?.width ?? 0) + 18) }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 9, y: 3, width: max(0, bounds.width - 18), height: 18)
    }
}

// MARK: - Hover

/// A view that shows the pointer over it. The agent window has one
/// authority for the pointer (`AgentWindowView.pointerMoved(to:)`), which
/// sets this on the deepest such view under the pointer and clears it on
/// the one before.
@MainActor
protocol AgentHoverable: AnyObject {
    var isHovered: Bool { get set }
}

// MARK: - Button

/// The one button of the agent window (native-look.md 3.1): a rounded fill
/// that steps with the pointer (rest, hover, pressed), content its owner
/// lays out on its layer, and an action on mouse-up inside. It never takes
/// the keys, so no focus ring can appear; the pointer stays the arrow.
class AgentButton: NSControl, AgentActivationClickSafeRegion, AgentHoverable {
    enum Phase: Equatable { case rest, hover, pressed }

    /// The fill's white alpha in each phase.
    var fills: (rest: Double, hover: Double, pressed: Double) = (0, 0.05, 0.10) {
        didSet { applyFill(animated: false) }
    }
    /// An opaque colour under the fill (the current row's raised surface);
    /// the fill is then mixed into it.
    var base: ClawddyPalette.RGB? {
        didSet { if base != oldValue { applyFill(animated: false) } }
    }
    /// The layer that shows the fill: the backing layer, or a layer of the
    /// button's own that can also cast a shadow (AppKit resets a backing
    /// layer's shadow).
    var fillLayer: CALayer?
    /// Called when the phase changes, for content that follows it.
    var onPhase: ((Phase) -> Void)?
    /// Runs on mouse-up inside.
    var onPress: (() -> Void)?
    /// Runs on a right-click or a Control-click, with the event, for a
    /// menu.
    var onRightClick: ((NSEvent) -> Void)?
    /// Set, a press that moves more than 4 pt is a drag, not a click: each
    /// move from then on goes here, with where the press was (in the
    /// window), and the release to `onDrop` (flows.md 3.5, ruling 33).
    var onDrag: ((NSEvent, NSPoint) -> Void)?
    var onDrop: (() -> Void)?
    private var pressedAt: NSPoint?
    private var dragging = false

    private(set) var phase: Phase = .rest
    var isHovered = false { didSet { if isHovered != oldValue { updatePhase() } } }
    /// A button that can do nothing now is drawn as not being one: no
    /// hover, no press, and a click does nothing (ruling 32); VoiceOver
    /// hears it dimmed.
    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { endDrag() }
            setAccessibilityEnabled(isEnabled)
            updatePhase()
        }
    }
    private var isPressed = false { didSet { if isPressed != oldValue { updatePhase() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        refusesFirstResponder = true
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let onRightClick { return onRightClick(event) }
        guard isEnabled else { return }
        pressedAt = event.locationInWindow
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard onDrag != nil else {
            isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
            return
        }
        // A press whose drag Escape cancelled does nothing more.
        guard let pressedAt else { return }
        let point = event.locationInWindow
        if dragging || abs(point.x - pressedAt.x) > 4 || abs(point.y - pressedAt.y) > 4 {
            dragging = true
            isPressed = false
            onDrag?(event, pressedAt)
        } else {
            isPressed = bounds.contains(convert(point, from: nil))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { endDrag() }
        if dragging { return onDrop?() ?? () }
        let fires = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if fires { onPress?() }
    }

    /// The press is over: a drag that Escape cancelled ignores the rest of
    /// it, and its release does nothing.
    func endDrag() {
        pressedAt = nil
        dragging = false
        isPressed = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onRightClick else { return super.rightMouseDown(with: event) }
        onRightClick(event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let onPress else { return false }
        onPress()
        return true
    }

    private func updatePhase() {
        let next: Phase = !isEnabled ? .rest : isPressed ? .pressed : isHovered ? .hover : .rest
        guard next != phase else { return }
        let lighter = fill(for: next) < fill(for: phase)
        phase = next
        applyFill(animated: lighter)
        onPhase?(phase)
    }

    private func fill(for phase: Phase) -> Double {
        switch phase {
        case .rest: fills.rest
        case .hover: fills.hover
        case .pressed: fills.pressed
        }
    }

    /// The fill for the phase: set at once on entering and pressing, and
    /// over 150 ms back on leaving and releasing (native-look.md 2.7).
    private func applyFill(animated: Bool) {
        guard let layer = fillLayer ?? layer else { return }
        let alpha = fill(for: phase)
        let color: CGColor? = if let base {
            base.blended(with: .init(red: 1, green: 1, blue: 1), opacity: alpha).cgColor()
        } else {
            alpha > 0 ? ClawddyPalette.white(alpha) : nil
        }
        AgentMotion.animate(layer, "backgroundColor", to: color, duration: animated ? AgentMotion.duration(.fade(AgentMotion.small), in: self) : 0)
    }
}

// MARK: - Key cap

/// A key as the chrome shows it (native-look.md 3.1): its glyphs in 11 pt
/// on a small rounded fill, 16 tall, at least 18 wide.
final class AgentKeyCap: AgentLayer {
    private let label = AgentTextLayer()

    override init() {
        super.init()
        cornerRadius = 4
        cornerCurve = .continuous
        addSublayer(label)
    }

    override init(layer: Any) { super.init(layer: layer) }

    /// Shows `keys` in `color` on `fill`; returns the cap's width.
    @discardableResult
    func show(_ keys: String, color: CGColor, fill: CGColor?) -> CGFloat {
        let text = AgentText(string: keys, font: AgentMetrics.key, color: color, lineHeight: 16, alignment: .center)
        label.text = text
        backgroundColor = fill
        let width = max(18, text.width + 10)
        bounds.size = CGSize(width: width, height: 16)
        label.frame = CGRect(x: 0, y: 0, width: width, height: 16)
        return width
    }
}

// MARK: - Marks and symbols

/// SF Symbols drawn once into a bitmap per symbol, size, colour and scale,
/// and shared by every layer that shows one (native-look.md 3.2). Used on
/// the main thread only, where the layers are.
enum AgentSymbol {
    struct Key: Hashable {
        var name: String
        var pointSize: CGFloat
        var weight: NSFont.Weight
        var color: ClawddyPalette.RGB
        var box: CGFloat
        var scale: CGFloat
    }

    nonisolated(unsafe) private static var cache: [Key: CGImage] = [:]
    nonisolated(unsafe) private static var arcs: [Key: CGImage] = [:]

    /// The working mark: a three-quarter arc, radius 5, 1.5 pt with round
    /// caps, in a 14 pt box (native-look.md decision 3, ruling 28).
    static func arc(color: ClawddyPalette.RGB, scale: CGFloat) -> CGImage {
        let key = Key(name: "arc", pointSize: 5, weight: .regular, color: color, box: 14, scale: scale)
        if let image = arcs[key] { return image }
        let pixels = Int((14 * scale).rounded())
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { preconditionFailure("No bitmap for the working mark") }
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(color.cgColor())
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.addArc(center: CGPoint(x: 7, y: 7), radius: 5, startAngle: .pi / 2, endAngle: .pi / 2 + 1.5 * .pi, clockwise: false)
        context.strokePath()
        guard let image = context.makeImage() else { preconditionFailure("No image for the working mark") }
        arcs[key] = image
        return image
    }

    /// The symbol in `color`, its alignment rectangle centred in a square
    /// `box` points wide.
    static func image(_ key: Key) -> CGImage {
        if let image = cache[key] { return image }
        guard let symbol = NSImage(systemSymbolName: key.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: key.pointSize, weight: key.weight))
        else { preconditionFailure("No SF Symbol \(key.name)") }
        let pixels = Int((key.box * key.scale).rounded())
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { preconditionFailure("No bitmap for \(key.name)") }
        context.scaleBy(x: key.scale, y: key.scale)
        let size = symbol.size
        let alignment = symbol.alignmentRect
        // The alignment rectangle's centre on the box's.
        let origin = CGPoint(
            x: key.box / 2 - alignment.midX,
            y: key.box / 2 - alignment.midY)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        symbol.draw(in: CGRect(origin: origin, size: size))
        key.color.nsColor.set()
        CGRect(x: 0, y: 0, width: key.box, height: key.box).fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { preconditionFailure("No image for \(key.name)") }
        cache[key] = image
        return image
    }
}

extension AgentShownState {
    /// The state's mark: its symbol, size, weight and colour in a 14 pt box
    /// (native-look.md 3.2).
    func symbol(_ palette: ClawddyPalette, scale: CGFloat) -> AgentSymbol.Key {
        func key(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: ClawddyPalette.RGB) -> AgentSymbol.Key {
            AgentSymbol.Key(name: name, pointSize: size, weight: weight, color: color, box: 14, scale: scale)
        }
        switch self {
        case .working: return key("arc", 5, .regular, palette.text2)
        case .asks: return key("circle.fill", 9, .regular, palette.signal)
        case .problem: return key("triangle.fill", 10, .regular, palette.problem)
        case .finishedUnread: return key("checkmark", 11, .semibold, palette.signal)
        case .finished: return key("checkmark", 11, .semibold, palette.text3)
        case .paused: return key("pause", 10, .bold, palette.text3)
        case .limitReset: return key("pause", 10, .bold, palette.signal)
        }
    }
}

/// A 14 pt mark: the state's symbol, shared as one image by every mark of
/// that state. The working mark turns, one turn in 1.2 s, linear, by one
/// repeating animation the render server runs (ruling 28): the main thread
/// does nothing per frame. Marks turn only while `turning` is set, which the
/// window clears while it cannot be seen and under Reduce Motion.
final class AgentMarkLayer: AgentLayer {
    var state: AgentShownState? { didSet { if state != oldValue { refresh() } } }
    var palette: ClawddyPalette = .prototype { didSet { if palette != oldValue { refresh() } } }
    /// The mark is where it can be seen (its tile in view, its row's list
    /// shown), which its owner says: off screen it does not turn.
    var onScreen = true { didSet { if onScreen != oldValue { syncTurn() } } }

    /// Every mark, for `turning`.
    nonisolated(unsafe) private static let all = NSHashTable<AgentMarkLayer>.weakObjects()
    /// Whether working marks turn: the window is seen and Reduce Motion is
    /// off.
    nonisolated(unsafe) private(set) static var turning = true

    static func setTurning(_ turning: Bool) {
        guard turning != Self.turning else { return }
        Self.turning = turning
        for mark in all.allObjects { mark.syncTurn() }
    }

    /// Working marks turning now, for the harness and tests.
    static var turningCount: Int {
        all.allObjects.filter { $0.animation(forKey: "turn") != nil }.count
    }

    override init() {
        super.init()
        contentsGravity = .center
        contentsScale = AgentMetrics.scale
        bounds.size = CGSize(width: 14, height: 14)
        Self.all.add(self)
    }

    override init(layer: Any) { super.init(layer: layer) }

    override var contentsScale: CGFloat {
        didSet { if contentsScale != oldValue { refresh() } }
    }

    private func refresh() {
        defer { syncTurn() }
        guard let state else {
            contents = nil
            return
        }
        let symbol = state.symbol(palette, scale: contentsScale)
        contents = state == .working
            ? AgentSymbol.arc(color: symbol.color, scale: contentsScale)
            : AgentSymbol.image(symbol)
    }

    /// One repeating rotation while working and turning; none otherwise.
    private func syncTurn() {
        let turns = state == .working && Self.turning && onScreen
        guard turns != (animation(forKey: "turn") != nil) else { return }
        guard turns else { return removeAnimation(forKey: "turn") }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 1.2
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(name: .linear)
        turn.isRemovedOnCompletion = false
        add(turn, forKey: "turn")
    }
}

/// A layer showing one symbol in a square box.
final class AgentSymbolLayer: AgentLayer {
    var symbol: AgentSymbol.Key? {
        didSet {
            guard symbol != oldValue else { return }
            contents = symbol.map(AgentSymbol.image)
        }
    }

    override init() {
        super.init()
        contentsGravity = .center
        contentsScale = AgentMetrics.scale
    }

    override init(layer: Any) { super.init(layer: layer) }
}

// MARK: - Continuous corners

extension CGPath {
    /// A rounded rectangle with continuous corners, as `cornerCurve =
    /// .continuous` draws them: the iOS 7 corner curve, each corner spread
    /// over 1.528 × `radius` of its edges (the published Bézier fit of it).
    /// For shapes that must follow a layer's continuous corners, such as a
    /// tile's top edge.
    /// The 1 pt line of light along a continuous rounded rectangle's top
    /// edge (native-look.md 2.5), its centre `inset` + 0.5 pt inside the
    /// edge, for a shape layer clipped to the top `radius` points, so it
    /// runs from one corner's 9 o'clock over the top to the other's 3
    /// o'clock and follows the corners.
    static func topLight(_ size: CGSize, radius: CGFloat, inset: CGFloat) -> CGPath {
        continuousRoundedRect(
            CGRect(origin: .zero, size: size).insetBy(dx: inset + 0.5, dy: inset + 0.5), radius: radius - inset - 0.5)
    }

    static func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let limit = min(rect.width, rect.height) / 2 / 1.52866483
        let r = min(radius, limit)
        let path = CGMutablePath()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        path.move(to: point(minX + 1.52866483 * r, minY))
        // Top right.
        path.addLine(to: point(maxX - 1.52866483 * r, minY))
        path.addCurve(to: point(maxX - 0.66993427 * r, minY + 0.06549600 * r),
                      control1: point(maxX - 1.08849323 * r, minY), control2: point(maxX - 0.86840689 * r, minY))
        path.addLine(to: point(maxX - 0.63149399 * r, minY + 0.07491100 * r))
        path.addCurve(to: point(maxX - 0.07491100 * r, minY + 0.63149399 * r),
                      control1: point(maxX - 0.37282392 * r, minY + 0.16905899 * r),
                      control2: point(maxX - 0.16905899 * r, minY + 0.37282392 * r))
        path.addLine(to: point(maxX - 0.06549600 * r, minY + 0.66993427 * r))
        path.addCurve(to: point(maxX, minY + 1.52866483 * r),
                      control1: point(maxX, minY + 0.86840689 * r), control2: point(maxX, minY + 1.08849323 * r))
        // Bottom right.
        path.addLine(to: point(maxX, maxY - 1.52866483 * r))
        path.addCurve(to: point(maxX - 0.06549600 * r, maxY - 0.66993427 * r),
                      control1: point(maxX, maxY - 1.08849323 * r), control2: point(maxX, maxY - 0.86840689 * r))
        path.addLine(to: point(maxX - 0.07491100 * r, maxY - 0.63149399 * r))
        path.addCurve(to: point(maxX - 0.63149399 * r, maxY - 0.07491100 * r),
                      control1: point(maxX - 0.16905899 * r, maxY - 0.37282392 * r),
                      control2: point(maxX - 0.37282392 * r, maxY - 0.16905899 * r))
        path.addLine(to: point(maxX - 0.66993427 * r, maxY - 0.06549600 * r))
        path.addCurve(to: point(maxX - 1.52866483 * r, maxY),
                      control1: point(maxX - 0.86840689 * r, maxY), control2: point(maxX - 1.08849323 * r, maxY))
        // Bottom left.
        path.addLine(to: point(minX + 1.52866483 * r, maxY))
        path.addCurve(to: point(minX + 0.66993427 * r, maxY - 0.06549600 * r),
                      control1: point(minX + 1.08849323 * r, maxY), control2: point(minX + 0.86840689 * r, maxY))
        path.addLine(to: point(minX + 0.63149399 * r, maxY - 0.07491100 * r))
        path.addCurve(to: point(minX + 0.07491100 * r, maxY - 0.63149399 * r),
                      control1: point(minX + 0.37282392 * r, maxY - 0.16905899 * r),
                      control2: point(minX + 0.16905899 * r, maxY - 0.37282392 * r))
        path.addLine(to: point(minX + 0.06549600 * r, maxY - 0.66993427 * r))
        path.addCurve(to: point(minX, maxY - 1.52866483 * r),
                      control1: point(minX, maxY - 0.86840689 * r), control2: point(minX, maxY - 1.08849323 * r))
        // Top left.
        path.addLine(to: point(minX, minY + 1.52866483 * r))
        path.addCurve(to: point(minX + 0.06549600 * r, minY + 0.66993427 * r),
                      control1: point(minX, minY + 1.08849323 * r), control2: point(minX, minY + 0.86840689 * r))
        path.addLine(to: point(minX + 0.07491100 * r, minY + 0.63149399 * r))
        path.addCurve(to: point(minX + 0.63149399 * r, minY + 0.07491100 * r),
                      control1: point(minX + 0.16905899 * r, minY + 0.37282392 * r),
                      control2: point(minX + 0.37282392 * r, minY + 0.16905899 * r))
        path.addLine(to: point(minX + 0.66993427 * r, minY + 0.06549600 * r))
        path.addCurve(to: point(minX + 1.52866483 * r, minY),
                      control1: point(minX + 0.86840689 * r, minY), control2: point(minX + 1.08849323 * r, minY))
        path.closeSubpath()
        return path
    }
}

/// What a menu item made with `NSMenuItem(title:run:)` runs. The item keeps
/// it as its `representedObject`, since its `target` is weak.
private final class AgentMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func choose(_ sender: NSMenuItem) { run() }
}

extension NSMenuItem {
    /// An item that runs `run` when chosen.
    convenience init(title: String, run: @escaping () -> Void) {
        let action = AgentMenuAction(run)
        self.init(title: title, action: #selector(AgentMenuAction.choose(_:)), keyEquivalent: "")
        target = action
        representedObject = action
    }
}
