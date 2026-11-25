import AppKit
import Testing
@testable import Ghostty

/// The fixes of the last review (`neon/review-final.md`, rulings 1 to 9):
/// saving, the older build's data, quitting, settled agents, keys and
/// motion.
@MainActor
struct AgentLastReviewTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-last-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setWritable(_ url: URL, _ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o700 : 0o500], ofItemAtPath: url.path)
    }

    /// Ruling 1: a write of `agents.json` that fails leaves memory as the
    /// truth: nothing reloads the file over it, an outside edit is not read
    /// while the change is unsaved, and the next change, or quitting, writes
    /// it; only a write that succeeded says what the file holds.
    @Test func aFailedSaveKeepsMemoryAndIsWrittenAgain() async throws {
        let base = try folder()
        defer {
            try? setWritable(base.appendingPathComponent("root"), true)
            try? FileManager.default.removeItem(at: base)
        }
        let root = AgentDataRoot(url: base.appendingPathComponent("root", isDirectory: true))
        let config = AgentConfig(root: root)
        let first = try #require(config.addProject(name: "first", workingDirectory: base.path))
        config.waitForWrites()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!config.unsaved)

        // The folder refuses writes: the change stays in memory, unsaved.
        try setWritable(root.url, false)
        let second = try #require(config.addProject(name: "second", workingDirectory: base.path, after: first))
        try await Task.sleep(for: .milliseconds(100))
        #expect(config.unsaved)
        #expect(config.persistenceErrorMessage != nil)
        #expect(config.projects.map(\.id) == [first, second])
        // The disk takes writes again, and someone else writes the file
        // (here the older content): the watcher does not read it over the
        // unsaved change.
        try setWritable(root.url, true)
        try AgentConfig.atomicWrite(try Data(contentsOf: root.agentsFile) + Data(" ".utf8), to: root.agentsFile)
        try await Task.sleep(for: .milliseconds(300))
        #expect(config.projects.map(\.id) == [first, second])
        #expect(config.unsaved)

        // Quitting writes what memory holds.
        config.waitForWrites()
        let saved = try JSONDecoder().decode(AgentConfigFile.self, from: Data(contentsOf: root.agentsFile))
        #expect(saved.projects.map(\.id) == [first, second])
        try await Task.sleep(for: .milliseconds(100))
        #expect(!config.unsaved)
        #expect(config.persistenceErrorMessage == nil)
    }

    /// Ruling 1: the next change after a failed write writes everything
    /// memory holds; the watcher reads an outside edit only once our writes
    /// are done and nothing is unsaved.
    @Test func theNextChangeWritesWhatAFailedWriteLost() async throws {
        let base = try folder()
        defer {
            try? setWritable(base.appendingPathComponent("root"), true)
            try? FileManager.default.removeItem(at: base)
        }
        let root = AgentDataRoot(url: base.appendingPathComponent("root", isDirectory: true))
        let config = AgentConfig(root: root)
        let first = try #require(config.addProject(name: "first", workingDirectory: base.path))
        config.waitForWrites()
        try setWritable(root.url, false)
        let second = try #require(config.addProject(name: "second", workingDirectory: base.path, after: first))
        try await Task.sleep(for: .milliseconds(100))
        #expect(config.unsaved)
        try setWritable(root.url, true)
        let third = try #require(config.addProject(name: "third", workingDirectory: base.path, after: second))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!config.unsaved)
        let saved = try JSONDecoder().decode(AgentConfigFile.self, from: Data(contentsOf: root.agentsFile))
        #expect(saved.projects.map(\.id) == [first, second, third])
    }

    /// Ruling 2: a `state.json` of an older build that cannot be read is
    /// moved to the backups under its own name and the fold says where; the
    /// app goes on. A record that cannot be read is left as it is and only
    /// its agent goes without a folded record; fork markers are deleted.
    @Test func anUnreadableStateFileIsMovedAside() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = AgentDataRoot(url: base.appendingPathComponent("root", isDirectory: true))
        try FileManager.default.createDirectory(at: root.statusDir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: root.stateFile)
        let fork = root.statusDir.appendingPathComponent("\(UUID().uuidString).fork.json")
        try Data("{}".utf8).write(to: fork)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let moved = try #require(try AgentStateFold.fold(root: root, agents: [UUID()], lastActive: { _ in nil }, now: now))
        #expect(moved == root.backupDir(named: "state-json", date: now))
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("state.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.stateFile.path))
        #expect(!FileManager.default.fileExists(atPath: fork.path))

        // A readable state file with one unreadable record: the others fold.
        let (good, corrupt) = (UUID(), UUID())
        try Data(#"{"running":[]}"#.utf8).write(to: root.stateFile)
        try Data("{".utf8).write(to: AgentRecord.url(corrupt, root.statusDir))
        #expect(try AgentStateFold.fold(root: root, agents: [good, corrupt], lastActive: { _ in nil }, now: now + 1) == nil)
        #expect(try AgentRecord.load(good, from: root.statusDir) != nil)
        #expect(try Data(contentsOf: AgentRecord.url(corrupt, root.statusDir)) == Data("{".utf8))
    }

    /// Ruling 2: an agent whose record cannot be read alone shows a problem
    /// naming the file, and nothing launches or sends to it on a record of
    /// defaults; the others are unaffected.
    @Test func anUnreadableRecordStopsOnlyItsAgent() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let broken = try h.addAgent("Broken")
        let fine = try h.addAgent("Fine")
        try FileManager.default.createDirectory(at: h.root.statusDir, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: AgentRecord.url(broken, h.root.statusDir))
        h.start()
        let agent = try h.agent(broken)
        #expect(agent.record.state == .problem)
        #expect(agent.record.problem?.text?.contains(AgentRecord.url(broken, h.root.statusDir).path) == true)
        #expect(!h.bridge.reaches(broken))
        try h.activate(broken)
        #expect(!h.providers.launchRequests.contains { $0.agentID == broken })
        try h.activate(fine)
        #expect(h.providers.launchRequests.contains { $0.agentID == fine })
    }

    /// Ruling 3: Clawddy's own question whenever an agent works or waits
    /// its turn to start, whatever Ghostty's settings say; nothing to ask
    /// with neither.
    @Test func quittingAsksWhileAgentsWorkOrWaitToStart() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let ids = try (0..<4).map { try h.addAgent("agent \($0)") }
        h.start()
        #expect(h.bridge.quitNotice == nil)
        for id in ids { try h.activate(id) }
        // Three start; the fourth waits its turn.
        #expect(h.bridge.quitNotice == "1 agent waiting its turn to start does not start.")
    }

    /// Ruling 8: Window ▸ Toggle Full Screen (⌃⌘F) and Ghostty's own
    /// full-screen key in an agent's terminal toggle the agent window's full
    /// screen; another window's terminal does not.
    @Test func fullScreenReachesTheAgentWindow() throws {
        final class Probe: AgentWorkspaceWindow {
            var toggles = 0
            override func toggleFullScreen(_ sender: Any?) { toggles += 1 }
        }
        let window = Probe(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable],
                           backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let item = NSMenuItem(title: "Toggle Full Screen", action: #selector(AgentWorkspaceWindow.toggleGhosttyFullScreen(_:)), keyEquivalent: "")
        #expect(window.responds(to: item.action))
        #expect(window.validateMenuItem(item))
        window.toggleGhosttyFullScreen(item)
        #expect(window.toggles == 1)
        let inside = NSView(), elsewhere = NSView()
        window.contentView?.addSubview(inside)
        NotificationCenter.default.post(name: Ghostty.Notification.ghosttyToggleFullscreen, object: inside)
        NotificationCenter.default.post(name: Ghostty.Notification.ghosttyToggleFullscreen, object: elsewhere)
        #expect(window.toggles == 2)
        window.close()
    }
}

extension AgentInteractionTests {
    /// The last review's fixes that need the window.
    @MainActor
    @Suite
    struct LastReview {
        /// Ruling 8: with a text field of Ghostty's over the shown terminal
        /// holding the keys (its search field), the terminal's own keys,
        /// ⌘G, ⇧⌘G and ⇧⌘F among them, are not taken by the app.
        @Test func ghosttysSearchFieldKeepsItsKeys() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 22))
            d.windowController.terminals.stack.addSubview(field)
            #expect(d.window.makeFirstResponder(field))
            #expect(d.controller.keyContext == .inside)
            for chord in [AgentChord.command("g"), .command("g", .shift), .command("f", .shift)] {
                #expect(AgentChords.command(for: chord, in: .inside) == nil)
            }
            field.removeFromSuperview()
        }

        /// Ruling 7: an agent's terminal never rings Ghostty's bell (no
        /// sound, no Dock bounce, no border); a plain terminal still does.
        @Test func anAgentsTerminalRingsNoBell() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "sunrise-tables")
            defer { d.close() }
            let surface = try #require(d.detail.surface(id: try d.id("sunrise-tables")))
            #expect(surface.isAgentTerminal)
            var rang = 0
            let observer = NotificationCenter.default.addObserver(forName: .ghosttyBellDidRing, object: surface, queue: nil) { _ in
                rang += 1
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            Ghostty.App.bellRang(on: surface)
            #expect(rang == 0)
            #expect(!surface.bell)
            // The same view as a plain Ghostty terminal rings.
            surface.isAgentTerminal = false
            defer { surface.isAgentTerminal = true }
            Ghostty.App.bellRang(on: surface)
            #expect(rang == 1)
        }

        /// Ruling 9: settling inside and undoing within the motion ends the
        /// motion at once: the tile shows its agent, not a blank tile.
        @Test func settleInsideThenUndoAtOnce() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "review")
            defer { d.close() }
            d.window.forcesTerminalsVisible = true
            let review = try d.id("review")
            let view = d.windowController.windowView
            try await d.key(2, .maskCommand)
            #expect(view.zoomState.agent == review)
            try await d.key(6, .maskCommand)
            #expect(try !d.h.agent(review).isSettled)
            #expect(view.zoomState.agent == nil)
            let tile = try #require(d.grid.tiles[review])
            #expect(!tile.isZoomed)
            #expect(tile.contentOpacity == 1)
        }

        /// Ruling 9: a row moved by the pointer whose agent leaves the list
        /// ends the drag: the keys are not taken for it any more.
        @Test func aListDragEndsWhenItsRowGoes() async throws {
            let d = try await AgentWorkspaceDriver(.standard, shown: "review")
            defer { d.close() }
            let docs = try d.id("docs")
            let from = try d.point(ofRow: docs)
            try await d.hold(from: from, to: NSPoint(x: from.x, y: from.y - 60))
            #expect(d.windowController.list.isDragging)
            #expect(d.h.bridge.settle(id: docs))
            try await d.settle()
            #expect(!d.windowController.list.isDragging)
            try await d.release(at: from)
        }

        /// Ruling 1: a record that cannot be written puts the sentence in
        /// the top bar, kept until a write succeeds.
        @Test func anUnsavedRecordIsShownUntilItIsWritten() async throws {
            let d = try await AgentWorkspaceDriver(.standard)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.h.root.statusDir.path)
                d.close()
            }
            let review = try d.id("review")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: d.h.root.statusDir.path)
            #expect(d.h.bridge.settle(id: review))
            try await d.waitUntil("the write fails") { !d.h.bridge.unsavedFiles.isEmpty }
            try await d.waitUntil("the notice shows") { d.windowController.topBar.notice == AgentNotices.unsaved }
            #expect(d.windowController.topBar.statusLine == AgentNotices.unsaved)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.h.root.statusDir.path)
            d.h.bridge.unsettle(id: review)
            try await d.waitUntil("the write succeeds") { d.h.bridge.unsavedFiles.isEmpty }
            try await d.waitUntil("the notice goes") { d.windowController.topBar.notice == nil }
        }
    }
}
