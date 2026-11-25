import AppKit
import Testing
@testable import Ghostty

/// Drives the real agent window as a person does, inside the test host,
/// which runs in the background and never becomes the active app: the window
/// `ClawddyController.showWorkspace` builds, over a harness's fixture, in the
/// window list but seen by no one (transparent, under every normal window,
/// out of every switcher, not under the real pointer), acting as the key and
/// main window (`AgentWorkspaceWindow.actsAsKey`), with the
/// controller standing in the app delegate's place, so the menus and
/// Ghostty's key routing are the app's. Input is real `NSEvent`s: mouse
/// down, dragged and up at a line's laid-out place, put on the app's own
/// queue, which dispatches them to the window as it does the hardware's;
/// and key presses with their modifiers, which go to the window's key
/// equivalents, the menus and then its first responder, as the app gives a
/// key window's. Nothing comes forward, takes the keys or is seen, nothing is
/// posted system-wide and no accessibility permission is needed. "Has the
/// keys" is the window's first responder.
///
/// An agent that runs in the fixture has a real terminal in the stack running
/// `/bin/cat`, and every launch runs `/bin/cat` too, so "the terminal has the
/// keys" is a real Ghostty surface being first responder. Its state is driven
/// through the harness's terminal reports and hooks.
@MainActor
final class AgentWorkspaceDriver {
    let h: AgentBridgeHarness
    let controller: ClawddyController
    let window: AgentWorkspaceWindow
    let windowController: AgentWindowController
    let detail: AgentTerminalsController
    private let appDelegate: AppDelegate
    private let appController: ClawddyController
    private var eventNumber = 0

    var model: AgentWorkspaceModel { h.workspace }

    /// A workspace with `variant`'s agents, inside `shown` as kept from the
    /// last run, or at home in the first project.
    init(
        _ variant: WorkspaceFixture.Variant = .standard,
        shown: String? = nil,
        states: [String: WorkspaceFixture.Reached] = [:]
    ) async throws {
        h = try AgentBridgeHarness(now: Date() - 4 * 60)
        h.config.removeProject(id: h.config.projects[0].id)
        try WorkspaceFixture.add(variant, to: h, states: states)
        h.providers.prepareLaunch = { _ in
            .success(AgentPreparedLaunch(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                environment: [:],
                metadataAvailability: .waiting))
        }
        appDelegate = try #require(NSApp.delegate as? AppDelegate)
        controller = ClawddyController(
            ghostty: appDelegate.ghostty,
            rootLock: try h.root.lock(),
            config: h.config,
            bridge: h.bridge,
            workspaceModel: h.workspace,
            notifier: AgentUserNotificationCenter(),
            isTestHost: true,
            isProduction: false)
        controller.wireWorkspace()
        if let shown {
            let id = try WorkspaceFixture.id(of: shown, in: h)
            h.workspace.show(.inside(id), in: try #require(h.config.project(forAgent: id)).id)
        }

        appController = appDelegate.clawddy
        appDelegate.clawddy = controller
        controller.installAgentMenu()

        // The window restores its last frame from this.
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame AgentWorkspace")
        window = try #require(controller.showWorkspace(activate: false) as? AgentWorkspaceWindow)
        window.actsAsKey = true
        window.forcesTerminalsVisible = true
        windowController = try #require(controller.windowController)
        detail = try #require(controller.terminals)
        window.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 700), display: false)
        // In the window list, so that it takes clicks and drags, and seen by
        // no one: transparent, under every normal window, out of every
        // switcher, not under the real pointer, never key in fact.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
        window.orderBack(nil)

        // What runs has its terminal.
        for id in h.bridge.agents.keys where h.host.hasSurface(id: id) {
            #expect(detail.showOrSwitch(
                agent: try h.agent(id),
                focusTerminal: false,
                select: false,
                createConfig: { Self.terminal }))
        }
        if let id = h.workspace.shownAgentID {
            detail.show(id)
            detail.focusTerminal()
        }
        try await settle()
    }

    /// A terminal that waits for input, as a provider does at its prompt.
    static var terminal: Ghostty.SurfaceConfiguration {
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = "/bin/cat"
        return configuration
    }

    /// Puts the app back as it was. The bridge stops first, so nothing
    /// reacts to its terminals closing. Nothing came forward, took the keys
    /// or was seen: the app is not active, no window is key, and every
    /// window in the list is transparent.
    func close() {
        #expect(!NSApp.isActive, "the test host became the active app")
        #expect(NSApp.keyWindow == nil, "a window took the keys")
        #expect(NSApp.windows.filter(\.isVisible).allSatisfy { $0.alphaValue == 0 }, "a window could be seen")
        let ids = Array(h.bridge.agents.keys)
        h.remove()
        for id in ids { detail.removeSurface(id: id) }
        window.actsAsKey = false
        window.forcesTerminalsVisible = false
        // The next test's window takes the saved frame's name.
        window.setFrameAutosaveName("")
        window.close()
        NSApp.mainMenu?.items.removeAll { $0.title == "Agent" }
        appDelegate.clawddy = appController
    }

    // MARK: Finding

    func id(_ name: String) throws -> UUID {
        try WorkspaceFixture.id(of: name, in: h)
    }

    func project(_ name: String) throws -> UUID {
        try #require(h.config.projects.first { $0.name == name }).id
    }

    /// The middle of an agent's row in the list, in the window's
    /// coordinates.
    func point(ofRow id: UUID) throws -> NSPoint {
        let row = try #require(windowController.list.row(of: id), "no row for \(id)")
        return row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
    }

    /// The middle of "All of <project>".
    var backRowPoint: NSPoint {
        let back = windowController.list.back
        return back.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), to: nil)
    }

    /// The tiles at home.
    var grid: AgentHomeGrid { windowController.grid }

    /// The selected tiles' names, the cursor's first.
    var selectedNames: [String] {
        let selection = grid.selection
        let names = grid.order.filter(selection.selected.contains).compactMap { h.bridge.agents[$0]?.name }
        let cursor = selection.cursor.flatMap { h.bridge.agents[$0]?.name }
        guard let cursor else { return names }
        return [cursor] + names.filter { $0 != cursor }
    }

    /// The agents' names in the list, in its order.
    var rowNames: [String] {
        windowController.list.order.compactMap { h.bridge.agents[$0]?.name }
    }

    /// What has the keys.
    var firstResponder: NSResponder? { window.firstResponder }

    /// The shown agent's terminal has the keys.
    var terminalHasKeys: Bool {
        guard let surface = window.firstResponder as? Ghostty.SurfaceView,
              let shown = model.shownAgentID
        else { return false }
        return detail.activeID == shown && surface === detail.surface(id: shown)
    }

    /// Which agent's terminal the window's first responder is, if one is.
    var terminalWithKeys: String {
        guard let surface = window.firstResponder as? Ghostty.SurfaceView else { return "none" }
        let shown = h.bridge.agents.values.filter { detail.hasSurface(id: $0.id) }.map(\.name)
        return "a terminal in \(String(describing: surface.window)), in the pane: \(surface.isDescendant(of: detail.view)), panes \(shown), active \(String(describing: detail.activeID.flatMap { h.bridge.agents[$0]?.name }))"
    }

    // MARK: Input

    /// A click at a point of the window.
    func click(at point: NSPoint) async throws {
        try await send([
            mouse(.leftMouseDown, at: point),
            mouse(.leftMouseUp, at: point),
        ])
    }

    /// A press at `from`, the pointer dragged to `to` in steps, and let go.
    func drag(from: NSPoint, to: NSPoint, steps: Int = 8) async throws {
        var events = [try mouse(.leftMouseDown, at: from)]
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            events.append(try mouse(.leftMouseDragged, at: NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
        }
        events.append(try mouse(.leftMouseUp, at: to))
        try await send(events)
    }

    /// A press at `from` and the pointer dragged to `to` in steps, not let go.
    func hold(from: NSPoint, to: NSPoint, steps: Int = 4) async throws {
        var events = [try mouse(.leftMouseDown, at: from)]
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            events.append(try mouse(.leftMouseDragged, at: NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
        }
        try await send(events)
    }

    /// The middle of an agent's tile, in the window's coordinates.
    func point(ofTile id: UUID) throws -> NSPoint {
        let tile = try #require(grid.tiles[id])
        return tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
    }

    /// A right-click at a point of the window: the view the window sends it
    /// to, which a test asks instead of opening the menu (a context menu's
    /// tracking would hold the test).
    func rightClickTarget(at point: NSPoint) -> NSView? {
        windowController.windowView.hitTest(windowController.windowView.superview?.convert(point, from: nil) ?? point)
    }

    /// The pointer moved to a point of the window, as the window's one
    /// pointer authority hears it.
    func hover(at point: NSPoint) {
        windowController.windowView.pointerMoved(to: point)
    }

    /// The mouse pressed at a point of the window, and not let go.
    func press(at point: NSPoint) async throws {
        try await send([mouse(.leftMouseDown, at: point)])
    }

    /// The mouse let go at a point of the window.
    func release(at point: NSPoint) async throws {
        try await send([mouse(.leftMouseUp, at: point)])
    }

    /// A key press: `code` with `flags`, as the keyboard makes it, given to
    /// `target`, the workspace window unless another stands for the key
    /// window.
    func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], to target: NSWindow? = nil) async throws {
        deliver(try keyEvent(code, flags, down: true), to: target ?? window)
        deliver(try keyEvent(code, flags, down: false), to: target ?? window)
        try await settle()
    }

    /// A key press handled now, with no turn of the run loop after it: what
    /// the key's own frame holds.
    func keyNow(_ code: CGKeyCode, _ flags: CGEventFlags = []) throws {
        deliver(try keyEvent(code, flags, down: true), to: window)
        deliver(try keyEvent(code, flags, down: false), to: window)
    }

    /// Types `text` through the window's `sendEvent`, as AppKit hands it
    /// the keyboard's keys, where keys for a starting CLI are held.
    func typeThroughWindow(_ text: String) async throws {
        for character in text {
            let code = try #require(Self.keyCodes[character], "no key for \(character)")
            window.sendEvent(try keyEvent(code, [], down: true))
            window.sendEvent(try keyEvent(code, [], down: false))
        }
        try await settle()
    }

    /// Types `text`, one key per character.
    func type(_ text: String, to target: NSWindow? = nil) async throws {
        for character in text {
            let code = try #require(Self.keyCodes[character], "no key for \(character)")
            deliver(try keyEvent(code, [], down: true), to: target ?? window)
            deliver(try keyEvent(code, [], down: false), to: target ?? window)
        }
        try await settle()
    }

    /// Esc put on the app's queue, where the app's event monitors see it,
    /// as a drag's does; with no key window, the app dispatches it nowhere
    /// else.
    func escapeThroughTheQueue() async throws {
        try await post([keyEvent(Self.escape, [], down: true), keyEvent(Self.escape, [], down: false)])
    }

    /// A key event as the app gives it to its key window: a key down to the
    /// window's key equivalents, then the menus', then, as the window does,
    /// its first responder, which a window off screen does not do itself.
    private func deliver(_ event: NSEvent, to target: NSWindow) {
        switch event.type {
        case .keyDown:
            if target.performKeyEquivalent(with: event) || NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return
            }
            target.firstResponder?.keyDown(with: event)
        default:
            target.firstResponder?.keyUp(with: event)
        }
    }

    static let returnKey: CGKeyCode = 36
    static let escape: CGKeyCode = 53
    static let upArrow: CGKeyCode = 126
    static let downArrow: CGKeyCode = 125
    static let leftArrow: CGKeyCode = 123
    static let rightArrow: CGKeyCode = 124
    /// The keys of `type`, on a US layout.
    private static let keyCodes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, " ": 49, "-": 27,
    ]

    private func keyEvent(_ code: CGKeyCode, _ flags: CGEventFlags, down: Bool) throws -> NSEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = flags
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        // The characters the key types (Escape "\u{1b}", Return "\r", an
        // arrow's function-key character), as a text view reads them.
        if let characters = AgentHarnessKeys.characters(for: code) {
            let units = Array(characters.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        return try #require(NSEvent(cgEvent: event))
    }

    private func mouse(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        modifiers: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) throws -> NSEvent {
        eventNumber += 1
        return try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1))
    }

    /// Mouse events to the window, through the app's queue, which sets
    /// them as the current event as it dispatches them.
    func send(_ events: [NSEvent]) async throws {
        try await post(events)
    }

    /// Puts `events` on the app's queue and waits until the app has taken
    /// them off and dispatched them: a marker event put after them has come
    /// off too. Then lets SwiftUI and the run loop catch up.
    func post(_ events: [NSEvent]) async throws {
        let marker = MarkerWatch(window: window)
        defer { marker.stop() }
        for event in events { NSApp.postEvent(event, atStart: false) }
        NSApp.postEvent(try marker.event(), atStart: false)
        try await waitUntil("the app dispatches the events") { marker.seen }
        try await settle()
    }

    /// Lets the run loop turn a few times: the views follow what they
    /// observe on a later turn.
    func settle() async throws {
        window.layoutIfNeeded()
        for _ in 0..<3 { try await Task.sleep(for: .milliseconds(20)) }
        window.layoutIfNeeded()
    }

    /// Waits for `condition`, for at most `seconds`.
    func waitUntil(_ what: String, seconds: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date() + seconds
        while !condition() {
            try #require(
                Date() < deadline,
                "timed out waiting until \(what); active \(NSApp.isActive), key \(String(describing: NSApp.keyWindow)), main \(String(describing: NSApp.mainWindow)), frontmost \(String(describing: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Watches for an application-defined marker event coming off the app's
/// queue.
@MainActor
private final class MarkerWatch {
    private static var next = 0
    private let token: Int
    private let windowNumber: Int
    private(set) var seen = false
    private var monitor: Any?

    init(window: NSWindow) {
        Self.next += 1
        token = Self.next
        windowNumber = window.windowNumber
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self, token] event in
            guard event.data1 == token else { return event }
            MainActor.assumeIsolated { self?.seen = true }
            return nil
        }
    }

    func event() throws -> NSEvent {
        try #require(NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            subtype: 0,
            data1: token,
            data2: 0))
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
