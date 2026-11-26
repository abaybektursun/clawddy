import AppKit
import Testing
@testable import Ghostty

extension AgentInteractionTests {
    /// The chip of a new-agent line names the CLI new agents use and changes
    /// it (flows.md 6.3, "Choosing the CLI"; shortcuts.md, Tab).
    @MainActor
    @Suite
    struct CLIChip {
        private static let tab: CGKeyCode = 48
        private static let f2: CGKeyCode = 120

        /// Starting a new agent the chip names the CLI, always, and is a
        /// pop-up button with the CLI as its value; a reply or several
        /// selected name no CLI and are words only. The floating new-agent
        /// line has the same chip.
        @Test func theChipNamesTheCLIWhereANewAgentStarts() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let line = d.windowController.line
            #expect(line.chipText == "New Claude Code agent in ghostty")
            #expect(line.chip.cli == "Claude Code")
            #expect(line.chip.isAccessibilityElement() && line.chip.accessibilityRole() == .popUpButton)
            #expect(line.chip.accessibilityValue() as? String == "Claude Code")
            #expect(line.chip.accessibilityLabel() == "CLI for new agents")
            #expect(line.textView.placeholder == "Describe the task, or Tab to change the CLI")

            try await d.key(AgentWorkspaceDriver.downArrow)
            #expect(line.chipText.hasPrefix("Reply to "))
            #expect(line.chip.cli == nil && !line.chip.isAccessibilityElement())
            try await d.key(AgentWorkspaceDriver.rightArrow, .maskShift)
            #expect(line.chipText == "To 2 agents")
            #expect(line.chip.cli == nil && !line.chip.isEnabled)

            try await d.key(AgentWorkspaceDriver.escape)
            try await d.key(45, .maskCommand)
            let palette = d.windowController.palettePanel
            #expect(palette.chipText == "New Claude Code agent in ghostty")
            #expect(palette.chip.cli == "Claude Code" && palette.chip.accessibilityRole() == .popUpButton)
            #expect(palette.textView.placeholder == "Describe the task, or Tab to change the CLI")
        }

        /// Whatever the CLI and the project's name, the CLI's name fits in
        /// the chip: only the project's name is cut. At the window's
        /// narrowest the chip keeps its width and the text its room.
        @Test func theChipKeepsTheCLIAtTheNarrowestWidth() async throws {
            for provider in AgentProviderID.allCases {
                let words = AgentText(string: "New \(provider.displayName) agent in …", font: AgentMetrics.bodyMedium, color: .black)
                #expect(words.width + 18 <= AgentChip.maxWidth, "\(provider)")
            }
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            var frame = d.window.frame
            frame.size.width = agentWorkspaceMinimumSize.width
            d.window.setFrame(frame, display: false)
            try await d.settle()
            let line = d.windowController.line
            for _ in AgentProviderID.allCases {
                #expect(line.chip.frame.width == line.chip.fittingWidth)
                #expect(line.chip.frame.maxX < line.textView.convert(NSPoint.zero, to: line).x)
                try await d.key(AgentWorkspaceDriver.escape)
                d.windowController.focus(.line)
                try await d.key(Self.tab)
            }
        }

        /// A click on the chip shows the CLIs, the current one checked, one
        /// not installed dimmed; choosing one is the setting the Agent menu
        /// shows, and the chip follows. A reply's chip shows nothing.
        @Test func aClickOnTheChipOffersTheCLIs() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            var shown: [NSMenu] = []
            d.windowController.showMenu = { menu, _ in shown.append(menu) }
            d.h.providers.health = AgentProviderHealth(installation: .missing, authentication: .unavailable("Codex is not installed."))
            d.h.bridge.refreshProviderHealth(.codex)
            let line = d.windowController.line
            func clickChip() async throws {
                try await d.click(at: line.chip.convert(NSPoint(x: line.chip.bounds.midX, y: line.chip.bounds.midY), to: nil))
            }
            try await clickChip()
            let menu = try #require(shown.last)
            #expect(menu.items.map(\.title) == ["Claude Code", "Codex — not installed", "Antigravity"])
            #expect(menu.items.map(\.state) == [.on, .off, .off])
            #expect(menu.items.map(\.isEnabled) == [true, false, true])
            menu.performActionForItem(at: 2)
            try await d.settle()
            #expect(d.model.newAgentProvider == .antigravity)
            #expect(line.chipText == "New Antigravity agent in ghostty")
            #expect(line.chip.accessibilityValue() as? String == "Antigravity")

            try await d.key(AgentWorkspaceDriver.downArrow)
            try await clickChip()
            #expect(shown.count == 1)
        }

        /// Tab and Shift-Tab step through the installed CLIs in a new-agent
        /// line, wrapping, the text kept; in every other place of the keys
        /// table they change nothing: the tiles, a reply, several selected,
        /// find, a name being edited.
        @Test func tabChangesTheCLIOnlyInANewAgentLine() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let line = d.windowController.line
            d.windowController.focus(.line)
            try await d.type("tidy")
            for expected in [AgentProviderID.codex, .antigravity, .claudeCode] {
                try await d.key(Self.tab)
                #expect(d.model.newAgentProvider == expected)
                #expect(line.chipText == "New \(expected.displayName) agent in ghostty")
            }
            try await d.key(Self.tab, .maskShift)
            #expect(d.model.newAgentProvider == .antigravity)
            #expect(line.textView.string == "tidy")
            // A CLI not installed is stepped over.
            d.h.providers.health = AgentProviderHealth(installation: .missing, authentication: .unavailable("Codex is not installed."))
            d.h.bridge.refreshProviderHealth(.codex)
            try await d.key(Self.tab)
            try await d.key(Self.tab)
            #expect(d.model.newAgentProvider == .antigravity)
            try await d.key(Self.tab, .maskShift)
            #expect(d.model.newAgentProvider == .claudeCode)

            // The tiles, then one selected with the tiles holding the keys.
            try await d.key(AgentWorkspaceDriver.escape)
            try await d.key(Self.tab)
            try await d.key(AgentWorkspaceDriver.downArrow)
            try await d.key(Self.tab)
            #expect(d.model.newAgentProvider == .claudeCode)
            // Several selected, the line with the keys.
            try await d.key(AgentWorkspaceDriver.rightArrow, .maskShift)
            d.windowController.focus(.line)
            try await d.key(Self.tab)
            #expect(d.model.newAgentProvider == .claudeCode)
            #expect(line.chipText == "To 2 agents")

            // The floating new-agent line steps too.
            try await d.key(AgentWorkspaceDriver.escape)
            try await d.key(AgentWorkspaceDriver.escape)
            try await d.key(45, .maskCommand)
            try await d.key(Self.tab)
            #expect(d.model.newAgentProvider == .antigravity)
            #expect(d.windowController.palettePanel.chipText == "New Antigravity agent in ghostty")
            try await d.key(AgentWorkspaceDriver.escape)

            // Find.
            try await d.key(35, .maskCommand)
            try await d.type("rev")
            try await d.key(Self.tab)
            #expect(d.model.newAgentProvider == .antigravity)
            #expect(d.windowController.palettePanel.textView.string == "rev")
            try await d.key(AgentWorkspaceDriver.escape)

            // A name being edited.
            d.windowController.focus(.tiles)
            try await d.key(AgentWorkspaceDriver.downArrow)
            try await d.key(Self.f2)
            #expect(d.model.renaming != nil)
            try await d.key(Self.tab)
            #expect(d.model.newAgentProvider == .antigravity)
            #expect(d.model.renaming != nil)
        }

        /// Inside a terminal Tab is the terminal's: the CLI is unchanged and
        /// the terminal keeps the keys.
        @Test func tabInsideATerminalIsTheTerminals() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            #expect(d.controller.keyContext == .inside)
            try await d.key(Self.tab)
            #expect(d.model.newAgentProvider == .claudeCode)
            #expect(d.controller.keyContext == .inside)
        }

        /// A start uses the CLI the chip names.
        @Test func aStartUsesTheCLIShown() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            d.windowController.focus(.line)
            try await d.key(Self.tab)
            #expect(d.windowController.line.chipText == "New Codex agent in ghostty")
            try await d.type("tidy the docs")
            try await d.key(AgentWorkspaceDriver.returnKey)
            let started = try #require(d.h.config.projects.first { $0.name == "ghostty" }?.agents.last)
            #expect(started.name == "Tidy the docs")
            #expect(d.h.bridge.agents[started.id]?.provider == .codex)
        }
    }
}
