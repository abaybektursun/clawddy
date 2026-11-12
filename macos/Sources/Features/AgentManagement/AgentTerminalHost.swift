import AppKit
import Combine

/// Per-agent host that conforms to TerminalView's required contracts so a
/// Ghostty.SurfaceView can render inside the workspace detail pane while
/// Ghostty's focus chain runs unchanged.
///
/// Focus invariant (mirrors BaseTerminalController.syncFocusToSurfaceTree):
/// a surface is "focused" iff its hosting window is key AND it is this
/// host's selected surface AND it is firstResponder. If any leg goes false,
/// libghostty must be told via focusDidChange(false) — otherwise
/// SurfaceView.performKeyEquivalent early-returns on !focused and arrows,
/// escape, and ctrl-c get eaten by AppKit before reaching the surface.
///
/// Clipboard invariant (mirrors BaseTerminalController): pending clipboard
/// confirmations flow through the same policy and the same sheet presenter as
/// terminal windows. Agent surfaces must not hang under `clipboard-read = ask`.
///
/// Re-run the invariant on:
///   - focusedSurface changes (didSet)
///   - workspace window didBecomeKey/didResignKey (driven by the hosting
///     controller, which forwards to the active host)
///   - every accepted NSWindow first-responder transition (driven by
///     AgentWorkspaceWindow)
final class AgentTerminalHost: NSObject, ObservableObject, TerminalViewModel, TerminalViewDelegate {

    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init() {
        didSet {
            // A surface that leaves this host can no longer present UI. Resolve
            // its request as denied instead of leaving it pending forever.
            for surface in oldValue where !surfaceTree.contains(surface) {
                clipboardConfirmation.cancelPendingRequest(for: surface)
            }
        }
    }

    @Published var commandPaletteIsShowing: Bool = false

    var updateOverlayIsVisible: Bool { false }

    /// The window the host's view is currently displayed in. Set by the
    /// hosting controller. syncFocus reads window.isKeyWindow from here.
    weak var hostingWindow: NSWindow? {
        didSet {
            guard oldValue !== hostingWindow else { return }
            observeHostingWindowClose()
        }
    }

    /// The currently selected surface. Setting this re-runs the focus
    /// invariant — exactly what BaseTerminalController does.
    var focusedSurface: Ghostty.SurfaceView? {
        didSet { syncFocus() }
    }

    /// Shared clipboard-confirmation presentation. The presenter reads the
    /// request from the surface, so this host keeps no second copy.
    private let clipboardConfirmation = ClipboardConfirmationPresenter()

    private var clipboardConfirmationCancellable: AnyCancellable?
    private var hostingWindowCloseObserver: NSObjectProtocol?

    override init() {
        super.init()

        // Preserve Ghostty's clipboard privacy contract: the sheet is anchored
        // to the surface's owning window, never to a global key/main window.
        clipboardConfirmation.windowForSurface = { [weak self] surface in
            surface.window ?? self?.hostingWindow
        }

        clipboardConfirmationCancellable = ClipboardConfirmationPresenter
            .pendingRequestsPublisher(for: $surfaceTree.eraseToAnyPublisher())
            .sink { [weak self] id, request in
                guard let self,
                      let surface = self.surfaceTree.first(where: { $0.id == id }) else { return }
                self.clipboardConfirmation.requestDidChange(
                    request,
                    for: surface,
                    isSelected: surface == self.focusedSurface)
            }
    }

    deinit {
        if let hostingWindowCloseObserver {
            NotificationCenter.default.removeObserver(hostingWindowCloseObserver)
        }

        // No sheet or pending callback may outlive the pane it belongs to.
        clipboardConfirmation.cancelPendingRequests(in: surfaceTree)
    }

    /// Re-runs Ghostty's exact focus rule against the host's window + tree.
    func syncFocus() {
        var newlyFocused: Ghostty.SurfaceView?
        for view in surfaceTree {
            let isFocused = AgentFocusPolicy.isTerminalFocused(
                windowIsKey: hostingWindow?.isKeyWindow ?? false,
                surfaceIsSelected: view == focusedSurface,
                surfaceIsFirstResponder: view.isFirstResponder)
            view.focusDidChange(isFocused)
            if isFocused { newlyFocused = view }
        }

        // A request that arrived before the surface could present (window not
        // key yet, surface not first responder yet) is shown once focus lands.
        if let newlyFocused {
            clipboardConfirmation.presentPendingRequest(
                for: newlyFocused,
                isSelected: newlyFocused == focusedSurface)
        }
    }

    /// Close any sheet before the workspace window goes away.
    private func observeHostingWindowClose() {
        if let hostingWindowCloseObserver {
            NotificationCenter.default.removeObserver(hostingWindowCloseObserver)
            self.hostingWindowCloseObserver = nil
        }

        guard let hostingWindow else { return }
        hostingWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: hostingWindow,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.clipboardConfirmation.cancelPendingRequests(in: self.surfaceTree)
        }
    }

    // MARK: - TerminalViewDelegate

    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        focusedSurface = to
    }

    func pwdDidChange(to: URL?) {}
    func cellSizeDidChange(to: NSSize) {}
    func performAction(_ action: String, on: Ghostty.SurfaceView) {}
    func performSplitAction(_ action: TerminalSplitOperation) {}
}
