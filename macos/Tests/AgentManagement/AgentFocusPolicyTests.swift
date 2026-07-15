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
}
