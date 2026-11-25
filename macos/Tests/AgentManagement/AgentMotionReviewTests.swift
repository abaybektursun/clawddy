import AppKit
import Testing
@testable import Ghostty

extension AgentInteractionTests {
    /// The review of motion (`neon/review-s10.md`): what is shown, what takes
    /// the pointer and what a motion leaves behind follow the state at once;
    /// the animations are only the picture.
    @MainActor
    @Suite
    struct MotionReview {
        /// Ruling 2: switching project while a tile grows ends that motion
        /// at once and gives the tile its content back; nothing floats over
        /// the new project.
        @Test func aProjectSwitchEndsTheGrowAndReturnsTheContent() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            d.window.forcesTerminalsVisible = true
            try await d.key(AgentWorkspaceDriver.downArrow)
            let id = try #require(d.grid.selection.cursor)
            let tile = try #require(d.grid.tiles[id])
            try await d.key(AgentWorkspaceDriver.returnKey)
            let view = d.windowController.windowView
            try await d.key(30, [.maskCommand, .maskShift])
            #expect(view.zoomState.agent == nil)
            #expect(view.zoomCover.layer?.sublayers?.isEmpty ?? true)
            #expect(!tile.isZoomed)
            #expect(!tile.lendsContent)
        }

        /// Ruling 3 and 1: settling a tile at home: its place takes the
        /// pointer and VoiceOver at once, the tile's content goes to 0 and
        /// the place to 1 (the fades are only the picture); undone, the
        /// reverse, and the place takes no pointer from that moment.
        @Test func settleAndUndoCrossFadeAndThePointerFollowsAtOnce() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(AgentWorkspaceDriver.downArrow)
            let id = try #require(d.grid.selection.cursor)
            try await d.key(2, .maskCommand)
            let tile = try #require(d.grid.tiles[id])
            let place = try #require(tile.settledPlace)
            #expect(place.isActive && !place.isHidden)
            #expect(place.layer?.opacity == 1)
            #expect(tile.contentOpacity == 0)
            try await d.key(6, .maskCommand)
            #expect(!place.isActive)
            #expect(place.hitTest(NSPoint(x: 10, y: 10)) == nil)
            #expect(place.layer?.opacity == 0)
            #expect(tile.contentOpacity == 1)
        }

        /// Ruling 4: a density change gives each tile its new sentence lines
        /// at once (shown under a held picture of the old ones while the row
        /// moves, never a moment late), and its screen text its new size by
        /// the motion's end.
        @Test func densityTakesItsNewClampAtOnce() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            for _ in 0..<3 { try await d.key(27, .maskCommand) }
            try await d.settle()
            #expect(d.grid.tiles.values.allSatisfy { !$0.holdsClamp })
        }

        /// Entering, the key's own frame holds the state, the terminal with
        /// the keys and the motion, and nothing that shows only after 50 ms:
        /// the list joins the window, filled, once that frame is committed;
        /// a plain terminal has no SwiftUI overlay at all.
        @Test func theFrameOfEnterHoldsOnlyWhatItShows() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            d.window.forcesTerminalsVisible = true
            try await d.key(AgentWorkspaceDriver.downArrow)
            let id = try #require(d.grid.selection.cursor)
            let list = d.windowController.list
            try d.keyNow(AgentWorkspaceDriver.returnKey)
            #expect(d.model.shownAgentID == id)
            #expect(d.windowController.windowView.zoomState.agent == id)
            #expect(list.isHidden)
            #expect(d.windowController.terminals.stack.overlayView == nil)
            try await d.settle()
            #expect(!list.isHidden)
            #expect(list.row(of: id)?.isCurrent == true)
            #expect(d.windowController.header.agentID == id)
        }

        /// Nothing of home shows inside a terminal and nothing of inside at
        /// home, by every way in and out: home is home, the line and its
        /// edge pills (which go and come with it); inside is the list, the
        /// header and the screen. A click where a pill was, inside, reaches
        /// the terminal.
        @Test func nothingOfHomeShowsInsideAndNothingOfInsideAtHome() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            d.window.forcesTerminalsVisible = true
            let view = d.windowController.windowView
            // Two columns and one row: coral's third tile, which waits, is
            // below the fold, so home has its "1 waiting below" pill.
            d.window.setFrame(NSRect(x: 80, y: 80, width: 900, height: 700), display: false)
            try await d.key(30, [.maskCommand, .maskShift])
            for _ in 0..<4 { try await d.key(24, .maskCommand) }
            func rest() async throws {
                try await d.waitUntil("the motion ends") { view.zoomState.agent == nil }
                try await d.settle()
            }
            func home(_ what: String) async throws {
                try await rest()
                let pills = [("pillAbove", view.pillAbove), ("pillBelow", view.pillBelow)].filter { $0.1.count > 0 }.map(\.0)
                #expect(Set(view.shownRegions) == Set(["home", "line"] + pills), "\(what): \(view.shownRegions)")
            }
            func inside(_ what: String) async throws {
                try await rest()
                #expect(Set(view.shownRegions) == ["list", "header", "screen"], "\(what): \(view.shownRegions)")
            }
            try await home("coral at home")
            #expect(view.pillBelow.count == 1 && !view.pillBelow.isHidden)
            let pill = view.pillBelow.convert(NSPoint(x: view.pillBelow.bounds.midX, y: view.pillBelow.bounds.midY), to: nil)

            // Return.
            try await d.key(AgentWorkspaceDriver.downArrow)
            try await d.key(AgentWorkspaceDriver.returnKey)
            try await inside("after Return")
            let shown = try #require(d.model.shownAgentID)
            let surface = try #require(d.detail.surface(id: shown))
            let hit = try #require(view.hitTest(view.superview?.convert(pill, from: nil) ?? pill))
            #expect(hit.isDescendant(of: surface), "a click where the pill was reaches \(hit)")
            // Leave.
            try await d.key(AgentWorkspaceDriver.escape, .maskCommand)
            try await home("after leaving")
            // Opened on purpose (find, a notification, a click).
            d.controller.openAgent(try d.id("buoy-catalog"))
            try await inside("opened on purpose")
            // Find opened and closed inside.
            try await d.key(35, .maskCommand)
            try await d.key(AgentWorkspaceDriver.escape)
            try await inside("after find")
            // To a project whose view is home, and back.
            try await d.key(33, [.maskCommand, .maskShift])
            try await home("ghostty from inside coral")
            try await d.key(30, [.maskCommand, .maskShift])
            try await inside("back to coral")
            // The walk, across projects.
            for step in 1...3 {
                try await d.key(38, .maskCommand)
                if d.model.walk != nil { try await inside("walk step \(step)") }
            }
            try await d.key(AgentWorkspaceDriver.escape, .maskCommand)
            try await rest()
            // Settle inside.
            d.controller.openAgent(try d.id("buoy-catalog"))
            try await inside("buoy-catalog")
            try await d.key(2, .maskCommand)
            try await home("after settling inside")
            // Closed and reopened inside.
            d.controller.openAgent(try d.id("anchor-alarm"))
            try await inside("anchor-alarm")
            d.window.actsAsKey = false
            d.window.orderOut(nil)
            let delegate = try #require(NSApp.delegate as? AppDelegate)
            _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            d.window.actsAsKey = true
            try await inside("closed and reopened")
        }

        /// Tiles that grow in a density change show their new screen lines
        /// during the motion's last frames, not a frame after it ends: the
        /// clamp is gone before the grid rests.
        @Test func growingTilesShowTheirLinesBeforeTheMotionEnds() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            d.window.forcesTerminalsVisible = true
            try await d.key(27, .maskCommand)
            try await d.waitUntil("the rows rest") { !d.grid.isMoving }
            try await Task.sleep(for: .milliseconds(50))
            try await d.key(24, .maskCommand)
            #expect(d.grid.isMoving)
            #expect(d.grid.tiles.values.contains { $0.holdsClamp })
            var released: CFTimeInterval?
            let deadline = Date() + 1
            while released == nil, Date() < deadline {
                if d.grid.tiles.values.allSatisfy({ !$0.holdsClamp }) { released = CACurrentMediaTime() }
                try await Task.sleep(for: .milliseconds(2))
            }
            let at = try #require(released)
            #expect(at < d.grid.restsAt + 0.002, "released \((at - d.grid.restsAt) * 1000) ms after the rows rest")
        }

        /// Part 2 of the final review: tiles draw no new text while the grid
        /// moves (a density change here), so the motion has every frame; they
        /// draw again once it rests.
        @Test func tilesDrawNothingWhileTheGridMoves() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            d.window.forcesTerminalsVisible = true
            try await d.waitUntil("a tick", seconds: 2) { d.windowController.tailCost.ticks > 0 }
            try await d.key(27, .maskCommand)
            #expect(d.grid.isMoving)
            let ticks = d.windowController.tailCost.ticks
            try await Task.sleep(for: .milliseconds(80))
            #expect(d.windowController.tailCost.ticks == ticks)
            try await d.waitUntil("ticks again", seconds: 2) { d.windowController.tailCost.ticks > ticks }
            #expect(!d.grid.isMoving)
        }

        /// Hand-over check c: while the window cannot be seen (closed,
        /// covered), the tile refresh clock does not run at all, so the app
        /// does not wake 16 times a second for nothing; it runs again when
        /// the window can be seen.
        ///
        /// The window is taken off the screen, as closing does. Being
        /// transparent and under every normal window does not make it
        /// unseen: the window server counts a window as seen while any part
        /// of it is uncovered, whatever its alpha, and the driver's window
        /// reaches below the screen's visible frame, into the Dock's row,
        /// where whether something covers it depends on the person's desktop.
        @Test func theRefreshClockStopsWhileTheWindowIsNotSeen() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            #expect(d.windowController.refreshes)
            d.window.forcesTerminalsVisible = false
            d.window.orderOut(nil)
            try await d.waitUntil("the window is not seen") { !d.windowController.refreshes }
            #expect(AgentMarkLayer.turningCount == 0)
            d.window.orderBack(nil)
            d.window.forcesTerminalsVisible = true
            try await d.settle()
            #expect(d.windowController.refreshes)
        }

        /// Ruling 1: the news and the status line's Undo take no pointer from
        /// the moment they end, also while they fade out.
        @Test func endedNewsAndUndoTakeNoPointer() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let header = d.windowController.header
            try d.h.completeTurn(try d.id("import-logbooks"))
            try await d.settle()
            #expect(header.newsAgentID != nil)
            header.endNews()
            let news = header.news.frame
            #expect(header.hitTest(header.convert(NSPoint(x: news.midX, y: news.midY), to: header.superview)) === header)

            let bar = d.windowController.topBar
            bar.say("Settled x", for: 0.01, undoable: true)
            #expect(bar.showsUndo)
            try await d.waitUntil("the line ends") { !bar.showsUndo }
            let undo = bar.undo.frame
            #expect(bar.hitTest(bar.convert(NSPoint(x: undo.midX, y: undo.midY), to: bar.superview)) === bar)
        }
    }
}
