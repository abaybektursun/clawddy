enum AgentFocusPolicy {
    /// Ghostty may handle key equivalents only when AppKit and the workspace
    /// agree that this exact terminal owns keyboard focus.
    static func isTerminalFocused(
        windowIsKey: Bool,
        surfaceIsSelected: Bool,
        surfaceIsFirstResponder: Bool
    ) -> Bool {
        windowIsKey && surfaceIsSelected && surfaceIsFirstResponder
    }
}
