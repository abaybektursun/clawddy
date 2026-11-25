import AppKit
import Testing
@testable import Ghostty

/// One owner of the keys: after any change of what is shown, the window's
/// first responder is the one the model names (`AgentWindowController.
/// focusOwnerHolds`), never the window itself at home, a hidden view, or a
/// terminal that is hidden or going. The sequences around an agent whose CLI
/// stops: the soak found home's tiles without the keys after one.
extension AgentInteractionTests {
    @MainActor
    @Suite
    struct FocusOwner {
        /// Enters `name` on purpose: its CLI starts and its terminal (here
        /// `/bin/cat`, which never reports) is shown with the keys.
        private func enterStarting(_ name: String, _ d: AgentWorkspaceDriver) async throws -> UUID {
            let id = try d.id(name)
            d.controller.openAgent(id)
            try await d.waitUntil("its terminal", seconds: 3) { d.detail.hasSurface(id: id) && d.terminalHasKeys }
            return id
        }

        private func holds(_ d: AgentWorkspaceDriver, _ what: Comment) {
            #expect(d.windowController.focusOwnerHolds, what)
        }

        /// The soak's case, made certain: Ghostty's deferred `moveFocus` to
        /// the terminal just left (a terminal's own program can set one
        /// off, as ending a search does) runs while the terminal still
        /// shrinks into its tile. It must not take the tiles' keys, which
        /// the window then kept when the terminal was hidden.
        @Test func aDeferredFocusToTheTerminalJustLeftDoesNotTakeTheTilesKeys() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let id = try await enterStarting("docs", d)
            let surface = try #require(d.detail.surface(id: id))
            try await d.key(AgentWorkspaceDriver.escape, .maskCommand)
            #expect(d.firstResponder === d.grid)
            Ghostty.moveFocus(to: surface)
            try await d.settle()
            try await Task.sleep(for: .milliseconds(300))
            #expect(d.firstResponder === d.grid)
            holds(d, "home after a deferred focus to the terminal left")
            try await d.key(AgentWorkspaceDriver.downArrow)
            #expect(!d.selectedNames.isEmpty)
        }

        /// Inside, with the floating new-agent line open, a deferred focus
        /// to the shown terminal leaves the field its keys.
        @Test func aDeferredFocusDoesNotTakeTheFloatingLinesKeys() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let id = try await enterStarting("docs", d)
            try await d.key(45, .maskCommand)
            #expect(d.firstResponder === d.windowController.palettePanel.textView)
            Ghostty.moveFocus(to: try #require(d.detail.surface(id: id)))
            try await d.settle()
            #expect(d.firstResponder === d.windowController.palettePanel.textView)
            holds(d, "the floating line keeps its keys")
            try await d.key(AgentWorkspaceDriver.escape)
            #expect(d.terminalHasKeys)
        }

        /// The launch times out after the person left: its terminal is
        /// closed at home; the tiles keep the keys.
        @Test func aLaunchTimingOutAfterLeavingLeavesTheTilesTheKeys() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            _ = try await enterStarting("docs", d)
            try await d.key(AgentWorkspaceDriver.escape, .maskCommand)
            #expect(d.firstResponder === d.grid)
            d.h.scheduler.advance(by: AgentBridge.startLimit)
            try await d.settle()
            try await Task.sleep(for: .milliseconds(250))
            #expect(d.firstResponder === d.grid)
            holds(d, "after the timeout at home")
            try await d.key(AgentWorkspaceDriver.downArrow)
            #expect(!d.selectedNames.isEmpty)
        }

        /// The launch times out while its terminal is shown: the window
        /// holds the keys inside (keys typed then start it again); leaving
        /// gives the tiles the keys.
        @Test func aLaunchTimingOutWhileShownThenLeaving() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let id = try await enterStarting("docs", d)
            d.h.scheduler.advance(by: AgentBridge.startLimit)
            try await d.settle()
            #expect(!d.detail.hasSurface(id: id))
            #expect(d.firstResponder === d.window)
            holds(d, "inside, no terminal")
            try await d.key(AgentWorkspaceDriver.escape, .maskCommand)
            try await Task.sleep(for: .milliseconds(250))
            #expect(d.firstResponder === d.grid)
            holds(d, "home after leaving")
        }

        /// The CLI exits while the person is inside, then they leave; or
        /// they leave at once after it exits; or switch project.
        @Test func theCLIExitingInsideThenLeavingOrSwitching() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            var id = try await enterStarting("docs", d)
            try d.h.terminalClosed(id)
            try await d.settle()
            holds(d, "inside after the exit")
            try await d.key(AgentWorkspaceDriver.escape, .maskCommand)
            try await Task.sleep(for: .milliseconds(250))
            #expect(d.firstResponder === d.grid)
            holds(d, "home after leaving an exited agent")

            id = try await enterStarting("docs", d)
            try await d.key(AgentWorkspaceDriver.escape, .maskCommand)
            try d.h.terminalClosed(id)
            try await d.settle()
            try await Task.sleep(for: .milliseconds(250))
            #expect(d.firstResponder === d.grid)
            holds(d, "home, the exit after leaving")

            id = try await enterStarting("docs", d)
            try d.h.terminalClosed(id)
            try await d.settle()
            try await d.key(30, [.maskCommand, .maskShift])
            try await Task.sleep(for: .milliseconds(250))
            #expect(d.model.shownAgentID == nil)
            holds(d, "another project's home after switching away")
        }

        /// Settle inside goes home with the keys on the tiles; the walk
        /// landing on a stopped agent gives the window the keys and ends
        /// where it began.
        @Test func settleInsideAndTheWalkOverAStoppedAgent() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let id = try await enterStarting("docs", d)
            try d.h.terminalClosed(id)
            try await d.settle()
            try await d.key(2, .maskCommand)
            try await Task.sleep(for: .milliseconds(250))
            #expect(d.model.shownAgentID == nil)
            #expect(d.firstResponder === d.grid)
            holds(d, "home after settling inside")

            for _ in 0..<8 {
                try await d.key(38, .maskCommand)
                holds(d, "during the walk")
                if d.model.walk == nil { break }
            }
            try await Task.sleep(for: .milliseconds(250))
            holds(d, "after the walk")
        }
    }
}
