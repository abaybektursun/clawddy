import AppKit
import Testing
@testable import Ghostty

/// The fixes of the whole-product review (`final-review-rulings.md`) that are
/// values or a table: the views kept during a walk, a name's hygiene, the
/// order of places, and Ghostty's own keys in the agent window.
@MainActor
struct AgentFinalReviewTests {
    /// The window owns its size: its content has none, so a normal launch
    /// once opened it 1 point wide and saved that frame. A saved frame below
    /// the minimum is not used, and the default fits the screen.
    @Test func openingFrameIsNeverBelowTheMinimum() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 949)
        let collapsed = NSRect(x: 755, y: 317, width: 1, height: 560)
        let opened = agentWorkspaceOpeningFrame(saved: collapsed, screen: screen)
        #expect(opened == NSRect(x: 36, y: 25, width: 1440, height: 900))
        #expect(agentWorkspaceOpeningFrame(saved: nil, screen: screen) == opened)

        let good = NSRect(x: 100, y: 80, width: 1200, height: 700)
        #expect(agentWorkspaceOpeningFrame(saved: good, screen: screen) == good)

        let small = NSRect(x: 0, y: 0, width: 1280, height: 720)
        #expect(agentWorkspaceOpeningFrame(saved: nil, screen: small) == small)
    }

    /// The real window, made as a normal launch makes it but without the
    /// saved frame, comes out at a usable size after its content is assigned.
    @Test func windowIsNotCollapsedByItsContent() {
        let controller = NSViewController()
        controller.view = NSView()
        let window = makeAgentWorkspaceWindow(controller: controller, background: .black)
        defer {
            window.setFrameAutosaveName("")
            window.close()
        }
        #expect(window.frame.width >= agentWorkspaceMinimumSize.width)
        #expect(window.frame.height >= agentWorkspaceMinimumSize.height)
    }

    /// Ruling 7: landing on agents during a walk saves no project's view;
    /// a relaunch mid-walk shows every project as before the walk, except
    /// the one the person is in, which keeps where they are.
    @Test func aWalkSavesNoViewButWhereThePersonIs() throws {
        let suite = "clawddy-walk-views-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID(), a = UUID(), b = UUID(), c = UUID()
        let model = AgentWorkspaceModel(defaults: defaults)
        model.show(.inside(a), in: first)
        model.show(.home, in: second)
        model.walk = AgentWalk(
            origin: .init(project: second, view: .home, selection: AgentTileSelection(), scroll: 0, views: model.views),
            waiting: [], shown: nil, at: Date())
        model.show(.inside(b), in: first)
        model.show(.inside(c), in: second)

        let relaunched = AgentWorkspaceModel(defaults: defaults)
        #expect(relaunched.currentProjectID == second)
        #expect(relaunched.views[first] == .inside(a))
        #expect(relaunched.views[second] == .inside(c))

        // Crossing into the first project, the second gets its old view back
        // on disk, and the first keeps where the person is.
        model.show(.inside(b), in: first)
        let again = AgentWorkspaceModel(defaults: defaults)
        #expect(again.views[first] == .inside(b))
        #expect(again.views[second] == .home)
    }

    /// Ruling 10: line breaks of every kind and tabs become spaces, zero-width
    /// characters go; the kept name is trimmed and at most 60 characters.
    @Test func aNameIsOneCleanLine() {
        #expect(AgentNameField.clean("fix\r\nlogin\rnow\u{2028}x\u{2029}y\u{85}z\tw\u{0B}v") == "fix login now x y z w v")
        #expect(AgentNameField.clean("a\u{200B}b\u{200C}c\u{200D}d\u{2060}e\u{FEFF}f") == "abcdef")
        let field = AgentNameField()
        field.textView.setText("  \u{200B}  hello\nworld\t ")
        #expect(field.name == "hello world")
        field.textView.setText(String(repeating: "x", count: 70))
        #expect(field.name.count == AgentNameField.longest)
    }

    /// Ruling 13: Ghostty's default ⌘ chords that shortcuts.md does not name
    /// do nothing at home, in the line, the palette and a name field (a
    /// field keeps its own text editing); inside a terminal only those the
    /// terminal owns go on to it, and the rest do nothing.
    @Test func ghosttysOwnKeysInTheAgentWindow() throws {
        func chord(_ code: CGKeyCode, _ flags: CGEventFlags) throws -> AgentChord {
            try #require(AgentChord(event: try AgentCommandTests.key(code, flags)))
        }
        let cmd = CGEventFlags.maskCommand
        let arrow: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
        // Ghostty's macOS defaults (src/config/Config.zig) that only work in
        // a terminal: clear screen, paste, paste selection, find, use
        // selection for find, find previous... , write screen, the
        // line-start/end and prompt jumps.
        let terminalOwned: [AgentChord] = try [
            chord(40, cmd), chord(9, cmd), chord(9, [cmd, .maskShift]), chord(3, cmd), chord(14, cmd),
            chord(3, [cmd, .maskShift]), chord(5, cmd), chord(5, [cmd, .maskShift]), chord(38, [cmd, .maskShift]),
            chord(123, arrow.union(cmd)), chord(124, arrow.union(cmd)), chord(126, arrow.union(cmd)),
            chord(125, arrow.union(cmd)), chord(126, arrow.union([cmd, .maskShift])), chord(125, arrow.union([cmd, .maskShift])),
        ]
        // The rest the agent window has no use for: redo, reopen closed tab,
        // close all windows, write screen two ways, splits, inspector.
        let unused: [AgentChord] = try [
            chord(6, [cmd, .maskShift]), chord(17, [cmd, .maskShift]), chord(13, [cmd, .maskShift, .maskAlternate]),
            chord(38, [cmd, .maskShift, .maskControl]), chord(38, [cmd, .maskShift, .maskAlternate]),
            chord(33, [cmd, .maskControl]), chord(30, [cmd, .maskControl]), chord(34, [cmd, .maskAlternate]),
        ] + [123, 124, 125, 126].map { try chord($0, arrow.union([cmd, .maskControl, .maskShift])) }
        let editing = AgentChords.fieldEditingKeys
        for chord in terminalOwned {
            #expect(AgentChords.command(for: chord, in: .inside) == nil, "\(chord) inside")
            #expect(AgentChords.command(for: chord, in: .homeTiles) == .nothing, "\(chord) on the tiles")
            for context in [AgentKeyContext.homeLine, .palette, .textField] {
                #expect(AgentChords.command(for: chord, in: context) == (editing.contains(chord) ? nil : .nothing), "\(chord) in \(context)")
            }
        }
        for chord in unused {
            for context in AgentKeyContext.allCases {
                let fieldsOwn = editing.contains(chord) && [.homeLine, .palette, .textField].contains(context)
                #expect(AgentChords.command(for: chord, in: context) == (fieldsOwn ? nil : .nothing), "\(chord) in \(context)")
            }
        }
        // ⇧⌘Z: a field's redo, nothing anywhere else.
        let redo = try chord(6, [cmd, .maskShift])
        #expect(AgentChords.command(for: redo, in: .homeLine) == nil)
        #expect(AgentChords.command(for: redo, in: .inside) == .nothing)
    }
}

extension AgentInteractionTests {
    /// The whole-product review's fixes driven through the window.
    @MainActor
    @Suite
    struct FinalReview {
        private static let f2: CGKeyCode = 120

        /// (Serialized with the driven tests: their windows use the same
        /// saved frame's name.) Window restoration comes after the window is made and puts back the
        /// frame of its own saved state: after the session with the collapsed
        /// window, the owner's came back at the minimum size. The frame has one
        /// owner, the one saved under the window's name, which the window opens
        /// with: restoration leaves the window that frame, and since the saved
        /// frame follows every change at once, it must be taken before
        /// restoration runs. (AppKit's restoration coder is its own: a coder
        /// with none of its keys restores nothing, and `keepingFrame` stands for
        /// restoration changing the frame.)
        @Test func restorationLeavesTheWindowItsSavedFrame() throws {
            func made() -> AgentWorkspaceWindow {
                let controller = NSViewController()
                controller.view = NSView()
                return makeAgentWorkspaceWindow(controller: controller, background: .black)
            }
            // Inside the screen's visible frame: a saved frame is kept on screen.
            let visible = try #require(NSScreen.main).visibleFrame
            let good = NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 1000, height: 600)
            // A collapsed frame as the bad session saved it: AppKit reads it as
            // the minimum size; the window opens at the default instead.
            UserDefaults.standard.set("755 317 1 560 0 0 1512 949 ", forKey: "NSWindow Frame \(AgentWorkspaceWindow.frameName)")
            let collapsed = made()
            #expect(collapsed.frame == agentWorkspaceOpeningFrame(saved: nil, screen: try #require(collapsed.screen ?? NSScreen.main).visibleFrame))
            collapsed.setFrameAutosaveName("")
            collapsed.close()
            let first = made()
            #expect(first.isRestorable)
            #expect(first.frameAutosaveName == AgentWorkspaceWindow.frameName)
            first.setFrame(good, display: false)
            first.saveFrame(usingName: AgentWorkspaceWindow.frameName)
            first.setFrameAutosaveName("")
            first.close()

            // The next launch opens at the saved frame; restoration putting back
            // a collapsed one leaves it there, and the saved frame too.
            let window = made()
            defer {
                window.setFrameAutosaveName("")
                window.close()
            }
            #expect(window.frame == good)
            window.keepingFrame { window.setFrame(NSRect(x: 755, y: 317, width: 1, height: 560), display: false) }
            #expect(window.frame == good)
            #expect(AgentWorkspaceWindow.savedFrame() == good)
            let state = NSKeyedArchiver(requiringSecureCoding: true)
            window.restoreState(with: try NSKeyedUnarchiver(forReadingFrom: state.encodedData))
            #expect(window.frame == good)
        }

        /// Ruling 9: the header's name field is as wide as the name plus
        /// room to type, at most 320 pt or 36 % of the pane, and the
        /// sentence shows after it; a row's halo keeps clear of the row's
        /// sentence.
        @Test func nameFieldsFitTheirPlace() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let header = d.windowController.header
            d.controller.rename(try d.id("sunrise-tables"), at: .header)
            try await d.settle()
            let field = d.windowController.nameField
            #expect(field.superview === header)
            #expect(field.frame.width <= min(320, (header.bounds.width * 0.36).rounded()))
            #expect(field.frame.width >= header.nameFrame.width - 1)
            try await d.key(AgentWorkspaceDriver.escape)

            let review = try d.id("review")
            d.controller.rename(review, at: .row)
            try await d.settle()
            let row = try #require(d.windowController.list.row(of: review))
            #expect(field.superview === row)
            #expect(field.frame.maxY + row.nameHalo + 1 <= row.sentenceGlyphTop)
            try await d.key(AgentWorkspaceDriver.escape)
        }

        /// Ruling 13: ⌘1–9 at home count the model's places, the order the
        /// grid shows and the Agent menu names.
        @Test func thePlacesHaveOneOwner() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            let project = try #require(d.h.config.projects.first { $0.id == d.model.currentProjectID })
            #expect(d.model.places(of: project, agents: d.h.bridge.agents).map(\.id) == d.grid.order)
            try await d.key(19, .maskCommand)
            #expect(d.model.shownAgentID == d.grid.order[1])
        }

        /// Ruling 14: a start from find at home with a draft in the line
        /// leaves the draft alone; ⌘Z there is text undo.
        @Test func aStartFromFindLeavesTheDraft() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer { d.close() }
            d.windowController.focus(.line)
            try await d.type("half a task")
            try await d.key(35, .maskCommand)
            try await d.type("zzqq nothing matches")
            try await d.key(36, .maskCommand)
            let line = d.windowController.line.textView
            #expect(d.firstResponder === line)
            #expect(line.string == "half a task")
            let agents = d.h.bridge.agents.count
            try await d.key(6, .maskCommand)
            #expect(d.h.bridge.agents.count == agents)
        }
    }
}
