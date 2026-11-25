import AppKit

/// The one text input of the agent window (native-look.md 4): the typing
/// line, the palette's field, the floating new-agent line, and later rename,
/// all this class. A TextKit 1 `NSTextView` with every automatic behaviour
/// off: plain text, no spelling marks, no substitutions, no predictions, no
/// Writing Tools, no focus ring, no background; the caret in ink, the
/// selection in ink at 28 %, IME composition underlined in the second tone.
/// It draws its placeholder itself, at the first line's place, so a chip
/// beside it can share the baseline. It grows with its text up to
/// `maxLines`, then scrolls (its owner sets the frames from `textHeight`).
/// Files and folders dropped or pasted become their paths. Its undo is its
/// own (`fieldUndo`), never the window's, so text undo never undoes a
/// settle. It handles no key itself: its owner's `command` decides every
/// key command (Return, Escape, arrows at the edges, Tab), so no input
/// method's keys are ever taken while it composes.
final class AgentTextView: NSTextView {
    /// The field's font and line height (native-look.md 2.4: the line 14/22,
    /// the palette 17/24).
    let font14or17: NSFont
    let lineHeight: CGFloat
    /// Lines it grows to before it scrolls.
    let maxLines: Int
    /// Its own undo manager.
    let fieldUndo = UndoManager()

    /// The words shown while it is empty; changing them never touches the
    /// text.
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    var placeholderColor: NSColor = .tertiaryLabelColor {
        didSet { needsDisplay = true }
    }
    /// A key command (`doCommand(by:)`'s selector): true when the owner took
    /// it. Return, Shift-Return, Escape, Up, Down, Tab come here.
    var command: ((Selector) -> Bool)?
    /// The text changed (typing, paste, undo, IME commit).
    var onChange: (() -> Void)?
    /// It gave up the keys (a click elsewhere): a name being edited is kept.
    var onResign: (() -> Void)?
    /// One line that scrolls sideways (a name), not wrapped text.
    let wraps: Bool

    init(font: NSFont, lineHeight: CGFloat, maxLines: Int, inset: NSSize, wraps: Bool = true) {
        font14or17 = font
        self.lineHeight = lineHeight
        self.maxLines = maxLines
        self.wraps = wraps
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(
            width: wraps ? 100 : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = wraps
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: lineHeight), textContainer: container)
        textContainerInset = inset
        isVerticallyResizable = wraps
        isHorizontallyResizable = !wraps
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = wraps ? [.width] : []
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// native-look.md 4.2, every setting.
    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        enabledTextCheckingTypes = 0
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        inlinePredictionType = .no
        if #available(macOS 15, *) { writingToolsBehavior = .none }
        usesFindBar = false
        usesFontPanel = false
        usesRuler = false
        isIncrementalSearchingEnabled = false
        usesInspectorBar = false
        allowsUndo = true
        drawsBackground = false
        focusRingType = .none
        isFieldEditor = false
        isEditable = true
        isSelectable = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        defaultParagraphStyle = paragraph
        typingAttributes = textAttributes(paragraph)
        registerForDraggedTypes([.fileURL, .string])
    }

    /// TextKit puts a line's extra height above its glyphs: the baseline
    /// sits at the line's height less the descent. Raised by the difference,
    /// it sits where `AgentMetrics.baseline` puts every other text, so a
    /// chip beside it shares its baseline to the pixel.
    private var baselineRaise: CGFloat {
        (lineHeight + font14or17.descender) - AgentMetrics.baseline(font14or17, lineHeight: lineHeight)
    }

    private func textAttributes(_ paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        [.font: font14or17, .paragraphStyle: paragraph, .baselineOffset: baselineRaise]
    }

    /// Colours from the palette: ink text and caret, ink at 28 % selection,
    /// IME underline in the second tone, placeholder in the third.
    func apply(_ palette: ClawddyPalette) {
        let ink = palette.ink.nsColor
        textColor = ink
        insertionPointColor = ink
        typingAttributes[.foregroundColor] = ink
        selectedTextAttributes = [.backgroundColor: palette.ink.nsColor.withAlphaComponent(0.28), .foregroundColor: ink]
        markedTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: palette.text2.nsColor]
        placeholderColor = palette.text3.nsColor
    }

    // MARK: Size

    /// The height its text takes, at most `maxLines` lines: what its owner
    /// sizes it and its slab to.
    var textHeight: CGFloat {
        guard let layoutManager, let textContainer else { return lineHeight }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let lines = max(1, Int((used / lineHeight).rounded()))
        return CGFloat(min(lines, maxLines)) * lineHeight + 2 * textContainerInset.height
    }

    /// Lines its text takes now (wrapped), for the owner's growth.
    var lineCount: Int {
        guard let layoutManager, let textContainer else { return 1 }
        layoutManager.ensureLayout(for: textContainer)
        return max(1, Int((layoutManager.usedRect(for: textContainer).height / lineHeight).rounded()))
    }

    /// The caret (no selection) is on the first visual line, or there is
    /// no text.
    var caretOnFirstLine: Bool {
        guard let layoutManager, let textContainer, !string.isEmpty else { return true }
        guard selectedRange().length == 0 else { return false }
        layoutManager.ensureLayout(for: textContainer)
        let caret = selectedRange().location
        if caret == 0 { return true }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, (string as NSString).length - 1))
        let caretLine = layoutManager.lineFragmentRect(forGlyphAt: caret >= (string as NSString).length ? max(0, glyph) : glyph, effectiveRange: nil)
        let first = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        // The caret after a trailing newline sits on a line of its own.
        if caret >= (string as NSString).length, string.hasSuffix("\n") { return false }
        return caretLine.minY <= first.minY
    }

    /// Where the first line's baseline sits, from this view's top.
    var firstBaseline: CGFloat {
        textContainerInset.height + AgentMetrics.baseline(font14or17, lineHeight: lineHeight)
    }

    // MARK: Text

    /// Replaces the whole text (a project's draft, a send emptying it),
    /// never while an input method composes, and with a fresh undo history.
    func setText(_ text: String) {
        if hasMarkedText() { unmarkText() }
        guard string != text else { return }
        string = text
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        fieldUndo.removeAllActions()
        onChange?()
        needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
        onChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    /// The caret spans the glyphs, not the whole line box: the text sits
    /// raised to the shared baseline, so the line box's caret would hang
    /// below it.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let height = (font14or17.ascender - font14or17.descender).rounded(.up)
        let baseline = rect.minY + AgentMetrics.baseline(font14or17, lineHeight: lineHeight)
        var caret = rect
        caret.origin.y = AgentMetrics.snap(baseline - font14or17.ascender)
        caret.size.height = height
        super.drawInsertionPoint(in: caret, color: color, turnedOn: flag)
    }

    // MARK: Keys

    /// The modifiers of the key being handled now.
    private var keyFlags: NSEvent.ModifierFlags = []

    override func keyDown(with event: NSEvent) {
        keyFlags = event.modifierFlags
        defer { keyFlags = [] }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        // Option-Return comes as its own command; Return with Shift held is
        // a new line too.
        if selector == #selector(insertNewline(_:)), keyFlags.contains(.shift) {
            return super.doCommand(by: #selector(insertNewlineIgnoringFieldEditor(_:)))
        }
        if command?(selector) == true { return }
        // Moving the caret ends a run of typing: ⌘Z undoes what came after.
        if NSStringFromSelector(selector).hasPrefix("move") { breakUndoCoalescing() }
        // Tab and Shift-Tab do nothing in any field.
        if selector == #selector(insertTab(_:)) || selector == #selector(insertBacktab(_:)) { return }
        super.doCommand(by: selector)
    }

    /// The field's own editing keys while it has the keys: select all, copy,
    /// cut, paste, and redo, so they work whatever the menus can reach (an
    /// app in the background, a sheet). The window's key table has the
    /// app's chords first (⌘Z included: text undo or cancelling a start).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "a"): selectAll(nil)
        case ([.command], "c"): copy(nil)
        case ([.command], "x"): cut(nil)
        case ([.command], "v"): paste(nil)
        case ([.command], "z"): fieldUndo.undo()
        case ([.command, .shift], "z"): fieldUndo.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Escape's default, completion, does nothing in any field.
    override func complete(_ sender: Any?) {}

    override func cancelOperation(_ sender: Any?) {
        if command?(#selector(cancelOperation(_:))) == true { return }
    }

    override var undoManager: UndoManager? { fieldUndo }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        onResign?()
        return true
    }

    /// A click into the field of a window that is not key places the caret
    /// too: the line and the palette are safe regions (they take the
    /// activating click).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes = textAttributes(paragraph)
        attributes[.foregroundColor] = placeholderColor
        let text = NSAttributedString(string: placeholder, attributes: attributes)
        let origin = textContainerOrigin
        text.draw(with: NSRect(x: origin.x, y: origin.y, width: bounds.width - origin.x, height: lineHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Paste and drop

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.fileURL, .string] }

    /// Files and folders become their paths, separated by a space; a path
    /// with a space or a quote in single quotes.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .fileURL,
              let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return super.readSelection(from: pboard, type: type) }
        insertText(Self.paths(urls), replacementRange: selectedRange())
        return true
    }

    override func preferredPasteboardType(from availableTypes: [NSPasteboard.PasteboardType], restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?) -> NSPasteboard.PasteboardType? {
        if availableTypes.contains(.fileURL) { return .fileURL }
        return availableTypes.contains(.string) ? .string : nil
    }

    /// The paths of `urls` as typed into a shell line.
    static func paths(_ urls: [URL]) -> String {
        urls.map { url in
            let path = url.path
            guard path.contains(where: { $0 == " " || $0 == "'" || $0 == "\"" }) else { return path }
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
