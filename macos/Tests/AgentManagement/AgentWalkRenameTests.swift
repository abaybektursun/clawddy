import AppKit
import Testing
@testable import Ghostty

/// The walk's order, position and arrivals, as a value (flows.md 6.6,
/// ruling 5, final review rulings 4 and 5).
struct AgentWalkTests {
    private let ids = (0..<6).map { _ in UUID() }
    private let start = Date(timeIntervalSince1970: 1_000)
    private var origin: AgentWalk.Origin {
        AgentWalk.Origin(project: nil, view: .home, selection: AgentTileSelection(), scroll: 0, views: [:])
    }

    /// The agents waiting now, all since before the walk began unless `since`
    /// says otherwise.
    private func waiting(_ agents: [UUID], since: [UUID: Date] = [:]) -> [AgentWalk.Waiting] {
        agents.map { AgentWalk.Waiting(id: $0, since: since[$0] ?? start.addingTimeInterval(-60)) }
    }

    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    /// The first press fixes the order, without the agent shown; each press
    /// lands on the next one, and the position counts them.
    @Test func visitsInOrderWithoutTheShownAgent() {
        let now = waiting([ids[0], ids[1], ids[2]])
        var walk = AgentWalk(origin: origin, waiting: now, shown: ids[1], at: start)
        #expect(walk.advance(waiting: now, at: at(1)) == ids[0])
        #expect(walk.words(waiting: now) == "1 of 2 waiting")
        // Read on landing: it no longer waits.
        let after = waiting([ids[1], ids[2]])
        #expect(walk.advance(waiting: after, at: at(2)) == ids[2])
        #expect(walk.position(waiting: waiting([ids[1]])) == (1, 1))
        #expect(walk.advance(waiting: waiting([ids[1]]), at: at(3)) == nil)
    }

    /// The agent the person is on stays counted when it stops waiting; one
    /// ahead that stopped waiting is passed over and no longer counted.
    @Test func agentsThatStopWaiting() {
        let all = waiting([ids[0], ids[1], ids[2]])
        var walk = AgentWalk(origin: origin, waiting: all, shown: nil, at: start)
        #expect(walk.advance(waiting: all, at: at(1)) == ids[0])
        // The first was answered, the second finished being read elsewhere.
        let now = waiting([ids[2]])
        #expect(walk.words(waiting: now) == "1 of 2 waiting")
        #expect(walk.advance(waiting: now, at: at(2)) == ids[2])
        #expect(walk.words(waiting: now) == "1 of 1 waiting")
    }

    /// Agents that come to wait after the walk began join its end, in the
    /// waiting order.
    @Test func arrivalsJoinTheEnd() {
        let first = waiting([ids[0], ids[1]])
        var walk = AgentWalk(origin: origin, waiting: first, shown: ids[5], at: start)
        #expect(walk.advance(waiting: first, at: at(1)) == ids[0])
        // A new one sorts first in the waiting order, but joins the end.
        let now = waiting([ids[3], ids[1], ids[5]], since: [ids[3]: at(2)])
        #expect(walk.words(waiting: now) == "1 of 3 waiting")
        #expect(walk.advance(waiting: now, at: at(3)) == ids[1])
        #expect(walk.advance(waiting: waiting([ids[3], ids[5]], since: [ids[3]: at(2)]), at: at(4)) == ids[3])
        #expect(walk.visited == [ids[0], ids[1], ids[3]])
    }

    /// Final review ruling 4: an agent the walk landed on, which stopped
    /// waiting and then waits again, joins the end like a new arrival; the
    /// one on screen never does while it is on screen; the agent shown at
    /// the start joins when it comes to wait after the walk began.
    @Test func anAgentWaitingAgainJoinsTheEnd() {
        let a = ids[0], b = ids[1], shown = ids[2]
        var walk = AgentWalk(origin: origin, waiting: waiting([a, b, shown]), shown: shown, at: start)
        #expect(walk.advance(waiting: waiting([a, b, shown]), at: at(1)) == a)
        // On A, answered (it works), then it asks again while on screen.
        let asksAgain = waiting([a, b, shown], since: [a: at(2)])
        #expect(walk.words(waiting: asksAgain) == "1 of 2 waiting")
        #expect(walk.advance(waiting: asksAgain, at: at(3)) == b)
        // Off screen now, A joins the end; B, read, no longer waits.
        let later = waiting([a, shown], since: [a: at(2)])
        #expect(walk.words(waiting: later) == "1 of 2 waiting")
        #expect(walk.advance(waiting: later, at: at(4)) == a)
        // The agent shown at the start, still waiting since before: no
        // stop; once it waits anew, it joins.
        #expect(walk.advance(waiting: waiting([shown]), at: at(5)) == nil)
        var fresh = walk
        #expect(fresh.advance(waiting: waiting([shown], since: [shown: at(4.5)]), at: at(5)) == shown)
    }

    /// Final review ruling 5: "k of N" counts the one on screen, those to
    /// visit and those landed on that still wait; a settled agent leaves the
    /// count, and undoing the settle makes it the next stop.
    @Test func theCountTellsTheTruth() {
        let all = waiting(Array(ids[0..<4]))
        var walk = AgentWalk(origin: origin, waiting: all, shown: nil, at: start)
        #expect(walk.advance(waiting: all, at: at(1)) == ids[0])
        #expect(walk.advance(waiting: all, at: at(2)) == ids[1])
        // The first still waits (a question passed over): it counts behind.
        #expect(walk.words(waiting: all) == "2 of 4 waiting")
        // The second is settled during the walk: it leaves the count.
        let settled = waiting([ids[0], ids[2], ids[3]])
        #expect(walk.advance(waiting: settled, at: at(3)) == ids[2])
        #expect(walk.words(waiting: settled) == "2 of 3 waiting")
        // Its settle undone: it is the next stop.
        walk.comeNext([ids[1]])
        #expect(walk.words(waiting: all) == "2 of 4 waiting")
        #expect(walk.advance(waiting: all, at: at(4)) == ids[1])
    }

    /// Each agent is visited once for each time it starts waiting: those
    /// passed without an answer are not visited again, and the press after
    /// the last ends the walk while they still wait.
    @Test func agentsPassedUnansweredAreNotVisitedAgain() {
        let two = waiting([ids[0], ids[1]])
        var walk = AgentWalk(origin: origin, waiting: two, shown: nil, at: start)
        #expect(walk.advance(waiting: two, at: at(1)) == ids[0])
        #expect(walk.advance(waiting: two, at: at(2)) == ids[1])
        #expect(walk.words(waiting: two) == "2 of 2 waiting")
        #expect(walk.advance(waiting: two, at: at(3)) == nil)
    }

    /// Seven waiting: three passed unanswered, the fourth answered, it asks
    /// again later; the walk visits the fourth a second time at its end and
    /// the three passed never again. The count never goes down on the way
    /// forward except when an agent stops waiting.
    @Test func sevenWaitingTheFourthAsksAgain() {
        let seven = (0..<7).map { _ in UUID() }
        var walk = AgentWalk(origin: origin, waiting: waiting(seven), shown: nil, at: start)
        var landed: [UUID] = []
        var words: [String] = []
        func press(_ now: [AgentWalk.Waiting], _ seconds: Double) -> UUID? {
            let next = walk.advance(waiting: now, at: at(seconds))
            if let next { landed.append(next) }
            words.append(walk.words(waiting: now))
            return next
        }
        let all = waiting(seven)
        for press1 in 1...4 { _ = press(all, Double(press1)) }
        #expect(words == ["1 of 7 waiting", "2 of 7 waiting", "3 of 7 waiting", "4 of 7 waiting"])
        // The fourth answered: it works, still on screen and counted.
        var now = waiting(seven.filter { $0 != seven[3] })
        #expect(walk.words(waiting: now) == "4 of 7 waiting")
        _ = press(now, 5)
        // On the fifth: the fourth stopped waiting and leaves the count.
        #expect(words.last == "4 of 6 waiting")
        // The fourth asks again: it joins the end.
        now = waiting(seven, since: [seven[3]: at(5.5)])
        #expect(walk.words(waiting: now) == "4 of 7 waiting")
        _ = press(now, 6)
        _ = press(now, 7)
        _ = press(now, 8)
        #expect(words.suffix(3) == ["5 of 7 waiting", "6 of 7 waiting", "7 of 7 waiting"])
        #expect(press(now, 9) == nil)
        #expect(landed == Array(seven) + [seven[3]])
    }

    /// With no one waiting the walk lands nowhere.
    @Test func noOneWaiting() {
        var walk = AgentWalk(origin: origin, waiting: waiting([ids[0]]), shown: ids[0], at: start)
        #expect(walk.advance(waiting: waiting([ids[0]]), at: at(1)) == nil)
        #expect(walk.isEmpty)
    }
}

extension AgentInteractionTests {
    /// The walk, rename in place and mark unread, through the window
    /// (flows.md 6.6, 6.9, 6.12).
    @MainActor
    @Suite
    struct WalkAndRename {
        private static let cmd = CGEventFlags.maskCommand
        private static let j: CGKeyCode = 38
        private static let f2: CGKeyCode = 120

        private func words(_ d: AgentWorkspaceDriver) -> String { d.windowController.topBar.waitingWords }
        private func status(_ d: AgentWorkspaceDriver) -> String? { d.windowController.topBar.statusLine }

        /// From home with a tile selected, ⌘J visits every waiting agent,
        /// this project's first, questions before finished turns, then the
        /// other project; the top bar shows the position; landing starts no
        /// CLI; the press after the last returns home with the same cursor.
        @Test func walksEveryoneAcrossProjectsAndReturns() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let ghostty = try d.project("ghostty")
            try await d.key(AgentWorkspaceDriver.downArrow)
            try await d.key(AgentWorkspaceDriver.rightArrow)
            let start = d.model.selection(in: ghostty)
            #expect(start.cursor == (try d.id("review")))
            let running = d.h.bridge.agents.values.filter(\.isRunning).count

            var visited: [String] = []
            // "k of N": a finished turn read on landing leaves the count; a
            // question passed over stays in it, behind (final review ruling 5).
            let counts = ["1 of 4 waiting", "2 of 4 waiting", "2 of 3 waiting", "3 of 3 waiting"]
            for press in 1...4 {
                try await d.key(Self.j, Self.cmd)
                let shown = try #require(d.model.shownAgentID)
                visited.append(d.h.bridge.agents[shown]?.name ?? "")
                #expect(words(d) == counts[press - 1], "press \(press)")
                #expect(d.detail.hasSurface(id: shown) ? d.terminalHasKeys : d.firstResponder === d.window)
            }
            #expect(visited == ["soundings", "review", "anchor-alarm", "slow-builds"])
            #expect(d.h.bridge.agents.values.filter(\.isRunning).count == running)

            // The two questions passed over still wait, and are not visited
            // again: the next press returns to where the walk began.
            try await d.key(Self.j, Self.cmd)
            #expect(d.model.walk == nil)
            #expect(d.model.currentProjectID == ghostty)
            #expect(d.model.shownAgentID == nil)
            #expect(d.model.selection(in: ghostty) == start)
            #expect(d.firstResponder === d.grid)
            #expect(status(d) == "That was everyone. Back where you started.")
            // The other project keeps the view it had: home.
            #expect(d.model.views[try d.project("coral")] ?? .home == .home)
            #expect(words(d) == "3 waiting on you")
        }

        /// ⌘D in a walk settles in place, says so with Undo in the top bar,
        /// and lands on the next without going home; ⌘Z there brings it back
        /// and the walk goes on. ⌘D on the last returns inside the agent the
        /// walk began in, the status line keeping "Settled".
        @Test func settleAdvancesAndUndoKeepsTheWalk() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let soundings = try d.id("soundings")
            try await d.key(Self.j, Self.cmd)
            #expect(d.model.shownAgentID == soundings)

            try await d.key(2, Self.cmd)
            #expect(d.h.bridge.agents[soundings]?.isSettled == true)
            #expect(d.model.shownAgentID == (try d.id("review")))
            #expect(status(d) == "Settled soundings")
            #expect(d.windowController.topBar.showsUndo)
            // A settled agent leaves the count (final review ruling 5).
            #expect(words(d) == "1 of 3 waiting")

            try await d.key(6, Self.cmd)
            #expect(d.h.bridge.agents[soundings]?.isSettled == false)
            #expect(d.model.shownAgentID == (try d.id("review")))
            #expect(d.model.walk != nil)
            // Undone, it is the next stop.
            #expect(words(d) == "1 of 4 waiting")
            try await d.key(Self.j, Self.cmd)
            #expect(d.model.shownAgentID == soundings)
            try d.h.startTurn(soundings)

            try await d.key(Self.j, Self.cmd)
            try d.h.startTurn(try d.id("anchor-alarm"))
            try await d.key(Self.j, Self.cmd)
            #expect(d.model.shownAgentID == (try d.id("slow-builds")))
            try await d.key(2, Self.cmd)
            #expect(d.model.walk == nil)
            #expect(d.model.shownAgentID == (try d.id("sunrise-tables")))
            #expect(status(d) == "Settled slow-builds")
            #expect(d.windowController.topBar.showsUndo)
        }

        /// An agent that comes to wait during the walk joins its end; one
        /// answered while the person is on it stays theirs.
        @Test func arrivalsJoinTheEndAndAnAnsweredOneStays() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(Self.j, Self.cmd)
            let soundings = try d.id("soundings")
            #expect(d.model.shownAgentID == soundings)
            try d.h.osc(soundings, "state=working:app=claude-code")
            let logbooks = try d.id("import-logbooks")
            try d.h.completeTurn(logbooks)
            try await d.settle()
            #expect(d.model.shownAgentID == soundings)
            #expect(words(d) == "1 of 5 waiting")
            var last: UUID?
            for _ in 0..<4 {
                try await d.key(Self.j, Self.cmd)
                last = d.model.shownAgentID
            }
            #expect(last == logbooks)
        }

        /// Entering another way, going home or switching project ends the
        /// walk where the person is; projects passed through keep their view.
        @Test func otherNavigationEndsTheWalk() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            for _ in 0..<3 { try await d.key(Self.j, Self.cmd) }
            #expect(d.model.shownAgentID == (try d.id("anchor-alarm")))
            try await d.key(AgentWorkspaceDriver.escape, Self.cmd)
            #expect(d.model.walk == nil)
            #expect(d.model.currentProjectID == (try d.project("coral")))
            #expect(d.model.shownAgentID == nil)
            #expect(d.model.views[try d.project("ghostty")] == .inside(try d.id("sunrise-tables")))
            #expect(words(d) == "3 waiting on you")

            try await d.key(Self.j, Self.cmd)
            #expect(d.model.walk != nil)
            try await d.key(30, [.maskCommand, .maskShift])
            #expect(d.model.walk == nil)
        }

        /// Final review ruling 6: removing a project ends a walk; a walk whose
        /// beginning is gone (the agent it began in settled) ends at the
        /// current project's home and says only that it was everyone.
        @Test func aWalkWhoseBeginningIsGone() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "review")
            defer { d.close() }
            let review = try d.id("review")
            try await d.key(Self.j, Self.cmd)
            #expect(d.model.walk != nil)
            d.h.bridge.settle(id: review)
            try await d.settle()
            for name in ["soundings", "anchor-alarm", "slow-builds"] {
                try d.h.startTurn(try d.id(name))
            }
            try await d.key(Self.j, Self.cmd)
            #expect(d.model.walk == nil)
            #expect(d.model.shownAgentID == nil)
            #expect(status(d) == "That was everyone.")
            #expect(d.firstResponder === d.grid)

            try d.h.completeTurn(try d.id("import-logbooks"))
            try await d.settle()
            try await d.key(Self.j, Self.cmd)
            #expect(d.model.walk != nil)
            d.controller.removeProject(try #require(d.model.currentProjectID))
            try await d.settle()
            #expect(d.model.walk == nil)
        }

        /// With no one waiting, ⌘J says so and nothing moves.
        @Test func noOneWaitingSaysSo() async throws {
            let d = try await AgentWorkspaceDriver(.nothingWaiting, shown: "sunrise-tables")
            defer { d.close() }
            let shown = d.model.shownAgentID
            try await d.key(Self.j, Self.cmd)
            #expect(d.model.shownAgentID == shown)
            #expect(d.model.walk == nil)
            #expect(status(d) == "No one else is waiting")
        }

        /// F2 edits the cursor tile's name in place, in its font on its line
        /// box, all selected; typed keys and app chords reach only the field;
        /// Return keeps the name and gives the tiles the keys.
        @Test func f2RenamesTheCursorTile() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(AgentWorkspaceDriver.downArrow)
            let id = try d.id("soundings")
            try await d.key(Self.f2)
            let field = d.windowController.nameField
            let tile = try #require(d.grid.tiles[id])
            #expect(d.model.renaming?.agent == id)
            #expect(field.superview === tile)
            #expect(field.frame == tile.nameFrame)
            #expect(field.textView.font14or17 == tile.nameFont)
            #expect(field.textView.selectedRange() == NSRange(location: 0, length: "soundings".count))
            #expect(d.controller.keyContext == .textField)

            try await d.type("fix login")
            try await d.key(Self.j, Self.cmd)
            try await d.key(2, Self.cmd)
            try await d.key(AgentWorkspaceDriver.downArrow)
            #expect(d.model.shownAgentID == nil)
            #expect(d.h.bridge.agents[id]?.isSettled == false)
            #expect(field.textView.string == "fix login")
            try await d.key(AgentWorkspaceDriver.returnKey)
            #expect(d.h.bridge.agents[id]?.name == "fix login")
            #expect(d.h.config.projects.flatMap(\.agents).first { $0.id == id }?.name == "fix login")
            #expect(d.h.bridge.agents[id]?.autoNamed == false)
            #expect(field.isHidden)
            #expect(d.firstResponder === d.grid)
            #expect(d.model.shownAgentID == nil)
        }

        /// Escape restores the old name; an empty name keeps it; a click
        /// elsewhere keeps the typed one.
        @Test func escapeEmptyAndClickAway() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(AgentWorkspaceDriver.downArrow)
            let id = try d.id("soundings")
            try await d.key(Self.f2)
            try await d.type("other")
            try await d.key(AgentWorkspaceDriver.escape)
            #expect(d.h.bridge.agents[id]?.name == "soundings")
            #expect(d.firstResponder === d.grid)

            try await d.key(Self.f2)
            try await d.key(51)
            try await d.key(AgentWorkspaceDriver.returnKey)
            #expect(d.h.bridge.agents[id]?.name == "soundings")

            try await d.key(Self.f2)
            try await d.type("kept")
            try await d.click(at: try d.point(ofTile: try d.id("review")))
            #expect(d.h.bridge.agents[id]?.name == "kept")
            #expect(d.windowController.nameField.isHidden)
        }

        /// Final review ruling 8: a click on empty space keeps the name and
        /// gives the tiles the keys; a click on a control keeps it and the
        /// control acts; a tile being renamed that is settled cancels the
        /// edit and the tiles get the keys.
        @Test func clicksOutsideKeepTheNameAndASettledTileCancelsIt() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(AgentWorkspaceDriver.downArrow)
            let id = try d.id("soundings")
            try await d.key(Self.f2)
            try await d.type("on empty")
            // Empty space under the last row of tiles.
            let empty = d.grid.convert(NSPoint(x: d.grid.bounds.maxX - 30, y: d.grid.bounds.maxY - 6), to: nil)
            try await d.click(at: empty)
            #expect(d.h.bridge.agents[id]?.name == "on empty")
            #expect(d.windowController.nameField.isHidden)
            #expect(d.firstResponder === d.grid)
            #expect(d.model.shownAgentID == nil)

            try await d.key(Self.f2)
            try await d.type("then find")
            let find = try #require(d.windowController.topBar.findButtonFrame)
            try await d.click(at: d.windowController.topBar.convert(NSPoint(x: find.midX, y: find.midY), to: nil))
            #expect(d.h.bridge.agents[id]?.name == "then find")
            #expect(d.windowController.paletteShown)
            try await d.key(AgentWorkspaceDriver.escape)

            try await d.key(Self.f2)
            try await d.type("settled away")
            d.h.bridge.settle(id: id)
            try await d.settle()
            #expect(d.model.renaming == nil)
            #expect(d.windowController.nameField.isHidden)
            #expect(d.h.bridge.agents[id]?.name == "then find")
            #expect(d.firstResponder === d.grid)
        }

        /// While the name is edited, other agents finishing, this one changing
        /// state and its CLI's title never touch the field; the title waits
        /// and goes when a name is kept, and is taken when the edit is
        /// cancelled. Two agents may share a name; a name stops at 60
        /// characters.
        @Test func theFieldSurvivesChangesAndTitlesWait() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(AgentWorkspaceDriver.downArrow)
            let id = try d.id("soundings")
            try await d.key(Self.f2)
            try await d.type("templ")
            try d.h.completeTurn(try d.id("import-logbooks"))
            try d.h.osc(id, "state=working:app=claude-code")
            d.h.bridge.onConversationTitle?(id, "A title from the CLI")
            try await d.settle()
            #expect(d.model.renaming?.waitingTitle == "A title from the CLI")
            #expect(d.windowController.nameField.textView.string == "templ")
            #expect(!d.windowController.nameField.isHidden)
            try await d.type("ate x")
            try await d.key(AgentWorkspaceDriver.returnKey)
            #expect(d.h.bridge.agents[id]?.name == "template x")

            try await d.key(Self.f2)
            d.h.bridge.onConversationTitle?(id, "Another title")
            try await d.key(AgentWorkspaceDriver.escape)
            #expect(d.h.bridge.agents[id]?.name == "template x")

            try await d.key(Self.f2)
            try await d.type(String(repeating: "a", count: 70))
            #expect(d.windowController.nameField.textView.string.count == AgentNameField.longest)
            try await d.key(AgentWorkspaceDriver.escape)
            try await d.key(Self.f2)
            try await d.type("review")
            try await d.key(AgentWorkspaceDriver.returnKey)
            #expect(d.h.bridge.agents[id]?.name == "review")
        }

        /// A row's menu renames on the row; a double-click on the header's
        /// name renames there; the palette's Rename inside renames in the
        /// header. Return gives the terminal the keys back.
        @Test func renameOnARowAndInTheHeader() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let review = try d.id("review")
            let menu = d.controller.rowMenu(for: review)
            let item = try #require(menu.items.first { $0.title == "Rename" })
            #expect(item.isEnabled)
            menu.performActionForItem(at: menu.index(of: item))
            try await d.settle()
            let row = try #require(d.windowController.list.row(of: review))
            #expect(d.windowController.nameField.superview === row)
            #expect(d.windowController.nameField.textView.font14or17 == row.nameFont)
            try await d.type("r2")
            try await d.key(AgentWorkspaceDriver.returnKey)
            #expect(d.h.bridge.agents[review]?.name == "r2")
            try await d.waitUntil("the terminal has the keys") { d.terminalHasKeys }

            let header = d.windowController.header
            let name = header.convert(NSPoint(x: 40, y: header.bounds.midY), to: nil)
            try await d.send([try mouseEvent(d, .leftMouseDown, name, 1), try mouseEvent(d, .leftMouseUp, name, 1),
                              try mouseEvent(d, .leftMouseDown, name, 2), try mouseEvent(d, .leftMouseUp, name, 2)])
            #expect(d.model.renaming?.place == .header)
            #expect(d.windowController.nameField.superview === header)
            try await d.key(AgentWorkspaceDriver.escape)
            try await d.waitUntil("the terminal has the keys") { d.terminalHasKeys }

            try await d.key(35, Self.cmd)
            try await d.type("rename")
            try await d.key(AgentWorkspaceDriver.returnKey)
            #expect(d.model.renaming?.place == .header)
            try await d.type("u2")
            try await d.key(AgentWorkspaceDriver.returnKey)
            #expect(d.h.bridge.agents[try d.id("u2")] != nil)
        }

        private func mouseEvent(_ d: AgentWorkspaceDriver, _ type: NSEvent.EventType, _ point: NSPoint, _ clicks: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: d.window.windowNumber, context: nil, eventNumber: clicks, clickCount: clicks,
                pressure: type == .leftMouseUp ? 0 : 1))
        }

        /// ⌘U: at home on the cursor tile; inside on the agent shown, which
        /// stays unread while it is looked at, until it is entered again; on
        /// another state it says so.
        @Test func markUnreadAtHomeAndInside() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let review = try d.id("review")
            try await d.click(at: try d.point(ofRow: review))
            try await d.waitUntil("review is read") { d.h.bridge.agents[review]?.record.unread == false }
            try await d.key(32, Self.cmd)
            #expect(d.h.bridge.agents[review]?.record.unread == true)
            #expect(status(d) == "Marked unread")
            #expect(d.model.shownAgentID == review)
            d.window.makeFirstResponder(d.window)
            d.detail.focusTerminal()
            try await d.settle()
            #expect(d.h.bridge.agents[review]?.record.unread == true, "looking at it does not read it again")

            try await d.key(AgentWorkspaceDriver.escape, Self.cmd)
            #expect(d.grid.selection.cursor == review)
            try await d.key(AgentWorkspaceDriver.returnKey)
            try await d.waitUntil("entering reads it") { d.h.bridge.agents[review]?.record.unread == false }
            try await d.key(AgentWorkspaceDriver.escape, Self.cmd)
            try await d.key(32, Self.cmd)
            #expect(d.h.bridge.agents[review]?.record.unread == true)
            try await d.key(AgentWorkspaceDriver.rightArrow)
            try await d.key(32, Self.cmd)
            #expect(status(d) == "Only a finished agent can be marked unread")
        }
    }
}
