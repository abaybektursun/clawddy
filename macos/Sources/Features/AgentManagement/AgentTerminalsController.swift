import AppKit
import Combine
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentTerminals")

/// Creates each agent's Ghostty terminal and keeps it in the terminal stack
/// (`AgentTerminalStack`), which keeps every live terminal in the window and
/// alone decides which one is shown, draws and may take the keys. Its view
/// is the screen (`AgentScreenView`): the rounded frame the shown terminal
/// sits in.
///
/// All keys are UUID-based. Zero rekey on rename.
///
/// This controller is the only creator of agent surfaces. It reports each
/// surface's close, process exit and program status to the bridge, tagged
/// with the launch the surface was created for.
final class AgentTerminalsController: NSViewController {
    private weak var ghostty: Ghostty.App?
    private let bridge: AgentBridge

    /// Every live agent terminal, the shown agent's presented.
    let stack: AgentTerminalStack
    let screen: AgentScreenView
    /// The agent the screen shows, which the workspace model decides: its
    /// terminal when it has one.
    private(set) var activeID: UUID?
    /// Runs when the screen's terminal comes or goes.
    var onPresentationChanged: (() -> Void)?

    private var closeAlert: NSAlert?

    init(ghostty: Ghostty.App, bridge: AgentBridge) {
        self.ghostty = ghostty
        self.bridge = bridge
        self.stack = AgentTerminalStack(ghostty: ghostty)
        self.screen = AgentScreenView(stack: stack)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = screen
    }

    /// Shows the agent's terminal, if it has one, or none. It launches
    /// nothing and gives no keys.
    func show(_ id: UUID?) {
        activeID = id
        refreshPresentation()
    }

    /// The one place presentation is computed: the stack shows the active
    /// agent's terminal, if it has one (its invariant is the stack's).
    private func refreshPresentation() {
        stack.present(activeID)
        onPresentationChanged?()
    }

    /// Creates the agent's terminal when it has none; when the agent is the
    /// one the screen shows and `select` is set, presents it and, with
    /// `focusTerminal`, gives it the keys. The screen never switches to an
    /// agent the workspace does not show.
    @discardableResult
    func showOrSwitch(
        agent: AgentInstance,
        focusTerminal: Bool = true,
        select: Bool = true,
        createConfig: () -> Ghostty.SurfaceConfiguration?
    ) -> Bool {
        let id = agent.id
        var isNew = false
        if stack.surface(id: id) == nil {
            guard let ghostty else { fatalError("AgentTerminalsController used without ghostty") }
            guard let app = ghostty.app, let config = createConfig() else { return false }
            let surface = Ghostty.SurfaceView(app, baseConfig: config)
            // The mark and the sentence carry a CLI's progress, and the app's
            // notification its news: no Ghostty bar or notification of its own.
            surface.isAgentTerminal = true
            // In the window from now on: an attached surface reports its own
            // process's exit, shown or not.
            stack.add(surface, for: id, observers: observeAgentSurface(
                surface,
                childExited: surface.$childExitedMessage.compactMap { $0 }.map { _ in },
                title: surface.$title,
                agentID: id,
                generation: agent.launchGeneration,
                bridge: bridge))
            isNew = true
            logger.info("created terminal for agent \(id)")
        }
        if select, id == activeID {
            refreshPresentation()
            if focusTerminal { stack.giveKeysToPresented() }
        }
        return isNew
    }

    /// Present a pane whose asynchronous preparation just finished. Authority
    /// to present or focus is re-derived from the agent the screen shows now,
    /// not from the activation that started the launch, so a change of agent
    /// during preparation cannot steal focus. The pane is still created when
    /// it is not shown; it is kept for when it is.
    @discardableResult
    func presentPreparedSurface(
        agent: AgentInstance,
        createConfig: () -> Ghostty.SurfaceConfiguration?
    ) -> Bool {
        let window = view.window
        let presentation = AgentLaunchPresentationPolicy.decide(
            agentID: agent.id,
            selectedAgentID: activeID,
            anotherViewHasKeys: anotherViewHasKeys,
            windowIsVisible: window?.isVisible ?? false,
            windowIsMiniaturized: window?.isMiniaturized ?? false)
        return showOrSwitch(
            agent: agent,
            focusTerminal: presentation.focusesTerminal,
            select: presentation.presentsPane,
            createConfig: createConfig)
    }

    /// Whether a view other than the terminals has the keys (a text field),
    /// read from the window's real first responder, never from a copy of it:
    /// the window itself and the terminals do not count.
    private var anotherViewHasKeys: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return !responder.isDescendant(of: stack)
    }

    /// Gives the keys to the shown agent's terminal; with none, to the
    /// window, where keys typed for an agent whose CLI does not run are held
    /// and start it (`ClawddyController.holdKey`).
    func focusTerminal() {
        guard stack.presentedSurface != nil else {
            view.window?.makeFirstResponder(nil)
            return
        }
        stack.giveKeysToPresented()
    }

    /// Asks before closing an agent terminal whose provider is still running,
    /// saying what will happen
    /// (`AgentCloseConfirmation`), in the form of Ghostty's terminal windows
    /// (`BaseTerminalController.closeSurface`): one sheet at a time, and with
    /// no window to ask in, the close goes ahead.
    func confirmClose(id: UUID, then close: @escaping @MainActor () -> Void) {
        guard closeAlert == nil, stack.surface(id: id) != nil, let agent = bridge.agents[id] else { return }
        guard let window = view.window else {
            close()
            return
        }
        let text = AgentCloseConfirmation(name: agent.name)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.addButton(withTitle: AgentCloseConfirmation.confirm)
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        closeAlert = alert
        Task {
            let response = await alert.beginSheetModal(for: window)
            // Keeps focus where it was under Stage Manager (Ghostty #8336).
            alert.window.orderOut(nil)
            closeAlert = nil
            if response == .alertFirstButtonReturn { close() }
        }
    }

    func removeSurface(id: UUID) {
        logger.info("removeSurface \(id)")
        stack.remove(id)
        refreshPresentation()
    }

    func hasSurface(id: UUID) -> Bool { stack.surface(id: id) != nil }

    /// The agent's terminal, shown or not.
    func surface(id: UUID) -> Ghostty.SurfaceView? { stack.surface(id: id) }

    func screen(id: UUID) -> String? {
        guard let surface = stack.surface(id: id)?.surface else { return nil }
        var text = ghostty_text_s()
        // The active area: the screen's bottom rows, where the CLI draws its
        // input, wherever the person has scrolled.
        let active = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, active, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    func input(_ input: AgentTerminalInput, to id: UUID) {
        guard let model = stack.surface(id: id)?.surfaceModel else { return }
        func press(_ key: Ghostty.Input.Key, mods: Ghostty.Input.Mods = [], codepoint: UInt32 = 0) {
            model.sendKeyEvent(Ghostty.Input.KeyEvent(key: key, action: .press, mods: mods, unshiftedCodepoint: codepoint))
            model.sendKeyEvent(Ghostty.Input.KeyEvent(key: key, action: .release, mods: mods, unshiftedCodepoint: codepoint))
        }
        switch input {
        case .paste(let text): model.sendText(text)
        case .enter: press(.enter)
        case .escape: press(.escape)
        case .interrupt: press(.c, mods: .ctrl, codepoint: 0x63)
        }
    }
}

/// The rounded frame the shown terminal sits in (native-look.md 3.7): the
/// theme's own background, radius 10, clipping square to its corners, the
/// stack inset 12 / 16 / 10 / 16. Without a terminal it says, in one quiet
/// line, why: the CLI is starting, or typing will continue the
/// conversation.
final class AgentScreenView: NSView {
    static let inset = NSEdgeInsets(top: 12, left: 16, bottom: 10, right: 16)

    let stack: AgentTerminalStack
    private let quiet = AgentTextLayer()
    private var quietLine: String?
    var palette: ClawddyPalette = .prototype {
        didSet { if palette != oldValue { applyPalette() } }
    }

    init(stack: AgentTerminalStack) {
        self.stack = stack
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.addSublayer(quiet)
        addSubview(stack)
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let frame = NSRect(
            x: inset.left, y: inset.top,
            width: max(0, bounds.width - inset.left - inset.right),
            height: max(0, bounds.height - inset.top - inset.bottom))
        if stack.frame != frame { stack.frame = frame }
        // Where the terminal's first line would be: 2 pt of Ghostty's own
        // padding inside the inset.
        quiet.frame = CGRect(x: inset.left + 2, y: inset.top + 2, width: max(0, frame.width - 4), height: 18)
    }

    /// The quiet line under where the terminal would be, or none.
    func showQuietLine(_ text: String?) {
        quietLine = text
        quiet.text = text.map { AgentText(string: $0, font: AgentMetrics.body, color: palette.text3.cgColor()) }
    }

    private func applyPalette() {
        layer?.backgroundColor = palette.screenLit.cgColor()
        showQuietLine(quietLine)
    }
}
