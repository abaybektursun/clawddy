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
/// Re-run the invariant on:
///   - focusedSurface changes (didSet)
///   - workspace window didBecomeKey/didResignKey (driven by the hosting
///     controller, which forwards to the active host)
///   - every accepted NSWindow first-responder transition (driven by
///     AgentWorkspaceWindow)
final class AgentTerminalHost: NSObject, ObservableObject, TerminalViewModel, TerminalViewDelegate {

    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init()
    @Published var commandPaletteIsShowing: Bool = false

    var updateOverlayIsVisible: Bool { false }

    /// The window the host's view is currently displayed in. Set by the
    /// hosting controller. syncFocus reads window.isKeyWindow from here.
    weak var hostingWindow: NSWindow?

    /// The currently selected surface. Setting this re-runs the focus
    /// invariant — exactly what BaseTerminalController does.
    var focusedSurface: Ghostty.SurfaceView? {
        didSet { syncFocus() }
    }

    /// Re-runs Ghostty's exact focus rule against the host's window + tree.
    func syncFocus() {
        for view in surfaceTree {
            let isFocused = AgentFocusPolicy.isTerminalFocused(
                windowIsKey: hostingWindow?.isKeyWindow ?? false,
                surfaceIsSelected: view == focusedSurface,
                surfaceIsFirstResponder: view.isFirstResponder)
            view.focusDidChange(isFocused)
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
