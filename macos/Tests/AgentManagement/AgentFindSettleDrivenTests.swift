import AppKit
import Testing
@testable import Ghostty

extension AgentInteractionTests {
    /// Find, settle, undo and projects, through the window (flows.md 6.2,
    /// 6.7, 6.8).
    @MainActor
    @Suite
    struct FindAndSettle {
        private static let cmd = CGEventFlags.maskCommand

        /// ⌘P opens find with the keys in its field; typing narrows it at
        /// each key; Return opens the highlighted agent inside, its terminal
        /// with the keys; ⌘P again and Escape close it, the keys back where
        /// they were.
        @Test func findOpensNarrowsAndOpens() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            try await d.key(35, Self.cmd)
            #expect(d.windowController.paletteShown)
            #expect(d.windowController.palettePanel.mode == .find)
            #expect(d.controller.keyContext == .palette)
            // Empty: up to 5 agents, waiting first, then up to 5 commands.
            let groups = d.controller.findRows.map(\.group)
            #expect(groups.filter { $0 == "Commands" }.count == 5)
            #expect(groups.prefix(1) == ["Agents"])
            try await d.key(35, Self.cmd)
            #expect(!d.windowController.paletteShown)
            try await d.waitUntil("its terminal has the keys") { d.terminalHasKeys }

            try await d.key(35, Self.cmd)
            try await d.type("revi")
            guard case .agent(let hit, _, _)? = d.controller.findRows.first else {
                Issue.record("no agent row: \(d.controller.findRows)")
                return
            }
            #expect(hit.name == "review")
            try await d.key(AgentWorkspaceDriver.escape)
            #expect(!d.windowController.paletteShown)
            try await d.waitUntil("its terminal has the keys again") { d.terminalHasKeys }

            try await d.key(35, Self.cmd)
            try await d.type("review")
            try await d.key(AgentWorkspaceDriver.returnKey)
            #expect(!d.windowController.paletteShown)
            #expect(d.model.shownAgentID == (try d.id("review")))
        }

        /// The pointer highlights a row only when it moves over it, at each
        /// row in turn; arrows move the highlight; a resting pointer keeps
        /// none of it when the text changes; a click runs the row.
        @Test func findRowsFollowThePointerOnlyWhenItMoves() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(35, Self.cmd)
            let list = d.windowController.palettePanel.list
            func point(_ row: Int) -> NSPoint {
                let frame = list.rowFrames[row]
                return list.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            }
            #expect(list.rowFrames.count >= 6)
            for row in [1, 3, 5, 2] {
                d.hover(at: point(row))
                #expect(d.controller.findHighlight == row, "row \(row)")
            }
            // The same point again: no move, the arrows keep theirs.
            try await d.key(AgentWorkspaceDriver.downArrow)
            #expect(d.controller.findHighlight == 3)
            d.hover(at: point(2))
            #expect(d.controller.findHighlight == 3)
            // At the left and right ends of a row too.
            let frame = list.rowFrames[4]
            d.hover(at: list.convert(NSPoint(x: frame.minX + 2, y: frame.midY), to: nil))
            #expect(d.controller.findHighlight == 4)
            d.hover(at: list.convert(NSPoint(x: frame.maxX - 2, y: frame.midY + 1), to: nil))
            #expect(d.controller.findHighlight == 4)
            // Typing resets the highlight to the first row under a resting
            // pointer.
            try await d.type("e")
            #expect(d.controller.findHighlight == 0)
            // A click on a command row runs it: "New agent" opens the
            // floating new-agent line with the keys (ruling 32).
            try await d.key(AgentWorkspaceDriver.escape)
            try await d.key(35, Self.cmd)
            try await d.type("new agent")
            let row = try #require(d.controller.findRows.firstIndex {
                $0 == .command(title: "New agent", key: "⌘N", marks: [NSRange(location: 0, length: 3), NSRange(location: 4, length: 5)])
            })
            try await d.click(at: point(row))
            #expect(d.windowController.paletteShown && d.windowController.palettePanel.mode == .new)
            #expect(d.window.firstResponder === d.windowController.palettePanel.textView)
            try await d.key(AgentWorkspaceDriver.escape)
            #expect(!d.windowController.paletteShown)
        }

        /// ⌘↩ with no match starts an agent from the text and the keys land
        /// in the empty home line, where ⌘Z cancels it (ruling 26); with
        /// matches it does nothing.
        @Test func commandReturnInFindStartsOnlyWithoutMatches() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(35, Self.cmd)
            try await d.type("review")
            let before = d.h.config.allAgentEntries.count
            try await d.key(36, Self.cmd)
            #expect(d.windowController.paletteShown)
            #expect(d.h.config.allAgentEntries.count == before)
            try await d.key(AgentWorkspaceDriver.escape)
            try await d.key(35, Self.cmd)
            try await d.type("zqx bug")
            #expect(d.controller.findRows.isEmpty)
            try await d.key(36, Self.cmd)
            #expect(!d.windowController.paletteShown)
            #expect(d.window.firstResponder === d.windowController.line.textView)
            let started = try #require(d.h.config.projects.first { $0.name == "ghostty" }?.agents.last)
            #expect(started.name == "Zqx bug")
            try await d.key(6, Self.cmd)
            #expect(d.h.bridge.agents[started.id] == nil)
            #expect(d.windowController.topBar.statusLine == "Cancelled Zqx bug")
        }

        /// Settling at home keeps the place with Undo, moves the cursor to
        /// the next tile and moves or redraws no other tile; the place's
        /// Undo, clicked, brings it back selected; ⌘Z does the same.
        @Test func settleAtHomeKeepsThePlaceAndUndoBringsItBack() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let review = try d.id("review")
            d.h.bridge.agentViewed(review)
            d.windowController.focus(.tiles)
            d.grid.select(.only(review))
            #expect(d.selectedNames == ["review"])
            let others = d.grid.order.filter { $0 != review }
            // Every tile has drawn what it shows (the refresh tick gives
            // tiles not yet drawn their text, a few at a time, and each text
            // layer draws it at the next display pass).
            func displayed(_ layer: CALayer) -> Bool {
                !layer.needsDisplay() && (layer.sublayers ?? []).allSatisfy(displayed)
            }
            try await d.waitUntil("every tile drew", seconds: 3) {
                d.grid.tiles.values.allSatisfy { $0.hasDrawnScreen && !$0.isStale && $0.layer.map(displayed) == true }
            }
            let frames = others.map { d.grid.tiles[$0]?.frame }
            let draws = others.map { d.grid.tiles[$0]?.draws ?? 0 }

            try await d.key(2, Self.cmd)
            #expect(d.h.bridge.agents[review]?.isSettled == true)
            let tile = try #require(d.grid.tiles[review])
            #expect(tile.isSettledPlace)
            let place = try #require(tile.settledPlace)
            #expect(!place.undo.isHidden)
            #expect(d.selectedNames == ["sunrise-tables"])
            #expect(others.map { d.grid.tiles[$0]?.frame } == frames)
            #expect(others.map { d.grid.tiles[$0]?.draws ?? 0 } == draws)
            #expect(d.windowController.line.settledCount == 1)

            // A click on the place itself does nothing; on its Undo it
            // brings the agent back.
            try await d.click(at: place.convert(NSPoint(x: 8, y: 8), to: nil))
            #expect(d.h.bridge.agents[review]?.isSettled == true)
            try await d.click(at: place.undo.convert(NSPoint(x: place.undo.bounds.midX, y: place.undo.bounds.midY), to: nil))
            #expect(d.h.bridge.agents[review]?.isSettled == false)
            #expect(!tile.isSettledPlace)
            #expect(d.selectedNames == ["review"])
            #expect(d.windowController.topBar.statusLine == "Brought back review")

            try await d.key(2, Self.cmd)
            try await d.key(6, Self.cmd)
            #expect(d.h.bridge.agents[review]?.isSettled == false)
        }

        /// Several selected: working, asking and stopped agents are skipped
        /// and the status line says so (ruling 11); settling one asking
        /// agent alone is allowed; a working one alone is refused.
        @Test func settleSeveralSkipsWorkingAndAsking() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(AgentWorkspaceDriver.downArrow)
            try await d.key(0, Self.cmd)
            try await d.key(2, Self.cmd)
            #expect(d.windowController.topBar.statusLine == "Settled 2. Skipped 2 that are working or need you.")
            #expect(try d.h.agent(try d.id("review")).isSettled)
            #expect(try d.h.agent(try d.id("docs")).isSettled)
            #expect(try !d.h.agent(try d.id("soundings")).isSettled)
            #expect(try !d.h.agent(try d.id("sunrise-tables")).isSettled)
            try await d.key(6, Self.cmd)
            #expect(d.windowController.topBar.statusLine == "Brought back 2 agents")

            try await d.click(at: try d.point(ofTile: try d.id("sunrise-tables")))
            try await d.key(AgentWorkspaceDriver.escape)
            try await d.key(2, Self.cmd)
            #expect(d.windowController.topBar.statusLine == "Still working. Press ⎋ to interrupt it first.")
            try await d.key(AgentWorkspaceDriver.escape)
            try await d.key(53, Self.cmd)
            try await d.waitUntil("home") { d.model.shownAgentID == nil }
            d.grid.select(.only(try d.id("soundings")))
            try await d.key(2, Self.cmd)
            #expect(try d.h.agent(try d.id("soundings")).isSettled)
        }

        /// Inside, ⌘D settles the agent shown and goes home, its place in
        /// view and the cursor on the next; ⌘Z brings it back from inside
        /// another agent and from another project, to its place.
        @Test func undoSurvivesNavigation() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "review")
            defer { d.close() }
            let review = try d.id("review")
            try await d.key(2, Self.cmd)
            #expect(d.model.shownAgentID == nil)
            #expect(d.grid.tiles[review]?.isSettledPlace == true)
            #expect(d.selectedNames == ["sunrise-tables"])
            // Into another agent: the place closes.
            try await d.key(AgentWorkspaceDriver.returnKey)
            #expect(d.model.settledPlaces.isEmpty)
            // Another project, then ⌘Z.
            try await d.key(30, [.maskCommand, .maskShift])
            #expect(d.model.currentProjectID == (try d.project("coral")))
            try await d.key(6, Self.cmd)
            #expect(try !d.h.agent(review).isSettled)
            try await d.key(30, [.maskCommand, .maskShift])
            try await d.key(53, Self.cmd)
            #expect(d.grid.order.prefix(2).map { d.h.bridge.agents[$0]?.name } == ["soundings", "review"])
        }

        /// Remove project (flows.md 6.2): every agent settled, a working one
        /// too, the next project shown, Undo in the status line; after the
        /// CLIs' end its working agent's turn ends interrupted; ⌘Z brings
        /// back the project at its place and its agents; within 60 s exactly
        /// as before, its working agent still running.
        @Test func removeProjectAndUndo() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let ghostty = try d.project("ghostty")
            let working = try d.id("sunrise-tables")
            #expect(try d.h.agent(working).isRunning)
            let states = d.h.config.projects[0].agents.map { d.h.bridge.agents[$0.id]?.record.state }
            d.controller.action(for: .removeProject, in: .homeTiles)?()
            try await d.settle()
            #expect(d.h.config.projects.map(\.name) == ["coral"])
            #expect(d.model.currentProjectID == (try d.project("coral")))
            #expect(d.windowController.topBar.statusLine == "Removed ghostty and settled its 4 agents.")
            #expect(d.windowController.topBar.showsUndo)
            #expect(try d.h.agent(working).isSettled && d.h.agent(working).isRunning)
            try await d.key(6, Self.cmd)
            #expect(d.h.config.projects.map(\.name) == ["ghostty", "coral"])
            #expect(d.model.currentProjectID == ghostty)
            #expect(try d.h.agent(working).isRunning)
            #expect(d.h.config.projects[0].agents.map { d.h.bridge.agents[$0.id]?.record.state } == states)
            #expect(d.windowController.topBar.statusLine == "Brought back ghostty")

            // After 60 s.
            d.controller.action(for: .removeProject, in: .homeTiles)?()
            d.h.scheduler.advance(by: 61)
            try await d.settle()
            let agent = try d.h.agent(working)
            #expect(!agent.isRunning && agent.record.interrupted)
            d.controller.undo(in: .inside)
            #expect(d.h.config.projects.map(\.name) == ["ghostty", "coral"])
            #expect(!agent.isSettled && !agent.isRunning)
            // The only project removed: the first-launch screen.
            for project in d.h.config.projects {
                d.controller.switchProject(project.id)
                d.controller.action(for: .removeProject, in: .homeTiles)?()
            }
            try await d.settle()
            #expect(d.h.config.projects.isEmpty)
            #expect(!d.windowController.windowView.firstLaunch.isHidden)
            // A folder dragged over it: the outline hides the words under it.
            let view = d.windowController.windowView
            let drag = AgentHarnessDrag(urls: [FileManager.default.temporaryDirectory], at: NSPoint(x: 500, y: 400), in: d.window)
            #expect(view.draggingEntered(drag) == .copy)
            #expect(view.firstLaunch.isHidden && view.dropOutline.isShown)
            view.draggingExited(drag)
            #expect(!view.firstLaunch.isHidden)
            try await d.key(6, Self.cmd)
            #expect(d.h.config.projects.count == 1)
        }

        /// Folders dropped anywhere at home: the outline and the words while
        /// dragged, each added in order, the last current; a folder already
        /// here becomes current; files alone are refused.
        @Test func foldersDroppedOnTheWindowBecomeProjects() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
            let one = base.appendingPathComponent("alpha"), two = base.appendingPathComponent("beta")
            for folder in [one, two] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let file = base.appendingPathComponent("notes.txt")
            try Data("x".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: base) }
            let view = d.windowController.windowView
            for point in [NSPoint(x: 60, y: 300), NSPoint(x: 1000, y: 600), NSPoint(x: 540, y: 120)] {
                let drag = AgentHarnessDrag(urls: [one], at: point, in: d.window)
                #expect(view.draggingEntered(drag) == .copy)
                #expect(view.dropOutline.isShown && view.dropOutline.text == "Add alpha as a project")
                view.draggingExited(drag)
                #expect(!view.dropOutline.isShown)
            }
            let both = AgentHarnessDrag(urls: [one, two], at: NSPoint(x: 500, y: 400), in: d.window)
            #expect(view.draggingEntered(both) == .copy)
            #expect(view.dropOutline.text == "Add 2 folders as projects")
            #expect(view.performDragOperation(both))
            #expect(d.h.config.projects.map(\.name) == ["ghostty", "coral", "alpha", "beta"])
            #expect(d.h.config.projects.first { $0.id == d.model.currentProjectID }?.name == "beta")
            #expect(d.window.firstResponder === d.windowController.line.textView)
            let again = AgentHarnessDrag(urls: [one], at: NSPoint(x: 500, y: 400), in: d.window)
            _ = view.draggingEntered(again)
            #expect(view.performDragOperation(again))
            #expect(d.h.config.projects.count == 4)
            #expect(d.windowController.topBar.statusLine == "alpha is already here")
            let files = AgentHarnessDrag(urls: [file], at: NSPoint(x: 500, y: 400), in: d.window)
            #expect(view.draggingEntered(files) == [])
            #expect(!view.dropOutline.isShown)
            // Let go over the window: AppKit says the refused drag left it.
            view.draggingExited(files)
            #expect(d.windowController.topBar.statusLine == "Drop a folder, not a file")
            // Over the open palette a folder is refused and shows no outline.
            try await d.key(35, Self.cmd)
            let overPalette = AgentHarnessDrag(urls: [two], at: NSPoint(x: 500, y: 400), in: d.window)
            #expect(view.draggingEntered(overPalette) == [])
            #expect(!view.dropOutline.isShown)
            view.draggingExited(overPalette)
            // A file let go over the open palette says nothing (final review
            // ruling 16).
            d.windowController.topBar.say("before", for: 6)
            let fileOverPalette = AgentHarnessDrag(urls: [file], at: NSPoint(x: 500, y: 400), in: d.window)
            #expect(view.draggingEntered(fileOverPalette) == [])
            view.draggingExited(fileOverPalette)
            #expect(d.windowController.topBar.statusLine == "before")
        }

        /// A tile's menu at each column acts on that agent's state; at home
        /// its Settle settles the selection it is in.
        @Test func tileMenusAtEveryColumn() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            d.h.bridge.agentViewed(try d.id("review"))
            for id in d.grid.order {
                let target = d.rightClickTarget(at: try d.point(ofTile: id))
                #expect(target === d.grid.tiles[id], "\(d.h.bridge.agents[id]?.name ?? "")")
                let menu = d.controller.rowMenu(for: id)
                let state = d.h.bridge.agents[id]?.record.state
                #expect(menu.items[3].isEnabled == (state != .working))
            }
            d.grid.select(.only(try d.id("review")))
            let menu = d.controller.rowMenu(for: try d.id("review"))
            menu.performActionForItem(at: 3)
            #expect(try d.h.agent(try d.id("review")).isSettled)
        }

        /// Interrupt and send to several never wipes the half line the
        /// person typed into one of them: skipped and named (S7 review
        /// ruling 1). When every one refuses, also late, after the
        /// interrupts, all is as before the key (ruling 2).
        @Test func interruptAndSendKeepsTypedTextAndRollsBack() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let busy = try d.id("sunrise-tables")
            let asking = try d.id("soundings")
            // Claude's input box, its half line typed by the person: one
            // line at a time, each echoed and printed back by `cat` before
            // the next, so the rows never interleave.
            let rule = String(repeating: "─", count: 40)
            for (part, shows) in [("\(rule)\n", 2), ("❯\u{00A0}half a line\n", 2), (rule, 3)] {
                d.detail.input(.paste(part), to: busy)
                let marker = part.hasPrefix("❯") ? "half a line" : "─"
                try await d.waitUntil("\(part) shows", seconds: 3) {
                    (d.detail.screen(id: busy) ?? "").components(separatedBy: "\n").filter { $0.contains(marker) }.count >= shows
                }
            }
            var selection = AgentTileSelection.only(asking)
            selection.press(busy, toggles: true, in: d.grid.order)
            d.grid.select(selection)
            d.windowController.focus(.line)
            try await d.type("stop")
            try await d.key(36, Self.cmd)
            #expect(
                d.windowController.topBar.statusLine?.contains("sunrise-tables: its terminal holds text you typed") == true,
                "\(d.windowController.topBar.statusLine ?? "") screen: \(d.detail.screen(id: busy) ?? "none")")
            #expect(d.detail.screen(id: busy)?.contains("^[") == false)
            #expect(d.windowController.line.textView.string == "stop")
            #expect(Set(d.grid.selection.selected) == [asking, busy])
            #expect(d.window.firstResponder === d.windowController.line.textView)

            // Known only after the interrupts: the working agent never
            // comes back ready within 2 s.
            try await d.key(30, [.maskCommand, .maskShift])
            let coral = try d.project("coral")
            let logbooks = try d.id("import-logbooks")
            let alarm = try d.id("anchor-alarm")
            for stays in [true, false] {
                var both = AgentTileSelection.only(alarm)
                both.press(logbooks, toggles: true, in: d.grid.order)
                d.grid.select(both)
                d.windowController.focus(.line)
                try await d.type("go")
                try await d.key(36, Self.cmd)
                #expect(d.windowController.line.textView.string.isEmpty)
                if !stays { try await d.key(30, [.maskCommand, .maskShift]) }
                d.h.scheduler.advance(by: 2.1)
                try await d.settle()
                #expect(d.model.draft(in: coral) == "go")
                #expect(Set(d.model.selection(in: coral).selected) == [alarm, logbooks])
                if stays {
                    #expect(d.windowController.line.textView.string == "go")
                    #expect(d.window.firstResponder === d.windowController.line.textView)
                    d.windowController.line.textView.setText("")
                    d.model.setDraft("", in: coral)
                } else {
                    #expect(d.model.currentProjectID != coral)
                    #expect(d.windowController.line.textView.string != "go")
                }
            }
        }

        /// The floating new-agent line closes when an agent is entered by
        /// any path or the project switches, and its text stays with the
        /// project it was typed in (S7 review ruling 5).
        @Test func theFloatingLineClosesAndKeepsItsProjectsText() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            try await d.key(45, Self.cmd)
            try await d.type("half")
            d.controller.openAgent(try d.id("review"))
            #expect(!d.windowController.paletteShown)
            try await d.key(45, Self.cmd)
            #expect(d.windowController.palettePanel.textView.string == "half")
            // ⇧⌘] does nothing while the palette has the keys; a switch by
            // another path closes it.
            try await d.key(30, [.maskCommand, .maskShift])
            #expect(d.windowController.paletteShown)
            d.controller.switchProject(try d.project("coral"))
            #expect(!d.windowController.paletteShown)
            d.controller.openAgent(try d.id("buoy-catalog"))
            try await d.key(45, Self.cmd)
            #expect(d.windowController.palettePanel.textView.string.isEmpty)
        }

        /// The pill for waiting agents below sits 10 pt over the line at any
        /// height of the line (S7 review ruling 6).
        @Test func thePillBelowRidesOverTheLine() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let view = d.windowController.windowView
            for lines in ["a", "a\nb\nc", "a\nb\nc\nd\ne\nf\ng"] {
                d.windowController.line.textView.setText(lines)
                view.layoutSubtreeIfNeeded()
                #expect(view.pillBelow.frame.maxY == view.line.frame.minY - 10)
            }
        }

        /// Settling the agent being looked at by its row's menu does what ⌘D
        /// inside does (S8 review ruling 1): home, its settled place shown;
        /// in a walk, settled in place and on to the next.
        @Test func settlingTheShownAgentByItsRowGoesHomeOrOnInAWalk() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "review")
            defer { d.close() }
            let review = try d.id("review")
            let menu = d.controller.rowMenu(for: review)
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Settle"))
            try await d.settle()
            #expect(d.h.bridge.agents[review]?.isSettled == true)
            #expect(d.model.shownAgentID == nil)
            #expect(d.grid.tiles[review]?.isSettledPlace == true)

            d.controller.undo(in: .homeTiles)
            try await d.key(38, Self.cmd)
            let first = try #require(d.model.shownAgentID)
            let rowMenu = d.controller.rowMenu(for: first)
            rowMenu.performActionForItem(at: rowMenu.indexOfItem(withTitle: "Settle"))
            try await d.settle()
            #expect(d.h.bridge.agents[first]?.isSettled == true)
            #expect(d.model.shownAgentID != nil && d.model.shownAgentID != first)
            #expect(d.model.walk != nil)
        }

        /// A settled agent is silent (S8 review ruling 2): what its CLI
        /// reports still reaches its record, but nothing is posted or
        /// announced, and it never counts as waiting.
        @Test func aSettledAgentIsSilent() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let logbooks = try d.id("import-logbooks")
            #expect(d.h.bridge.settle(id: logbooks, includingWorking: true))
            let (posted, announced) = (d.h.notifier.posted.count, d.h.notifier.announced.count)
            try d.h.completeTurn(logbooks)
            try d.h.startTurn(logbooks)
            try d.h.osc(logbooks, "state=blocked:app=claude-code:kind=question")
            try await d.settle()
            #expect(d.h.bridge.agents[logbooks]?.record.state == .asks)
            #expect(d.h.notifier.posted.count == posted)
            #expect(d.h.notifier.announced.count == announced)
            #expect(d.h.bridge.agents[logbooks]?.record.isWaitingOnYou == false)
        }

        /// ⌘Z in the empty floating new-agent line never restores a settle
        /// (S8 review ruling 4); removing a project and undoing it brings back
        /// its home's selection too (ruling 5).
        @Test func floatingLineUndoAndProjectHomeComeBack() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(AgentWorkspaceDriver.downArrow)
            try await d.key(AgentWorkspaceDriver.rightArrow)
            let review = try d.id("review")
            try await d.key(2, Self.cmd)
            #expect(d.h.bridge.agents[review]?.isSettled == true)
            try await d.key(AgentWorkspaceDriver.returnKey)
            #expect(d.model.shownAgentID != nil)
            try await d.key(45, Self.cmd)
            #expect(d.controller.keyContext == .palette)
            try await d.key(6, Self.cmd)
            #expect(d.h.bridge.agents[review]?.isSettled == true)
            try await d.key(AgentWorkspaceDriver.escape)
            try await d.key(6, Self.cmd)
            #expect(d.h.bridge.agents[review]?.isSettled == false)

            try await d.key(AgentWorkspaceDriver.escape, Self.cmd)
            let ghostty = try d.project("ghostty")
            let selection = d.model.selection(in: ghostty)
            #expect(!selection.isEmpty)
            d.controller.action(for: .removeProject, in: .homeTiles)?()
            try await d.settle()
            d.controller.undo(in: .homeTiles)
            try await d.settle()
            #expect(d.model.currentProjectID == ghostty)
            #expect(d.model.selection(in: ghostty) == selection)
        }

        /// The palette sits at the top bar's bottom plus 13 % of the stage;
        /// the dim layer covers the stage only; a list taller than 46 % of
        /// the stage ends on a whole row (S8 review ruling 6).
        @Test func thePaletteSitsInTheStage() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(35, Self.cmd)
            let view = d.windowController.windowView
            let stage = view.bounds.height - AgentTopBar.height
            #expect(view.paletteView.frame.minY == AgentTopBar.height + (stage * 0.13).rounded())
            #expect(view.veil.frame.minY == AgentTopBar.height)
            #expect(view.paletteView.listLimit == (stage * 0.46).rounded())
        }
    }
}
