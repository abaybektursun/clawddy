import Testing
@testable import Ghostty

/// Regression coverage for the clipboard-confirmation contract (H6).
///
/// Agent surfaces had no clipboard-confirmation path, so a request that normal
/// terminal windows would show as a sheet stayed pending forever and the agent
/// CLI hung under the default `clipboard-read = ask`. These tests pin the
/// extracted policy that both `BaseTerminalController` and
/// `AgentTerminalHost` now apply: presentation, replacement, dismissal,
/// completion, and teardown cancellation.
struct AgentClipboardConfirmationTests {
    /// Identity stand-in for surfaces and requests. `ObjectIdentifier` is all
    /// the policy needs, so the lifecycle is testable without libghostty.
    private final class Handle {}

    /// All identities stay alive for the whole test so `ObjectIdentifier`
    /// values cannot be recycled.
    private struct Identities {
        let surface = Handle()
        let otherSurface = Handle()
        let request = Handle()
        let newerRequest = Handle()
    }

    private func change(
        surface: Handle,
        request: Handle?,
        focused: Bool = true,
        selected: Bool = true
    ) -> ClipboardConfirmationPolicy.RequestChange {
        ClipboardConfirmationPolicy.RequestChange(
            surface: ObjectIdentifier(surface),
            request: request.map { ObjectIdentifier($0) },
            isFocused: focused,
            isSelected: selected)
    }

    private func state(
        pending: Handle? = nil,
        visible: Handle? = nil,
        visibleSurface: Handle? = nil
    ) -> ClipboardConfirmationPolicy.State {
        ClipboardConfirmationPolicy.State(
            pendingRequest: pending.map { ObjectIdentifier($0) },
            visibleRequest: visible.map { ObjectIdentifier($0) },
            visibleSurface: visibleSurface.map { ObjectIdentifier($0) })
    }

    // MARK: - Request presentation

    @Test func focusedSelectedSurfacePresentsItsRequest() {
        let ids = Identities()
        let decision = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: ids.request),
            state: state(pending: ids.request))

        #expect(decision == .present)
    }

    @Test func unfocusedSurfaceRetainsRequestAndSignalsAttention() {
        let ids = Identities()
        let decision = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: ids.request, focused: false),
            state: state(pending: ids.request))

        // The request stays on the surface; the host posts a bell but must not
        // present a sheet that would steal focus from another surface.
        #expect(decision == .signalAttention)

        let whenFocused = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: ids.request),
            state: state(pending: ids.request))
        #expect(whenFocused == .present)
    }

    @Test func focusedButUnselectedSurfaceDiscardsRequest() {
        let ids = Identities()
        let decision = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: ids.request, selected: false),
            state: state(pending: ids.request))

        #expect(decision == .discardPending)
    }

    @Test func unfocusedUnselectedSurfaceNeverPresents() {
        let ids = Identities()
        let decision = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: ids.request, focused: false, selected: false),
            state: state(pending: ids.request))

        #expect(decision == .signalAttention)
    }

    // MARK: - Replacement and stale events

    @Test func duplicateEventIsIgnored() {
        let ids = Identities()
        let decision = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: ids.request),
            state: state(
                pending: ids.request,
                visible: ids.request,
                visibleSurface: ids.surface))

        #expect(decision == .ignore)
    }

    @Test func staleEventCannotReplaceNewerPendingRequest() {
        let ids = Identities()
        let decision = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: ids.request),
            state: state(pending: ids.newerRequest))

        #expect(decision == .ignore)
    }

    @Test func sameSurfaceReplacementUpdatesVisibleSheetInPlace() {
        let ids = Identities()
        let decision = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: ids.newerRequest),
            state: state(
                pending: ids.newerRequest,
                visible: ids.request,
                visibleSurface: ids.surface))

        #expect(decision == .replaceVisible)
    }

    @Test func requestFromAnotherSurfaceCannotReplaceVisibleSheet() {
        let ids = Identities()
        let decision = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: ids.newerRequest),
            state: state(
                pending: ids.newerRequest,
                visible: ids.request,
                visibleSurface: ids.otherSurface))

        #expect(decision == .discardPending)
    }

    // MARK: - Dismissal

    @Test func clearedRequestDismissesOnlyItsOwnVisibleSheet() {
        let ids = Identities()
        let ownsSheet = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: nil),
            state: state(
                visible: ids.request,
                visibleSurface: ids.surface))
        #expect(ownsSheet == .dismissVisible)

        let otherSheet = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: nil),
            state: state(
                visible: ids.request,
                visibleSurface: ids.otherSurface))
        #expect(otherSheet == .ignore)

        let noSheet = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: nil),
            state: state())
        #expect(noSheet == .ignore)

        let stillPending = ClipboardConfirmationPolicy.decide(
            change(surface: ids.surface, request: nil),
            state: state(
                pending: ids.newerRequest,
                visible: ids.request,
                visibleSurface: ids.surface))
        #expect(stillPending == .ignore)
    }

    // MARK: - Response completion

    @Test func completionDismissesSheetAndClearsOnlyMatchingPendingRequest() {
        let ids = Identities()

        let matching = ClipboardConfirmationPolicy.decideCompletion(
            ClipboardConfirmationPolicy.Completion(
                request: ObjectIdentifier(ids.request),
                pendingRequest: ObjectIdentifier(ids.request)))
        #expect(matching.decision == .dismissVisible)
        #expect(matching.clearsPending)

        // Completing may synchronously install a newer request. That request
        // must survive and be presented by its own event.
        let replaced = ClipboardConfirmationPolicy.decideCompletion(
            ClipboardConfirmationPolicy.Completion(
                request: ObjectIdentifier(ids.request),
                pendingRequest: ObjectIdentifier(ids.newerRequest)))
        #expect(replaced.decision == .dismissVisible)
        #expect(!replaced.clearsPending)

        let alreadyCleared = ClipboardConfirmationPolicy.decideCompletion(
            ClipboardConfirmationPolicy.Completion(
                request: ObjectIdentifier(ids.request),
                pendingRequest: nil))
        #expect(!alreadyCleared.clearsPending)
    }

    // MARK: - Teardown cancellation

    @Test func teardownClosesOwnSheetAndAlwaysClearsPending() {
        let ids = Identities()

        let ownSheet = ClipboardConfirmationPolicy.decideTeardown(
            surface: ObjectIdentifier(ids.surface),
            state: state(
                pending: ids.request,
                visible: ids.request,
                visibleSurface: ids.surface))
        #expect(ownSheet.decision == .dismissVisible)
        #expect(ownSheet.clearsPending)

        // A surface leaving the host must never close another surface's sheet.
        let otherSheet = ClipboardConfirmationPolicy.decideTeardown(
            surface: ObjectIdentifier(ids.surface),
            state: state(
                pending: ids.request,
                visible: ids.request,
                visibleSurface: ids.otherSurface))
        #expect(otherSheet.decision == .ignore)
        #expect(otherSheet.clearsPending)

        // Nothing pending: teardown is a no-op, so the presenter does not
        // publish a spurious clear into the surface.
        let noRequest = ClipboardConfirmationPolicy.decideTeardown(
            surface: ObjectIdentifier(ids.surface),
            state: state())
        #expect(noRequest.decision == .ignore)
        #expect(!noRequest.clearsPending)
    }

    // MARK: - Agent focus lifecycle

    /// Agent panes drive the same policy with the same focus invariant as
    /// terminal windows: a request waits until the workspace window is key and
    /// the pane holds first responder, then presents.
    @Test func agentPaneRetainsRequestUntilFocusInvariantPasses() {
        let ids = Identities()

        let windowIsKey = false
        let selected = true
        let firstResponder = true
        let initiallyFocused = AgentFocusPolicy.isTerminalFocused(
            windowIsKey: windowIsKey,
            surfaceIsSelected: selected,
            surfaceIsFirstResponder: firstResponder)
        #expect(!initiallyFocused)
        #expect(ClipboardConfirmationPolicy.decide(
            change(
                surface: ids.surface,
                request: ids.request,
                focused: initiallyFocused,
                selected: selected),
            state: state(pending: ids.request)) == .signalAttention)

        let focused = AgentFocusPolicy.isTerminalFocused(
            windowIsKey: true,
            surfaceIsSelected: selected,
            surfaceIsFirstResponder: firstResponder)
        #expect(focused)
        #expect(ClipboardConfirmationPolicy.decide(
            change(
                surface: ids.surface,
                request: ids.request,
                focused: focused,
                selected: selected),
            state: state(pending: ids.request)) == .present)
    }
}
