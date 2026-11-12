import AppKit
import Combine

/// Owns a surface host's single clipboard-confirmation sheet and applies
/// `ClipboardConfirmationPolicy` to real surfaces.
///
/// Terminal windows (`BaseTerminalController`) and agent panes
/// (`AgentTerminalHost`) both delegate here, so presentation, replacement,
/// completion, and teardown cancellation have one implementation and agent
/// surfaces obey the same `clipboard-read = ask` privacy contract as normal
/// terminal surfaces.
///
/// The sheet is anchored to the window that owns the requesting surface. This
/// type never consults a global key or main window: presenting on the wrong
/// window would steal focus and can attach the sheet to a different tab.
final class ClipboardConfirmationPresenter: ClipboardConfirmationViewDelegate {
    /// The visible sheet, if any.
    private var visible: ClipboardConfirmationController?

    /// The window the visible sheet is attached to.
    private weak var presentingWindow: NSWindow?

    /// Supplies the window that owns `surface`. Hosts that are not window
    /// controllers (agent panes) provide their workspace window here.
    var windowForSurface: ((Ghostty.SurfaceView) -> NSWindow?)?

    /// Apply a pending-request transition published by a surface.
    @discardableResult
    func requestDidChange(
        _ request: Ghostty.ClipboardConfirmationRequest?,
        for target: Ghostty.SurfaceView,
        isSelected: Bool
    ) -> ClipboardConfirmationPolicy.Decision {
        let decision = ClipboardConfirmationPolicy.decide(
            ClipboardConfirmationPolicy.RequestChange(
                surface: ObjectIdentifier(target),
                request: request.map { ObjectIdentifier($0) },
                isFocused: target.focused,
                isSelected: isSelected),
            state: state(for: target))

        apply(decision, request: request, for: target)
        return decision
    }

    /// Retry presentation for a surface that just gained focus.
    ///
    /// Requests that arrived while the surface was unfocused stay on the
    /// surface. This is what turns the attention signal into the sheet.
    func presentPendingRequest(for target: Ghostty.SurfaceView, isSelected: Bool) {
        guard target.focused, isSelected,
              let request = target.pendingClipboardConfirmation else { return }
        requestDidChange(request, for: target, isSelected: true)
    }

    /// Cancel a surface's pending request, closing its sheet first.
    ///
    /// Used when a surface leaves its host's tree, its pane is removed, or the
    /// hosting window closes. The request resolves as denied; libghostty never
    /// waits forever for a surface that no longer has UI.
    func cancelPendingRequest(for target: Ghostty.SurfaceView) {
        let outcome = ClipboardConfirmationPolicy.decideTeardown(
            surface: ObjectIdentifier(target),
            state: state(for: target))

        if outcome.decision == .dismissVisible {
            dismiss()
        }
        if outcome.clearsPending {
            target.pendingClipboardConfirmation = nil
        }
    }

    /// Cancel every pending request in a tree, for host or window teardown.
    func cancelPendingRequests(in tree: SplitTree<Ghostty.SurfaceView>) {
        // Close the sheet before clearing requests so no sheet outlives the
        // surface it represents.
        if visible != nil { dismiss() }

        for surface in tree {
            surface.pendingClipboardConfirmation = nil
        }
    }

    /// Build a publisher of pending-request transitions for a surface tree.
    ///
    /// The host owns its surface tree as `@Published`, so `SurfaceView`s added
    /// or removed from the tree automatically gain or lose the subscription.
    static func pendingRequestsPublisher(
        for surfaceTree: AnyPublisher<SplitTree<Ghostty.SurfaceView>, Never>
    ) -> AnyPublisher<(Ghostty.SurfaceView.ID, Ghostty.ClipboardConfirmationRequest?), Never> {
        surfaceTree
            .map { tree -> AnyPublisher<(Ghostty.SurfaceView.ID, Ghostty.ClipboardConfirmationRequest?), Never> in
                // Carry the stable value-type ID rather than capturing the
                // surface in the operator chain. The subscription therefore
                // cannot extend the SurfaceView's lifetime.
                let requests: [AnyPublisher<(Ghostty.SurfaceView.ID, Ghostty.ClipboardConfirmationRequest?), Never>] =
                    tree.map { surface in
                        let id = surface.id
                        return surface.$pendingClipboardConfirmation
                            .map { (id, $0) }
                            .eraseToAnyPublisher()
                    }
                return Publishers.MergeMany(requests).eraseToAnyPublisher()
            }
            // Cancelling the old MergeMany releases every subscription for
            // surfaces removed from the current tree.
            .switchToLatest()
            // Published emits synchronously from the libghostty callback. Hop
            // to the main queue both for AppKit and so completing a request
            // cannot invalidate callback state while that callback is active.
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    // MARK: - ClipboardConfirmationViewDelegate

    func clipboardConfirmationComplete(
        _ action: ClipboardConfirmationView.Action,
        remember: Bool
    ) {
        guard let controller = visible else { return }
        let request = controller.confirmation

        var pendingRequest: Ghostty.ClipboardConfirmationRequest?
        if let surface = request.surface {
            pendingRequest = surface.pendingClipboardConfirmation
        }
        let outcome = ClipboardConfirmationPolicy.decideCompletion(
            ClipboardConfirmationPolicy.Completion(
                request: ObjectIdentifier(request),
                pendingRequest: pendingRequest.map { ObjectIdentifier($0) }))

        // End the sheet no matter what.
        dismiss()

        switch action {
        case .cancel:
            request.cancel()
        case .confirm:
            request.complete(remember: remember)
        }

        // Clear only if this is still the surface's current request. Completing
        // the request may synchronously cause a newer request to replace it.
        if outcome.clearsPending,
           let target = request.surface,
           target.pendingClipboardConfirmation === request {
            target.pendingClipboardConfirmation = nil
        }
    }

    // MARK: - Presentation

    private func state(for target: Ghostty.SurfaceView) -> ClipboardConfirmationPolicy.State {
        let visibleSurface = visible?.confirmation.surface
        return ClipboardConfirmationPolicy.State(
            pendingRequest: target.pendingClipboardConfirmation.map { ObjectIdentifier($0) },
            visibleRequest: visible.map { ObjectIdentifier($0.confirmation) },
            visibleSurface: visibleSurface.map { ObjectIdentifier($0) })
    }

    private func apply(
        _ decision: ClipboardConfirmationPolicy.Decision,
        request: Ghostty.ClipboardConfirmationRequest?,
        for target: Ghostty.SurfaceView
    ) {
        switch decision {
        case .present:
            guard let request else { return }
            present(request, for: target)

        case .replaceVisible:
            guard let request else { return }
            visible?.replaceConfirmation(with: request)

        case .dismissVisible:
            dismiss()

        case .signalAttention:
            if !target.bell {
                NotificationCenter.default.post(
                    name: .ghosttyBellDidRing,
                    object: target)
            }

        case .discardPending:
            target.pendingClipboardConfirmation = nil

        case .ignore:
            break
        }
    }

    private func present(
        _ request: Ghostty.ClipboardConfirmationRequest,
        for target: Ghostty.SurfaceView
    ) {
        guard visible == nil else { return }
        guard let window = windowForSurface?(target) ?? target.window else { return }

        let controller = ClipboardConfirmationController(
            confirmation: request,
            delegate: self)
        guard let sheet = controller.window else { return }

        visible = controller
        presentingWindow = window
        window.beginSheet(sheet)
    }

    private func dismiss() {
        guard let controller = visible else { return }
        visible = nil

        // Capture and clear before ending the sheet: ending it can
        // synchronously produce a new request that installs a new sheet.
        let window = presentingWindow
        presentingWindow = nil

        guard let sheet = controller.window else { return }
        (sheet.sheetParent ?? window)?.endSheet(sheet)
    }
}
