import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// The flows of `docs/clawddy-design/flows.md` driven through the real
/// agent window with real input (`AgentWorkspaceDriver`): after each, what
/// the window shows and what has the keys.
@MainActor
@Suite(.serialized)
struct AgentInteractionTests {
    /// Runs inside the real test host. If hosted runs did not set
    /// `XCTestConfigurationFilePath`, Clawddy would have started at launch and
    /// this test fails. It is here, in this serialized suite, because the
    /// other tests here put a controller of their own in the app delegate's
    /// place and add the Agent menu while they run.
    @Test func testHostDoesNotStartClawddy() throws {
        #expect(AgentDataRoot.isRunningTests(environment: ProcessInfo.processInfo.environment))
        // It runs in the background: never the active app, no window on screen.
        #expect(NSApp.activationPolicy() == .prohibited)
        #expect(!NSApp.isActive)
        #expect(NSApp.windows.filter(\.isVisible).isEmpty)
        #expect(Bundle.main.bundleIdentifier == "com.mitchellh.ghostty.clawddy-tests")
        let clawddy = try #require(NSApp.delegate as? AppDelegate).clawddy
        // `setup()` sets the environment path first, so nil means it returned at once.
        #expect(clawddy.bridge.environmentPath == nil)
        #expect(clawddy.bridge.agents.isEmpty)
        #expect(NSApp.mainMenu?.items.contains { $0.title == "Agent" } != true)
        #expect(clawddy.workspaceModel.defaults == nil)
        #expect(clawddy.config.root.url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    /// The flows driven through the window, off screen, the app in the
    /// background.
    @MainActor
    @Suite
    struct Driven {
        /// Command-J, from a focused terminal, goes to an agent that waits,
        /// its prompt ready: the table claims it before the terminal, whose
        /// Ghostty binding (`scroll_to_selection`, performable) would
        /// otherwise keep it from any menu. The current project's question
        /// comes first.
        @Test func commandJGoesToTheNextWaitingAgent() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            #expect(d.terminalHasKeys)

            try await d.key(38, .maskCommand)
            #expect(d.model.shownAgentID == (try d.id("soundings")))
            #expect(d.terminalHasKeys)
        }

        /// Command-] and Command-[ step through the list, round its ends,
        /// starting nothing; each lands with the keys on the agent's
        /// terminal, or on the window where it has none.
        @Test func commandBracketsStepThroughTheListAndWrap() async throws {
            let d = try await AgentWorkspaceDriver(.nothingWaiting, shown: "sunrise-tables")
            defer { d.close() }
            let start = try #require(d.model.shownAgentID)
            let rows = d.windowController.list.order
            #expect(rows.count == 4)
            for code: CGKeyCode in [30, 33] {
                var presses = 0
                repeat {
                    try await d.key(code, .maskCommand)
                    presses += 1
                    let id = try #require(d.model.shownAgentID)
                    #expect(d.detail.hasSurface(id: id) ? d.terminalHasKeys : d.firstResponder === d.window, "\(id)")
                } while d.model.shownAgentID != start && presses <= 2 * rows.count
                #expect(d.model.shownAgentID == start, "key \(code)")
                #expect(presses == rows.count, "key \(code)")
            }
            // Passing through started nothing.
            let running = d.h.bridge.agents.values.filter(\.isRunning).map(\.id)
            #expect(Set(running) == Set(d.h.bridge.agents.keys.filter { d.detail.hasSurface(id: $0) }))
            #expect(d.h.bridge.agents[try d.id("docs")]?.isRunning == false)
        }

        /// Shift-Command-] and Shift-Command-[ switch project, round the
        /// ends, and each project comes back as it was left: inside the
        /// agent it was left in, or at home.
        @Test func shiftCommandBracketsSwitchProjectsAndReturnWhereEachWasLeft() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }

            try await d.key(30, [.maskCommand, .maskShift])
            #expect(d.model.currentProjectID == (try d.project("coral")))
            #expect(d.model.shownAgentID == nil)
            #expect(d.firstResponder === d.grid)

            try await d.key(19, .maskCommand)
            #expect(d.model.shownAgentID == (try d.id("import-logbooks")))

            try await d.key(30, [.maskCommand, .maskShift])
            #expect(d.model.currentProjectID == (try d.project("ghostty")))
            #expect(d.model.shownAgentID == (try d.id("sunrise-tables")))
            #expect(d.terminalHasKeys)

            try await d.key(33, [.maskCommand, .maskShift])
            #expect(d.model.currentProjectID == (try d.project("coral")))
            #expect(d.model.shownAgentID == (try d.id("import-logbooks")))
            #expect(d.terminalHasKeys)
        }

        /// Command-2 enters the agent in the list's second row, its prompt
        /// ready; Command-4 opens one that is not running, on purpose, so it
        /// starts and its terminal takes the keys.
        @Test func commandDigitEntersTheAgentInThatRow() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }

            try await d.key(19, .maskCommand)
            #expect(d.model.shownAgentID == (try d.id("review")))
            #expect(d.terminalHasKeys)

            let docs = try d.id("docs")
            #expect(d.h.bridge.agents[docs]?.isRunning == false)
            try await d.key(21, .maskCommand)
            #expect(d.model.shownAgentID == docs)
            try await d.waitUntil("it starts with the keys") { d.terminalHasKeys }
            #expect(d.h.bridge.agents[docs]?.surfaceState == .open)
        }

        /// Command-Escape and a click on "All of <project>" go home; the
        /// stack then shows no terminal and the window has the keys. At home
        /// Command-Escape does nothing.
        @Test func backToAllAgents() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }

            try await d.key(53, .maskCommand)
            #expect(d.model.shownAgentID == nil)
            #expect(d.firstResponder === d.grid)
            // The terminal is hidden once it has shrunk into its tile.
            try await d.waitUntil("the terminal is hidden after the shrink") { d.detail.stack.presentedSurface == nil }
            #expect(d.controller.action(for: .backToAllAgents, in: .homeTiles) == nil)

            try await d.key(18, .maskCommand)
            #expect(d.model.shownAgentID == (try d.id("soundings")))
            try await d.click(at: d.backRowPoint)
            #expect(d.model.shownAgentID == nil)
            try await d.waitUntil("home shows and the list hides after the shrink") {
                !d.windowController.windowView.home.isHidden && d.windowController.list.isHidden
            }
        }

        /// A click on a row enters that agent, on purpose: its CLI starts
        /// and its terminal has the keys.
        @Test func clickingARowEntersTheAgent() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let docs = try d.id("docs")

            try await d.click(at: try d.point(ofRow: docs))

            #expect(d.model.shownAgentID == docs)
            try await d.waitUntil("it starts with the keys") { d.terminalHasKeys }
        }

        /// The list's order is the project's saved order, and stays so while
        /// agents change state; no row is laid out again or moves, and a row
        /// whose agent did not change draws nothing.
        @Test func theListKeepsItsOrderAndRowsWhileAgentsChangeState() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let project = try #require(d.h.config.projects.first { $0.name == "ghostty" })
            #expect(d.rowNames == project.agents.map(\.name))
            let list = d.windowController.list
            let frames = list.order.map { list.row(of: $0)?.frame }
            let review = try d.id("review")
            let untouched = try #require(list.row(of: review))
            let (draws, layouts) = (untouched.draws, untouched.layouts)

            // Three others change state, one of them three times.
            let sunrise = try d.id("sunrise-tables")
            try d.h.completeTurn(sunrise)
            try d.h.startTurn(sunrise)
            try d.h.osc(sunrise, "state=blocked:app=claude-code:kind=question")
            try d.h.completeTurn(try d.id("soundings"))
            try WorkspaceFixture.drive(d.h, try d.id("docs"), to: .working)
            try await d.settle()

            #expect(d.rowNames == project.agents.map(\.name))
            #expect(list.order.map { list.row(of: $0)?.frame } == frames)
            #expect(untouched.draws == draws)
            #expect(untouched.layouts == layouts)
            #expect(list.row(of: review) === untouched)
        }

        /// The top bar's count is the number of agents whose record waits on
        /// the person, in every project, and each project's number is its
        /// own; both follow a change at once.
        @Test func theWaitingCountIsTheRecordsWaiting() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            func waiting(_ project: String? = nil) -> Int {
                d.h.config.projects.filter { project == nil || $0.name == project }
                    .flatMap(\.agents).filter { d.h.bridge.agents[$0.id]?.record.isWaitingOnYou == true }.count
            }
            let bar = d.windowController.topBar
            #expect(bar.waitingCount == waiting())
            #expect(bar.waitingCount == 4)
            #expect(bar.shownProjects.map(\.waiting) == [waiting("ghostty"), waiting("coral")])

            try d.h.completeTurn(try d.id("import-logbooks"))
            try await d.settle()
            #expect(bar.waitingCount == waiting())
            #expect(bar.waitingCount == 5)
            #expect(bar.shownProjects.map(\.waiting) == [waiting("ghostty"), waiting("coral")])
        }

        /// An agent of another project that comes to wait on the person while
        /// another is shown arrives as news in the header; the keys stay in
        /// the terminal and the shown agent does not change. A click on it
        /// enters that agent.
        @Test func newsArrivesWithoutTakingTheKeys() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let logbooks = try d.id("import-logbooks")

            try d.h.completeTurn(logbooks)
            try await d.settle()

            let header = d.windowController.header
            #expect(header.newsAgentID == logbooks)
            #expect(d.model.shownAgentID == (try d.id("sunrise-tables")))
            #expect(d.terminalHasKeys)

            try await d.click(at: header.news.convert(NSPoint(x: header.news.bounds.midX, y: header.news.bounds.midY), to: nil))
            #expect(d.model.shownAgentID == logbooks)
            #expect(header.newsAgentID == nil)
        }

        /// The pointer over a row shows it, and leaving shows it no more; a
        /// press shows the pressed fill until the release.
        @Test func rowsShowThePointerAndThePress() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let review = try #require(d.windowController.list.row(of: try d.id("review")))
            let point = try d.point(ofRow: try d.id("review"))

            d.windowController.windowView.pointerMoved(to: point)
            #expect(review.phase == .hover)
            d.windowController.windowView.pointerMoved(to: nil)
            #expect(review.phase == .rest)

            try await d.press(at: point)
            #expect(review.phase == .pressed)
            try await d.release(at: NSPoint(x: point.x + 400, y: point.y))
            #expect(review.phase == .rest)
            // Let go outside: nothing entered.
            #expect(d.model.shownAgentID == (try d.id("sunrise-tables")))
        }

        /// Ghostty's tab and split keys do nothing in the agent window: no
        /// terminal window, tab or split appears, the shown agent stays, and
        /// the terminal keeps the keys.
        @Test func tabAndSplitKeysDoNothing() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let windows = TerminalController.all.count
            let surfaces = d.h.bridge.agents.keys.filter { d.detail.hasSurface(id: $0) }.count
            for (code, flags) in [
                (17, .maskCommand), (2, [.maskCommand, .maskShift]), (35, [.maskCommand, .maskShift]),
                (36, [.maskCommand, .maskShift]), (125, [.maskCommand, .maskAlternate]),
                (126, [.maskCommand, .maskControl]), (13, [.maskCommand, .maskAlternate]),
            ] as [(CGKeyCode, CGEventFlags)] {
                try await d.key(code, flags)
                #expect(TerminalController.all.count == windows, "key \(code)")
                #expect(d.model.shownAgentID == (try d.id("sunrise-tables")), "key \(code)")
                #expect(d.terminalHasKeys, "key \(code)")
            }
            #expect(d.h.bridge.agents.keys.filter { d.detail.hasSurface(id: $0) }.count == surfaces)
        }

        /// A chord whose command a later stage builds claims nothing yet:
        /// its key goes on to Ghostty as before. Keys that edit terminal
        /// text are Ghostty's: Command-K clears the screen above the line,
        /// Command-Left sends Control-A.
        @Test func terminalKeysReachGhostty() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            // ⌘↩ (Ghostty's full screen) is claimed and does nothing inside.
            #expect(d.controller.performChord(try AgentCommandTests.key(36, .maskCommand)))
            #expect(!d.window.styleMask.contains(.fullScreen))
            let surface = try #require(d.detail.surface(id: try d.id("sunrise-tables")))
            func text() -> String {
                surface.cachedVisibleContents.get()
                    .components(separatedBy: "\n").filter { !$0.hasPrefix("Last login:") }
                    .joined().trimmingCharacters(in: .whitespaces)
            }
            try await d.type("abc")
            try await d.key(AgentWorkspaceDriver.returnKey)
            try await d.type("xyz")
            try await d.waitUntil("the terminal echoes", seconds: 3) { text().contains("abcabcxyz") }
            try await d.key(40, .maskCommand)
            // Ghostty keeps the cursor's line.
            try await d.waitUntil("Command-K clears the screen", seconds: 3) { text() == "xyz" }
            try await d.key(123, [.maskCommand, .maskSecondaryFn, .maskNumericPad])
            try await d.waitUntil("Command-Left sends Control-A", seconds: 3) { text().contains("^A") }
        }

        /// The chords act only in the agent window while it is main: with
        /// another window main, the Agent menu's items that show a chord are
        /// off and claim nothing, and the window claims nothing. In a text
        /// field the app's chords do nothing, and neither do Ghostty's.
        @Test func chordsActOnlyInTheMainAgentWindowOutsideTextFields() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let menu = try #require(NSApp.mainMenu?.items.first { $0.title == "Agent" }?.submenu)
            let find = try #require(menu.items.first { $0.representedObject as? AgentCommand == .findAgent })
            let commandP = try AgentCommandTests.key(35, .maskCommand)
            let commandJ = try AgentCommandTests.key(38, .maskCommand)
            #expect(d.controller.validateMenuItem(find))

            d.window.actsAsKey = false
            #expect(d.controller.keyContext == nil)
            // Another window main, or the agent window closed: the commands
            // that open it act from the menu (final review ruling 1); their
            // keys stay Ghostty's.
            d.controller.menuWillOpen(menu)
            #expect(d.controller.validateMenuItem(find))
            let settle = try #require(menu.items.first { $0.representedObject as? AgentCommand == .settle })
            #expect(!d.controller.validateMenuItem(settle))
            d.controller.menuDidClose(menu)
            // A key's search of the menus, with no menu open, finds it
            // disabled: the key stays Ghostty's.
            #expect(!d.controller.validateMenuItem(find))
            #expect(!d.controller.performChord(commandJ))
            #expect(NSApp.mainMenu?.performKeyEquivalent(with: commandP) != true)
            #expect(NSApp.mainMenu?.performKeyEquivalent(with: commandJ) != true)
            d.window.actsAsKey = true

            let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
            d.window.contentView?.addSubview(field)
            defer { field.removeFromSuperview() }
            #expect(d.window.makeFirstResponder(field))
            #expect(d.controller.keyContext == .textField)
            let shown = d.model.shownAgentID
            let windows = TerminalController.all.count
            #expect(d.controller.performChord(commandJ))
            #expect(d.controller.performChord(try AgentCommandTests.key(45, .maskCommand)))
            #expect(d.model.shownAgentID == shown)
            #expect(TerminalController.all.count == windows)
            #expect(d.window.firstResponder === field)
            #expect(!d.controller.validateMenuItem(find))
        }

        /// Final review ruling 1: with the agent window closed, the Agent
        /// menu's window-opening commands are enabled and the rest are not;
        /// a click on the Dock icon (`applicationShouldHandleReopen`) shows the
        /// agent window as it was and opens no terminal window. Ruling 2:
        /// nothing asked the system for a permission.
        @Test func theClosedWindowComesBackFromTheDockAndTheMenu() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let shown = d.model.shownAgentID
            let menu = try #require(NSApp.mainMenu?.items.first { $0.title == "Agent" }?.submenu)
            d.window.actsAsKey = false
            d.window.orderOut(nil)
            d.controller.menuWillOpen(menu)
            for item in menu.items {
                guard let command = item.representedObject as? AgentCommand else { continue }
                #expect(d.controller.validateMenuItem(item) == AgentCommand.opensWindow.contains(command), "\(command.title)")
            }
            d.controller.menuDidClose(menu)
            #expect(menu.items.first?.title == "Show agents")
            let delegate = try #require(NSApp.delegate as? AppDelegate)
            let windows = TerminalController.all.count
            #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
            #expect(TerminalController.all.count == windows)
            #expect(d.controller.workspaceWindow === d.window)
            #expect(d.model.shownAgentID == shown)
            #expect(AgentPermissionRequests.made.isEmpty)
            d.window.actsAsKey = true
        }

        /// Command-N creates "agent 1" at the end of the current project,
        /// starts it at once, enters it, and its prompt has the keys. (S8
        /// opens the new-agent line instead.)
        /// Keys typed into an agent whose CLI is not running start it and are
        /// held, in order, until its first report, then reach its terminal.
        @Test func keysTypedWhileItStartsArriveInOrderAtTheFirstReport() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "docs")
            defer { d.close() }
            let id = try d.id("docs")
            try await d.typeThroughWindow("held keys")
            try await d.waitUntil("its CLI starts") { d.h.bridge.agents[id]?.surfaceState == .open }
            #expect(d.controller.heldKeys[id]?.filter(\.isPress).count == 9)
            NotificationCenter.default.post(
                name: .ghosttyDidReceiveProgramStatus,
                object: try #require(d.detail.surface(id: id)),
                userInfo: [Notification.Name.ProgramStatusKey: try programStatus("state=idle:app=claude-code")])
            #expect(d.controller.heldKeys[id] == nil)
            try await d.waitUntil("cat echoes them", seconds: 5) { d.detail.screen(id: id)?.contains("held keys") == true }
        }

        /// Last review ruling 6: a ⌘V held while the CLI starts pastes what
        /// the clipboard held when it was pressed, not what it holds when the
        /// CLI is ready.
        @Test func aHeldPasteDeliversTheClipboardOfThePress() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "docs")
            defer { d.close() }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            d.controller.pasteboard = pasteboard
            let id = try d.id("docs")
            pasteboard.clearContents()
            pasteboard.setString("pressed", forType: .string)
            try await d.typeThroughWindow("a")
            try await d.key(9, .maskCommand)
            try await d.waitUntil("its CLI starts") { d.h.bridge.agents[id]?.surfaceState == .open }
            #expect(d.controller.heldKeys[id]?.filter(\.isPress).count == 2)
            pasteboard.clearContents()
            pasteboard.setString("later", forType: .string)
            NotificationCenter.default.post(
                name: .ghosttyDidReceiveProgramStatus,
                object: try #require(d.detail.surface(id: id)),
                userInfo: [Notification.Name.ProgramStatusKey: try programStatus("state=idle:app=claude-code")])
            try await d.waitUntil("cat echoes the paste", seconds: 5) { d.detail.screen(id: id)?.contains("apressed") == true }
            #expect(d.detail.screen(id: id)?.contains("later") == false)
        }

        /// A start that shows a screen and no report: past the hold limit the
        /// held keys are thrown away, the status line says so, and later keys
        /// reach the terminal, so the person can answer it.
        @Test func keysHeldForADialogAreThrownAwayAndLaterKeysGoThrough() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "docs")
            defer { d.close() }
            d.h.providers.prepareLaunch = { _ in
                .success(AgentPreparedLaunch(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "echo Update available; exec /bin/cat"],
                    environment: [:],
                    metadataAvailability: .waiting))
            }
            let id = try d.id("docs")
            try await d.typeThroughWindow("qz")
            try await d.waitUntil("the dialog is drawn", seconds: 5) {
                d.detail.screen(id: id)?.contains("Update available") == true
            }
            #expect(d.controller.heldKeys[id] != nil)
            try await d.waitUntil("the hold limit passes", seconds: 5) {
                d.h.scheduler.advance(by: 0.5)
                return d.controller.heldKeys[id] == nil
            }
            #expect(d.h.diagnostics.messages.contains { $0.contains("shows a screen with no report") })
            #expect(d.windowController.topBar.statusLine == "What you typed while it was starting was not sent.")
            // Later keys are not held: they go on to its terminal.
            #expect(!d.h.bridge.holdsKeys(for: id))
            let agent = try #require(d.h.bridge.agents[id])
            #expect(agent.surfaceState == .open && agent.processState == .launching && agent.isRunning)
            let launches = d.h.providers.launchRequests.count
            try await d.typeThroughWindow("cd")
            #expect(d.h.providers.launchRequests.count == launches)
            #expect(d.controller.heldKeys[id] == nil)
            try await d.type("cd")
            try await d.waitUntil("later keys reach it", seconds: 5) { d.detail.screen(id: id)?.contains("cd") == true }
            #expect(d.detail.screen(id: id)?.contains("qz") == false)
        }

        /// Leaving an agent whose CLI starts throws its held keys away.
        @Test func leavingAStartingAgentThrowsItsKeysAway() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "docs")
            defer { d.close() }
            let id = try d.id("docs")
            try await d.typeThroughWindow("xy")
            try await d.waitUntil("its CLI starts") { d.h.bridge.agents[id]?.surfaceState == .open }
            #expect(d.controller.heldKeys[id] != nil)
            try await d.key(53, .maskCommand)
            #expect(d.controller.heldKeys[id] == nil)
            #expect(d.windowController.topBar.statusLine == "What you typed while it was starting was not sent.")
        }

        /// Entering a stopped agent, even passing through, marks it read: no
        /// live terminal is needed to look at it.
        @Test func enteringAStoppedAgentMarksItRead() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let review = try d.id("review")
            try d.h.providerQuit(review, status: 0)
            #expect(d.h.bridge.agents[review]?.record.unread == true && d.h.bridge.agents[review]?.isRunning == false)
            try await d.key(33, .maskCommand)
            #expect(d.model.shownAgentID == review)
            #expect(d.h.bridge.agents[review]?.record.unread == false && d.h.bridge.agents[review]?.isRunning == false)
        }

        /// Each CLI the same way: find lists "New <CLI> agent" for its name,
        /// running it opens the floating new-agent line whose chip names the
        /// CLI when it is not the default, and Return starts an agent of that
        /// CLI.
        @Test func eachCLIsNewAgentFromFind() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            #expect(d.model.newAgentProvider == .claudeCode)
            for provider in AgentProviderID.allCases {
                try await d.key(35, .maskCommand)
                try await d.type(provider.displayName.lowercased())
                let title = "New \(provider.displayName) agent"
                let row = try #require(d.controller.findRows.firstIndex {
                    if case let .command(found, _, _) = $0 { return found == title }
                    return false
                }, "\(title) for “\(provider.displayName)”")
                for _ in 0..<row { try await d.key(AgentWorkspaceDriver.downArrow) }
                try await d.key(AgentWorkspaceDriver.returnKey)
                #expect(d.windowController.paletteShown && d.windowController.palettePanel.mode == .new)
                #expect(d.windowController.palettePanel.chipText
                    == (provider == .claudeCode ? "New agent in ghostty" : "New \(provider.displayName) agent in ghostty"))
                try await d.type("tidy the docs")
                try await d.key(AgentWorkspaceDriver.returnKey)
                let started = try #require(d.h.config.projects.first { $0.name == "ghostty" }?.agents.last)
                #expect(d.h.bridge.agents[started.id]?.provider == provider, "\(provider)")
                try await d.key(AgentWorkspaceDriver.escape)
                #expect(!d.windowController.paletteShown)
            }
        }

        @Test func commandNInsideOpensTheFloatingNewAgentLine() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let shown = try #require(d.model.shownAgentID)

            try await d.key(45, .maskCommand)
            #expect(d.windowController.paletteShown)
            #expect(d.window.firstResponder === d.windowController.palettePanel.textView)
            #expect(d.controller.keyContext == .palette)
            #expect(d.windowController.palettePanel.chipText == "New agent in ghostty")

            // Return starts it; the field empties and stays open for the next.
            try await d.type("fix the docs")
            try await d.key(AgentWorkspaceDriver.returnKey)
            let project = try #require(d.h.config.projects.first { $0.name == "ghostty" })
            let started = try #require(project.agents.last)
            #expect(started.name == "Fix the docs")
            #expect(d.h.bridge.agents[started.id]?.record.firstInstruction == "fix the docs")
            #expect(d.windowController.paletteShown)
            #expect(d.windowController.palettePanel.textView.string.isEmpty)
            #expect(d.model.shownAgentID == shown)

            // ⌘Z in the empty field cancels that start.
            try await d.key(6, .maskCommand)
            #expect(d.h.config.projects.first { $0.name == "ghostty" }?.agents.contains { $0.id == started.id } == false)

            // Escape: closed, the terminal has the keys again.
            try await d.key(AgentWorkspaceDriver.escape)
            #expect(!d.windowController.paletteShown)
            try await d.waitUntil("its terminal has the keys") { d.terminalHasKeys }
        }

        /// The terminal stack (`AgentTerminalStack`) through the window. A
        /// terminal whose agent is not shown reports its own process's exit
        /// to the bridge, and its pane goes.
        @Test func anExitOfAHiddenTerminalReachesTheBridge() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let review = try d.id("review")
            let agent = try d.h.agent(review)
            #expect(agent.isRunning)
            d.detail.removeSurface(id: review)
            var exits = Ghostty.SurfaceConfiguration()
            exits.command = "/bin/sh -c 'sleep 0.05; exit 3'"
            #expect(d.detail.showOrSwitch(agent: agent, focusTerminal: false, select: false) { exits })
            #expect(d.detail.surface(id: review)?.window === d.window)
            #expect(d.detail.surface(id: review)?.isHiddenOrHasHiddenAncestor == true)

            try await d.waitUntil("the bridge hears the exit", seconds: 5) { !agent.isRunning }
            #expect(!d.detail.hasSurface(id: review))
            #expect(d.model.shownAgentID == (try d.id("sunrise-tables")))
        }

        /// Stepping through agents leaves every running agent's terminal in
        /// the window and only the shown one shown, drawing and focused.
        @Test func steppingKeepsEveryTerminalInTheWindow() async throws {
            let d = try await AgentWorkspaceDriver(.nothingWaiting, shown: "sunrise-tables")
            defer { d.close() }
            let running = d.h.bridge.agents.values.filter { d.detail.hasSurface(id: $0.id) }.map(\.id)
            #expect(running.count >= 3)
            for _ in 0..<6 {
                try await d.key(30, .maskCommand)
                let shown = try #require(d.model.shownAgentID)
                for other in running {
                    let surface = try #require(d.detail.surface(id: other))
                    #expect(surface.window === d.window)
                    #expect(surface.isHiddenOrHasHiddenAncestor == (other != shown))
                    #expect(surface.isWindowVisible == (other == shown))
                    #expect(surface.focused == (other == shown))
                }
                if d.detail.hasSurface(id: shown) { #expect(d.window.firstResponder === d.detail.surface(id: shown)) }
            }
        }

        // MARK: Home

        /// At launch home has no tile selected and the tiles have the keys;
        /// Down selects the first tile, Shift-Right extends, Escape collapses
        /// then clears (rulings 2 to 4).
        @Test func homeStartsWithNothingSelectedAndArrowsSelect() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            #expect(d.model.shownAgentID == nil)
            #expect(d.grid.selection.isEmpty)
            #expect(d.firstResponder === d.grid)
            #expect(d.grid.order.compactMap { d.h.bridge.agents[$0]?.name }
                == ["soundings", "review", "sunrise-tables", "docs"])

            try await d.key(AgentWorkspaceDriver.downArrow)
            #expect(d.selectedNames == ["soundings"])
            try await d.key(AgentWorkspaceDriver.rightArrow, .maskShift)
            #expect(d.selectedNames == ["review", "soundings"])
            try await d.key(AgentWorkspaceDriver.escape)
            #expect(d.selectedNames == ["review"])
            try await d.key(AgentWorkspaceDriver.escape)
            #expect(d.grid.selection.isEmpty)
            try await d.key(AgentWorkspaceDriver.upArrow)
            #expect(d.selectedNames == ["docs"])
        }

        /// Return on a tile enters it on purpose (its CLI starts); ⌘⎋ comes
        /// back home with the cursor on it and the tiles with the keys.
        @Test func returnEntersAndBackComesHomeWithTheCursorOnTheAgent() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(AgentWorkspaceDriver.upArrow)
            #expect(d.selectedNames == ["docs"])

            try await d.key(AgentWorkspaceDriver.returnKey)
            let docs = try d.id("docs")
            #expect(d.model.shownAgentID == docs)
            try await d.waitUntil("it starts with the keys") { d.terminalHasKeys }

            try await d.key(53, .maskCommand)
            #expect(d.model.shownAgentID == nil)
            #expect(d.selectedNames == ["docs"])
            #expect(d.firstResponder === d.grid)
        }

        /// A letter on the one selected tile opens its terminal and arrives
        /// in its input; on an agent asking a question the terminal opens
        /// with its menu and the letter is not delivered (flows.md 4.4).
        @Test func aLetterOnASelectedTileArrivesInItsTerminal() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(AgentWorkspaceDriver.downArrow)
            try await d.key(AgentWorkspaceDriver.rightArrow)
            try await d.key(AgentWorkspaceDriver.rightArrow)
            #expect(d.selectedNames == ["sunrise-tables"])

            try await d.type("q")
            let sunrise = try d.id("sunrise-tables")
            #expect(d.model.shownAgentID == sunrise)
            let surface = try #require(d.detail.surface(id: sunrise))
            try await d.waitUntil("the terminal reads the letter", seconds: 3) {
                surface.cachedVisibleContents.get().contains("q")
            }

            try await d.key(53, .maskCommand)
            try await d.key(AgentWorkspaceDriver.leftArrow)
            try await d.key(AgentWorkspaceDriver.leftArrow)
            #expect(d.selectedNames == ["soundings"])
            try await d.type("z")
            let asking = try d.id("soundings")
            #expect(d.model.shownAgentID == asking)
            let menu = try #require(d.detail.surface(id: asking))
            try await Task.sleep(for: .milliseconds(600))
            #expect(!menu.cachedVisibleContents.get().contains("z"))
        }

        /// Switching to a project whose view is home shows no tile selected;
        /// the density keys change its rows, remembered per project.
        @Test func eachProjectHasItsOwnHomeAndDensity() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(AgentWorkspaceDriver.downArrow)
            let rows = d.grid.layout.rows
            try await d.key(27, .maskCommand)
            #expect(d.grid.layout.rows == rows + 1)

            try await d.key(30, [.maskCommand, .maskShift])
            #expect(d.model.currentProjectID == (try d.project("coral")))
            #expect(d.grid.selection.isEmpty)
            #expect(d.grid.layout.rows == rows)

            try await d.key(33, [.maskCommand, .maskShift])
            #expect(d.grid.selection.isEmpty)
            #expect(d.grid.layout.rows == rows + 1)
            try await d.key(29, .maskCommand)
            #expect(d.grid.layout.rows == rows)
        }

        /// One agent changing state redraws and lays out only its own tile;
        /// starting twelve more agents moves and resizes no tile there was
        /// (flows.md 8.5).
        @Test func tilesKeepPlaceAndOnlyTheChangedTileRedraws() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.settle()
            let tiles = d.grid.tiles
            let frames = tiles.mapValues(\.frame)
            let review = try d.id("review")
            let before = tiles.mapValues { ($0.draws, $0.layouts) }
            let gridLayouts = d.grid.layouts

            try d.h.startTurn(review)
            try await d.settle()
            for (id, tile) in tiles where id != review {
                #expect(tile.draws == before[id]?.0, "\(id)")
                #expect(tile.layouts == before[id]?.1, "\(id)")
            }
            #expect(try #require(tiles[review]).draws > (before[review]?.0 ?? 0))
            #expect(d.grid.layouts == gridLayouts)

            let project = try #require(d.h.config.projects.first { $0.name == "ghostty" })
            for number in 1...12 {
                _ = try #require(d.h.bridge.createAgent(name: "more \(number)", config: d.h.config, project: project.name))
            }
            try await d.settle()
            #expect(d.grid.order.count == 16)
            for (id, frame) in frames { #expect(d.grid.tiles[id]?.frame == frame, "\(id)") }

            // The last one, scrolled out of view, comes to wait: the pill
            // below says so, and a click on it brings it into view.
            let last = try #require(d.grid.order.last)
            try WorkspaceFixture.drive(d.h, last, to: .done)
            try await d.settle()
            let pill = d.windowController.windowView.pillBelow
            #expect(pill.count == 1)
            #expect(!pill.isHidden)
            pill.onPress?()
            try await d.settle()
            #expect(d.grid.visibleRect.contains(try #require(d.grid.tiles[last]).frame))
            #expect(pill.isHidden)
        }

        /// Every column of home and both pills take the pointer: hover,
        /// press, click, drag and right-click reach the tile under the
        /// pointer wherever it is, though the header and the screen sit over
        /// home at opacity 0; inside, home and the pills take none, and a
        /// hidden keys panel takes none.
        @Test func thePointerReachesEveryColumnAndBothPills() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let project = try #require(d.h.config.projects.first { $0.name == "ghostty" })
            for number in 1...12 {
                _ = try #require(d.h.bridge.createAgent(name: "more \(number)", config: d.h.config, project: project.name))
            }
            try await d.settle()
            let columns = d.grid.layout.columns
            #expect(columns >= 3)
            let view = d.windowController.windowView
            for column in 0..<columns {
                let id = d.grid.order[column]
                let tile = try #require(d.grid.tiles[id])
                let point = try d.point(ofTile: id)
                #expect(d.rightClickTarget(at: point) === tile, "column \(column)")
                d.hover(at: point)
                #expect(tile.isHovered, "column \(column)")
                try await d.press(at: point)
                #expect(d.model.selection(in: project.id).cursor == id, "column \(column)")
                try await d.release(at: point)
                #expect(d.model.shownAgentID == id, "column \(column)")
                try await d.key(AgentWorkspaceDriver.escape, .maskCommand)
                #expect(d.model.shownAgentID == nil)
                // Inside, none of home takes the pointer.
            }
            d.hover(at: NSPoint(x: 0, y: 0))

            // A drag from the last column of the first row to the first.
            let moving = d.grid.order[columns - 1]
            try await d.drag(from: try d.point(ofTile: moving), to: try d.point(ofTile: d.grid.order[0]))
            try await d.settle()
            #expect(d.grid.order.first == moving)

            // Both pills take the pointer.
            let last = try #require(d.grid.order.last)
            try WorkspaceFixture.drive(d.h, last, to: .done)
            try await d.settle()
            let below = view.pillBelow
            #expect(!below.isHidden)
            let belowPoint = below.convert(NSPoint(x: below.bounds.midX, y: below.bounds.midY), to: nil)
            #expect(d.rightClickTarget(at: belowPoint) === below)
            try await d.click(at: belowPoint)
            #expect(d.grid.visibleRect.intersects(try #require(d.grid.tiles[last]).frame))
            d.grid.scroll(NSPoint(x: 0, y: d.grid.bounds.height))
            try await d.settle()
            let above = view.pillAbove
            #expect(!above.isHidden)
            let abovePoint = above.convert(NSPoint(x: above.bounds.midX, y: above.bounds.midY), to: nil)
            #expect(d.rightClickTarget(at: abovePoint) === above)

            // Inside, the pointer over home's place goes to the terminal's
            // regions, and a hidden keys panel takes nothing.
            try await d.key(AgentWorkspaceDriver.returnKey)
            try await d.click(at: try d.point(ofTile: d.grid.order[0]))
            try await d.settle()
            if d.model.shownAgentID != nil {
                let target = d.rightClickTarget(at: try d.point(ofTile: d.grid.order[columns - 1]))
                #expect(target.map { !$0.isDescendant(of: view.home) } ?? true)
            }
            let panelPoint = view.convert(NSPoint(x: view.keysPanel.frame.midX, y: view.keysPanel.frame.midY), to: nil)
            #expect(d.rightClickTarget(at: panelPoint).map { !$0.isDescendant(of: view.keysPanel) } ?? true)
        }

        /// A tile out of view does no work for its agent: no draw, no
        /// layout, no read of its terminal; it catches up when it comes into
        /// view, by the refresh tick, not in the frame of the scroll. Its
        /// mark does not turn while out of view.
        @Test func aTileOutOfViewDoesNoWork() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let project = try #require(d.h.config.projects.first { $0.name == "ghostty" })
            for number in 1...12 {
                _ = try #require(d.h.bridge.createAgent(name: "more \(number)", config: d.h.config, project: project.name))
            }
            try await d.settle()
            // Long enough for the tick to draw every tile once.
            try await Task.sleep(for: .seconds(1.5))
            let last = try #require(d.grid.order.last)
            let tile = try #require(d.grid.tiles[last])
            #expect(!tile.isOnScreen)
            let before = (tile.draws, tile.layouts)
            try WorkspaceFixture.drive(d.h, last, to: .done)
            try await d.settle()
            #expect(tile.draws == before.0)
            #expect(tile.layouts == before.1)
            #expect(tile.isStale)

            d.grid.scrollToVisible(tile.frame)
            #expect(tile.isOnScreen)
            #expect(tile.draws == before.0)
            try await d.waitUntil("the tick brings it up to date") { !tile.isStale }
            try await d.settle()
            #expect(tile.draws > before.0)
        }

        /// The chip names where typing goes, and is the only thing that
        /// decides it (rulings 1 to 3): a new agent with nothing selected,
        /// "Reply to" with one tile and the tiles holding the keys, "To N
        /// agents" with several, whose line dims the others to 55 %.
        @Test func theChipNamesWhereTypingGoes() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let line = d.windowController.line
            #expect(line.chipText == "New agent in ghostty")
            #expect(line.textView.placeholder == "Describe the task")
            try await d.key(AgentWorkspaceDriver.downArrow)
            let first = try #require(d.grid.selection.cursor.flatMap { d.h.bridge.agents[$0]?.name })
            #expect(line.chipText == "Reply to \(first)")
            #expect(line.textView.placeholder == "Type to reply, or ⌘N for a new agent")
            try await d.key(AgentWorkspaceDriver.rightArrow, .maskShift)
            #expect(line.chipText == "To 2 agents")
            #expect(line.textView.placeholder == "One instruction for all 2")
            // Return with several selected moves to the line.
            try await d.key(AgentWorkspaceDriver.returnKey)
            #expect(d.window.firstResponder === line.textView)
            #expect(d.controller.keyContext == .homeLine)
            #expect(d.grid.tiles.values.filter(\.isDimmed).count == d.grid.tiles.count - 2)
            // Escape on an empty line collapses the selection and gives the
            // tiles the keys; nothing dims.
            try await d.key(AgentWorkspaceDriver.escape)
            #expect(d.window.firstResponder === d.grid)
            #expect(d.grid.selection.selected.count == 1)
            #expect(d.grid.tiles.values.allSatisfy { !$0.isDimmed })
            #expect(line.chipText.hasPrefix("Reply to "))
        }

        /// The line starts an agent from a task and keeps the keys; ⌘Z in
        /// the empty line cancels the start; a key typed with nothing
        /// selected lands in the line; Escape never deletes the text; each
        /// project keeps its own draft.
        @Test func theLineStartsAgentsAndKeepsDrafts() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let line = d.windowController.line.textView
            try await d.type("fix the export")
            #expect(d.window.firstResponder === line)
            #expect(line.string == "fix the export")
            try await d.key(AgentWorkspaceDriver.returnKey)
            let project = try #require(d.h.config.projects.first { $0.name == "ghostty" })
            let started = try #require(project.agents.last)
            #expect(started.name == "Fix the export")
            #expect(d.h.bridge.agents[started.id]?.record.state == .working)
            #expect(line.string.isEmpty)
            #expect(d.window.firstResponder === line)
            #expect(d.grid.selection.isEmpty)
            #expect(d.windowController.topBar.statusLine == "Started Fix the export. ⌘Z cancels it.")
            try await d.key(6, .maskCommand)
            #expect(d.h.config.projects.first { $0.name == "ghostty" }?.agents.contains { $0.id == started.id } == false)
            #expect(d.windowController.topBar.statusLine == "Cancelled Fix the export")

            try await d.type("half a task")
            try await d.key(AgentWorkspaceDriver.escape)
            #expect(d.window.firstResponder === d.grid)
            #expect(line.string == "half a task")
            // Another project has its own draft; this one's comes back.
            try await d.key(30, [.maskCommand, .maskShift])
            #expect(line.string == "")
            try await d.key(33, [.maskCommand, .maskShift])
            #expect(line.string == "half a task")
        }

        /// ⌥→ moves the selected tile one place later, saved as the
        /// project's order; the cursor stays on it. Dragging a tile onto
        /// another place drops it there; dragging a row in the list does
        /// the same (flows.md 3.5).
        @Test func tilesAndRowsMoveByKeysAndByDragging() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            func order() throws -> [String] {
                try #require(d.h.config.projects.first { $0.name == "ghostty" }).agents.map(\.name)
            }
            try await d.key(AgentWorkspaceDriver.downArrow)
            try await d.key(AgentWorkspaceDriver.rightArrow, .maskAlternate)
            try await d.settle()
            #expect(try order() == ["review", "soundings", "sunrise-tables", "docs"])
            #expect(d.selectedNames == ["soundings"])
            #expect(d.grid.order.compactMap { d.h.bridge.agents[$0]?.name } == (try order()))

            try await d.drag(from: try d.point(ofTile: try d.id("docs")), to: try d.point(ofTile: try d.id("review")))
            try await d.settle()
            #expect(try order() == ["docs", "review", "soundings", "sunrise-tables"])
            #expect(!d.grid.isDragging)

            try await d.key(AgentWorkspaceDriver.returnKey)
            try await d.settle()
            let first = try d.point(ofRow: try d.id("docs"))
            let last = try d.point(ofRow: try d.id("sunrise-tables"))
            try await d.drag(from: first, to: NSPoint(x: last.x, y: last.y - 10))
            try await d.settle()
            #expect(try order() == ["review", "soundings", "sunrise-tables", "docs"])
        }

        /// ⌘C copies the selected agents' sentences as "<name>: <sentence>",
        /// one per line; holding ⌘ shows the numbers 1 to 9 over the first
        /// tiles' marks and letting go hides them; a tile's menu lists Open,
        /// Rename, Mark as unread and Settle.
        @Test func copyNumbersAndMenu() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            try await d.key(AgentWorkspaceDriver.downArrow)
            try await d.key(AgentWorkspaceDriver.rightArrow, .maskShift)
            let review = try d.h.agent(try d.id("review"))
            let soundings = try d.h.agent(try d.id("soundings"))
            #expect(d.controller.sentencesToCopy()
                == "soundings: \(soundings.sentence.text)\nreview: \(review.sentence.text)")

            let down = try #require(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: d.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 55))
            d.grid.flagsChanged(with: down)
            try await d.waitUntil("the numbers show", seconds: 1) { d.grid.showsNumbers }
            let up = try #require(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: d.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 55))
            d.grid.flagsChanged(with: up)
            #expect(!d.grid.showsNumbers)

            // Read, finished: it can be renamed, marked unread and settled.
            d.h.bridge.agentViewed(review.id)
            let menu = d.controller.rowMenu(for: review.id)
            #expect(menu.items.map(\.title) == ["Open", "Rename", "Mark as unread", "Settle"])
            #expect(menu.items.map(\.isEnabled) == [true, true, true, true])
            let working = d.controller.rowMenu(for: try d.id("sunrise-tables"))
            #expect(working.items.map(\.isEnabled) == [true, true, false, false])
        }
    }
}
