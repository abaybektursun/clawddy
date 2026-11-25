import AppKit
import Combine

/// Per-agent host of what a terminal needs besides its view: Ghostty's
/// clipboard confirmations.
///
/// Focus is not the host's: `AgentTerminalStack` decides which terminal is
/// shown, may take the keys and has Ghostty's focus, for all of them at once.
/// A pane holds one surface, which is selected exactly when the stack
/// presents it (`isPresented`); what SwiftUI reports as focused is ignored.
///
/// Clipboard invariant (mirrors BaseTerminalController): pending clipboard
/// confirmations flow through the same policy and the same sheet presenter as
/// terminal windows. Agent surfaces must not hang under `clipboard-read = ask`.
final class AgentTerminalHost: NSObject, ObservableObject {

    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init() {
        didSet {
            // A surface that leaves this host can no longer present UI. Resolve
            // its request as denied instead of leaving it pending forever.
            for surface in oldValue where !surfaceTree.contains(surface) {
                clipboardConfirmation.cancelPendingRequest(for: surface)
            }
        }
    }

    /// Whether the stack shows this host's terminal. Set by the stack.
    var isPresented = false

    /// Shared clipboard-confirmation presentation. The presenter reads the
    /// request from the surface, so this host keeps no second copy.
    private let clipboardConfirmation = ClipboardConfirmationPresenter()

    private var clipboardConfirmationCancellable: AnyCancellable?

    override init() {
        super.init()

        // Preserve Ghostty's clipboard privacy contract: the sheet is anchored
        // to the surface's owning window, never to a global key/main window.
        // An agent's terminal is always in the workspace window.
        clipboardConfirmation.windowForSurface = { surface in surface.window }

        clipboardConfirmationCancellable = ClipboardConfirmationPresenter
            .pendingRequestsPublisher(for: $surfaceTree.eraseToAnyPublisher())
            .sink { [weak self] id, request in
                guard let self,
                      let surface = self.surfaceTree.first(where: { $0.id == id }) else { return }
                self.clipboardConfirmation.requestDidChange(
                    request,
                    for: surface,
                    isSelected: self.isPresented)
            }
    }

    deinit {
        // No sheet or pending callback may outlive the pane it belongs to.
        clipboardConfirmation.cancelPendingRequests(in: surfaceTree)
    }

    /// A request that arrived before the surface could present (window not
    /// key yet, surface not first responder yet) is shown once focus lands.
    /// The stack calls this when its terminal gains Ghostty's focus.
    func presentPendingClipboardRequest() {
        for surface in surfaceTree {
            clipboardConfirmation.presentPendingRequest(for: surface, isSelected: isPresented)
        }
    }

    /// Closes any sheet before the workspace window goes away; the stack
    /// calls this as it closes.
    func cancelPendingClipboardRequests() {
        clipboardConfirmation.cancelPendingRequests(in: surfaceTree)
    }
}
