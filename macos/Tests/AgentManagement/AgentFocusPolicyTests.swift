import AppKit
import Testing
@testable import Ghostty

struct AgentFocusPolicyTests {
    @Test func terminalFocusRequiresEveryAppKitAndWorkspaceInvariant() {
        #expect(AgentFocusPolicy.isTerminalFocused(
            windowIsKey: true,
            surfaceIsSelected: true,
            surfaceIsFirstResponder: true))

        #expect(!AgentFocusPolicy.isTerminalFocused(
            windowIsKey: false,
            surfaceIsSelected: true,
            surfaceIsFirstResponder: true))
        #expect(!AgentFocusPolicy.isTerminalFocused(
            windowIsKey: true,
            surfaceIsSelected: false,
            surfaceIsFirstResponder: true))
        #expect(!AgentFocusPolicy.isTerminalFocused(
            windowIsKey: true,
            surfaceIsSelected: true,
            surfaceIsFirstResponder: false))
    }

    @Test func firstMousePromotesOnlySafeWorkspacePanes() {
        #expect(AgentFirstMousePolicy.shouldPromoteWindow(
            eventType: .leftMouseDown,
            windowIsKey: false,
            targetsSafeRegion: true))

        #expect(!AgentFirstMousePolicy.shouldPromoteWindow(
            eventType: .leftMouseDown,
            windowIsKey: true,
            targetsSafeRegion: true))
        #expect(!AgentFirstMousePolicy.shouldPromoteWindow(
            eventType: .leftMouseDown,
            windowIsKey: false,
            targetsSafeRegion: false))
        #expect(!AgentFirstMousePolicy.shouldPromoteWindow(
            eventType: .rightMouseDown,
            windowIsKey: false,
            targetsSafeRegion: true))
    }

    @Test func clickingAnAlreadySelectedAgentStillMeansInspect() {
        let id = UUID()
        #expect(AgentSelectionIntent.rowClick(
            currentSelection: id,
            clickedID: id) == .inspect)
        #expect(AgentSelectionIntent.rowClick(
            currentSelection: id,
            clickedID: UUID()) == .inspect)
    }
}
