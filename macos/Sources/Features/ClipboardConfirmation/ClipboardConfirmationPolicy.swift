/// The authoritative routing policy for terminal clipboard confirmations.
///
/// libghostty delivers every clipboard request as a pending request stored on
/// the owning `SurfaceView`. Each surface host decides when that request may be
/// shown, replaced, dismissed, or denied. That policy used to live only inside
/// `BaseTerminalController`, so agent panes (`AgentTerminalHost`) never answered
/// requests and the CLI hung under the default `clipboard-read = ask`.
///
/// This type is that policy, extracted so every host applies exactly the same
/// rules. It is intentionally identity-based and AppKit-free: real surfaces,
/// real requests, and unit-test doubles are all expressible as
/// `ObjectIdentifier`, so the transitions can be exercised without libghostty.
enum ClipboardConfirmationPolicy {
    /// The request a surface currently holds plus the sheet a host is showing.
    ///
    /// `pendingRequest` mirrors `SurfaceView.pendingClipboardConfirmation`, the
    /// authoritative storage for a request. A host must never keep a second
    /// pending copy: libghostty's callback state is owned by that property.
    struct State: Equatable {
        var pendingRequest: ObjectIdentifier?
        var visibleRequest: ObjectIdentifier?
        var visibleSurface: ObjectIdentifier?
    }

    /// A published pending-request transition.
    ///
    /// `request` is nil when the surface cleared its request (completion,
    /// cancellation, or teardown).
    struct RequestChange: Equatable {
        var surface: ObjectIdentifier
        var request: ObjectIdentifier?
        var isFocused: Bool
        var isSelected: Bool
    }

    /// The visible sheet finishing and the surface's current pending request.
    struct Completion: Equatable {
        var request: ObjectIdentifier
        var pendingRequest: ObjectIdentifier?
    }

    /// The action a host must take for a transition.
    enum Decision: Equatable {
        /// Show the request in a new sheet anchored to the surface's window.
        case present

        /// Update the visible sheet in place. Dismissing and re-showing would
        /// briefly return focus to the terminal, which can produce another
        /// request and repeat the cycle.
        case replaceVisible

        /// Close the visible sheet because its request was cleared.
        case dismissVisible

        /// Keep the pending request but signal that it needs attention. Used
        /// when the surface is not focused yet; the request is presented when
        /// focus arrives.
        case signalAttention

        /// Deny the request silently. Another surface owns the sheet or this
        /// surface is no longer the selected one.
        case discardPending

        /// Nothing to do (duplicate, stale, or unrelated event).
        case ignore
    }

    /// A decision plus whether the surface's pending request must be cleared.
    struct Outcome: Equatable {
        var decision: Decision
        var clearsPending: Bool
    }

    /// Decide what to do with a published pending-request transition.
    static func decide(_ change: RequestChange, state: State) -> Decision {
        guard let request = change.request else {
            // The surface cleared its request. Close the sheet only if this
            // surface owns it; another surface's sheet must stay up.
            guard state.pendingRequest == nil,
                  state.visibleRequest != nil,
                  state.visibleSurface == change.surface else {
                return .ignore
            }
            return .dismissVisible
        }

        // Ignore values queued before a newer request replaced them.
        guard state.pendingRequest == request else { return .ignore }

        if let visibleRequest = state.visibleRequest {
            if visibleRequest == request { return .ignore }

            // `SurfaceView` has already cancelled the request this one
            // replaced. Update the sheet in place when the same surface owns
            // it; a request from another surface cannot replace a sheet that
            // is already attached to this window.
            guard state.visibleSurface == change.surface else {
                return .discardPending
            }
            return .replaceVisible
        }

        // Presenting for an unfocused surface would bring another window or
        // tab forward and steal focus. Retain the request and flag attention.
        if !change.isFocused { return .signalAttention }

        // Only the host's selected surface may present a sheet.
        guard change.isSelected else { return .discardPending }

        return .present
    }

    /// Decide how finishing the visible sheet affects the surface's request.
    ///
    /// The sheet always closes. The pending request is cleared only if it is
    /// still the completed request; completing may synchronously install a
    /// newer request that must be left alone.
    static func decideCompletion(_ completion: Completion) -> Outcome {
        Outcome(
            decision: .dismissVisible,
            clearsPending: completion.pendingRequest == completion.request)
    }

    /// Decide how removing a surface from its host affects clipboard state.
    ///
    /// Teardown always clears the surface's pending request (libghostty resolves
    /// it as denied). It closes the sheet only when that surface owns it.
    static func decideTeardown(surface: ObjectIdentifier, state: State) -> Outcome {
        Outcome(
            decision: state.visibleSurface == surface ? .dismissVisible : .ignore,
            clearsPending: state.pendingRequest != nil)
    }
}
