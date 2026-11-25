import AppKit

/// An agent's name being edited in place (flows.md 6.9, native-look.md 4.2):
/// the one text field class over the name on a tile, a row or the header, in
/// the name's own font, on its own line box, so the name does not move by a
/// pixel when editing begins. It sits on a lighter fill with a 4 pt halo and
/// scrolls sideways when the name is longer than its place. It is a subview
/// of the view whose name it edits, which hides its own name meanwhile and
/// never touches the field: nothing the agent does replaces, moves or commits
/// it. One field serves every place; the window controller owns it.
final class AgentNameField: NSView, NSTextViewDelegate {
    /// The most characters a name has (flows.md 4.3).
    static let longest = 60

    /// The field, in the font of the name it edits (made again when that
    /// font differs: a row's name at rest is medium, a tile's semibold).
    private(set) var textView = AgentNameField.field(AgentMetrics.bodySemibold)
    /// A key command (Return, Escape, Up, Down); the field gave up the keys;
    /// its text changed.
    var command: ((Selector) -> Bool)?
    var onResign: (() -> Void)?
    var onChange: (() -> Void)?
    private let scroll = NSScrollView()
    private let halo = AgentLayer()
    private let fill = AgentLayer()
    /// How far the halo reaches above and below the name's line box: 4 pt,
    /// less where the host's next line of text is closer.
    private var haloRise: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        // native-look.md 4.2: fill white 7 % at radius 4, and a 4 pt halo of
        // white 7 % behind it at radius 8.
        for (part, radius) in [(halo, 8.0), (fill, 4.0)] {
            part.cornerRadius = radius
            part.cornerCurve = .continuous
            part.backgroundColor = ClawddyPalette.white(0.07)
            layer?.addSublayer(part)
        }
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.focusRingType = .none
        scroll.contentView.drawsBackground = false
        scroll.contentView.focusRingType = .none
        addSubview(scroll)
        adopt(textView)
        isHidden = true
    }

    private static func field(_ font: NSFont) -> AgentTextView {
        AgentTextView(font: font, lineHeight: 18, maxLines: 1, inset: .zero, wraps: false)
    }

    private func adopt(_ field: AgentTextView) {
        textView = field
        scroll.documentView = field
        field.delegate = self
        // A name takes no files.
        field.unregisterDraggedTypes()
        field.registerForDraggedTypes([.string])
        field.setAccessibilityLabel("Name")
        field.command = { [weak self] in self?.command?($0) ?? false }
        field.onResign = { [weak self] in self?.onResign?() }
        field.onChange = { [weak self] in self?.onChange?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows `name` over `frame` (the name's line box) in `host`, all of it
    /// selected, its halo reaching `halo` above and below.
    func show(_ name: String, font: NSFont, over frame: CGRect, halo: CGFloat, in host: NSView, palette: ClawddyPalette) {
        if textView.font14or17 != font { adopt(Self.field(font)) }
        if superview !== host { host.addSubview(self) }
        haloRise = halo
        textView.apply(palette)
        place(frame)
        isHidden = false
        textView.setText(name)
        textView.setSelectedRange(NSRange(location: 0, length: (name as NSString).length))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Follows the name's line box when its host lays out again.
    func place(_ frame: CGRect) {
        if self.frame != frame { self.frame = frame }
        fill.frame = bounds
        halo.frame = bounds.insetBy(dx: -4, dy: -haloRise)
        scroll.frame = bounds
        textView.minSize = NSSize(width: bounds.width, height: 18)
        textView.frame.size.height = 18
        if textView.frame.width < bounds.width { textView.frame.size.width = bounds.width }
    }

    /// What was typed, as a name: one line, at most `longest` characters,
    /// without the spaces around it.
    var name: String {
        String(Self.clean(textView.string).prefix(Self.longest)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Characters that take no room: zero-width spaces and joiners, the
    /// word joiner, the byte order mark.
    private static let zeroWidth: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x180E]

    /// `text` as one line of a name (flows.md 6.9, final review ruling 10):
    /// line breaks of every kind and tabs become spaces, so words stay
    /// apart, and zero-width characters go.
    static func clean(_ text: String) -> String {
        let scalars = text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if zeroWidth.contains(scalar.value) { return nil }
            return CharacterSet.newlines.contains(scalar) || scalar == "\t" ? " " : scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Pasted line breaks and tabs become spaces, zero-width characters go,
    /// and the name stops at `longest` characters; an input method's text in
    /// progress is let through and cut when it is kept.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text, !textView.hasMarkedText() else { return true }
        let cleaned = Self.clean(text)
        let room = Self.longest - ((textView.string as NSString).replacingCharacters(in: range, with: "") as String).count
        let fitted = String(cleaned.prefix(max(0, room)))
        guard fitted != text else { return true }
        if !fitted.isEmpty || range.length > 0 { textView.insertText(fitted, replacementRange: range) }
        return false
    }
}

/// A view whose agent's name can be edited in place: a tile, a row, the
/// header. While it edits, its own name is hidden under the field, and its
/// layout keeps the field on the name's line box.
@MainActor
protocol AgentNameHost: NSView {
    /// The name's line box, where the field goes.
    var nameFrame: CGRect { get }
    /// The font the name is drawn in now.
    var nameFont: NSFont { get }
    /// How far the field's halo may reach above and below the name's line
    /// box without touching the host's other text.
    var nameHalo: CGFloat { get }
    var editsName: Bool { get set }
}

extension AgentNameHost {
    var nameHalo: CGFloat { 4 }

    /// The field over the name, when it is being edited here.
    var nameField: AgentNameField? {
        guard editsName else { return nil }
        return subviews.lazy.compactMap { $0 as? AgentNameField }.first { !$0.isHidden }
    }
}
