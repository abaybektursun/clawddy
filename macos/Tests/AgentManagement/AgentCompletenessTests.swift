import AppKit
import Testing
@testable import Ghostty

extension AgentInteractionTests {
    /// The menu bar, VoiceOver and the Edit menu, through the window
    /// (words.md "Menus", flows.md 1 and 2.1).
    @MainActor
    @Suite
    struct Completeness {
        private static let cmd = CGEventFlags.maskCommand

        private func agentMenu() throws -> NSMenu {
            let menu = try #require(NSApp.mainMenu?.items.first { $0.title == "Agent" }?.submenu)
            menu.update()
            return menu
        }

        private func enabled(_ menu: NSMenu, _ title: String) -> Bool? {
            menu.items.first { $0.title == title }?.isEnabled
        }

        /// Each Agent menu item is enabled exactly where it acts and applies:
        /// with nothing selected at home Settle, Mark as unread, Rename and
        /// the moves are off; on a finished, read tile they are on; inside,
        /// the tile keys are off and the agent keys on. "Open agent" names
        /// the places. The settings show their choices; Help's item is Keys.
        @Test func theAgentMenuIsEnabledWhereItApplies() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            var menu = try agentMenu()
            for title in ["Settle", "Mark as unread", "Rename", "Move earlier", "Move later", "Back to all agents", "Previous agent"] {
                #expect(enabled(menu, title) == false, "\(title) with nothing selected")
            }
            #expect(enabled(menu, "Next waiting agent") == true)
            let places = try #require(menu.items.first { $0.title == "Open agent" }?.submenu)
            places.update()
            #expect(places.items.filter { !$0.isHidden }.map(\.title) == d.grid.order.compactMap { d.h.bridge.agents[$0]?.name })

            let review = try d.id("review")
            d.h.bridge.agentViewed(review)
            try await d.key(AgentWorkspaceDriver.downArrow)
            try await d.key(AgentWorkspaceDriver.rightArrow)
            menu = try agentMenu()
            for title in ["Settle", "Mark as unread", "Rename", "Move earlier", "Move later"] {
                #expect(enabled(menu, title) == true, "\(title) on a finished tile")
            }

            try await d.key(AgentWorkspaceDriver.returnKey)
            menu = try agentMenu()
            for title in ["Smaller tiles", "Move earlier", "Move later"] { #expect(enabled(menu, title) == false, "\(title)") }
            for title in ["Back to all agents", "Previous agent", "Next agent", "Settle", "Rename"] { #expect(enabled(menu, title) == true, "\(title)") }

            d.controller.menuNeedsUpdate(menu)
            let settings = try #require(menu.items.first { $0.title == "New agents use" }?.submenu)
            #expect(settings.items.filter { $0.state == .on }.map(\.title) == ["Claude Code"])
            #expect(settings.items.map(\.title) == ["Claude Code", "Codex", "Antigravity"])
            #expect(menu.items.first { $0.title == "Notify when an agent is waiting" }?.state == .off)
            let help = NSApp.mainMenu?.items.first { $0.submenu?.title == "Help" }?.submenu
            #expect(help?.items.first { $0.keyEquivalent == "?" }?.title == "Keys")
        }

        /// Move earlier and Move later move the selected tiles as ⌥← ⌥→ do.
        @Test func moveEarlierAndLaterFromTheMenu() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(AgentWorkspaceDriver.downArrow)
            try await d.key(AgentWorkspaceDriver.rightArrow)
            let review = try d.id("review")
            d.controller.action(for: .moveEarlier, in: .homeTiles)?()
            try await d.settle()
            #expect(d.grid.order.first == review)
            d.controller.action(for: .moveLater, in: .homeTiles)?()
            try await d.settle()
            #expect(d.grid.order.firstIndex(of: review) == 1)
            #expect(d.controller.action(for: .moveEarlier, in: .inside) == nil)
        }

        /// VoiceOver reads each tile's name, state, age and sentence and its
        /// screen's lines, can press it to open it, and knows which are
        /// selected; home is a list; find's results are buttons it can press;
        /// at home the hidden header is not read.
        @Test func voiceOverReadsAndActs() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let soundings = try d.id("soundings")
            let tile = try #require(d.grid.tiles[soundings])
            #expect(tile.accessibilityRole() == .button)
            #expect(tile.accessibilityLabel() == "soundings")
            #expect((tile.accessibilityValue() as? String)?.hasPrefix("Has a question, asked") == true)
            let children = tile.accessibilityChildren() ?? []
            let screen = try #require(children.first as? NSAccessibilityElement)
            #expect(screen.accessibilityLabel() == "Last lines of its terminal")
            #expect(d.grid.accessibilityRole() == .list)
            #expect(d.windowController.header.isAccessibilityElement() == false)

            try await d.key(AgentWorkspaceDriver.downArrow)
            #expect(tile.isAccessibilitySelected())
            #expect((d.grid.accessibilitySelectedChildren() ?? []).count == 1)

            try await d.key(35, Self.cmd)
            let results = d.windowController.palettePanel.list.accessibilityChildren() ?? []
            #expect(results.count == d.controller.findRows.count)
            let first = try #require(results.first as? AgentPaletteResult)
            guard case let .agent(hit, state, _)? = d.controller.findRows.first else {
                Issue.record("no agent row")
                return
            }
            #expect(first.accessibilityLabel() == "\(hit.name), \(state.name), \(hit.project). \(hit.line)")
            #expect(first.accessibilityHelp() == "Press Return to open it.")
            #expect(first.accessibilityPerformPress())
            try await d.settle()
            #expect(!d.windowController.paletteShown)
            #expect(d.model.shownAgentID != nil)
            #expect(d.windowController.header.isAccessibilityElement())

            try await d.key(AgentWorkspaceDriver.escape, Self.cmd)
            #expect(tile.accessibilityPerformPress())
            try await d.settle()
            #expect(d.model.shownAgentID == soundings)
        }

        /// Edit ▸ Copy and Select All reach the tiles.
        @Test func theEditMenuReachesTheTiles() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            #expect(d.grid.responds(to: #selector(NSText.copy(_:))))
            d.grid.selectAll(nil)
            #expect(d.grid.selection.selected.count == d.grid.live.count)
        }
    }
}

extension AgentInteractionTests.Completeness {
    /// Pinching apart on a selected tile enters it; together inside goes
    /// back to all agents (flows.md 3.3); once per gesture.
    @Test func pinchingEntersAndLeaves() async throws {
        let d = try await AgentWorkspaceDriver(.standard)
        defer { d.close() }
        let view = d.windowController.windowView
        view.beginPinch()
        view.pinched(by: 0.3)
        #expect(d.model.shownAgentID == nil, "nothing selected: nothing")
        try await d.key(AgentWorkspaceDriver.downArrow)
        view.beginPinch()
        view.pinched(by: 0.15)
        #expect(d.model.shownAgentID == nil)
        view.pinched(by: 0.15)
        #expect(d.model.shownAgentID == (try d.id("soundings")))
        view.pinched(by: -0.6)
        #expect(d.model.shownAgentID != nil, "once per gesture")
        view.beginPinch()
        view.pinched(by: -0.3)
        #expect(d.model.shownAgentID == nil)
        #expect(d.grid.selection.cursor == (try d.id("soundings")))
    }
}
