import AppKit
import GhosttyKit
import ObjectiveC
import UserNotifications

/// Clawddy Dev started by `macos/harness.nu` with `CLAWDDY_HARNESS=<dir>`:
/// in the background, on data written from a scene, driven through a Unix
/// socket. It never becomes the active app and shows no window to the
/// person (`concealEveryWindow`); the workspace window, also under every
/// normal window and out of every switcher, acts as the key and main window
/// (`AgentWorkspaceWindow.actsAsKey`). It reads and writes Clawddy's data
/// only under `<dir>`:
///
/// - `scene.json`: the scene; `harness.nu help` documents its format
/// - `root/`: the data root, written from the scene when it has no `agents.json`
/// - `work/<project>/`: each project's folder
/// - `bin/`: first on the PATH agent terminals get (stand-in CLIs)
/// - `standin/<session id>.json`: each stand-in's `standin` object from the scene
/// - `control.sock`: one JSON request per line, one JSON reply per line
/// - `pid`: this process, while it runs
/// - pictures `shot` and `frames` write, which must be under `<dir>`
///
/// - `preferences.plist`: the run's preferences, in place of the bundle ID's
///   (`usePreferences`): the window's saved frame, the workspace's drafts,
///   densities and views, as a normal launch keeps them
///
/// The owner's preferences stay as they are; no status item, no window
/// restoration.
@MainActor
final class AgentHarness {
    nonisolated static let environmentKey = "CLAWDDY_HARNESS"

    /// Why `CLAWDDY_HARNESS` cannot be used.
    struct Refused: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// The harness folder of this process, or nil for an ordinary start.
    /// Read once, in main.swift before `ghostty_init` takes its snapshot of
    /// the environment, and removed from it, so no terminal, probe or shell
    /// inherits it.
    nonisolated static let directory: URL? = {
        let value = ProcessInfo.processInfo.environment[environmentKey]
        precondition(unsetenv(environmentKey) == 0, "unsetenv(\(environmentKey)) failed: errno \(errno)")
        do {
            return try resolve(value, bundleIdentifier: Bundle.main.bundleIdentifier)
        } catch {
            fatalError(error.localizedDescription)
        }
    }()

    /// The folder `value` names. Only the production bundle refuses one:
    /// a harness run must never touch the live data or the live CLIs' files.
    nonisolated static func resolve(_ value: String?, bundleIdentifier: String?) throws -> URL? {
        guard let value else { return nil }
        guard !AgentDataRoot.isProductionBundle(bundleIdentifier) else {
            throw Refused(reason: "\(bundleIdentifier ?? "") refuses \(environmentKey): only Clawddy Dev runs as a harness.")
        }
        guard value.hasPrefix("/") else {
            throw Refused(reason: "\(environmentKey) must be an absolute path, not “\(value)”.")
        }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }

    /// Before anything of AppKit runs (main.swift): the harness's own
    /// preferences (`usePreferences`), every window concealed
    /// (`concealEveryWindow`), no activation (`neverActivate`), and no saved
    /// window state restored and none saved: that folder belongs to the
    /// bundle ID, which the owner's own Clawddy Dev shares, and its windows
    /// would come on screen. The default is registered, so it lives only in
    /// this process. (`AgentFinalReviewTests` covers restoration's frame.)
    nonisolated static func prepareProcess(directory: URL) {
        usePreferences(of: directory)
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        concealEveryWindow()
        neverActivate()
    }

    /// The file a harness run keeps its preferences in, in place of the
    /// bundle ID's domain, which the owner's own Clawddy Dev uses.
    nonisolated static func preferencesFile(of directory: URL) -> URL {
        directory.appendingPathComponent("preferences.plist")
    }

    /// Makes `UserDefaults.standard`, for Swift and Objective-C callers
    /// alike, AppKit's saved window frames included, a file under the
    /// harness folder: an absolute path names a preferences file, so the run
    /// saves and reads back everything a normal launch does (the window's
    /// frame, the workspace's drafts, densities and views) and the owner's
    /// preferences are never read or written. `standardUserDefaults` is
    /// replaced through the Objective-C runtime's public functions, before
    /// anything reads a preference. Called once.
    private nonisolated static func usePreferences(of directory: URL) {
        let path = preferencesFile(of: directory).deletingPathExtension().path
        guard let defaults = UserDefaults(suiteName: path) else { fatalError("No preferences at \(path).") }
        let selector = #selector(getter: UserDefaults.standard)
        guard let method = class_getClassMethod(UserDefaults.self, selector) else {
            fatalError("UserDefaults lacks \(selector), which the harness replaces.")
        }
        let standard: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(method, imp_implementationWithBlock(standard))
    }

    /// Makes this process unable to become the active app, or to make any
    /// other app active, so the person's keyboard focus never moves.
    ///
    /// The `.prohibited` activation policy does not ensure it: an unlocked
    /// session lets such an app's `activate(ignoringOtherApps:)` succeed,
    /// as the finder's panel showed. So every in-process way to activate is
    /// replaced: NSApplication's `activateIgnoringOtherApps:` and
    /// `activate` do nothing, its `unhide:` unhides without activating, and
    /// NSRunningApplication's `activateWithOptions:` and
    /// `activateFromApplication:options:` do nothing and return false. Swift
    /// and Objective-C callers alike reach these through Objective-C dispatch,
    /// which finds the replacements. Called once, before AppKit starts.
    private nonisolated static func neverActivate() {
        func replace(_ cls: AnyClass, _ selector: Selector, with block: Any) {
            guard let method = class_getInstanceMethod(cls, selector) else {
                fatalError("\(cls) lacks \(selector), which the harness replaces.")
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        let ignoring: @convention(block) (UnsafeRawPointer, ObjCBool) -> Void = { _, _ in }
        let plain: @convention(block) (UnsafeRawPointer) -> Void = { _ in }
        let unhide: @convention(block) (UnsafeRawPointer, UnsafeRawPointer?) -> Void = { _, _ in
            MainActor.assumeIsolated { NSApp.unhideWithoutActivation() }
        }
        let other: @convention(block) (UnsafeRawPointer, UInt) -> ObjCBool = { _, _ in false }
        let otherFrom: @convention(block) (UnsafeRawPointer, UnsafeRawPointer?, UInt) -> ObjCBool = { _, _, _ in false }
        replace(NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)), with: ignoring)
        replace(NSApplication.self, #selector(NSApplication.activate as (NSApplication) -> () -> Void), with: plain)
        replace(NSApplication.self, #selector(NSApplication.unhide(_:)), with: unhide)
        replace(NSRunningApplication.self, #selector(NSRunningApplication.activate(options:)), with: other)
        replace(NSRunningApplication.self, #selector(NSRunningApplication.activate(from:options:)), with: otherFrom)
    }

    /// Makes every window of this process transparent and blind to the
    /// pointer from the moment it exists, for good, so none can show on the
    /// person's screen for even one frame, whoever creates it and however it
    /// is ordered in: panels that fade themselves in, sheets, alerts, menus,
    /// tooltips, Ghostty's own windows, the system's text input windows.
    ///
    /// Why it holds: every `NSWindow` is made by NSWindow's designated
    /// initializer, which each subclass's initializer must call. Its
    /// implementation is replaced by one that sets the window's alpha to 0
    /// and makes it ignore the pointer before returning, so before any code
    /// holds the window and can order it in. The setters of both properties
    /// are replaced too, so nothing, the animator proxy included, can raise
    /// the alpha or take clicks later. (The window server lists a window that
    /// was never ordered in with alpha 1; AppKit gives it its alpha as it
    /// orders it in, before it is drawn.) The window server draws a window, and
    /// its shadow, multiplied by its alpha, so an alpha of 0 draws nothing;
    /// a window that ignores the pointer passes the person's clicks to the
    /// window under it. Pictures do not need alpha: they draw the layer
    /// tree (`AgentWindowCapture`), and posted events reach a window by its
    /// number. Nothing else of the app reaches the screen in a harness run:
    /// it has no Dock tile, never owns the menu bar, makes no status item and
    /// posts no notification (`AgentHarnessNotifier`).
    ///
    /// The replacement uses the Objective-C runtime's public functions on
    /// public NSWindow methods, only in a harness run, before any window
    /// exists (`prepareProcess`). Called once.
    private nonisolated static func concealEveryWindow() {
        typealias Initializer = @convention(c) (UnsafeRawPointer, Selector, NSRect, UInt, UInt, ObjCBool) -> UnsafeRawPointer?
        typealias SetAlpha = @convention(c) (UnsafeRawPointer, Selector, CGFloat) -> Void
        typealias SetFlag = @convention(c) (UnsafeRawPointer, Selector, ObjCBool) -> Void
        let initSelector = #selector(NSWindow.init(contentRect:styleMask:backing:defer:))
        let alphaSelector = #selector(setter: NSWindow.alphaValue)
        let mouseSelector = #selector(setter: NSWindow.ignoresMouseEvents)
        guard let initMethod = class_getInstanceMethod(NSWindow.self, initSelector),
              let alphaMethod = class_getInstanceMethod(NSWindow.self, alphaSelector),
              let mouseMethod = class_getInstanceMethod(NSWindow.self, mouseSelector)
        else { fatalError("NSWindow lacks the methods the harness replaces.") }
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: Initializer.self)
        let setAlpha = unsafeBitCast(method_getImplementation(alphaMethod), to: SetAlpha.self)
        let setIgnoresMouse = unsafeBitCast(method_getImplementation(mouseMethod), to: SetFlag.self)
        // Raw pointers carry `self` and the result through untouched, so the
        // initializer keeps its reference counting: it consumes `self` and
        // returns the window retained.
        typealias ConcealingInit = @convention(block) (UnsafeRawPointer, NSRect, UInt, UInt, ObjCBool) -> UnsafeRawPointer?
        let concealingInit: ConcealingInit = { window, rect, style, backing, deferred in
            guard let made = initialize(window, initSelector, rect, style, backing, deferred) else { return nil }
            setAlpha(made, alphaSelector, 0)
            setIgnoresMouse(made, mouseSelector, true)
            return made
        }
        let pinnedAlpha: @convention(block) (UnsafeRawPointer, CGFloat) -> Void = { window, _ in
            setAlpha(window, alphaSelector, 0)
        }
        let pinnedMouse: @convention(block) (UnsafeRawPointer, ObjCBool) -> Void = { window, _ in
            setIgnoresMouse(window, mouseSelector, true)
        }
        method_setImplementation(initMethod, imp_implementationWithBlock(concealingInit))
        method_setImplementation(alphaMethod, imp_implementationWithBlock(pinnedAlpha))
        method_setImplementation(mouseMethod, imp_implementationWithBlock(pinnedMouse))
    }

    nonisolated static func root(of directory: URL) -> AgentDataRoot {
        AgentDataRoot(url: directory.appendingPathComponent("root", isDirectory: true))
    }

    let directory: URL
    var root: AgentDataRoot { Self.root(of: directory) }
    var binDirectory: URL { directory.appendingPathComponent("bin", isDirectory: true) }
    /// The Codex configuration whose `notify` each Codex launch's notify
    /// program runs; absent unless a run puts one there, so a harness never
    /// runs the owner's own notify program.
    var codexConfigFile: URL { directory.appendingPathComponent("codex-config.toml") }
    /// agy's data folder: the stand-in's `agy-data` when bin/ holds the
    /// stand-in, else the real agy's own (`--real`).
    var agyDataFolder: URL {
        FileManager.default.fileExists(atPath: binDirectory.appendingPathComponent("agy").path)
            ? directory.appendingPathComponent("agy-data", isDirectory: true)
            : AntigravityProvider.defaultDataFolder
    }
    var socketFile: URL { directory.appendingPathComponent("control.sock") }
    var pidFile: URL { directory.appendingPathComponent("pid") }
    /// Takes the bridge's notifications and announcements in place of the
    /// system, which would show them to the person.
    let notifier = AgentHarnessNotifier()
    private let scene: Scene

    private weak var controller: ClawddyController?
    private var window: AgentWorkspaceWindow?
    private var server: AgentHarnessServer?
    private var hideObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    /// The window was closed (⌘W) and has not been shown again: it then
    /// counts as neither key nor seen, as a closed window on screen.
    private(set) var windowClosed = false
    /// Times the app became active anyway, each undone at once; `state`
    /// reports it, and it must stay 0 (`neverActivate`).
    private var activations = 0
    /// This start wrote the scene: the first on the folder.
    private var wroteScene = false
    /// Menus the bar would have shown (right-click, Control-click, "N
    /// more", VoiceOver's show menu), recorded instead of shown: a menu
    /// holds the run while it is open and could show on the person's
    /// screen. Each: what it was for and its items.
    private var menusShown: [[String: Any]] = []
    /// Folders "Show in Finder" would have shown, and folder panels "Add a
    /// project folder…" would have opened: Finder and the panel would come
    /// on the person's screen.
    private var finderReveals: [String] = []
    private var folderPanels = 0

    /// Reads the scene; on a data root without `agents.json`, the first
    /// start on this folder, writes it there. Call holding the root's lock.
    init(directory: URL) {
        self.directory = directory
        let sceneFile = directory.appendingPathComponent("scene.json")
        do {
            let data = try Data(contentsOf: sceneFile)
            scene = try AgentRecord.decoder.decode(Scene.self, from: data)
            if !FileManager.default.fileExists(atPath: Self.root(of: directory).agentsFile.path) {
                try Self.write(scene: data, into: directory)
                wroteScene = true
            }
        } catch {
            fatalError("Could not set up the harness from \(sceneFile.path): \(error)")
        }
    }

    // MARK: - Scene

    /// The scene's projects and agents, in the terms of what the app stores:
    /// `agents.json` (projects, agents, provider, launch profile), each
    /// agent's saved session, and its record (`AgentRecord`), which a scene
    /// can give whole as `record` or through the prototype's short keys.
    /// `harness.nu help` documents the format.
    struct Scene: Decodable {
        struct Project: Decodable {
            var name: String
            var agents: [Agent]
        }

        struct Agent: Decodable {
            var name: String
            var provider: AgentProviderID?
            /// The session its next launch resumes.
            var session: String?
            /// Its CLI starts when the harness first starts on the folder.
            var running: Bool?
            /// It finished a turn not yet looked at.
            var unread: Bool?
            /// Its name is Clawddy's, which the conversation's title replaces.
            var autoNamed: Bool?
            var launchProfile: AgentLaunchProfile?
            /// Any fields of its record, dates in ISO 8601; the keys below
            /// and those above override them.
            var record: AgentRecord?
            /// The prototype's keys: `working`, `finished`, `asks`, `failed`
            /// or `paused`; whether it is settled; its sentence, which is the
            /// finished agent's last message, the question, the problem's or
            /// the limit's text; its first instruction; what a working agent
            /// does; how long ago its state changed.
            var state: String?
            var settled: Bool?
            var sentence: String?
            var firstInstruction: String?
            var step: String?
            var ageSeconds: Double?

            /// The record this agent starts with, as of `now`.
            func startingRecord(now: Date) throws -> AgentRecord {
                var record = record ?? AgentRecord()
                if record.changedAt == .distantPast { record.changedAt = now }
                if let ageSeconds { record.changedAt = now - ageSeconds }
                if let unread { record.unread = unread }
                if let autoNamed { record.nameSource = autoNamed ? .app : .person }
                if settled == true { record.settledAt = now }
                if let firstInstruction, !firstInstruction.isEmpty {
                    record.firstInstruction = firstInstruction
                    record.firstInstructionAt = record.changedAt
                }
                let text = sentence.flatMap { $0.isEmpty ? nil : $0 }
                switch state {
                case nil: break
                case "working":
                    record.state = .working
                    record.activity = step
                case "finished":
                    record.state = .finished
                    record.lastMessage = text ?? record.lastMessage
                case "asks":
                    record.state = .asks
                    record.question = text ?? record.question
                case "failed":
                    record.state = .problem
                    record.problem = record.problem ?? AgentRecord.Problem(kind: .error, text: text)
                case "paused":
                    record.state = .paused
                    record.limit = record.limit ?? AgentRecord.UsageLimit(message: text)
                case let other?:
                    throw Refused(reason: "Agent “\(name)” has the state “\(other)”, which a scene does not know.")
                }
                return record
            }
        }

        var projects: [Project]
        /// The selected agent, by name or `project/name`.
        var selected: String?
        /// The workspace window's size in points, [width, height].
        var window: [Double]?
    }

    /// Writes `scene` under `directory` as the app keeps its data: projects
    /// and agents through `AgentConfig`, saved sessions through
    /// `AgentSessionStore`, records through `AgentRecord`. Each agent's
    /// `standin` object goes, as it is, to
    /// `standin/<session id>.json`, so an agent with one needs a session.
    static func write(scene data: Data, into directory: URL) throws {
        let scene = try AgentRecord.decoder.decode(Scene.self, from: data)
        let root = root(of: directory)
        let fm = FileManager.default
        let config = AgentConfig(root: root)
        guard config.projects.isEmpty else {
            throw Refused(reason: "\(root.agentsFile.path) already holds projects.")
        }
        let now = Date()
        for project in scene.projects {
            guard !project.name.contains("/") else {
                throw Refused(reason: "Project name “\(project.name)” has a slash.")
            }
            let folder = directory.appendingPathComponent("work", isDirectory: true)
                .appendingPathComponent(project.name, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard config.addProject(name: project.name, workingDirectory: folder.path) != nil else {
                throw Refused(reason: "Project “\(project.name)” was not added: \(config.errorMessage ?? "a duplicate name").")
            }
            for agent in project.agents {
                guard let entry = config.addAgent(
                    project: project.name,
                    name: agent.name,
                    provider: agent.provider ?? .claudeCode,
                    launchProfile: agent.launchProfile ?? AgentLaunchProfile())
                else {
                    throw Refused(reason: "Agent “\(agent.name)” was not added to “\(project.name)”: \(config.errorMessage ?? "a duplicate name").")
                }
                if let session = agent.session {
                    try AgentSessionStore.write(
                        AgentSessionBinding(provider: entry.provider, sessionID: session, launchGeneration: nil),
                        for: entry.id,
                        directory: root.statusDir)
                }
                try AgentRecord.save(agent.startingRecord(now: now), for: entry.id, in: root.statusDir)
            }
        }
        config.waitForWrites()
        try writeStandIns(scene: data, into: directory)
    }

    /// Each agent's `standin` object, unchanged, in `standin/<session id>.json`.
    private static func writeStandIns(scene data: Data, into directory: URL) throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let projects = object?["projects"] as? [[String: Any]] ?? []
        let folder = directory.appendingPathComponent("standin", isDirectory: true)
        for agent in projects.flatMap({ $0["agents"] as? [[String: Any]] ?? [] }) {
            guard let standin = agent["standin"] else { continue }
            guard let session = agent["session"] as? String, AgentSessionStore.valid(session) else {
                throw Refused(reason: "Agent “\(agent["name"] ?? "")” has a standin but no valid session.")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: standin, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("\(session).json"))
        }
    }

    /// The agent `name` names: `project/name`, or the first agent so named.
    static func agent(named name: String, in config: AgentConfig) -> UUID? {
        for project in config.projects + config.removedProjects {
            for agent in project.agents where agent.name == name || "\(project.name)/\(agent.name)" == name {
                return agent.id
            }
        }
        return nil
    }

    // MARK: - Running

    /// Selects the scene's agent, opens the workspace window where no one
    /// sees it, then listens on the socket and writes the pid.
    /// On the first start on the folder, starts the CLIs of the scene's
    /// agents marked `running`, before the app continues those a quit cut
    /// off; a scene's working agent with a CLI is not one of those.
    func startSceneAgents(host: any AgentSurfaceHost) {
        guard wroteScene, let controller else { return }
        for agent in scene.projects.flatMap(\.agents) where agent.running == true {
            guard let id = Self.agent(named: agent.name, in: controller.config),
                  let project = controller.config.project(forAgent: id)
            else { fatalError("The scene's running agent “\(agent.name)” is not in the configuration.") }
            controller.bridge.activateAgent(id: id, host: host, project: project)
        }
    }

    func start(controller: ClawddyController) {
        self.controller = controller
        if let name = scene.selected {
            guard let id = Self.agent(named: name, in: controller.config) else {
                fatalError("The scene selects “\(name)”, which it does not have.")
            }
            guard let project = controller.config.project(forAgent: id)?.id else {
                fatalError("The scene's selected agent “\(name)” has no project.")
            }
            controller.workspaceModel.show(.inside(id), in: project)
        }
        guard let window = controller.showWorkspace(activate: false) as? AgentWorkspaceWindow else {
            fatalError("The workspace window did not open.")
        }
        self.window = window
        controller.revealInFinder = { [weak self] url in self?.finderReveals.append(url.path) }
        controller.askForFolder = { [weak self] _, _ in self?.folderPanels += 1 }
        controller.windowController?.topBar.showMenu = { [weak self] menu, event, view in
            let kind = view is AgentProjectButton ? "project" : view is AgentTopBar ? "bar" : "more"
            self?.menusShown.append([
                "for": kind, "byEvent": event != nil, "control": event?.modifierFlags.contains(.control) ?? false,
                "project": (view as? AgentProjectButton)?.project?.name ?? "", "items": Self.items(of: menu),
            ])
        }
        window.actsAsKey = true
        // The shown terminal draws in the transparent window, for pictures.
        window.forcesTerminalsVisible = true
        // The frame a normal launch opens with (`applyOpeningFrame`: the
        // saved one, else the default), unless this first start on the
        // folder has a scene naming a size, as a person resizing would;
        // transparent already (`concealEveryWindow`), and also under every
        // normal window and out of every switcher.
        if wroteScene, let size = scene.window.map({ NSSize(width: $0[0], height: $0[1]) }) {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        }
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
        // AppKit hides an app shortly after it turns `.prohibited`, and a
        // hidden app's windows are not on screen, where AppKit runs no
        // animation: a toggled sidebar would never move. So whenever the
        // app is hidden it is unhidden, still inactive, and the window is
        // ordered in again, on screen and transparent.
        hideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showUnhidden() }
        }
        showUnhidden()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activations += 1
                NSApp.deactivate()
            }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.windowClosed = true
                window.actsAsKey = false
                window.forcesTerminalsVisible = false
            }
        }
        let server = AgentHarnessServer(socketFile: socketFile) { [weak self] request in
            guard let self else { throw Refused(reason: "The harness has stopped.") }
            return try await self.perform(request)
        }
        self.server = server
        do {
            try "\(getpid())\n".write(to: pidFile, atomically: true, encoding: .utf8)
        } catch {
            fatalError("Could not write \(pidFile.path): \(error)")
        }
    }

    private func showUnhidden() {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard !windowClosed else { return }
        window?.orderBack(nil)
    }

    /// The app shows its window (`ClawddyController.showWorkspace`): a
    /// closed one comes back where the harness keeps it, key and seen again.
    func windowShown() {
        guard windowClosed, let window else { return }
        windowClosed = false
        window.actsAsKey = true
        window.forcesTerminalsVisible = true
        showUnhidden()
    }

    /// Stops listening and removes the socket and the pid file.
    func stop() {
        server?.stop()
        server = nil
        for observer in [hideObserver, activeObserver, closeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        hideObserver = nil
        activeObserver = nil
        closeObserver = nil
        for file in [socketFile, pidFile] {
            do {
                try FileManager.default.removeItemIfPresent(at: file)
            } catch {
                fatalError("Could not remove \(file.path): \(error)")
            }
        }
    }

    // MARK: - Commands

    /// One request: an object with one command as its key. The reply has
    /// `ok`; `state` and `wait` add `state`.
    /// The line as the harness reports it: its text, chip, placeholder,
    /// whether it has the keys, its frame and its height in lines, the
    /// baselines of the chip and the text (window points from the top), the
    /// caret's and the first line's place, marked text.
    private static func describe(line: AgentLineView, window: NSWindow?) -> [String: Any] {
        let field = line.textView
        let baselines = line.baselines
        let height = window?.contentView?.bounds.height ?? 0
        var firstLine: [Double] = []
        var caret: [Double] = []
        if let layout = field.layoutManager, let container = field.textContainer {
            layout.ensureLayout(for: container)
            if layout.numberOfGlyphs > 0 {
                let rect = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                let origin = field.convert(NSPoint(x: rect.minX, y: rect.minY + field.textContainerOrigin.y), to: nil)
                firstLine = [Double(origin.x), Double(height - origin.y)]
            }
            let caretRect = field.firstRect(forCharacterRange: field.selectedRange(), actualRange: nil)
            if let window {
                let local = window.convertFromScreen(caretRect)
                caret = [Double(local.minX), Double(height - local.maxY), Double(local.height)]
            }
        }
        return [
            "text": field.string, "chip": line.chipText, "placeholder": field.placeholder, "hasKeys": line.isFocused,
            "frame": rect(line.frame), "lines": field.lineCount, "marked": field.hasMarkedText(),
            "selected": [field.selectedRange().location, field.selectedRange().length],
            "chipBaseline": Double(height - baselines.chip), "textBaseline": Double(height - baselines.text),
            "firstLine": firstLine, "caret": caret, "canUndo": field.fieldUndo.canUndo, "canRedo": field.fieldUndo.canRedo,
        ]
    }

    /// A menu item's key as the menu shows it: "⌥⌘P".
    static func keyName(_ item: NSMenuItem) -> String {
        let marks: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let names: [String: String] = [
            String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): "←", String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): "→",
            "\u{1b}": "⎋", "\r": "↩", String(Character(UnicodeScalar(NSF2FunctionKey)!)): "F2",
        ]
        let prefix = marks.filter { item.keyEquivalentModifierMask.contains($0.0) }.map(\.1).joined()
        return prefix + (names[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
    }

    /// A menu's items as a person sees them: title (— for a separator),
    /// key and whether it is enabled.
    static func items(of menu: NSMenu) -> [[String: Any]] {
        menu.items.map { item in
            ["title": item.isSeparatorItem ? "—" : item.title, "enabled": item.isEnabled,
             "key": item.keyEquivalent.isEmpty ? "" : keyName(item), "submenu": item.submenu != nil]
        }
    }

    /// Lists `menu`'s items, or chooses the one titled `title` as a click
    /// would; a disabled item does nothing.
    private func choose(_ title: String?, in menu: NSMenu) throws -> [String: Any] {
        guard let title else { return ["ok": true, "items": Self.items(of: menu)] }
        guard let item = menu.items.first(where: { $0.title == title }) else {
            throw Refused(reason: "No item “\(title)”: \(menu.items.map(\.title)).")
        }
        guard item.isEnabled else { return ["ok": true, "enabled": false] }
        menu.performActionForItem(at: menu.index(of: item))
        return ["ok": true, "enabled": true]
    }

    private func perform(_ request: [String: Any]) async throws -> [String: Any] {
        guard request.count == 1, let entry = request.first else {
            throw Refused(reason: "A request is an object with one command, such as {\"state\":true}.")
        }
        let (command, argument) = (entry.key, entry.value)
        switch command {
        case "key":
            guard let chord = argument as? String else { throw Refused(reason: "key takes a chord, such as \"cmd+]\".") }
            let key = try AgentHarnessKeys.chord(chord)
            try await press(key.code, key.flags, text: nil)
        case "keys":
            // Several key presses in quick succession: `gaps` milliseconds
            // before each (0: in the same turn as the one before).
            let options = try object(argument, command)
            guard let chords = options["chords"] as? [String] else { throw Refused(reason: "keys takes {\"chords\":[...],\"gaps\":[ms...]}.") }
            let gaps = options["gaps"] as? [Double] ?? []
            for (index, chord) in chords.enumerated() {
                let gap = index < gaps.count ? gaps[index] : 0
                if gap > 0 { try await Task.sleep(for: .milliseconds(gap)) }
                let key = try AgentHarnessKeys.chord(chord)
                try await press(key.code, key.flags, text: nil)
            }
        case "type":
            guard let text = argument as? String else { throw Refused(reason: "type takes a string.") }
            for character in text {
                let key = try AgentHarnessKeys.key(for: character)
                try await press(key.code, key.flags, text: character == "\n" ? "\r" : String(character))
            }
        case "click":
            // `phase` "down" presses without letting go, for a picture of
            // the pressed state; "up" lets go.
            let options = try object(argument, command)
            let point = try point(options["x"], options["y"], command)
            let count = options["count"] as? Int ?? 1
            let flags = try AgentHarnessKeys.modifiers(options["modifiers"] as? String ?? "")
            let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            let right = (options["button"] as? String) == "right"
            let phase = options["phase"] as? String
            var events: [NSEvent] = []
            for click in 1...max(1, count) {
                if phase != "up" { events.append(try mouse(right ? .rightMouseDown : .leftMouseDown, at: point, modifiers, click)) }
                if phase != "down" { events.append(try mouse(right ? .rightMouseUp : .leftMouseUp, at: point, modifiers, click)) }
            }
            await post(events)
        case "drag":
            let options = try object(argument, command)
            guard let from = options["from"] as? [Double], let to = options["to"] as? [Double],
                  from.count == 2, to.count == 2
            else { throw Refused(reason: "drag takes {\"from\":[x,y],\"to\":[x,y],\"steps\":n}.") }
            let steps = max(1, options["steps"] as? Int ?? 10)
            let start = try point(from[0], from[1], command)
            let end = try point(to[0], to[1], command)
            var events = [try mouse(.leftMouseDown, at: start, [], 1)]
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let at = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                events.append(try mouse(.leftMouseDragged, at: at, [], 1))
            }
            // `"release": false` keeps the button down (a drag still held).
            if options["release"] as? Bool ?? true { events.append(try mouse(.leftMouseUp, at: end, [], 1)) }
            await post(events)
        case "move":
            // The pointer moving across the window: mouse-moved events given
            // to the window, which passes them to the views whose tracking
            // areas hold the point (the window server sends a window that
            // ignores the pointer none), and each point to the window's one
            // authority for hover (`AgentWindowView.pointerMoved`), which
            // the window server would reach through its tracking area.
            let options = try object(argument, command)
            guard let from = options["from"] as? [Double], let to = options["to"] as? [Double],
                  from.count == 2, to.count == 2
            else { throw Refused(reason: "move takes {\"from\":[x,y],\"to\":[x,y],\"steps\":n}.") }
            let steps = max(1, options["steps"] as? Int ?? 10)
            let start = try point(from[0], from[1], command)
            let end = try point(to[0], to[1], command)
            let events = try (0...steps).map { step in
                let t = CGFloat(step) / CGFloat(steps)
                return try mouse(.mouseMoved, at: NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), [], 0)
            }
            let window = try workspace
            for event in events {
                window.sendEvent(event)
                controller?.windowController?.windowView.pointerMoved(to: event.locationInWindow)
            }
        case "timed":
            // How long a key takes to show: until the key's work returns
            // (`handled`), until Core Animation has committed what it changed
            // (`committed`, the frame that shows it with the terminal's kept
            // last frame), and until the terminal shown then draws a new
            // frame of its own (`terminalFrame`, nil when none came within
            // 500 ms).
            guard let chord = argument as? String else { throw Refused(reason: "timed takes a chord, such as \"cmd+]\".") }
            let key = try AgentHarnessKeys.chord(chord)
            let start = DispatchTime.now().uptimeNanoseconds
            func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
            try await press(key.code, key.flags, text: nil)
            let handled = elapsed()
            // `work`: the key's handling and the commit of what it changed
            // (layout, drawing), done now on the main thread: the key's own
            // cost, without the wait for the display's next frame.
            CATransaction.flush()
            let work = elapsed()
            let frameLayer = (controller?.terminals?.stack.presentedSurface?.layer).flatMap(Self.contentLayer(in:))
            let shownContents = frameLayer?.contents.map { ObjectIdentifier($0 as AnyObject) }
            let committed: Double = await withCheckedContinuation { continuation in
                CATransaction.begin()
                CATransaction.setCompletionBlock { continuation.resume(returning: elapsed()) }
                CATransaction.commit()
            }
            var terminalFrame: Double?
            while let frameLayer, elapsed() < 500 {
                if frameLayer.contents.map({ ObjectIdentifier($0 as AnyObject) }) != shownContents {
                    terminalFrame = elapsed()
                    break
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            return ["ok": true, "handled": handled, "work": work, "committed": committed, "terminalFrame": terminalFrame as Any]
        case "command":
            // An Agent menu item chosen, by its command: newCodexAgent,
            // newClaudeAgent.
            guard let name = argument as? String, let controller else { throw Refused(reason: "command takes a command's name.") }
            let commands: [String: AgentCommand] = [
                "newCodexAgent": .newCodexAgent, "newClaudeAgent": .newClaudeAgent, "settle": .settle,
                "removeProject": .removeProject, "findAgent": .findAgent, "undo": .undo, "markUnread": .markUnread,
                "selectWorking": .selectWorking, "smallerTiles": .smallerTiles, "largerTiles": .largerTiles,
                "rename": .rename, "nextWaiting": .nextWaiting,
            ]
            guard let command = commands[name] else { throw Refused(reason: "No command “\(name)”: \(commands.keys.sorted()).") }
            controller.action(for: command, in: controller.keyContext)?()
        case "menuItem":
            // An item of an agent's tile or row menu chosen, as a right-click
            // then a click on it would: {"agent": name, "title": "Rename"}.
            let options = try object(argument, command)
            guard let name = options["agent"] as? String, let title = options["title"] as? String, let controller,
                  let id = controller.bridge.agents.values.first(where: { $0.name == name })?.id
            else { throw Refused(reason: "menuItem takes {\"agent\":name,\"title\":item}.") }
            let menu = controller.rowMenu(for: id)
            guard let item = menu.items.first(where: { $0.title == title }) else {
                throw Refused(reason: "No item “\(title)”: \(menu.items.map { $0.title }).")
            }
            guard item.isEnabled else { return ["ok": true, "enabled": false] }
            menu.performActionForItem(at: menu.index(of: item))
        case "projectMenu":
            // A project's menu, as a right-click on its name (or, with
            // "more": true, its entry's submenu in "N more") shows it:
            // {"project": name} lists its items; with "title", that item is
            // chosen, as a click on it would.
            let options = try object(argument, command)
            guard let name = options["project"] as? String, let controller, let bar = controller.windowController?.topBar,
                  let id = controller.config.projects.first(where: { $0.name == name })?.id
            else { throw Refused(reason: "projectMenu takes {\"project\":name,\"title\":item,\"more\":true}.") }
            let menu: NSMenu
            if options["more"] as? Bool == true {
                guard let entry = bar.moreMenu().items.first(where: { $0.submenu?.items.first?.title == "Go to \(name)" }),
                      let submenu = entry.submenu
                else { throw Refused(reason: "“\(name)” is not in “N more”.") }
                menu = submenu
            } else {
                menu = controller.projectMenu(for: id)
            }
            return try choose(options["title"] as? String, in: menu)
        case "hit":
            // The view a click at a point would reach: its class, and the
            // project when it is a project's name.
            let options = try object(argument, command)
            let at = try point(options["x"], options["y"], command)
            let window = try workspace
            let view = window.contentView?.superview?.hitTest(at)
            return ["ok": true, "view": view.map { String(describing: type(of: $0)) } ?? "",
                    "project": (view as? AgentProjectButton)?.project?.name ?? ""]
        case "barMenu":
            // The menu of the bar's empty part: {"title": item} chooses it.
            let options = try object(argument, command)
            guard let controller else { throw Refused(reason: "The harness has stopped.") }
            return try choose(options["title"] as? String, in: controller.barMenu())
        case "menus":
            // The menu bar's Agent, Edit and Help menus as validated now,
            // each as it is open: each item's title, key, enabled, checked
            // and hidden.
            guard let main = NSApp.mainMenu else { throw Refused(reason: "No main menu.") }
            func items(_ menu: NSMenu) -> [[String: Any]] {
                menu.delegate?.menuWillOpen?(menu)
                defer { menu.delegate?.menuDidClose?(menu) }
                menu.update()
                return menu.items.map { item in
                    var entry: [String: Any] = [
                        "title": item.isSeparatorItem ? "—" : item.title, "enabled": item.isEnabled,
                        "key": item.keyEquivalent.isEmpty ? "" : AgentHarness.keyName(item),
                        "checked": item.state == .on, "hidden": item.isHidden,
                    ]
                    if let submenu = item.submenu { entry["submenu"] = items(submenu) }
                    return entry
                }
            }
            var menus: [String: Any] = [:]
            for title in ["Agent", "Edit", "Help"] {
                if let menu = main.items.first(where: { $0.title == title || $0.submenu?.title == title })?.submenu {
                    menus[title] = items(menu)
                }
            }
            return ["ok": true, "menus": menus]
        case "accessibility":
            // The window as VoiceOver reads it, through the accessibility
            // protocol from inside the app (no permission needed): every
            // element with its role, label, value, whether it is selected
            // and whether it can be pressed.
            let window = try workspace
            var elements: [[String: Any]] = []
            func walk(_ node: Any, depth: Int) {
                guard depth < 14, let element = node as? NSAccessibilityProtocol else { return }
                let object = node as AnyObject
                let isElement = (node as? NSView)?.isAccessibilityElement() ?? true
                if (node as? NSView)?.isHiddenOrHasHiddenAncestor == true { return }
                if isElement, let role = element.accessibilityRole() {
                    elements.append([
                        "role": role.rawValue, "label": element.accessibilityLabel() ?? "",
                        "value": (element.accessibilityValue() as? String) ?? "",
                        "help": element.accessibilityHelp() ?? "",
                        "selected": element.isAccessibilitySelected(),
                        "press": object.responds(to: #selector(NSAccessibilityButton.accessibilityPerformPress)),
                        "depth": depth,
                    ])
                }
                for child in element.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
            }
            walk(window, depth: 0)
            return ["ok": true, "elements": elements]
        case "settleEnd":
            // How long a settled agent's CLI runs on, shortened for a test
            // (the product's is 60 s).
            guard let seconds = (argument as? NSNumber)?.doubleValue, let controller else {
                throw Refused(reason: "settleEnd takes seconds.")
            }
            controller.bridge.settledCLIEnd = seconds
        case "drop":
            // Folders or files dragged over the window and dropped, through
            // the window's dragging protocol methods, as AppKit's dragging
            // session calls them: `phase` "enter" (and stay, for a picture),
            // "drop" (enter then drop) or "exit".
            let options = try object(argument, command)
            guard let paths = options["paths"] as? [String], let view = controller?.windowController?.windowView else {
                throw Refused(reason: "drop takes {\"paths\":[…],\"x\":…,\"y\":…,\"phase\":\"enter\"|\"drop\"|\"exit\"}.")
            }
            let at = try point(options["x"] ?? 500, options["y"] ?? 400, command)
            let drag = AgentHarnessDrag(urls: paths.map { URL(fileURLWithPath: $0) }, at: at, in: try workspace)
            let operation = view.draggingEntered(drag)
            switch options["phase"] as? String ?? "drop" {
            case "enter": break
            case "exit": view.draggingExited(drag)
            default:
                // A refused drop: AppKit tells the window the drag left it,
                // with the button up.
                if operation.isEmpty { view.draggingExited(drag) } else { _ = view.performDragOperation(drag) }
            }
            try await settle()
            return ["ok": true, "operation": Int(operation.rawValue), "outline": view.dropOutline.isShown, "words": view.dropOutline.text]
        case "marked":
            // An input method composing: marked text set straight on the
            // field with the keys, as the system's input method does.
            let options = try object(argument, command)
            guard let text = options["text"] as? String, let field = try workspace.firstResponder as? AgentTextView
            else { throw Refused(reason: "marked takes {\"text\":…,\"selected\":[location,length]} with a field holding the keys.") }
            let range = options["selected"] as? [Int] ?? [(text as NSString).length, 0]
            field.setMarkedText(text, selectedRange: NSRange(location: range[0], length: range[1]), replacementRange: NSRange(location: NSNotFound, length: 0))
            return ["ok": true, "marked": field.hasMarkedText(), "text": field.string]
        case "commit":
            // The input method commits: its text replaces the marked text.
            guard let text = argument as? String, let field = try workspace.firstResponder as? AgentTextView
            else { throw Refused(reason: "commit takes the committed text, with a field holding the keys.") }
            field.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return ["ok": true, "marked": field.hasMarkedText(), "text": field.string]
        case "paste":
            // A paste into the field with the keys, from a pasteboard of the
            // harness's own (the general pasteboard is the person's): text,
            // or file URLs with `files`.
            let options = try object(argument, command)
            guard let field = try workspace.firstResponder as? AgentTextView else { throw Refused(reason: "paste needs a field holding the keys.") }
            let board = NSPasteboard(name: NSPasteboard.Name("clawddy-harness-\(getpid())"))
            board.clearContents()
            if let files = options["files"] as? [String] {
                board.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
                _ = field.readSelection(from: board, type: .fileURL)
            } else if let text = options["text"] as? String {
                board.setString(text, forType: .string)
                _ = field.readSelection(from: board, type: .string)
            }
            board.releaseGlobally()
            return ["ok": true, "text": field.string]
        case "resize":
            let options = try object(argument, command)
            guard let width = (options["width"] as? NSNumber)?.doubleValue,
                  let height = (options["height"] as? NSNumber)?.doubleValue
            else { throw Refused(reason: "resize takes {\"width\":points,\"height\":points}.") }
            let window = try workspace
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: width, height: height)), display: true)
        case "send":
            let options = try object(argument, command)
            guard let name = options["agent"] as? String, let text = options["text"] as? String else {
                throw Refused(reason: "send takes {\"agent\":name,\"text\":text,\"by\":\"app\",\"interrupt\":false}.")
            }
            let by: AgentRecord.Prompt.Sender = options["by"] as? String == "person" ? .person : .app
            let result = try await send(text, to: name, by: by, interrupting: options["interrupt"] as? Bool ?? false)
            return ["ok": true, "result": "\(result)"]
        case "open":
            guard let name = argument as? String, let controller, let id = Self.agent(named: name, in: controller.config)
            else { throw Refused(reason: "open takes an agent's name.") }
            controller.openAgent(id)
        case "start":
            let options = try object(argument, command)
            guard let controller, let detail = controller.terminals,
                  let task = options["task"] as? String, let projectName = options["project"] as? String,
                  let project = controller.config.projects.first(where: { $0.name == projectName })
            else { throw Refused(reason: "start takes {\"project\":name,\"task\":text,\"provider\":\"codex\"}.") }
            let provider = (options["provider"] as? String).flatMap(AgentProviderID.init(rawValue:)) ?? .claudeCode
            guard let entry = controller.bridge.startAgent(
                task: task, provider: provider, launchProfile: AgentLaunchProfile(),
                config: controller.config, project: project, host: detail)
            else { throw Refused(reason: "The agent was not started: \(controller.config.errorMessage ?? "")") }
            return ["ok": true, "name": entry.name]
        case "settle":
            guard let name = argument as? String, let controller, let id = Self.agent(named: name, in: controller.config)
            else { throw Refused(reason: "settle takes an agent's name.") }
            controller.bridge.settle(id: id, includingWorking: true)
        case "cancel":
            guard let name = argument as? String, let controller, let id = Self.agent(named: name, in: controller.config)
            else { throw Refused(reason: "cancel takes an agent's name.") }
            return ["ok": true, "cancelled": controller.bridge.cancelStart(id: id, config: controller.config)]
        case "shot":
            guard let path = argument as? String else { throw Refused(reason: "shot takes a PNG path under \(directory.path).") }
            let window = try workspace
            let picture = try AgentWindowCapture.picture(of: window)
            let file = try output(path)
            try picture.pngData().write(to: file)
            return ["ok": true, "file": file.path, "pixels": [picture.pixelsWide, picture.pixelsHigh],
                    "scale": Double(window.backingScaleFactor),
                    "terminals": AgentWindowCapture.terminalRects(in: window)]
        case "frames":
            let options = try object(argument, command)
            guard let prefix = options["prefix"] as? String, let action = options["action"] as? [String: Any] else {
                throw Refused(reason: "frames takes {\"prefix\":path,\"action\":request,\"ms\":200,\"step\":16}.")
            }
            let duration = (options["ms"] as? NSNumber)?.doubleValue ?? 200
            let step = (options["step"] as? NSNumber)?.doubleValue ?? 16
            let window = try workspace
            // `then`: further requests at moments of animation time, for
            // movements interrupted mid-way.
            let later = (options["then"] as? [[String: Any]] ?? []).map { entry in
                (at: ((entry["at"] as? NSNumber)?.doubleValue ?? 0) / 1000, action: { () async throws in
                    _ = try await self.perform(entry["action"] as? [String: Any] ?? [:])
                })
            }
            let pictures = try await AgentWindowCapture.frames(
                of: window, duration: duration / 1000, step: step / 1000, then: later
            ) {
                _ = try await self.perform(action)
                // What the action changed reaches the views before the first picture.
                try await self.settle()
            }
            let base = try output(prefix)
            var files: [String] = []
            for (index, picture) in pictures.enumerated() {
                let file = URL(fileURLWithPath: base.path + String(format: "-%03d.png", index))
                try picture.pngData().write(to: file)
                files.append(file.path)
            }
            let strip = URL(fileURLWithPath: base.path + "-strip.png")
            try AgentWindowCapture.strip(pictures).pngData().write(to: strip)
            return ["ok": true, "files": files, "strip": strip.path]
        case "flags":
            // Modifier keys pressed or let go, alone: "cmd", or "" for none.
            guard let names = argument as? String else { throw Refused(reason: "flags takes modifiers, such as \"cmd\", or \"\".") }
            let flags = try AgentHarnessKeys.modifiers(names)
            guard let event = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: try workspace.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)
            else { throw Refused(reason: "No flags event.") }
            try workspace.sendEvent(event)
        case "scroll":
            // The person scrolling home: `steps` wheel events of `dy` points
            // each, one every `interval` ms, while a display link stamps each
            // frame the window's display shows; the frame intervals and the
            // main thread's time come back.
            let options = try object(argument, command)
            let steps = options["steps"] as? Int ?? 120
            let dy = (options["dy"] as? NSNumber)?.doubleValue ?? -20
            let interval = (options["interval"] as? NSNumber)?.doubleValue ?? 8
            guard let home = controller?.windowController?.windowView.home else { throw Refused(reason: "No home.") }
            let clock = AgentFrameClock(view: home)
            let cpu = Self.mainThreadCPU()
            // With the display asleep no frame is stamped; then what the main
            // thread did shows instead: each event's handling with the commit
            // it causes, and how late each next step began (the main thread
            // was busy elsewhere).
            var handling: [Double] = []
            var late: [Double] = []
            var last = CACurrentMediaTime()
            for _ in 0..<steps {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: Int32(dy), wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:))
                else { throw Refused(reason: "No scroll event.") }
                let began = CACurrentMediaTime()
                late.append(max(0, (began - last) * 1000 - interval))
                home.scrollWheel(with: event)
                CATransaction.flush()
                handling.append((CACurrentMediaTime() - began) * 1000)
                last = CACurrentMediaTime()
                try await Task.sleep(for: .milliseconds(interval))
            }
            let stamps = clock.stop()
            let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
            let nominal = intervals.sorted().dropFirst(intervals.count / 2).first ?? 0
            return ["ok": true, "frames": stamps.count, "intervalsMs": intervals,
                    "medianMs": nominal, "maxMs": intervals.max() ?? 0,
                    "longFrames": intervals.filter { $0 > nominal * 1.5 }.count,
                    "mainThreadMs": (Self.mainThreadCPU() - cpu) * 1000,
                    "handlingMs": handling, "lateMs": late,
                    "scrolledTo": Double(home.contentView.bounds.minY)]
        case "mainThread":
            // The main thread's CPU time so far, and how many working marks
            // turn; `{"mainThread":{"turning":false}}` stops them first, as a
            // hidden window does.
            if let options = argument as? [String: Any], let turning = options["turning"] as? Bool {
                AgentMarkLayer.setTurning(turning)
            }
            return ["ok": true, "cpuSeconds": Self.mainThreadCPU(), "turning": AgentMarkLayer.turningCount]
        case "motion":
            // A movement as it plays: `action` performed while a display
            // link stamps every frame the window's display shows and reads,
            // at each, the presentation value of `probe.key` of the layer
            // named `probe.layer` (`CALayer.name`); back come the frame
            // intervals, the samples [seconds since the action, value], and
            // the main thread's time over `ms`.
            let options = try object(argument, command)
            guard let action = options["action"] as? [String: Any] else {
                throw Refused(reason: "motion takes {\"action\":request,\"ms\":300,\"probe\":{\"layer\":name,\"key\":keyPath}}.")
            }
            let duration = (options["ms"] as? NSNumber)?.doubleValue ?? 300
            let probe = options["probe"] as? [String: String]
            let window = try workspace
            guard let root = window.contentView?.superview?.layer, let view = window.contentView else { throw Refused(reason: "No layers.") }
            func find(_ name: String, in layer: CALayer) -> CALayer? {
                if layer.name == name { return layer }
                for sublayer in layer.sublayers ?? [] { if let found = find(name, in: sublayer) { return found } }
                return nil
            }
            let start = CACurrentMediaTime()
            var samples: [[Double]] = []
            let clock = AgentFrameClock(view: view)
            clock.onTick = { _ in
                // The presentation value is the one at this moment.
                let stamp = CACurrentMediaTime()
                guard let probe, let name = probe["layer"], let key = probe["key"], let layer = find(name, in: root) else { return }
                if let value = ((layer.presentation() ?? layer).value(forKeyPath: key) as? NSNumber)?.doubleValue {
                    samples.append([stamp - start, value])
                }
            }
            let cpu = Self.mainThreadCPU()
            _ = try await perform(action)
            let left = duration / 1000 - (CACurrentMediaTime() - start)
            if left > 0 { try await Task.sleep(for: .milliseconds(Int(left * 1000))) }
            let stamps = clock.stop()
            let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
            return ["ok": true, "intervalsMs": intervals, "samples": samples,
                    "late": intervals.filter { $0 > 1000 / 120 * 1.5 }.count,
                    "mainThreadMs": (Self.mainThreadCPU() - cpu) * 1000]
        case "curve":
            // The probe's presentation value at each step of animation
            // time after `action`, the clock held as for `frames`.
            let options = try object(argument, command)
            guard let action = options["action"] as? [String: Any], let probe = options["probe"] as? [String: String],
                  let name = probe["layer"], let key = probe["key"]
            else { throw Refused(reason: "curve takes {\"action\":request,\"ms\":200,\"step\":4,\"probe\":{\"layer\":name,\"key\":keyPath}}.") }
            let duration = (options["ms"] as? NSNumber)?.doubleValue ?? 200
            let step = (options["step"] as? NSNumber)?.doubleValue ?? 4
            func find(_ layer: CALayer) -> CALayer? {
                if layer.name == name { return layer }
                for sublayer in layer.sublayers ?? [] { if let found = find(sublayer) { return found } }
                return nil
            }
            let values = try await AgentWindowCapture.values(
                of: try workspace, duration: duration / 1000, step: step / 1000,
                action: {
                    _ = try await self.perform(action)
                    try await self.settle()
                },
                value: { root in
                    find(root).flatMap { (($0.presentation() ?? $0).value(forKeyPath: key) as? NSNumber)?.doubleValue }
                })
            return ["ok": true, "values": values]
        case "atRest":
            // Every layer of the window not at rest: an animation running
            // other than a working mark's turn, a transform or sublayer
            // transform that is not the identity, or the motion's snapshot.
            let window = try workspace
            guard let root = window.contentView?.superview?.layer else { throw Refused(reason: "No layers.") }
            var moving: [String] = []
            func walk(_ layer: CALayer, _ path: String) {
                let here = path + "/" + (layer.name ?? String(describing: type(of: layer)))
                let keys = (layer.animationKeys() ?? []).filter { $0 != "turn" }
                if !keys.isEmpty { moving.append(here + " animating " + keys.joined(separator: ",")) }
                if !CATransform3DIsIdentity(layer.sublayerTransform) { moving.append(here + " sublayerTransform") }
                if !CATransform3DIsIdentity(layer.transform), layer.animation(forKey: "turn") == nil, layer.name != "disk" {
                    moving.append(here + " transform")
                }
                if layer.name == "snapshot" { moving.append(here) }
                for sublayer in layer.sublayers ?? [] { walk(sublayer, here) }
            }
            walk(root, "")
            let zoom = controller?.windowController?.windowView.zoomState.agent != nil
            return ["ok": true, "moving": moving, "zooming": zoom]
        case "reduceMotion":
            // Stands for the system's Reduce Motion, which no test may change:
            // true, false, or null to follow the system.
            AgentMotion.reduceOverride = argument as? Bool
            controller?.windowController?.syncTurning()
            return ["ok": true, "reduced": AgentMotion.reduced]
        case "reopen":
            // A click on the Dock icon with no window shown: the same entry
            // point AppKit calls for it.
            guard let delegate = NSApp.delegate as? AppDelegate else { throw Refused(reason: "No app delegate.") }
            let handled = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            try await settle()
            return ["ok": true, "defaultHandling": handled]
        case "state":
            return ["ok": true, "state": state()]
        case "wait":
            return ["ok": true, "state": try await wait(object(argument, command))]
        case "quitQuestion":
            // What ⌘Q would ask now, without asking it.
            guard let delegate = NSApp.delegate as? AppDelegate else { throw Refused(reason: "No app delegate.") }
            return switch delegate.quitQuestion {
            case .clawddy(let notice): ["ok": true, "asks": "clawddy", "notice": notice]
            case .ghostty: ["ok": true, "asks": "ghostty"]
            case .none: ["ok": true, "asks": "nothing"]
            }
        case "quit":
            // After the reply is written; a harness run is stopped, not asked.
            (NSApp.delegate as? AppDelegate)?.quitsWithoutAsking = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        default:
            throw Refused(reason: "Unknown command “\(command)”: key, type, click, drag, move, timed, resize, send, shot, frames, state, wait, quitQuestion or quit.")
        }
        try await settle()
        return ["ok": true]
    }

    /// A file for a picture: `path` itself, or under the harness folder
    /// when relative, and in either case inside it, whose folders are made.
    private func output(_ path: String) throws -> URL {
        let file = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path))
            .standardizedFileURL
        guard file.path.hasPrefix(directory.path + "/") else {
            throw Refused(reason: "\(file.path) is outside the harness folder \(directory.path).")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return file
    }

    private func object(_ argument: Any, _ command: String) throws -> [String: Any] {
        guard let object = argument as? [String: Any] else { throw Refused(reason: "\(command) takes an object.") }
        return object
    }

    private var workspace: AgentWorkspaceWindow {
        get throws {
            guard let window else { throw Refused(reason: "The workspace window is not open.") }
            return window
        }
    }

    /// `x`, `y` in points from the window's top left, in the window's own
    /// coordinates, which start at its bottom left.
    private func point(_ x: Any?, _ y: Any?, _ command: String) throws -> NSPoint {
        guard let x = (x as? NSNumber)?.doubleValue, let y = (y as? NSNumber)?.doubleValue else {
            throw Refused(reason: "\(command) needs x and y, in points from the window's top left.")
        }
        return NSPoint(x: x, y: try workspace.frame.height - y)
    }

    /// A key press as the app gives one to its key window (the workspace
    /// window, or a panel of the app that is key, such as the finder): the
    /// key down to the window's key equivalents, then the menus', then the
    /// window, which passes it to its first responder; the key up to the
    /// window.
    private func press(_ code: CGKeyCode, _ flags: CGEventFlags, text: String?) async throws {
        let window = try NSApp.keyWindow ?? workspace
        for down in [true, false] {
            guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
                throw Refused(reason: "No key event for key code \(code).")
            }
            cgEvent.flags = flags
            cgEvent.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            // The character itself, whatever the keyboard layout; a key
            // that types none carries what the keyboard gives (Escape
            // "\u{1b}", an arrow its function-key character), as a text
            // view reads it.
            if let characters = text ?? AgentHarnessKeys.characters(for: code) {
                let units = Array(characters.utf16)
                cgEvent.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            guard let event = NSEvent(cgEvent: cgEvent) else { throw Refused(reason: "No NSEvent for key code \(code).") }
            if down, window.performKeyEquivalent(with: event)
                || NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                continue
            }
            window.sendEvent(event)
        }
    }

    private var eventNumber = 0

    private func mouse(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        _ modifiers: NSEvent.ModifierFlags,
        _ clickCount: Int
    ) throws -> NSEvent {
        eventNumber += 1
        let up = type == .leftMouseUp || type == .rightMouseUp
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: try workspace.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: up ? 0 : 1)
        else { throw Refused(reason: "No mouse event at \(point).") }
        return event
    }

    /// Puts `events` on the app's queue, which dispatches them to the window
    /// as it does the hardware's, and returns once a marker put after them
    /// has come off the queue too.
    private func post(_ events: [NSEvent]) async {
        eventNumber += 1
        let token = eventNumber
        let windowNumber = window?.windowNumber ?? 0
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let monitor = AgentHarnessMarker()
            monitor.handle = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
                guard event.data1 == token else { return event }
                if let handle = monitor.handle { NSEvent.removeMonitor(handle) }
                monitor.handle = nil
                continuation.resume()
                return nil
            }
            for event in events { NSApp.postEvent(event, atStart: false) }
            guard let marker = NSEvent.otherEvent(
                with: .applicationDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                subtype: 0,
                data1: token,
                data2: 0)
            else { fatalError("No application-defined event.") }
            NSApp.postEvent(marker, atStart: false)
        }
    }

    /// Lets the run loop turn a few times: SwiftUI applies some updates on
    /// a later turn.
    private func settle() async throws {
        window?.layoutIfNeeded()
        for _ in 0..<3 { try await Task.sleep(for: .milliseconds(20)) }
        window?.layoutIfNeeded()
    }

    /// Types `text` into the agent's terminal as text, not keys, and
    /// submits it with Return, whether or not the terminal is shown.
    /// Text into the agent's CLI through the app's one way in
    /// (`AgentBridge.send`), and how it ended.
    private func send(
        _ text: String, to name: String, by: AgentRecord.Prompt.Sender, interrupting: Bool
    ) async throws -> AgentSendResult {
        guard let controller, let id = Self.agent(named: name, in: controller.config) else {
            throw Refused(reason: "No agent “\(name)”.")
        }
        return await withCheckedContinuation { continuation in
            controller.bridge.send(text, to: id, by: by, interrupting: interrupting) { continuation.resume(returning: $0) }
        }
    }

    /// The CPU time the calling (main) thread has used, user and system.
    static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS, "thread_info failed: \(result)")
        func seconds(_ t: time_value_t) -> Double { Double(t.seconds) + Double(t.microseconds) / 1e6 }
        return seconds(info.user_time) + seconds(info.system_time)
    }

    /// The first layer under `layer` that has contents: where Ghostty puts
    /// each frame of a terminal.
    static func contentLayer(in layer: CALayer) -> CALayer? {
        if layer.contents != nil { return layer }
        for sublayer in layer.sublayers ?? [] {
            if let found = contentLayer(in: sublayer) { return found }
        }
        return nil
    }

    // MARK: - State

    /// The record as the JSON object it is stored as.
    private static func json(_ record: AgentRecord) -> Any {
        do {
            return try JSONSerialization.jsonObject(with: AgentRecord.encoder.encode(record))
        } catch {
            fatalError("The record does not encode: \(error)")
        }
    }

    /// What the person would see and what has the keys, as one JSON object:
    /// the view (home or inside), the current project and the shown agent,
    /// the window's real first responder; per agent the state the window
    /// shows, whether it waits on the person, the sentence, whether it runs,
    /// its terminal (`describe(surface:in:)`, or `none`), whether it has
    /// Ghostty's focus, and that terminal's text as Ghostty reads it
    /// (refreshed at most every 500 ms); what the top bar, the list and the
    /// header show; the notifications the system would have shown; every
    /// window of the app, with its alpha.
    func state() -> [String: Any] {
        guard let controller else { return [:] }
        let config = controller.config
        let bridge = controller.bridge
        let model = controller.workspaceModel
        let terminals = controller.terminals
        let windowController = controller.windowController
        var agents: [[String: Any]] = []
        for project in config.projects + config.removedProjects {
            for entry in project.agents {
                guard let agent = bridge.agents[entry.id] else { continue }
                let surface = terminals?.surface(id: entry.id)
                let sentence = agent.sentence
                let text = surface?.cachedVisibleContents.get() ?? ""
                agents.append([
                    "name": entry.name,
                    "project": project.name,
                    "id": entry.id.uuidString,
                    "provider": entry.provider.rawValue,
                    "state": "\(agent.shownState)",
                    "waiting": agent.record.isWaitingOnYou,
                    "unread": agent.isUnread,
                    "running": agent.isRunning,
                    "process": "\(agent.processState)",
                    "activity": "\(agent.activityState)",
                    "record": Self.json(agent.record),
                    "settled": agent.isSettled,
                    "projectRemoved": config.isRemoved(project: project.id),
                    "inputReady": agent.runtime.inputReady,
                    "heldKeys": controller.heldKeys[entry.id]?.filter(\.isPress).count ?? 0,
                    "sentence": sentence.text,
                    "sentenceByApp": sentence.isAppWritten,
                    "surface": surface.map { Self.describe(surface: $0, in: window) } ?? "none",
                    "focused": surface?.focused ?? false,
                    "terminal": surface.map(Self.measure(surface:)) ?? [:],
                    "text": text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression),
                ])
            }
        }
        let shown = model.shownAgentID
        let responder = window?.firstResponder
        // The window server's list: whether a window is ordered in, which
        // `isVisible` does not say of a window acting as shown.
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreen = Set(listed.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
            .compactMap { $0[kCGWindowNumber as String] as? Int })
        var interface: [String: Any] = [:]
        if let windowController {
            let list = windowController.list
            interface = [
                "listRows": list.order.compactMap { id -> [String: Any]? in
                    guard let row = list.row(of: id) else { return nil }
                    return ["name": bridge.agents[id]?.name ?? "", "frame": Self.rect(row.frame),
                            "current": row.isCurrent, "draws": row.draws, "layouts": row.layouts]
                },
                "listDragging": list.isDragging,
                "regions": windowController.windowView.shownRegions,
                "headerAgent": windowController.header.agentID.flatMap { bridge.agents[$0]?.name } ?? "",
                "notice": windowController.topBar.notice ?? "",
                "waitingCount": windowController.topBar.waitingCount,
                "projects": windowController.topBar.shownProjects.map { project -> [String: Any] in
                    let button = windowController.topBar.button(of: project.id)
                    return ["name": project.name, "waiting": project.waiting, "current": project.isCurrent,
                            "frame": button.map { Self.rect($0.frame) } ?? [],
                            // Where it is on screen now, mid-glide included.
                            "shownX": button.flatMap { $0.layer?.presentation()?.frame.minX }.map(Double.init) ?? -1,
                            "lifted": button?.isLifted ?? false,
                            "label": button?.accessibilityLabel() ?? "", "value": (button?.accessibilityValue() as? String) ?? "",
                            "actions": button?.accessibilityCustomActions()?.map(\.name) ?? []]
                },
                "projectOrder": config.projects.map(\.name),
                // One owner of the keys: the first responder is the one the
                // model names (every soak step asserts it), and how often
                // it had to be given back.
                "focusOwnerHolds": windowController.focusOwnerHolds,
                "focusRepairs": windowController.focusRepairs,
                "barDragging": windowController.topBar.isDragging,
                "more": windowController.topBar.moreButtonFrame.map(Self.rect) ?? [],
                "menusShown": menusShown,
                "finderReveals": finderReveals,
                "folderPanels": folderPanels,
                "statusLine": windowController.topBar.statusLine ?? "",
                "news": windowController.header.newsAgentID.flatMap { bridge.agents[$0]?.name } ?? "",
                "hovered": windowController.windowView.hoveredView.map { String(describing: type(of: $0)) } ?? "",
                "keysPanel": windowController.keysPanel.isShown,
                "tiles": windowController.grid.order.compactMap { id -> [String: Any]? in
                    guard let tile = windowController.grid.tiles[id] else { return nil }
                    return ["name": bridge.agents[id]?.name ?? "", "frame": Self.rect(tile.frame),
                            "selected": tile.isSelected, "cursor": tile.isCursor,
                            "draws": tile.draws, "layouts": tile.layouts,
                            "zoomed": tile.isZoomed, "clamped": tile.holdsClamp,
                            "contentOpacity": tile.contentOpacity, "settledPlace": tile.isSettledPlace]
                },
                "rows": windowController.grid.layout.rows,
                "columns": windowController.grid.layout.columns,
                "gridLayouts": windowController.grid.layouts,
                "tailCost": ["ticks": windowController.tailCost.ticks, "totalMs": windowController.tailCost.totalMs,
                             "maxMs": windowController.tailCost.maxMs, "workingTiles": windowController.tailCost.tiles],
                "turningMarks": AgentMarkLayer.turningCount,
                "line": Self.describe(line: windowController.line, window: window),
                "palette": [
                    "shown": windowController.paletteShown,
                    "mode": windowController.palettePanel.mode == .find ? "find" : "new",
                    "text": windowController.palettePanel.textView.string,
                    "chip": windowController.palettePanel.chipText,
                    "frame": Self.rect(windowController.palettePanel.frame),
                    "highlighted": controller.findHighlight,
                    "rows": controller.findRows.map { row -> [String: Any] in
                        switch row {
                        case let .agent(hit, state, age):
                            ["group": row.group, "name": hit.name, "line": hit.line, "project": hit.project, "age": age,
                             "state": "\(state)", "match": hit.lineMatches.first.map { [$0.location, $0.length] } ?? [],
                             "matches": hit.lineMatches.map { [$0.location, $0.length] }]
                        case let .command(title, key, marks):
                            ["group": row.group, "name": title, "key": key ?? "", "marks": marks.map { [$0.location, $0.length] }]
                        }
                    },
                ] as [String: Any],
                "settledPlaces": windowController.grid.order.filter { windowController.grid.tiles[$0]?.isSettledPlace == true }
                    .compactMap { bridge.agents[$0]?.name },
                "placesWithUndo": windowController.grid.order.filter {
                    windowController.grid.tiles[$0]?.settledPlace.map { !$0.undo.isHidden && !$0.isHidden } == true
                }.compactMap { bridge.agents[$0]?.name },
                "statusUndo": windowController.topBar.showsUndo,
                "settledCount": windowController.line.settledCount,
                "undo": controller.undoMenu.title,
                "dropOutline": windowController.windowView.dropOutline.isShown ? windowController.windowView.dropOutline.text : "",
                "pillBelow": Self.rect(windowController.windowView.pillBelow.frame),
                "pillBelowShown": !windowController.windowView.pillBelow.isHidden,
                "lineFrame": Self.rect(windowController.line.frame),
                "removedProjects": config.removedProjects.map(\.name),
                "dimmedTiles": windowController.grid.tiles.values.filter(\.isDimmed).count,
                "waitingWords": windowController.topBar.waitingWords,
                "walk": model.walk.map { walk -> [String: Any] in
                    ["visited": walk.visited.compactMap { bridge.agents[$0]?.name },
                     "origin": walk.origin.project.flatMap { id in config.projects.first { $0.id == id }?.name } ?? ""]
                } ?? [:],
                "renaming": model.renaming.map { renaming -> [String: Any] in
                    ["agent": bridge.agents[renaming.agent]?.name ?? "", "place": "\(renaming.place)",
                     "text": windowController.nameField.textView.string,
                     "frame": Self.rect(windowController.nameField.frame),
                     "shown": !windowController.nameField.isHidden]
                } ?? [:],
                "homeScroll": Double(windowController.homeScroll),
                "firstLaunchShown": !windowController.windowView.firstLaunch.isHidden,
            ]
        }
        return [
            "pid": Int(getpid()),
            // The system's frontmost app is the one that gets the keys;
            // AppKit's `isActive` can read true for a moment while a panel
            // of this app becomes key, with the frontmost app unchanged.
            "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
            "active": NSApp.isActive,
            "activations": activations,
            "permissionRequests": AgentPermissionRequests.made,
            "windowClosed": windowClosed,
            "terminalWindows": TerminalController.all.count,
            "hidden": NSApp.isHidden,
            "keyWindow": NSApp.keyWindow != nil,
            "view": shown == nil ? "home" : "inside",
            "selected": shown.flatMap { bridge.agents[$0]?.name } ?? "",
            "project": config.projects.first { $0.id == model.currentProjectID }?.name ?? "",
            "providers": Dictionary(uniqueKeysWithValues: bridge.providerHealth.map { provider, health in
                (provider.rawValue, "\(health.installation)")
            }),
            "focus": responder is Ghostty.SurfaceView ? "terminal"
                : responder === windowController?.line.textView ? "line"
                : responder === windowController?.palettePanel.textView ? "palette"
                : responder === windowController?.grid ? "tiles"
                : responder === windowController?.nameField.textView ? "name"
                : responder === window ? "window"
                : (responder as? NSTextView)?.isFieldEditor == true ? "field" : "other",
            "firstResponder": describe(responder),
            "scale": Double(window?.backingScaleFactor ?? 0),
            "window": window.map { [Double($0.frame.width), Double($0.frame.height)] } ?? [],
            // Where the window is and the frame its preferences keep for the
            // next launch (`AgentWorkspaceWindow.frameName`).
            "windowFrame": window.map { Self.rect($0.frame) } ?? [],
            "savedFrame": AgentWorkspaceWindow.savedFrame().map(Self.rect) ?? [],
            "interface": interface,
            "agents": agents,
            "notifications": notifier.posted,
            "windows": NSApp.windows.map {
                ["number": $0.windowNumber, "title": $0.title, "class": String(describing: type(of: $0)),
                 "visible": $0.isVisible, "onScreen": onScreen.contains($0.windowNumber), "alpha": Double($0.alphaValue)]
            },
        ]
    }

    private static func rect(_ rect: NSRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
    }

    /// A terminal's size in points and in cells, and where it last saw the
    /// pointer (`mouseOver`, `mouseAt`), for the hidden terminals' checks.
    static func measure(surface: Ghostty.SurfaceView) -> [String: Any] {
        var out: [String: Any] = [
            "points": [Double(surface.frame.width), Double(surface.frame.height)],
            "mouseOver": surface.mouseOverSurface,
            "trackingAreas": surface.trackingAreas.count,
        ]
        if let location = surface.mouseLocationInSurface { out["mouseAt"] = [Double(location.x), Double(location.y)] }
        if let cSurface = surface.surface {
            let size = ghostty_surface_size(cSurface)
            out["cells"] = [Int(size.columns), Int(size.rows)]
        }
        return out
    }

    /// `visible` (shown and drawing), `occluded` (hidden, drawing stopped),
    /// `shown-occluded` (shown while the window cannot be seen); anything
    /// else breaks `AgentTerminalStack`'s invariant: `detached`,
    /// `hidden-drawing`.
    static func describe(surface: Ghostty.SurfaceView, in window: NSWindow?) -> String {
        guard surface.window != nil, surface.window === window else { return "detached" }
        switch (surface.isHiddenOrHasHiddenAncestor, surface.isWindowVisible) {
        case (false, true): return "visible"
        case (true, false): return "occluded"
        case (false, false): return "shown-occluded"
        case (true, true): return "hidden-drawing"
        }
    }

    /// `terminal:<agent>`, `field` for a text field being edited, `window`,
    /// `none`, or the responder's class.
    private func describe(_ responder: NSResponder?) -> String {
        guard let responder else { return "none" }
        if let surface = responder as? Ghostty.SurfaceView, let controller {
            let id = controller.bridge.agents.keys.first { controller.terminals?.surface(id: $0) === surface }
            return "terminal:" + (id.flatMap { controller.bridge.agents[$0]?.name } ?? "unknown")
        }
        if let editor = responder as? NSTextView, editor.isFieldEditor { return "field" }
        if responder === window { return "window" }
        return String(describing: type(of: responder))
    }

    /// Polls `state` until every key of `condition` but `agent` and
    /// `timeout` matches: in the named agent's entry when `agent` is given,
    /// else at the top. `text` matches when the terminal's text contains
    /// it; any other key when equal.
    private func wait(_ condition: [String: Any]) async throws -> [String: Any] {
        let timeout = (condition["timeout"] as? NSNumber)?.doubleValue ?? 5
        let deadline = Date() + timeout
        let wanted = condition.filter { $0.key != "agent" && $0.key != "timeout" }
        while true {
            let state = state()
            var scope = state
            if let name = condition["agent"] as? String {
                let agents = state["agents"] as? [[String: Any]] ?? []
                scope = agents.first { $0["name"] as? String == name || "\($0["project"] ?? "")/\($0["name"] ?? "")" == name } ?? [:]
            }
            let matches = wanted.allSatisfy { key, value in
                if key == "text", let text = scope[key] as? String, let part = value as? String {
                    return text.contains(part)
                }
                return (scope[key] as? NSObject)?.isEqual(value) == true
            }
            if matches { return state }
            guard Date() < deadline else {
                throw Refused(reason: "Timed out after \(timeout) s waiting for \(condition); state: \(state)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Stamps every frame a view's display shows, from its display link.
@MainActor
final class AgentFrameClock: NSObject {
    private var link: CADisplayLink?
    private(set) var stamps: [CFTimeInterval] = []

    init(view: NSView) {
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Runs at each frame, with its time.
    var onTick: ((CFTimeInterval) -> Void)?

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        onTick?(link.timestamp)
    }

    func stop() -> [CFTimeInterval] {
        link?.invalidate()
        link = nil
        return stamps
    }
}

/// Holds a local event monitor for the closure that removes it.
private final class AgentHarnessMarker {
    var handle: Any?
}

/// What the bridge would have shown or said to the person, kept instead.
@MainActor
final class AgentHarnessNotifier: AgentNotifier {
    private(set) var posted: [String] = []

    func post(_ request: UNNotificationRequest) {
        posted.append("\(request.identifier): \(request.content.title) — \(request.content.body)")
    }

    func removeNotifications(withIdentifiers identifiers: [String]) {
        posted.removeAll { line in identifiers.contains { line.hasPrefix($0 + ":") } }
    }

    func announce(_ message: String) {
        posted.append("announce: \(message)")
    }
}

/// Key codes and modifiers of a US keyboard, by name.
enum AgentHarnessKeys {
    struct Key: Equatable {
        var code: CGKeyCode
        var flags: CGEventFlags
    }

    /// Each character a US key types without Shift, and with it.
    private static let plain: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, " ": 49, "\n": 36, "\t": 48,
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
        "~": "`",
    ]
    private static let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53,
        "esc": 53, "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111,
    ]
    private static let modifierNames: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "shift": .maskShift, "opt": .maskAlternate,
        "option": .maskAlternate, "alt": .maskAlternate, "ctrl": .maskControl, "control": .maskControl,
    ]

    /// The key that types `character` on a US keyboard, with Shift for an
    /// upper-case letter or a shifted symbol.
    static func key(for character: Character) throws -> Key {
        if let code = plain[character] { return Key(code: code, flags: []) }
        let lower = Character(character.lowercased())
        if character.isUppercase, let code = plain[lower] { return Key(code: code, flags: .maskShift) }
        if let base = shifted[character], let code = plain[base] { return Key(code: code, flags: .maskShift) }
        throw AgentHarness.Refused(reason: "No US key types “\(character)”.")
    }

    /// `cmd+shift+]`, `ctrl+c`, `return`, `escape`, `cmd+up`: modifiers
    /// and one key, a character or a key's name, joined by `+`.
    static func chord(_ chord: String) throws -> Key {
        var parts = chord.lowercased().components(separatedBy: "+")
        // "cmd++" ends with the plus key.
        if chord.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let last = parts.last, !last.isEmpty else {
            throw AgentHarness.Refused(reason: "“\(chord)” names no key.")
        }
        let flags = try modifiers(parts.dropLast().joined(separator: "+"))
        if let code = named[last] { return Key(code: code, flags: flags) }
        guard last.count == 1, let character = last.first else {
            throw AgentHarness.Refused(reason: "“\(last)” is not a key.")
        }
        let key = try self.key(for: character)
        return Key(code: key.code, flags: flags.union(key.flags))
    }

    /// What the key with `code` types without modifiers, as the keyboard
    /// reports it.
    static func characters(for code: CGKeyCode) -> String? {
        let special: [CGKeyCode: Int] = [
            36: 0x0D, 48: 0x09, 51: 0x7F, 53: 0x1B, 117: NSDeleteFunctionKey, 115: NSHomeFunctionKey, 119: NSEndFunctionKey,
            116: NSPageUpFunctionKey, 121: NSPageDownFunctionKey, 123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
            125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey, 120: NSF2FunctionKey,
        ]
        if let scalar = special[code].flatMap(UnicodeScalar.init) { return String(Character(scalar)) }
        return plain.first { $0.value == code }.map { String($0.key) }
    }

    /// `cmd+shift` and the like; empty for none.
    static func modifiers(_ names: String) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names.lowercased().components(separatedBy: "+") where !name.isEmpty {
            guard let flag = modifierNames[name] else {
                throw AgentHarness.Refused(reason: "“\(name)” is not a modifier: cmd, shift, opt or ctrl.")
            }
            flags.insert(flag)
        }
        return flags
    }
}

/// A Unix socket server on the main queue: one JSON object per line in,
/// one JSON object per line out, requests of one connection answered in
/// order. Its descriptors close on exec, so no terminal inherits them.
@MainActor
final class AgentHarnessServer {
    typealias Handler = @MainActor ([String: Any]) async throws -> [String: Any]

    private let socketFile: URL
    private let handler: Handler
    private let listener: Int32
    private let acceptSource: DispatchSourceRead
    private var connections: [Int32: Connection] = [:]

    private final class Connection {
        let descriptor: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        var pending: [Data] = []
        var busy = false
        var ended = false

        init(descriptor: Int32) { self.descriptor = descriptor }
    }

    init(socketFile: URL, handler: @escaping Handler) {
        self.socketFile = socketFile
        self.handler = handler
        let path = socketFile.path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        precondition(path.utf8.count < capacity, "\(path) is longer than a socket path can be (\(capacity - 1) bytes).")
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: path.utf8)
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(descriptor >= 0, "socket failed: errno \(errno)")
        precondition(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0, "fcntl failed: errno \(errno)")
        // A socket left by a run that did not stop cleanly.
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0, "bind \(path) failed: errno \(errno)")
        precondition(chmod(path, 0o600) == 0, "chmod \(path) failed: errno \(errno)")
        precondition(listen(descriptor, 8) == 0, "listen failed: errno \(errno)")
        listener = descriptor
        acceptSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        acceptSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.accept() }
        }
        acceptSource.resume()
    }

    func stop() {
        acceptSource.cancel()
        close(listener)
        for connection in connections.values { end(connection) }
        unlink(socketFile.path)
    }

    private func accept() {
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else { return }
        precondition(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0, "fcntl failed: errno \(errno)")
        var on: Int32 = 1
        // A client that leaves early must not stop the app with SIGPIPE.
        precondition(
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
            "setsockopt failed: errno \(errno)")
        let connection = Connection(descriptor: descriptor)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.read(connection) }
        }
        connection.source = source
        connections[descriptor] = connection
        source.resume()
    }

    private func read(_ connection: Connection) {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(connection.descriptor, &bytes, bytes.count)
        if count <= 0 {
            // A last request without its newline still counts.
            if !connection.buffer.isEmpty { connection.pending.append(connection.buffer) }
            connection.buffer = Data()
            connection.ended = true
            connection.source?.cancel()
        } else {
            connection.buffer.append(contentsOf: bytes[0..<count])
            while let newline = connection.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = connection.buffer[connection.buffer.startIndex..<newline]
                connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
                if !line.isEmpty { connection.pending.append(Data(line)) }
            }
        }
        pump(connection)
    }

    private func pump(_ connection: Connection) {
        guard !connection.busy else { return }
        guard !connection.pending.isEmpty else {
            if connection.ended { end(connection) }
            return
        }
        let line = connection.pending.removeFirst()
        connection.busy = true
        Task { @MainActor in
            var reply: [String: Any]
            do {
                guard let request = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw AgentHarness.Refused(reason: "A request is a JSON object.")
                }
                reply = try await handler(request)
            } catch {
                // The caller is told what failed; the app goes on.
                reply = ["ok": false, "error": error.localizedDescription]
            }
            write(reply, to: connection)
            connection.busy = false
            pump(connection)
        }
    }

    private func write(_ reply: [String: Any], to connection: Connection) {
        var data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
        } catch {
            fatalError("A harness reply is not JSON: \(error)")
        }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(connection.descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                // The client has gone: nothing is left to tell it.
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    private func end(_ connection: Connection) {
        connection.source?.cancel()
        connection.source = nil
        if connections.removeValue(forKey: connection.descriptor) != nil {
            close(connection.descriptor)
        }
    }
}

/// A drag of files over the window for the harness's `drop`: what AppKit's
/// dragging session hands the window's dragging protocol methods.
final class AgentHarnessDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    weak var draggingDestinationWindow: NSWindow?

    init(urls: [URL], at location: NSPoint, in window: NSWindow) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("clawddy-harness-drag-\(getpid())"))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
        draggingLocation = location
        draggingDestinationWindow = window
    }

    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
