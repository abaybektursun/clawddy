import AppKit
import SwiftUI
import Testing
@testable import Ghostty

struct AgentDetailAppearanceTests {
    @Test func terminalCanvasContrastFollowsTerminalThemeNotSystemAppearance() {
        #expect(AgentCanvasAppearancePolicy.colorScheme(for: .black) == .dark)
        #expect(AgentCanvasAppearancePolicy.colorScheme(for: .white) == .light)
    }
}
