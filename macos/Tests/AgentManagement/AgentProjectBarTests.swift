import AppKit
import Testing
@testable import Ghostty

/// Rulings 32 to 34, after the owner's first minutes in the real app: the
/// plus button and ⌘N open the floating new-agent line everywhere, home
/// included; projects are managed where they are shown, in the top bar, by
/// a menu and by dragging; the projects' stored order is the one order.
extension AgentInteractionTests {
    @MainActor
    @Suite
    struct ProjectBar {
        // MARK: Ruling 32

        /// ⌘N and the plus button at home, with nothing, one or several tiles
        /// selected, or the line holding a draft: the floating new-agent line
        /// opens with the keys; Escape gives them back to who had them, the
        /// selection and the draft unchanged.
        @Test func newAgentOpensTheFloatingLineAtHomeAndEscapeGivesTheKeysBack() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let project = try #require(d.model.currentProjectID)
            let palette = d.windowController.palettePanel
            let bar = d.windowController.topBar
            func plus() async throws {
                let frame = try #require(bar.newButtonFrame)
                try await d.click(at: bar.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil))
            }
            func opensAndGivesBack(_ open: () async throws -> Void, to owner: NSResponder, _ what: Comment) async throws {
                let selection = d.model.selection(in: project)
                try await open()
                #expect(d.windowController.paletteShown, what)
                #expect(palette.mode == .new, what)
                #expect(palette.chipText == "New agent in ghostty", what)
                #expect(d.firstResponder === palette.textView, what)
                try await d.key(AgentWorkspaceDriver.escape)
                #expect(!d.windowController.paletteShown, what)
                #expect(d.firstResponder === owner, what)
                #expect(d.model.selection(in: project) == selection, what)
            }
            // Nothing selected, the tiles with the keys.
            #expect(d.model.selection(in: project).isEmpty)
            try await opensAndGivesBack({ try await d.key(45, .maskCommand) }, to: d.grid, "nothing selected, ⌘N")
            try await opensAndGivesBack(plus, to: d.grid, "nothing selected, plus")
            // One tile selected.
            try await d.key(AgentWorkspaceDriver.downArrow)
            #expect(d.model.selection(in: project).selected.count == 1)
            try await opensAndGivesBack({ try await d.key(45, .maskCommand) }, to: d.grid, "one selected, ⌘N")
            try await opensAndGivesBack(plus, to: d.grid, "one selected, plus")
            // Several selected.
            try await d.key(AgentWorkspaceDriver.rightArrow, .maskShift)
            #expect(d.model.selection(in: project).selected.count == 2)
            try await opensAndGivesBack({ try await d.key(45, .maskCommand) }, to: d.grid, "several selected, ⌘N")
            try await opensAndGivesBack(plus, to: d.grid, "several selected, plus")
            // The line holding a draft, with the keys.
            try await d.key(AgentWorkspaceDriver.escape)
            d.windowController.focus(.line)
            try await d.type("half a task")
            let line = d.windowController.line.textView
            try await opensAndGivesBack({ try await d.key(45, .maskCommand) }, to: line, "the line with a draft, ⌘N")
            try await opensAndGivesBack(plus, to: line, "the line with a draft, plus")
            #expect(line.string == "half a task")
        }

        /// At home the floating line stays open for a burst of starts, as it
        /// does inside; the plus button while it is open keeps its text.
        @Test func theFloatingLineAtHomeTakesABurstOfStarts() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let agents = d.h.bridge.agents.count
            try await d.key(45, .maskCommand)
            for task in ["first task", "second task", "third task"] {
                try await d.type(task)
                try await d.key(AgentWorkspaceDriver.returnKey)
                #expect(d.windowController.paletteShown)
                #expect(d.windowController.palettePanel.textView.string.isEmpty)
            }
            #expect(d.h.bridge.agents.count == agents + 3)
            try await d.type("kept")
            let frame = try #require(d.windowController.topBar.newButtonFrame)
            try await d.click(at: d.windowController.topBar.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil))
            #expect(d.windowController.palettePanel.textView.string == "kept")
            #expect(d.firstResponder === d.windowController.palettePanel.textView)
            try await d.key(AgentWorkspaceDriver.escape)
            #expect(d.firstResponder === d.grid)
        }

        // MARK: Ruling 33

        /// The project menu on the first, a middle and the last project: its
        /// items, Move left and Move right disabled at the ends, and each move
        /// saved at once as the one order the bar, ⇧⌘[ ⇧⌘] and the walk read.
        @Test func theProjectMenuMovesProjectsInTheStoredOrder() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try #require(d.h.config.addProject(name: "notes", workingDirectory: "/tmp/notes") != nil)
            try await d.settle()
            func names() -> [String] { d.h.config.projects.map(\.name) }
            #expect(names() == ["ghostty", "coral", "notes"])
            func menu(_ name: String) throws -> NSMenu { d.controller.projectMenu(for: try d.project(name)) }
            func enabled(_ menu: NSMenu, _ title: String) -> Bool? { menu.items.first { $0.title == title }?.isEnabled }

            let first = try menu("ghostty")
            #expect(first.items.map { $0.isSeparatorItem ? "—" : $0.title } == [
                "New agent in ghostty", "Move left", "Move right", "Show in Finder", "Remove project", "—", "Add a project folder…",
            ])
            #expect(enabled(first, "Move left") == false)
            #expect(enabled(first, "Move right") == true)
            #expect(enabled(try menu("coral"), "Move left") == true)
            #expect(enabled(try menu("coral"), "Move right") == true)
            #expect(enabled(try menu("notes"), "Move right") == false)
            let add = try #require(first.items.last)
            #expect(add.keyEquivalent == "o" && add.keyEquivalentModifierMask == .command)

            func choose(_ title: String, of name: String) throws {
                let menu = try menu(name)
                menu.performActionForItem(at: menu.indexOfItem(withTitle: title))
            }
            try choose("Move right", of: "ghostty")
            #expect(names() == ["coral", "ghostty", "notes"])
            try choose("Move left", of: "notes")
            #expect(names() == ["coral", "notes", "ghostty"])
            try await d.settle()
            #expect(d.windowController.topBar.shownProjects.map(\.name) == ["coral", "notes", "ghostty"])
            // Saved at once: the file read back has the order.
            d.h.config.waitForWrites()
            let reread = AgentConfig(root: d.h.root)
            reread.load()
            #expect(reread.projects.map(\.name) == ["coral", "notes", "ghostty"])
            // ⇧⌘] goes to the next project in that order: from ghostty, wrapping
            // to coral.
            #expect(d.model.currentProjectID == (try d.project("ghostty")))
            try await d.key(30, [.maskCommand, .maskShift])
            #expect(d.model.currentProjectID == (try d.project("coral")))
            try await d.key(30, [.maskCommand, .maskShift])
            #expect(d.model.currentProjectID == (try d.project("notes")))

            // New agent in <project> from another project's menu goes there and
            // opens the floating line.
            try choose("New agent in ghostty", of: "ghostty")
            try await d.settle()
            #expect(d.model.currentProjectID == (try d.project("ghostty")))
            #expect(d.windowController.paletteShown && d.windowController.palettePanel.chipText == "New agent in ghostty")
            try await d.key(AgentWorkspaceDriver.escape)

            // Show in Finder shows its folder.
            var revealed: [URL] = []
            d.controller.revealInFinder = { revealed.append($0) }
            try choose("Show in Finder", of: "notes")
            #expect(revealed.map(\.path) == ["/tmp/notes"])
        }

        /// Remove project from the menu of a project that is not current: the
        /// view stays; ⌘Z brings it back at its place, still not current.
        @Test func removingAnotherProjectKeepsTheViewAndUndoPutsItBack() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let ghostty = try d.project("ghostty")
            let coral = try d.project("coral")
            #expect(d.model.currentProjectID == ghostty)
            let menu = d.controller.projectMenu(for: coral)
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Remove project"))
            try await d.settle()
            #expect(d.h.config.projects.map(\.id) == [ghostty])
            #expect(d.model.currentProjectID == ghostty)
            #expect(d.windowController.topBar.showsUndo)
            try await d.key(6, .maskCommand)
            #expect(d.h.config.projects.map(\.id) == [ghostty, coral])
            #expect(d.model.currentProjectID == ghostty)
            #expect(d.h.bridge.agents.values.filter { d.h.config.project(forAgent: $0.id)?.id == coral }.allSatisfy { !$0.isSettled })
        }

        /// A right-click or a Control-click on a project's name shows its menu;
        /// on the bar's empty part, the bar's menu. A click switches project; a
        /// press that moves less than 4 pt is a click.
        @Test func rightAndControlClicksShowTheMenusAndSmallMovesAreClicks() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let bar = d.windowController.topBar
            var shown: [(titles: [String], view: NSView)] = []
            bar.showMenu = { menu, _, view in shown.append((menu.items.map(\.title), view)) }
            let coral = try d.project("coral")
            let button = try #require(bar.button(of: coral))
            let middle = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            try await d.send([try mouse(.rightMouseDown, at: middle, d), try mouse(.rightMouseUp, at: middle, d)])
            try await d.send([try mouse(.leftMouseDown, at: middle, d, .control), try mouse(.leftMouseUp, at: middle, d, .control)])
            #expect(shown.count == 2)
            #expect(shown.allSatisfy { $0.view === button && $0.titles.first == "New agent in coral" })
            #expect(d.model.currentProjectID != coral)
            // The bar's empty part, right-clicked and Control-clicked.
            let empty = bar.convert(NSPoint(x: bar.bounds.midX + 60, y: 22), to: nil)
            try await d.send([try mouse(.rightMouseDown, at: empty, d), try mouse(.rightMouseUp, at: empty, d)])
            try await d.send([try mouse(.leftMouseDown, at: empty, d, .control), try mouse(.leftMouseUp, at: empty, d, .control)])
            #expect(shown.count == 4)
            #expect(shown.dropFirst(2).allSatisfy { $0.view === bar && $0.titles == ["Add a project folder…"] })
            // A press that moves 3 pt is a click: coral becomes current.
            try await d.drag(from: middle, to: NSPoint(x: middle.x + 3, y: middle.y), steps: 3)
            #expect(d.model.currentProjectID == coral)
            #expect(d.h.config.projects.first?.id != coral)
        }

        /// Dragging a project's name along the bar: it follows the pointer, the
        /// others glide to make room, the drop saves the order at once; Escape
        /// during the drag puts everything back and saves nothing.
        @Test func draggingAProjectReordersAndEscapeCancels() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try #require(d.h.config.addProject(name: "notes", workingDirectory: "/tmp/notes") != nil)
            try await d.settle()
            let bar = d.windowController.topBar
            func centre(_ name: String) throws -> NSPoint {
                let button = try #require(bar.button(of: try d.project(name)))
                return button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            }
            func names() -> [String] { d.h.config.projects.map(\.name) }
            let current = d.model.currentProjectID

            // The first to the end.
            try await d.drag(from: try centre("ghostty"), to: NSPoint(x: try centre("notes").x + 30, y: try centre("notes").y), steps: 12)
            #expect(names() == ["coral", "notes", "ghostty"])
            #expect(d.model.currentProjectID == current, "a drag is not a click")
            // Their places are set at once; the glide only shows the way
            // there (it completes only where the window server draws the
            // window, which depends on the desktop).
            let xs = try ["coral", "notes", "ghostty"].map { try #require(bar.button(of: try d.project($0))).frame.minX }
            #expect(xs == xs.sorted())

            // The last to the middle.
            try await d.drag(from: try centre("ghostty"), to: try centre("notes"), steps: 12)
            #expect(names() == ["coral", "ghostty", "notes"])

            // Held mid-drag: lifted, the others making room; Escape puts it
            // back and the order stays.
            let from = try centre("coral")
            try await d.hold(from: from, to: NSPoint(x: try centre("notes").x, y: from.y), steps: 8)
            #expect(bar.isDragging)
            #expect(bar.button(of: try d.project("coral"))?.isLifted == true)
            try await d.key(AgentWorkspaceDriver.escape)
            #expect(!bar.isDragging)
            try await d.release(at: try centre("notes"))
            #expect(names() == ["coral", "ghostty", "notes"])
            #expect(bar.button(of: try d.project("coral"))?.isLifted == false)
            #expect(d.model.currentProjectID == current)
        }

        /// A drag whose first move goes far (a quick flick, few events)
        /// holds the item where it was pressed, so it follows the pointer
        /// exactly and lands where it shows: a project name, a row beside a
        /// terminal and a tile. The grab came from the first move before, so
        /// the item moved half the way and the order did not change.
        @Test func aQuickDragMovesWhatItShowsMoving() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try #require(d.h.config.addProject(name: "notes", workingDirectory: "/tmp/notes") != nil)
            try await d.settle()
            let bar = d.windowController.topBar
            func centre(_ view: NSView) -> NSPoint { view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
            let first = try #require(bar.button(of: try d.project("ghostty")))
            let last = try #require(bar.button(of: try d.project("notes")))
            try await d.drag(from: centre(first), to: centre(last), steps: 1)
            #expect(d.h.config.projects.map(\.name) == ["coral", "notes", "ghostty"])

            // A tile, at home.
            let order = d.grid.order
            try await d.drag(from: try d.point(ofTile: order[0]), to: try d.point(ofTile: order[order.count - 1]), steps: 1)
            try await d.settle()
            #expect(d.grid.order != order)
            #expect(d.grid.order.last == order[0])

            // A row beside a terminal.
            d.controller.openAgent(try d.id("sunrise-tables"))
            try await d.settle()
            let rows = d.windowController.list.order
            try await d.drag(from: try d.point(ofRow: rows[0]), to: try d.point(ofRow: rows[rows.count - 1]), steps: 1)
            try await d.settle()
            #expect(d.windowController.list.order.last == rows[0])
        }

        // MARK: Ruling 34 and accessibility

        /// Projects that do not fit go into "N more"; each entry has a submenu
        /// that goes to it and holds its menu, Move and Remove included.
        @Test func everyProjectInNMoreHasItsMenu() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            for index in 1...8 {
                try #require(d.h.config.addProject(name: "a project named \(index)", workingDirectory: "/tmp/p\(index)") != nil)
            }
            d.window.setFrame(NSRect(x: 80, y: 80, width: 900, height: 560), display: false)
            try await d.settle()
            let bar = d.windowController.topBar
            #expect(bar.moreButtonFrame != nil)
            let more = bar.moreMenu()
            #expect(!more.items.isEmpty)
            for entry in more.items {
                let titles = try #require(entry.submenu).items.map { $0.isSeparatorItem ? "—" : $0.title }
                #expect(titles.first?.hasPrefix("Go to ") == true)
                #expect(titles.contains("Move left") && titles.contains("Move right") && titles.contains("Remove project"))
            }
            // The last project, in "N more": Move right disabled; Move left moves it.
            let last = try #require(d.h.config.projects.last)
            let entry = try #require(more.items.first { $0.submenu?.items.first?.title == "Go to \(last.name)" })
            let submenu = try #require(entry.submenu)
            #expect(submenu.item(withTitle: "Move right")?.isEnabled == false)
            submenu.performActionForItem(at: submenu.indexOfItem(withTitle: "Move left"))
            #expect(d.h.config.projects.dropLast().last?.id == last.id)
            // Go to switches.
            let go = try #require(bar.moreMenu().items.compactMap(\.submenu).first)
            let target = go.items[0].title.replacingOccurrences(of: "Go to ", with: "")
            go.performActionForItem(at: 0)
            #expect(d.model.currentProjectID == (try d.project(target)))
        }

        /// Each project is a button named by its project, its value the counts;
        /// VoiceOver reaches every action of its menu as an action of the
        /// button, and the button shows the menu.
        @Test func eachProjectIsAButtonWithItsMenusActions() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let bar = d.windowController.topBar
            var shown = 0
            bar.showMenu = { _, _, _ in shown += 1 }
            let ghostty = try #require(bar.button(of: try d.project("ghostty")))
            #expect(ghostty.accessibilityRole() == .button)
            #expect(ghostty.accessibilityLabel() == "ghostty")
            let value = try #require(ghostty.accessibilityValue() as? String)
            #expect(value.hasPrefix("current, 4 agents, ") && value.hasSuffix(" waiting"))
            let coral = try #require(bar.button(of: try d.project("coral")))
            #expect(coral.accessibilityCustomActions()?.map(\.name) == [
                "New agent in coral", "Move left", "Show in Finder", "Remove project", "Add a project folder…",
            ])
            #expect(ghostty.accessibilityPerformShowMenu())
            #expect(shown == 1)
            // An action runs the item: Move left puts coral first.
            let move = try #require(coral.accessibilityCustomActions()?.first { $0.name == "Move left" })
            #expect(move.handler?() == true)
            #expect(d.h.config.projects.first?.name == "coral")
        }

        private func mouse(
            _ type: NSEvent.EventType, at point: NSPoint, _ d: AgentWorkspaceDriver, _ flags: NSEvent.ModifierFlags = []
        ) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: d.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
    }
}
