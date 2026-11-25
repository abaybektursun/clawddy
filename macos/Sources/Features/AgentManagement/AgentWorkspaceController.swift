import AppKit
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentWorkspace")

/// The chrome of the agent window holds only safe, reversible controls, so
/// its regions take the click that activates an inactive window. The
/// terminal's screen deliberately does not: its first activation click must
/// never be encoded as terminal input.
protocol AgentActivationClickSafeRegion: AnyObject {}

/// Centralizes first-responder transitions for the agent window and its
/// Ghostty terminals. Every change of first responder passes the agent terminals'
/// rule (`AgentTerminalStack.mayBecomeFirstResponder`: only the shown
/// terminal may take the keys), and Ghostty's focus bit of every terminal is
/// reconciled immediately after AppKit accepts the change.
class AgentWorkspaceWindow: NSWindow {
    /// The window's agent terminals; the stack sets itself when it enters
    /// the window.
    weak var terminals: AgentTerminalStack?

    /// A test or a harness run drives the window as the shown key and main
    /// window it would be in use, off screen, in an app that never becomes
    /// active.
    var actsAsKey = false {
        didSet { terminals?.syncFocus() }
    }

    /// A test or a harness run has the window count as seen although no one
    /// sees it, so the shown terminal draws, for pictures, and what follows
    /// the window being seen runs as it would on screen.
    var forcesTerminalsVisible = false {
        didSet { NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self) }
    }

    override var isKeyWindow: Bool { actsAsKey || super.isKeyWindow }
    override var isMainWindow: Bool { actsAsKey || super.isMainWindow }
    override var isVisible: Bool { actsAsKey || super.isVisible }
    override var occlusionState: NSWindow.OcclusionState {
        forcesTerminalsVisible ? .visible : super.occlusionState
    }

    /// Window restoration brings back what the window was (full screen,
    /// its place among windows), but not its frame: that has one owner, the
    /// frame saved under `frameName`, which the window opened with
    /// (`applyOpeningFrame`, just before). Restoration would put back the
    /// frame of its own last saved state, which a session with a collapsed
    /// window left at 1 point wide (AppKit then showed it at the minimum
    /// size), and the saved frame follows every change at once.
    override func restoreState(with coder: NSCoder) {
        keepingFrame { super.restoreState(with: coder) }
    }

    /// Runs `change` and gives the window back the frame it had before,
    /// unless `change` put it in full screen.
    func keepingFrame(_ change: () -> Void) {
        let owned = frame
        change()
        guard !styleMask.contains(.fullScreen), frame != owned else { return }
        setFrame(owned, display: false)
    }

    /// Edit ▸ Undo does what ⌘Z does where the keys are
    /// (`ClawddyController.undo(in:)`): text undo in a field holding text,
    /// else the session's last undoable action (flows.md 3.4).
    var onUndo: (() -> Void)?
    /// Edit ▸ Undo's title and whether it acts now ("Undo settle", greyed
    /// when nothing can be undone).
    var undoMenu: (() -> (title: String, enabled: Bool))?

    @objc func undo(_ sender: Any?) {
        onUndo?()
    }

    /// Window ▸ Toggle Full Screen and ⌃⌘F, which Ghostty's menu sends to
    /// its terminal windows, and Ghostty's own key for it in an agent's
    /// terminal (`ghosttyToggleFullscreen`): the system's full screen
    /// (last review ruling 8).
    @IBAction func toggleGhosttyFullScreen(_ sender: Any?) {
        toggleFullScreen(sender)
    }

    private var fullScreenObserver: NSObjectProtocol?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        fullScreenObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyToggleFullscreen, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let surface = note.object as? NSView, surface.window === self else { return }
                self.toggleFullScreen(nil)
            }
        }
    }

    deinit {
        if let fullScreenObserver { NotificationCenter.default.removeObserver(fullScreenObserver) }
    }

    /// Redo is a field's own.
    @objc func redo(_ sender: Any?) {
        (firstResponder as? AgentTextView)?.fieldUndo.redo()
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            let menu: (title: String, enabled: Bool) = undoMenu?() ?? ("Undo", false)
            item.title = menu.title
            return menu.enabled
        case #selector(redo(_:)):
            let field = (firstResponder as? AgentTextView)?.fieldUndo
            item.title = field?.redoMenuItemTitle ?? "Redo"
            return field?.canRedo == true
        default:
            return super.validateMenuItem(item)
        }
    }

    /// The app's chords (`AgentChords`, through
    /// `ClawddyController.performChord`): true when the key was one of them
    /// and its command ran.
    var performChord: ((NSEvent) -> Bool)?

    /// The app's chords come first, before any view, the focused terminal
    /// included, sees the key, and before the main menu, which AppKit asks
    /// after the key window. A key the table does not claim goes on exactly
    /// as in Ghostty.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyDuringDrag?(event) == true { return true }
        if event.type == .keyDown, performChord?(event) == true { return true }
        // ⌘V while a CLI starts is held with the keys (it never reaches
        // `sendEvent`).
        if event.type == .keyDown, event.modifierFlags.contains(.command), holdsKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// While a tile or a row is moved by the pointer, every key is taken
    /// here: Escape puts everything back, no other key acts (flows.md 3.5).
    var keyDuringDrag: ((NSEvent) -> Bool)?

    /// Whether `ClawddyController.holdKey` keeps this key for an agent whose
    /// CLI does not read its input yet.
    var holdsKey: ((NSEvent) -> Bool)?

    /// A hidden agent terminal never takes the keys, whoever asks: a click,
    /// the key-view loop, Ghostty's deferred `moveFocus`, or Clawddy itself.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let terminals, !terminals.mayBecomeFirstResponder(responder) {
            logger.info("refused the keys to a hidden agent terminal: \(String(describing: responder), privacy: .public)")
            return false
        }
        let accepted = super.makeFirstResponder(responder)
        if accepted {
            terminals?.syncFocus()
            onFirstResponderChange?()
        }
        return accepted
    }

    /// Runs after every change of first responder: what shows who has the
    /// keys follows (`AgentWindowController.focusChanged`).
    var onFirstResponderChange: (() -> Void)?

    /// Sees every mouse-down before the view under it: the keys panel
    /// closes on a click anywhere outside it.
    var onMouseDown: ((NSEvent) -> Void)?

    /// Keys typed for an agent whose CLI is starting are held, in order, and
    /// delivered at its first report: none lost to its login shell or a
    /// start-up screen, none twice (flows.md 4.5). Chords have been offered
    /// to `performKeyEquivalent` before a key comes here.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .keyUp, keyDuringDrag?(event) == true { return }
        if event.type == .keyDown || event.type == .keyUp, holdsKey?(event) == true { return }
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onMouseDown?(event) }
        let targetsSafeRegion = contentView.map { contentView in
            let location = contentView.convert(event.locationInWindow, from: nil)
            return AgentFirstMousePolicy.targetsSafeRegion(
                startingAt: contentView.hitTest(location))
        } ?? false
        if AgentFirstMousePolicy.shouldPromoteWindow(
            eventType: event.type,
            windowIsKey: isKeyWindow,
            targetsSafeRegion: targetsSafeRegion
        ) {
            // Promote before AppKit dispatches the original event, without
            // synthesizing, reposting, or retrying the click.
            NSApp.activate(ignoringOtherApps: true)
            makeKey()
        }
        super.sendEvent(event)
    }
}

enum AgentFirstMousePolicy {
    static func targetsSafeRegion(startingAt view: NSView?) -> Bool {
        var candidate = view
        while let view = candidate {
            if view is AgentActivationClickSafeRegion {
                return true
            }
            candidate = view.superview
        }
        return false
    }

    static func shouldPromoteWindow(
        eventType: NSEvent.EventType,
        windowIsKey: Bool,
        targetsSafeRegion: Bool
    ) -> Bool {
        eventType == .leftMouseDown && !windowIsKey && targetsSafeRegion
    }
}

extension NSView {
    /// The window controls in this view's coordinates, from its top left;
    /// nil where the window shows none, as in full screen.
    var windowControlsFrame: CGRect? {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              !zoom.isHiddenOrHasHiddenAncestor
        else { return nil }
        let frame = close.convert(close.bounds, to: self).union(zoom.convert(zoom.bounds, to: self))
        return isFlipped ? frame : CGRect(
            x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }
}

/// Creates the agent window: the content runs under a transparent
/// titlebar, so the window's own buttons sit at the left of the top bar,
/// and the title is not shown but stays set for Mission Control and the
/// Window menu. Its frame is kept in the preferences (a harness run's are
/// its own file, `AgentHarness.preferences`) and it comes back with window
/// restoration.
///
/// The window owns its size. Its content is laid out by frames and has no
/// size of its own, so assigning the content view controller shrinks the
/// window to nothing; the frame is set here, after that, every time.
let agentWorkspaceMinimumSize = NSSize(width: 900, height: 560)

/// The frame the agent window opens with: the saved one when it is at least
/// the minimum size, else 1440 by 900 (or what the screen allows) centred
/// on the screen. A saved frame below the minimum is never used.
func agentWorkspaceOpeningFrame(saved: NSRect?, screen visible: NSRect) -> NSRect {
    if let saved,
       saved.width >= agentWorkspaceMinimumSize.width,
       saved.height >= agentWorkspaceMinimumSize.height {
        return saved
    }
    let size = NSSize(width: min(1440, visible.width), height: min(900, visible.height))
    return NSRect(
        x: (visible.midX - size.width / 2).rounded(),
        y: (visible.midY - size.height / 2).rounded(),
        width: size.width,
        height: size.height)
}

func makeAgentWorkspaceWindow(controller: NSViewController, background: NSColor) -> AgentWorkspaceWindow {
    let window = AgentWorkspaceWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.contentViewController = controller
    // The app-wide appearance is synchronized asynchronously to avoid an
    // AppKit launch mutex. Pin this window before its first frame so the
    // window never flashes in the system appearance. Dark only.
    window.appearance = ClawddyPalette.appearance
    window.backgroundColor = background
    window.title = "Clawddy"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.contentMinSize = agentWorkspaceMinimumSize
    window.isReleasedWhenClosed = false
    window.identifier = NSUserInterfaceItemIdentifier("ClawddyAgentWorkspace")
    window.isRestorable = true
    window.restorationClass = AgentWorkspaceRestoration.self
    window.autorecalculatesKeyViewLoop = true

    // A toolbar with no items: its compact style is what lowers the window
    // controls toward the middle of the 44-point top bar (macOS 26: centred
    // 20 points down, against 16 with no toolbar).
    window.toolbar = NSToolbar(identifier: "AgentWorkspaceToolbar")
    window.toolbarStyle = .unifiedCompact

    // Naming the frame applies what is saved under the name, as AppKit
    // reads it (a collapsed frame raised to the minimum): the saved frame is
    // read first, and the opening frame decided after.
    let saved = AgentWorkspaceWindow.savedFrame()
    window.setFrameAutosaveName(AgentWorkspaceWindow.frameName)
    window.applyOpeningFrame(saved: saved)
    return window
}

extension AgentWorkspaceWindow {
    /// The name the window's frame is saved under in the preferences.
    static let frameName = "AgentWorkspace"

    /// The frame saved under `frameName`: the first four numbers of what
    /// the preferences hold ("x y width height", then the screen's).
    static func savedFrame(in defaults: UserDefaults = .standard) -> NSRect? {
        let numbers = (defaults.string(forKey: "NSWindow Frame \(frameName)") ?? "").split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 4 else { return nil }
        return NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// Gives the window its opening frame (`agentWorkspaceOpeningFrame`)
    /// from `saved`, the frame saved under `frameName`, which follows every move and
    /// resize: the one owner of the window's frame across launches. The
    /// saved frame is judged as it was saved: AppKit's own reading of it
    /// raises a collapsed one to the minimum size, which is how the owner's
    /// window came back at 900 by 560. A usable one is applied by AppKit,
    /// which keeps it on a screen.
    func applyOpeningFrame(saved: NSRect?) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let opening = agentWorkspaceOpeningFrame(saved: saved, screen: visible)
        if opening == saved, setFrameUsingName(Self.frameName) { return }
        setFrame(opening, display: false)
    }
}

final class AgentWorkspaceRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            let error = NSError(
                domain: "com.mitchellh.ghostty.clawddy.restoration",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The agent workspace is not ready."])
            completionHandler(nil, error)
            return
        }
        delegate.clawddy.restoreWorkspaceWindow(completionHandler: completionHandler)
    }
}
