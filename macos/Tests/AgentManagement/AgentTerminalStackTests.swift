import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

/// `AgentTerminalStack`'s invariant, on real Ghostty terminals in a
/// transparent window of the test host, under every normal window: every
/// terminal stays in the
/// window; only the presented one is shown and draws, and only while the
/// window can be seen; only it may take the keys; Ghostty's focus is true
/// for it alone, and only while it has the keys in the key window.
@MainActor
@Suite(.serialized)
struct AgentTerminalStackTests {
    /// A window acting as the key window, transparent and under every
    /// normal window, with a stack filling it but for a text field below,
    /// and one terminal per name, none presented. The test host is never
    /// the active app, so a window of it never really becomes key: key
    /// transitions are `actsAsKey` and the notifications AppKit posts.
    @MainActor
    private final class Fixture {
        let window: AgentWorkspaceWindow
        let stack: AgentTerminalStack
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        var ids: [String: UUID] = [:]

        init(_ names: [String], command: String = Fixture.echoingCat) throws {
            let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
            window = AgentWorkspaceWindow(
                contentRect: NSRect(x: 80, y: 80, width: 640, height: 400),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            // Seen by no one, as the workspace driver's.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
            window.actsAsKey = true
            window.forcesTerminalsVisible = true
            stack = AgentTerminalStack(ghostty: ghostty)
            let content = NSView()
            window.contentView = content
            for view in [stack, field] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(view)
            }
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: field.topAnchor),
                field.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                field.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                field.widthAnchor.constraint(equalToConstant: 200),
            ])
            window.orderBack(nil)
            for name in names {
                try add(name, command: command)
            }
        }

        func add(_ name: String, command: String = Fixture.echoingCat) throws {
            let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
            var configuration = Ghostty.SurfaceConfiguration()
            configuration.command = command
            let id = UUID()
            ids[name] = id
            stack.add(Ghostty.SurfaceView(try #require(ghostty.app), baseConfig: configuration), for: id, observers: [])
        }

        func surface(_ name: String) throws -> Ghostty.SurfaceView {
            let id = try #require(ids[name])
            return try #require(stack.surface(id: id))
        }

        func present(_ name: String?, keys: Bool = true) throws {
            stack.present(try name.map { try #require(ids[$0]) })
            if keys { #expect(stack.giveKeysToPresented()) }
        }

        /// Names of the terminals that are shown, draw, have Ghostty's focus.
        func shown() throws -> [String] { try names { !$0.isHiddenOrHasHiddenAncestor } }
        func drawing() throws -> [String] { try names { $0.isWindowVisible } }
        func focused() throws -> [String] { try names { $0.focused } }
        func inWindow() throws -> [String] { try names { $0.window === self.window } }

        func names(_ test: (Ghostty.SurfaceView) -> Bool) throws -> [String] {
            try ids.keys.sorted().filter { test(try surface($0)) }
        }

        func close() {
            for id in ids.values { stack.remove(id) }
            window.actsAsKey = false
            window.close()
        }

        /// `cat` with the terminal's echo on and signals off, so every key
        /// the terminal receives shows in its text: Control-C as `^C`,
        /// Escape as `^[`, the arrows as `^[[A`.
        nonisolated static let echoingCat = "/bin/sh -c 'stty -isig echoctl; exec /bin/cat'"
    }

    /// After A, B, C are presented in turn, all three are in the window,
    /// at the stack's size; only C is shown, draws, has the keys and
    /// Ghostty's focus.
    @Test func onlyThePresentedTerminalIsShownDrawsAndHasTheKeys() throws {
        let f = try Fixture(["a", "b", "c"])
        defer { f.close() }
        // Added, none presented: in the window, hidden, not drawing, no focus,
        // although a new surface starts out focused and drawing.
        #expect(try f.inWindow() == ["a", "b", "c"])
        #expect(try f.shown().isEmpty)
        #expect(try f.drawing().isEmpty)
        #expect(try f.focused().isEmpty)
        #expect(try f.names { !$0.trackingAreas.isEmpty }.isEmpty)

        for name in ["a", "b", "c"] { try f.present(name) }

        #expect(try f.inWindow() == ["a", "b", "c"])
        f.window.layoutIfNeeded()
        for name in ["a", "b", "c"] {
            #expect(try f.surface(name).frame.size == f.stack.bounds.size, "\(name)")
        }
        #expect(try f.shown() == ["c"])
        #expect(try f.drawing() == ["c"])
        #expect(try f.focused() == ["c"])
        #expect(f.window.firstResponder === (try f.surface("c")))
        // Only the shown terminal tracks the pointer: a hidden program gets
        // no mouse reports.
        #expect(try f.names { !$0.trackingAreas.isEmpty } == ["c"])
        // A notification names a surface; the stack knows its agent.
        #expect(f.stack.agent(ofSurface: try f.surface("b").id) == f.ids["b"])
    }

    /// A window that cannot be seen stops every terminal drawing; seen
    /// again, the presented one draws again. (Miniaturizing does this too
    /// through the window's occlusion state; a test does not miniaturize, as
    /// a minimized window shows in the Dock.)
    @Test func aWindowNotSeenStopsEveryTerminalDrawing() throws {
        let f = try Fixture(["a", "b"])
        defer { f.close() }
        try f.present("b")
        #expect(try f.drawing() == ["b"])

        // Ordered out: AppKit reports it unseen.
        f.window.orderOut(nil)
        f.window.forcesTerminalsVisible = false
        #expect(!f.window.occlusionState.contains(.visible))
        #expect(try f.drawing().isEmpty)
        #expect(try f.shown() == ["b"])

        f.window.forcesTerminalsVisible = true
        #expect(try f.drawing() == ["b"])
    }

    /// Ghostty's focus follows the window's key state, and a window that
    /// becomes key with the keys on itself gives them to the presented
    /// terminal, as Ghostty's terminal windows do.
    @Test func focusFollowsKeyStateAndComesBackToThePresentedTerminal() async throws {
        let f = try Fixture(["a", "b"])
        defer { f.close() }
        try f.present("a")
        #expect(try f.focused() == ["a"])

        f.window.actsAsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: f.window)
        #expect(try f.focused().isEmpty)

        _ = f.window.makeFirstResponder(nil)
        f.window.actsAsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: f.window)
        // On the next turn of the run loop, as Ghostty's own windows do it.
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.window.firstResponder === (try f.surface("a")))
        #expect(try f.focused() == ["a"])
    }

    /// A hidden terminal never takes the keys, whoever asks: the window
    /// refuses it directly, and Ghostty's own deferred move, asked for just
    /// before another agent is presented, lands nowhere.
    @Test func aHiddenTerminalNeverTakesTheKeys() async throws {
        let f = try Fixture(["a", "b"])
        defer { f.close() }
        try f.present("a")

        Ghostty.moveFocus(to: try f.surface("a"))
        try f.present("b")
        #expect(!f.window.makeFirstResponder(try f.surface("a")))
        try await Task.sleep(for: .milliseconds(300))

        #expect(f.window.firstResponder === (try f.surface("b")))
        #expect(try f.focused() == ["b"])
        #expect(try f.shown() == ["b"])
    }

    /// Presenting another agent while a terminal has the keys takes them
    /// from it first; presenting no agent leaves them with the window.
    @Test func hidingTheTerminalWithTheKeysTakesThemAway() throws {
        let f = try Fixture(["a", "b"])
        defer { f.close() }
        try f.present("a")

        try f.present("b", keys: false)
        #expect(f.window.firstResponder === f.window)
        #expect(try f.focused().isEmpty)

        try f.present("b")
        try f.present(nil, keys: false)
        #expect(f.window.firstResponder === f.window)
        #expect(try f.shown().isEmpty)
        #expect(try f.drawing().isEmpty)
    }

    /// Removing an agent's terminal takes it out of the window, the keys
    /// with it, and leaves the others as they were.
    @Test func removingATerminalTakesItOutOfTheWindow() throws {
        let f = try Fixture(["a", "b"])
        defer { f.close() }
        try f.present("a")
        let a = try f.surface("a")
        let id = try #require(f.ids["a"])

        f.stack.remove(id)

        #expect(f.stack.surface(id: id) == nil)
        #expect(a.window == nil)
        #expect(f.window.firstResponder === f.window)
        #expect(try f.surface("b").window === f.window)
        #expect(f.stack.presentedSurface == nil)
        f.ids["a"] = nil
    }

    /// The window reconciles Ghostty's focus after every change of first
    /// responder: a terminal that takes the keys while the window is not key
    /// is not focused (its own `becomeFirstResponder` would say it is), and
    /// is once the window becomes key.
    @Test func theWindowReconcilesFocusOnEveryResponderChange() async throws {
        let f = try Fixture(["a", "b"])
        defer { f.close() }
        f.window.actsAsKey = false
        try f.present("a")
        #expect(f.window.firstResponder === (try f.surface("a")))
        #expect(try f.focused().isEmpty)

        f.window.actsAsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: f.window)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try f.focused() == ["a"])
    }

    /// A text field that has the keys keeps them when another agent is
    /// presented, and no terminal has Ghostty's focus meanwhile.
    @Test func aTextFieldKeepsTheKeysWhenTheAgentChanges() throws {
        let f = try Fixture(["a", "b"])
        defer { f.close() }
        try f.present("a")
        #expect(f.window.makeFirstResponder(f.field))
        let editor = f.window.firstResponder
        #expect(AgentKeyEventRoutingPolicy.isTextEditingResponder(editor))
        #expect(try f.focused().isEmpty)

        try f.present("b", keys: false)
        #expect(f.window.firstResponder === editor)
        #expect(try f.focused().isEmpty)
        #expect(try f.shown() == ["b"])
    }

    /// A sheet coming and going leaves the keys and Ghostty's focus with
    /// the presented terminal.
    @Test func aSheetComingAndGoingLeavesTheKeysWithTheTerminal() async throws {
        let f = try Fixture(["a", "b"])
        defer { f.close() }
        try f.present("a")
        let sheet = InvisibleWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        sheet.isReleasedWhenClosed = false
        f.window.beginSheet(sheet, completionHandler: nil)
        try await Task.sleep(for: .milliseconds(100))
        f.window.endSheet(sheet)
        sheet.orderOut(nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(f.window.firstResponder === (try f.surface("a")))
        #expect(try f.focused() == ["a"])
        #expect(try f.shown() == ["a"])
    }

    /// A terminal added while another has the keys is hidden, does not
    /// draw, and takes nothing from it.
    @Test func addingAHiddenTerminalLeavesTheKeysWhereTheyAre() throws {
        let f = try Fixture(["a"])
        defer { f.close() }
        try f.present("a")
        try f.add("b")
        #expect(f.window.firstResponder === (try f.surface("a")))
        #expect(try f.focused() == ["a"])
        #expect(try f.shown() == ["a"])
        #expect(try f.drawing() == ["a"])
    }

    /// A hidden terminal follows the window's size at once, not when it is
    /// shown again: its view and its grid are the new size before its first
    /// frame on return.
    @Test func aHiddenTerminalIsResizedWithTheWindow() throws {
        let f = try Fixture(["a", "b"])
        defer { f.close() }
        try f.present("a")
        f.window.layoutIfNeeded()
        let b = try f.surface("b")
        let before = try #require(b.surface.map(ghostty_surface_size))

        var frame = f.window.frame
        frame.size.width += 240
        frame.size.height += 120
        f.window.setFrame(frame, display: false)
        f.window.layoutIfNeeded()

        #expect(b.isHiddenOrHasHiddenAncestor)
        #expect(b.frame.size == f.stack.bounds.size)
        let after = try #require(b.surface.map(ghostty_surface_size))
        #expect(after.columns > before.columns)
        #expect(after.rows > before.rows)
    }

    /// A hidden terminal does no layout and no size negotiation when
    /// anything else changes: it holds no SwiftUI view and no constraint,
    /// presenting and hiding others lays out no terminal, and it is laid out
    /// only when the stack's size changes. Ghostty's overlays follow only
    /// the shown terminal, and observe none while none is shown.
    @Test func aHiddenTerminalDoesNoWorkWhenSomethingElseChanges() throws {
        let f = try Fixture(["a", "b", "c"])
        defer { f.close() }
        try f.present("a")
        f.window.layoutIfNeeded()
        for name in ["a", "b", "c"] {
            let surface = try f.surface(name)
            var view: NSView? = surface
            while let current = view, current !== f.stack {
                #expect(!(current.className.contains("HostingView")), "\(name): \(current.className)")
                // AppKit's own translation of frames for a window that uses
                // Auto Layout is not a size negotiation of the terminal's.
                let negotiated = current.constraints.filter { !$0.className.contains("AutoresizingMask") }
                #expect(negotiated.isEmpty, "\(name): \(current.className)")
                view = current.superview
            }
        }
        let laidOut = f.stack.terminalLayouts
        for name in ["b", "c", "a", nil, "b"] {
            try f.present(name, keys: name != nil)
            f.window.layoutIfNeeded()
        }
        #expect(f.stack.terminalLayouts == laidOut)
        // Nothing to overlay: no SwiftUI view, nothing that needs Auto Layout.
        #expect(!f.stack.subviews.contains { $0 is AgentSurfaceOverlayHost })
        try f.present(nil, keys: false)
        #expect(f.stack.overlayView == nil)
        var frame = f.window.frame
        frame.size.width += 100
        f.window.setFrame(frame, display: false)
        f.window.layoutIfNeeded()
        #expect(f.stack.terminalLayouts == laidOut + 3)
    }

    /// Ghostty's overlays exist only while the shown terminal has one to
    /// show (here a link's address), over that terminal only, and are made
    /// anew for each terminal: no overlay's state carries from one agent's
    /// terminal to the next; a hidden terminal's overlay never shows.
    @Test func theOverlaysExistOnlyWhileTheShownTerminalHasOne() async throws {
        let f = try Fixture(["a", "b"])
        defer { f.close() }
        let a = try f.surface("a"), b = try f.surface("b")
        try f.present("b")
        #expect(f.stack.overlayView == nil)
        b.hoverUrl = "https://example.com/b"
        try await Self.nextTurn()
        let first = try #require(f.stack.overlayView)
        #expect(f.stack.overlaySurface === b)
        #expect(first.superview === f.stack)
        #expect(first.frame == f.stack.bounds)

        // Another terminal with nothing to overlay: gone at once.
        try f.present("a")
        #expect(f.stack.overlayView == nil)
        a.hoverUrl = "https://example.com/a"
        try await Self.nextTurn()
        #expect(f.stack.overlaySurface === a)
        let second = try #require(f.stack.overlayView)
        #expect(second !== first)

        // Back to the first: a new view, not the one it had.
        try f.present("b")
        #expect(f.stack.overlaySurface === b)
        #expect(f.stack.overlayView !== first)
        #expect(f.stack.overlayView !== second)
        // The address gone: so are the overlays.
        b.hoverUrl = nil
        try await Self.nextTurn()
        #expect(f.stack.overlayView == nil)
        // A hidden terminal's address shows nothing.
        try f.present(nil, keys: false)
        #expect(f.stack.overlayView == nil)
    }

    /// One turn of the main run loop, where the stack checks a change the
    /// terminal published before making it.
    private static func nextTurn() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    /// The pointer reaches the shown terminal through the overlays' layer
    /// where no overlay shows.
    @Test func thePointerReachesTheShownTerminalThroughTheOverlays() async throws {
        let f = try Fixture(["a"])
        defer { f.close() }
        try f.present("a")
        f.window.layoutIfNeeded()
        let centre = NSPoint(x: f.stack.bounds.midX, y: f.stack.bounds.midY)
        let a = try f.surface("a")
        #expect(try #require(f.stack.hitTest(f.stack.convert(centre, to: f.stack.superview))).isDescendant(of: a))
        // With an overlay showing (a link's address at the bottom).
        a.hoverUrl = "https://example.com"
        try await Self.nextTurn()
        f.window.layoutIfNeeded()
        #expect(f.stack.overlayView != nil)
        #expect(try #require(f.stack.hitTest(f.stack.convert(centre, to: f.stack.superview))).isDescendant(of: a))
    }

    /// Motion review ruling 6: the overlays' focus (the secure-input mark)
    /// follows the shown terminal's real focus; an agent's terminal offers
    /// no split, tab, close-split, title or inspector command, in its menu
    /// or the menu bar.
    @Test func overlaysFollowFocusAndAnAgentsTerminalIsNeverSplit() throws {
        let f = try Fixture(["a", "b"])
        defer { f.close() }
        try f.present("a")
        #expect(f.stack.overlayFocused)
        f.window.actsAsKey = false
        f.stack.syncFocus()
        #expect(!f.stack.overlayFocused)
        f.window.actsAsKey = true
        f.stack.syncFocus()
        #expect(f.stack.overlayFocused)

        let a = try f.surface("a")
        a.isAgentTerminal = true
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: f.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let titles = try #require(a.menu(for: event)).items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Paste", "Reset Terminal", "Terminal Read-only"])
        for action in [#selector(Ghostty.SurfaceView.splitRight(_:)), #selector(Ghostty.SurfaceView.splitDown(_:)),
                       #selector(Ghostty.SurfaceView.closeSurface(_:)), #selector(Ghostty.SurfaceView.changeTitle(_:))] {
            #expect(!a.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        }
        let b = try f.surface("b")
        #expect(b.validateMenuItem(NSMenuItem(title: "", action: #selector(Ghostty.SurfaceView.splitRight(_:)), keyEquivalent: "")))
    }

    /// Every key typed into the window, Control-C, Escape and the arrows
    /// among them, reaches the presented terminal and no other, agent after
    /// agent.
    @Test func keysReachThePresentedTerminalAndNoOther() async throws {
        let f = try Fixture(["a", "b", "c"])
        defer { f.close() }
        // The login banner on its own line first, as `text(of:)` expects:
        // a key typed before it would share its line.
        for name in ["a", "b", "c"] {
            let surface = try f.surface(name)
            let deadline = Date() + 5
            while Date() < deadline, !surface.cachedVisibleContents.get().contains("Last login:") {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        for name in ["a", "b", "c", "b", "a"] {
            try f.present(name)
            for (code, flags, text) in Self.line(name) {
                try press(code, flags, text, in: f.window)
            }
        }
        let expected = [
            "a": "xa^[^C^[[A^[[B^[[D^[[Cya" + "xa^[^C^[[A^[[B^[[D^[[Cya",
            "b": "xb^[^C^[[A^[[B^[[D^[[Cyb" + "xb^[^C^[[A^[[B^[[D^[[Cyb",
            "c": "xc^[^C^[[A^[[B^[[D^[[Cyc",
        ]
        for (name, line) in expected {
            let surface = try f.surface(name)
            let deadline = Date() + 5
            var text = ""
            while Date() < deadline {
                text = Self.text(of: surface)
                if text == line { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(text == line, "\(name)")
        }
    }

    /// A terminal's line: x and its name, Escape, Control-C, up, down,
    /// left, right, y and its name.
    private static func line(_ name: String) -> [(CGKeyCode, CGEventFlags, String?)] {
        let letter: [String: CGKeyCode] = ["a": 0, "b": 11, "c": 8, "x": 7, "y": 16]
        return [
            (letter["x"]!, [], "x"), (letter[name]!, [], name),
            (53, [], nil), (8, .maskControl, nil),
            (126, [], nil), (125, [], nil), (123, [], nil), (124, [], nil),
            (letter["y"]!, [], "y"), (letter[name]!, [], name),
        ]
    }

    /// The terminal's text, its lines joined, trailing blanks dropped,
    /// without the login banner.
    private static func text(of surface: Ghostty.SurfaceView) -> String {
        surface.cachedVisibleContents.get()
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("Last login:") }
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined()
    }

    /// A key press as the harness gives one (`AgentHarness.press`): the key
    /// down to the window's key equivalents, then the menus', then the window
    /// itself, which passes it to its first responder; the key up to the
    /// window. The app's own `NSApp.sendEvent` and its local monitors need a
    /// key window, which the test host never has; AppDelegate's monitor
    /// leaves every key alone while the agent window is main.
    private func press(_ code: CGKeyCode, _ flags: CGEventFlags, _ text: String?, in window: NSWindow) throws {
        for down in [true, false] {
            let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
            cgEvent.flags = flags
            cgEvent.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if let text {
                let units = Array(text.utf16)
                cgEvent.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            let event = try #require(NSEvent(cgEvent: cgEvent))
            if down, window.performKeyEquivalent(with: event)
                || NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                continue
            }
            window.sendEvent(event)
        }
    }
}

/// A window that never shows, whatever AppKit does to its alpha, for a
/// sheet in the test host.
private final class InvisibleWindow: NSWindow {
    override var alphaValue: CGFloat {
        get { 0 }
        set {}
    }
    override var ignoresMouseEvents: Bool {
        get { true }
        set {}
    }
}
