import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// Every live agent terminal of the workspace window, one over another, each
/// at the full size of the terminal area. One of them, the presented agent's,
/// is shown; the others stay in the window, hidden, with drawing stopped.
///
/// The invariant, owned here and nowhere else. For every terminal the stack
/// holds:
/// - it is in the window, at the stack's size, from `add` to `remove`;
/// - it is not hidden exactly when it is the presented agent's;
/// - it tracks the pointer exactly when it is shown, so a hidden program
///   gets no mouse reports (`SurfaceView.updateTrackingAreas`);
/// - it follows the stack's size whether shown or not, so it has its size
///   before its first frame on return;
/// - it draws (`ghostty_surface_set_occlusion(true)`) exactly when it is the
///   presented agent's and the window can be seen (`occlusionState` contains
///   `.visible`; a test or the harness forces that with
///   `AgentWorkspaceWindow.forcesTerminalsVisible`);
/// - it, or a view inside its pane, may be the window's first responder only
///   when it is the presented agent's: the window asks `mayBecomeFirstResponder`
///   before every change of first responder and refuses any other;
/// - Ghostty's focus (`SurfaceView.focusDidChange`, which gates the
///   terminal's key equivalents, Control-C among them) is true exactly when
///   the window is key, the terminal is the presented agent's, and it is the
///   window's first responder (`AgentFocusPolicy`), re-derived for every
///   terminal after every change of any of the three (`syncFocus`).
///
/// This is Ghostty's own rule for a terminal window, kept by the one object
/// that owns all of the window's terminals, as `BaseTerminalController` owns
/// its surface tree (`syncFocusToSurfaceTree`, `syncSurfaceTreeOcclusionState`,
/// `windowDidBecomeKey`), with the tree's focused surface replaced by the
/// presented agent. No terminal is ever taken out of the window and put back:
/// that re-hosting, and focus rules copied per terminal, are what let keys
/// reach no terminal or the wrong one.
///
/// A terminal is Ghostty's AppKit scroll view and surface
/// (`SurfaceScrollView`), placed by frame, with no SwiftUI and no Auto
/// Layout of its own: a hidden terminal does no layout, no drawing and no
/// size negotiation when anything else changes, and is laid out only when
/// the stack's size changes. (Ghostty's SwiftUI `TerminalView`, one per
/// terminal, observed every published change of its surface, so each
/// progress report, title or window focus change of a hidden terminal ran
/// a SwiftUI transaction, constraint updates and a layout of its hosting
/// view in the same turn as whatever the person did.) Ghostty's overlays
/// over a terminal (search, a link's address, key sequences, the size while
/// resizing, the secure input mark, bell and error views) are drawn by a
/// SwiftUI view that exists only while the shown terminal has one to show
/// (`AgentSurfaceOverlay`); a plain terminal costs the window no SwiftUI view
/// and nothing that needs Auto Layout.
///
/// The stack's layer is ours: the grow transform goes on the screen's
/// layers, never on a terminal's own layer.
final class AgentTerminalStack: NSView {

    /// One agent's terminal and what it needs, created and destroyed together.
    private struct Pane {
        let host: AgentTerminalHost
        let scroll: SurfaceScrollView
        let surface: Ghostty.SurfaceView
        /// Report the surface to the bridge; cancelled with the pane.
        let observers: [AnyCancellable]
    }

    private var panes: [UUID: Pane] = [:]
    private var windowObservers: [NSObjectProtocol] = []
    private let ghostty: Ghostty.App
    /// Ghostty's overlays over the shown terminal, over every terminal:
    /// made when the shown terminal has something to overlay, removed when
    /// it has nothing, and made anew for each terminal, so no overlay's
    /// state (search text, a link's address, a key sequence) carries from
    /// one agent's terminal to the next.
    private var overlay: AgentSurfaceOverlayHost?
    private let overlayFocus = AgentSurfaceOverlayFocus()
    /// The shown terminal's changes, and secure input's, which may bring an
    /// overlay or take it away.
    private var overlayWatch: [AnyCancellable] = []
    private weak var watchedSurface: Ghostty.SurfaceView?
    private var overlayCheckPending = false
    /// The shown terminal's size before it was resized, while Ghostty's
    /// size overlay is due to show, and until when.
    private var resize: (from: CGSize, until: Date)?

    /// The agent whose terminal is shown, if it has one.
    private(set) var presentedID: UUID?

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Terminals

    /// The agent's terminal, shown or not.
    func surface(id: UUID) -> Ghostty.SurfaceView? { panes[id]?.surface }

    /// The terminal that is shown, if any.
    var presentedSurface: Ghostty.SurfaceView? { presentedID.flatMap { panes[$0]?.surface } }

    /// The terminal Ghostty's overlays show over, while they exist.
    var overlaySurface: Ghostty.SurfaceView? { overlay?.surfaceView }
    /// The overlays' view, while it exists.
    var overlayView: NSView? { overlay }
    /// Whether the overlays take the shown terminal as focused.
    var overlayFocused: Bool { overlayFocus.focused }

    /// How many times a terminal was laid out, for the tests that a hidden
    /// terminal lays out only when the stack's size changes.
    private(set) var terminalLayouts = 0

    /// Puts the agent's new terminal in the window, hidden and not drawing
    /// unless its agent is presented.
    func add(_ surface: Ghostty.SurfaceView, for id: UUID, observers: [AnyCancellable]) {
        precondition(panes[id] == nil, "Agent \(id) already has a terminal in the stack.")
        let host = AgentTerminalHost()
        host.surfaceTree = SplitTree(view: surface)
        let scroll = SurfaceScrollView(contentSize: bounds.size, surfaceView: surface)
        scroll.isHidden = true
        addSubview(scroll, positioned: .below, relativeTo: overlay)
        // At its full size at once, so it can take the keys at once.
        place(scroll)
        // Ghostty starts a surface drawing while `isWindowVisible` says it
        // does not; tell it the truth before anything reads that mirror.
        if let cSurface = surface.surface { ghostty_surface_set_occlusion(cSurface, false) }
        surface.isWindowVisible = false
        panes[id] = Pane(host: host, scroll: scroll, surface: surface, observers: observers)
        sync()
    }

    /// Takes the agent's terminal out of the window for good, the keys
    /// first if it has them.
    func remove(_ id: UUID) {
        guard let pane = panes.removeValue(forKey: id) else { return }
        pane.observers.forEach { $0.cancel() }
        if let window, holdsFirstResponder(pane, in: window) {
            takeKeys(from: window)
        }
        pane.scroll.removeFromSuperview()
        sync()
    }

    /// Shows the agent's terminal, if it has one, and hides every other.
    /// A terminal being hidden gives up the keys first: AppKit would
    /// otherwise pass them to whichever view comes next.
    func present(_ id: UUID?) {
        presentedID = id
        if let window, let holder = panes.first(where: { holdsFirstResponder($0.value, in: window) }),
           holder.key != id {
            takeKeys(from: window)
        }
        sync()
    }

    /// Leaves the keys with the window. It must succeed: a terminal about
    /// to be hidden or removed that kept them would take keys no one sees.
    private func takeKeys(from window: NSWindow) {
        guard window.makeFirstResponder(nil) else {
            fatalError("\(String(describing: window.firstResponder)) refused to give up the keys before its terminal was hidden.")
        }
    }

    /// The agent whose terminal is the surface with this id (Ghostty's
    /// notifications name a surface by it).
    func agent(ofSurface surfaceID: UUID) -> UUID? {
        panes.first { $0.value.surface.id == surfaceID }?.key
    }

    /// Gives the shown terminal the keys. False when nothing is shown or
    /// the stack is not in a window.
    @discardableResult
    func giveKeysToPresented() -> Bool {
        guard let surface = presentedSurface, let window else { return false }
        return window.makeFirstResponder(surface)
    }

    /// Whether `responder` may become the window's first responder: anything
    /// outside the terminals, and the shown terminal or a view in its pane
    /// while the window names it the owner of the keys (`terminalOwnsKeys`:
    /// inside its agent, no palette open). A terminal still on screen as
    /// home comes back (the shrink of leaving) is no longer the owner:
    /// Ghostty's deferred `moveFocus`, which a terminal's own program can
    /// set off, would otherwise take the tiles' keys and leave them with
    /// the window when the terminal is hidden.
    func mayBecomeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView,
              let pane = panes.first(where: { view.isDescendant(of: $0.value.scroll) })
        else { return true }
        return pane.key == presentedID && terminalOwnsKeys(pane.key)
    }

    /// Whether the window names this agent's terminal the owner of the keys
    /// now (set by `AgentWindowController`).
    var terminalOwnsKeys: (UUID) -> Bool = { _ in true }

    // MARK: Size

    /// Every terminal at the stack's size, shown or not, so a hidden one
    /// has its size before its first frame on return; a terminal is laid
    /// out only when that size changes.
    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        needsLayout = true
        // Ghostty shows the shown terminal's new size for a moment after a
        // resize (`SurfaceResizeOverlay`, after the first size).
        if old != newSize, old != .zero, presentedID != nil, ghostty.config.resizeOverlay != .never {
            let shownFor = Double(ghostty.config.resizeOverlayDuration) / 1000 + 0.1
            resize = (from: resize?.from ?? old, until: Date() + shownFor)
            overlayMayChange()
            DispatchQueue.main.asyncAfter(deadline: .now() + shownFor + 0.05) { [weak self] in self?.overlayMayChange() }
        }
    }

    override func layout() {
        super.layout()
        for pane in panes.values { place(pane.scroll) }
        if let overlay, overlay.frame != bounds { overlay.frame = bounds }
    }

    private func place(_ scroll: SurfaceScrollView) {
        guard scroll.frame != bounds else { return }
        scroll.frame = bounds
        // A hidden view is not laid out by the window's pass; this one is
        // laid out now, once, for its new size.
        scroll.layoutSubtreeIfNeeded()
        terminalLayouts += 1
    }

    // MARK: The invariant

    /// Re-derives everything the invariant says from the presented agent and
    /// the window: shown, drawing, focus, and the overlays.
    private func sync() {
        for (id, pane) in panes {
            let presented = id == presentedID
            if pane.scroll.isHidden == presented { pane.scroll.isHidden = !presented }
            // Only the shown terminal tracks the pointer
            // (`SurfaceView.updateTrackingAreas`): a new surface made its
            // tracking area before it was in the hidden pane.
            if presented == pane.surface.trackingAreas.isEmpty { pane.surface.updateTrackingAreas() }
            pane.host.isPresented = presented
        }
        syncOverlay()
        syncDrawing()
        syncFocus()
    }

    /// Ghostty's overlays exist exactly while the shown terminal has one to
    /// show, over that terminal only; no hidden terminal's change reaches
    /// SwiftUI. Another terminal shown takes the old overlays away at once.
    private func syncOverlay() {
        let surface = presentedSurface
        if watchedSurface !== surface {
            watchedSurface = surface
            resize = nil
            overlayWatch = surface.map { surface in
                // Published before the change: checked once it is made.
                [surface.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.overlayMayChange() } },
                 SecureInput.shared.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.overlayMayChange() } }]
            } ?? []
        }
        if let resize, resize.until <= Date() { self.resize = nil }
        let wanted = surface.flatMap { hasOverlay($0) ? $0 : nil }
        if let overlay, overlay.surfaceView !== wanted { removeOverlay(overlay) }
        if overlay == nil, let wanted { addOverlay(over: wanted) }
    }

    /// Whether the shown terminal has anything of Ghostty's to overlay: what
    /// `AgentSurfaceOverlay` draws.
    private func hasOverlay(_ surface: Ghostty.SurfaceView) -> Bool {
        let config = ghostty.config
        return surface.searchState != nil || surface.hoverUrl != nil || !surface.keySequence.isEmpty
            || !surface.keyTables.isEmpty || surface.readonly || surface.childExitedMessage != nil
            || !surface.healthy || surface.error != nil || surface.highlighted
            || (surface.bell && config.bellFeatures.contains(.border))
            || (config.secureInputIndication && SecureInput.shared.enabled && overlayFocus.focused)
            || resize != nil
    }

    private func addOverlay(over surface: Ghostty.SurfaceView) {
        let host = AgentSurfaceOverlayHost(rootView: AgentSurfaceOverlay(
            ghostty: ghostty, surfaceView: surface, focus: overlayFocus, resizedFrom: resize?.from))
        host.sizingOptions = []
        host.frame = bounds
        addSubview(host)
        overlay = host
    }

    /// Takes the overlays away; keys typed in them (the search field) go
    /// back to the shown terminal.
    private func removeOverlay(_ host: AgentSurfaceOverlayHost) {
        let window = window
        let hadKeys = (window?.firstResponder as? NSView)?.isDescendant(of: host) ?? false
        if let window, hadKeys { takeKeys(from: window) }
        host.removeFromSuperview()
        overlay = nil
        if hadKeys { giveKeysToPresented() }
    }

    /// The shown terminal or secure input is about to change: whether an
    /// overlay shows is decided once the change is made, before the frame.
    private func overlayMayChange() {
        guard !overlayCheckPending else { return }
        overlayCheckPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlayCheckPending = false
            self.syncOverlay()
        }
    }

    /// Only the shown terminal draws, and only while the window can be seen.
    private func syncDrawing() {
        let seen = window?.occlusionState.contains(.visible) ?? false
        for (id, pane) in panes {
            let draws = seen && id == presentedID
            guard let cSurface = pane.surface.surface, pane.surface.isWindowVisible != draws else { continue }
            ghostty_surface_set_occlusion(cSurface, draws)
            pane.surface.isWindowVisible = draws
        }
    }

    /// Ghostty's focus for every terminal (`AgentFocusPolicy`). The window
    /// calls this after every accepted change of first responder.
    func syncFocus() {
        let windowIsKey = window?.isKeyWindow ?? false
        for (id, pane) in panes {
            let focused = AgentFocusPolicy.isTerminalFocused(
                windowIsKey: windowIsKey,
                surfaceIsSelected: id == presentedID,
                surfaceIsFirstResponder: pane.surface.isFirstResponder)
            pane.surface.focusDidChange(focused)
            if focused { pane.host.presentPendingClipboardRequest() }
        }
        let shownFocused = presentedSurface?.focused ?? false
        if overlayFocus.focused != shownFocused {
            overlayFocus.focused = shownFocused
            overlayMayChange()
        }
    }

    private func holdsFirstResponder(_ pane: Pane, in window: NSWindow) -> Bool {
        guard let view = window.firstResponder as? NSView else { return false }
        return view.isDescendant(of: pane.scroll)
    }

    // MARK: The window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        guard let window else { return }
        (window as? AgentWorkspaceWindow)?.terminals = self
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidBecomeKey() }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncFocus() }
            },
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncDrawing() }
            },
            // No clipboard sheet or pending request outlives the window.
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for pane in self.panes.values { pane.host.cancelPendingClipboardRequests() }
                }
            },
        ]
        sync()
    }

    /// As `BaseTerminalController.windowDidBecomeKey`: a window whose first
    /// responder is itself gives the keys back to the shown terminal. Both
    /// wait for the next turn of the run loop, as upstream's do, because
    /// becoming key races with AppKit restoring the responder; the move is
    /// decided then from the window as it is, so it never overrides a
    /// responder chosen in between.
    private func windowDidBecomeKey() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let window = self.window, window.firstResponder === window {
                self.giveKeysToPresented()
            }
            self.syncFocus()
        }
    }

    /// The stack takes no click itself: where no terminal is shown, a click
    /// reaches the view under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }
}

/// Whether the shown terminal has Ghostty's focus now (its `focused` is not
/// published): the secure-input mark follows it.
final class AgentSurfaceOverlayFocus: ObservableObject {
    @Published var focused = false
}

/// The SwiftUI host of the shown terminal's overlays. Where no overlay
/// shows, the pointer passes through to the terminal under it.
final class AgentSurfaceOverlayHost: NSHostingView<AgentSurfaceOverlay> {
    var surfaceView: Ghostty.SurfaceView { rootView.surfaceView }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }
}

/// Ghostty's overlays over one terminal, as its `SurfaceWrapper` draws them
/// (`SurfaceView.swift`), less what an agent's terminal never shows: the
/// progress bar (the mark carries progress), the split dimming and the
/// window's grab handle.
struct AgentSurfaceOverlay: View {
    let ghostty: Ghostty.App
    let surfaceView: Ghostty.SurfaceView
    @ObservedObject var focus: AgentSurfaceOverlayFocus
    /// The terminal's size before the resize that made these overlays, so
    /// Ghostty's size overlay shows the new size at once.
    let resizedFrom: CGSize?

    var body: some View {
        Overlays(surfaceView: surfaceView, focused: focus.focused, resizedFrom: resizedFrom).environmentObject(ghostty)
    }

    private struct Overlays: View {
        @ObservedObject var surfaceView: Ghostty.SurfaceView
        let focused: Bool
        let resizedFrom: CGSize?
        @ObservedObject private var secureInput = SecureInput.shared
        @EnvironmentObject private var ghostty: Ghostty.App

        var body: some View {
            ZStack {
                GeometryReader { geo in
                    if let surfaceSize = surfaceView.surfaceSize {
                        Ghostty.SurfaceResizeOverlay(
                            geoSize: geo.size,
                            size: surfaceSize,
                            overlay: ghostty.config.resizeOverlay,
                            position: ghostty.config.resizeOverlayPosition,
                            duration: ghostty.config.resizeOverlayDuration,
                            focusInstant: surfaceView.focusInstant,
                            lastSize: resizedFrom,
                            ready: resizedFrom != nil)
                    }
                }
                if surfaceView.readonly {
                    Ghostty.ReadonlyBadge { surfaceView.toggleReadonly(nil) }
                }
                Ghostty.KeyStateIndicator(keyTables: surfaceView.keyTables, keySequence: surfaceView.keySequence)
                    .zIndex(1)
                VStack(spacing: 0) {
                    if let url = surfaceView.hoverUrl { URLHoverBanner(url: url) }
                    if let msg = surfaceView.childExitedMessage {
                        ChildExitedMessageBar(msg: msg)
                            .font(.system(size: min(surfaceView.cellSize.height * 0.8, 30)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                if ghostty.config.secureInputIndication && secureInput.enabled && focused {
                    SecureInputOverlay()
                }
                if let searchState = surfaceView.searchState {
                    Ghostty.SurfaceSearchOverlay(
                        surfaceView: surfaceView, searchState: searchState, onClose: { surfaceView.endSearch() })
                }
                if ghostty.config.bellFeatures.contains(.border) {
                    Ghostty.BellBorderOverlay(bell: surfaceView.bell)
                }
                Ghostty.HighlightOverlay(highlighted: surfaceView.highlighted)
                if !surfaceView.healthy {
                    Rectangle().fill(ghostty.config.backgroundColor)
                    Ghostty.SurfaceRendererUnhealthyView()
                } else if surfaceView.error != nil {
                    Rectangle().fill(ghostty.config.backgroundColor)
                    Ghostty.SurfaceErrorView()
                }
            }
            .ghosttySurfaceView(surfaceView)
        }
    }
}
