import AppKit
import Carbon
import SwiftUI
import GhosttyKit
import UserNotifications
import OSLog

private final class ControllerReference: @unchecked Sendable {
    weak var value: ClawddyController?
    init(_ value: ClawddyController) { self.value = value }
}

/// Owns everything Clawddy adds to the app: agent config, bridge, workspace
/// model, the workspace window and detail controller, the search panel, the
/// Agent menu and the status item. `AppDelegate` keeps only lifecycle hooks, so upstream's AppDelegate stays upstream.
@MainActor
final class ClawddyController: NSObject {
    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "Clawddy")

    private let ghostty: Ghostty.App
    /// True inside a test host. Clawddy then never starts: no bridge, status
    /// item, hot key, probes or preferences, and its data root is a fresh
    /// temporary folder.
    private let isTestHost: Bool
    /// True only for the production bundle, the one identity that may take
    /// machine-wide resources and write the providers' global files.
    private let isProduction: Bool
    /// Set when Clawddy Dev runs as a harness (`CLAWDDY_HARNESS`): in the
    /// background, on its own data root, driven through its socket.
    private let harness: AgentHarness?
    /// Open for the life of the process; holds the data root's lock.
    private let rootLock: FileHandle
    let config: AgentConfig
    let bridge: AgentBridge
    let workspaceModel: AgentWorkspaceModel
    private let notifier: AgentUserNotificationCenter
    private(set) lazy var settingsController = SettingsController(
        preferencesFile: config.root.preferencesFile) { [weak self] in self?.preferences = $0 }
    /// The agent defaults, read from disk once, at their first use, and kept
    /// as they are saved (ruling 12). Unreadable preferences give the least
    /// permissive start mode, as `AgentPreferencesStore` says, and are
    /// logged.
    private lazy var preferences: AgentPreferences = {
        let loaded = AgentPreferencesStore.load(from: config.root.preferencesFile)
        if let error = loaded.error { Self.logger.error("\(error, privacy: .public)") }
        return loaded.preferences
    }()

    /// Fires when the number of waiting agents changes: the app sets its
    /// Dock badge.
    var onWaitingCountChanged: (() -> Void)?

    private(set) var workspaceWindow: NSWindow?
    /// The agent window's content: top bar, list, header, screen.
    private(set) var windowController: AgentWindowController?
    /// Every agent terminal, and the screen the shown one is in.
    var terminals: AgentTerminalsController? { windowController?.terminals }
    /// Find's words of every agent, kept between keys.
    private let searchIndex = AgentSearchIndex()
    /// What each row of find runs, in the rows' order.
    private var findTargets: [FindTarget] = []
    private(set) var findRows: [AgentPaletteRow] = []
    private(set) var findHighlight = 0
    /// The floating new-agent line's text, per project it was typed in.
    private var floatingDrafts: [UUID: String] = [:]
    private var floatingProject: UUID?
    /// Who had the keys before the palette opened: they go back there when
    /// it closes (flows.md 5).
    private var paletteReturn: AgentFocus = .tiles
    /// Shows a project's folder in Finder; a harness run records it
    /// instead, as Finder would come forward on the person's screen.
    var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// Asks for a folder to add as a project; a harness run records it
    /// instead, as the system's panel would show on the person's screen.
    var askForFolder: (NSWindow, @escaping (URL) -> Void) -> Void = { window, chosen in
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to add as a project"
        panel.prompt = "Add project"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            chosen(url)
        }
    }
    private var workspaceObservers: [NSObjectProtocol] = []
    /// The Agent or Help menu is open (the pointer, the keyboard's menu
    /// navigation or VoiceOver), as opposed to a key's search of the menus.
    private var openMenus = 0
    private var searchHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    convenience init(ghostty: Ghostty.App) {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let isTestHost = AgentDataRoot.isRunningTests(environment: environment)
        let isProduction = AgentDataRoot.isProductionBundle(Bundle.main.bundleIdentifier)
        let harnessDirectory = AgentHarness.directory
        let root = harnessDirectory.map(AgentHarness.root(of:)) ?? AgentDataRoot.resolve(
            directoryName: Bundle.main.object(
                forInfoDictionaryKey: AgentDataRoot.infoKey) as? String,
            isRunningTests: isTestHost,
            homeDirectory: home)
        if !isTestHost, let mismatch = AgentDataRoot.identityMismatch(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            root: root,
            homeDirectory: home) {
            fatalError(mismatch)
        }
        let rootLock: FileHandle
        var harness: AgentHarness?
        if let harnessDirectory {
            // A second instance on a harness root is a mistake to stop on,
            // not to ask about in an alert.
            do {
                rootLock = try root.lock()
            } catch {
                fatalError("Could not lock \(root.lockFile.path): \(error)")
            }
            harness = AgentHarness(directory: harnessDirectory)
        } else {
            rootLock = Self.lockOrExit(root)
        }
        Self.logger.info("data root \(root.url.path, privacy: .public)")

        let notifier = AgentUserNotificationCenter()
        self.init(
            ghostty: ghostty,
            rootLock: rootLock,
            config: AgentConfig(root: root),
            bridge: AgentBridge(
                root: root,
                providers: AgentProviderTable(
                    root: root,
                    // A harness never runs the owner's own Codex notify.
                    codexConfigFile: harness?.codexConfigFile
                        ?? AgentConfig.codexConfigDir.appendingPathComponent("config.toml"),
                    agyDataFolder: harness?.agyDataFolder ?? AntigravityProvider.defaultDataFolder),
                notifier: harness?.notifier ?? notifier),
            workspaceModel: AgentWorkspaceModel(defaults: isTestHost ? nil : .standard),
            notifier: notifier,
            isTestHost: isTestHost,
            isProduction: isProduction,
            harness: harness)
    }

    /// The controller over parts already made: the app's, on its data root,
    /// or a test's, on a temporary one, which then drives the real window.
    init(
        ghostty: Ghostty.App,
        rootLock: FileHandle,
        config: AgentConfig,
        bridge: AgentBridge,
        workspaceModel: AgentWorkspaceModel,
        notifier: AgentUserNotificationCenter,
        isTestHost: Bool,
        isProduction: Bool,
        harness: AgentHarness? = nil
    ) {
        self.ghostty = ghostty
        self.rootLock = rootLock
        self.config = config
        self.bridge = bridge
        self.workspaceModel = workspaceModel
        self.notifier = notifier
        self.isTestHost = isTestHost
        self.isProduction = isProduction
        self.harness = harness
        super.init()
    }

    /// A second instance on the same root would double-apply every event and
    /// race the first one's writes, so it tells the user and quits before
    /// touching any data.
    private static func lockOrExit(_ root: AgentDataRoot) -> FileHandle {
        do {
            return try root.lock()
        } catch let inUse as AgentDataRoot.InUse {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Clawddy is already running"
            alert.informativeText = inUse.localizedDescription
            alert.runModal()
            exit(1)
        } catch {
            fatalError("Could not lock \(root.lockFile.path): \(error)")
        }
    }

    // MARK: - App hooks

    /// A test host or a harness: the app stays in the background, with the
    /// `.prohibited` activation policy `setup` gives it, whatever the launch
    /// source or the `macos-hidden` setting says.
    nonisolated static var keepsAppInBackground: Bool {
        AgentDataRoot.isRunningTests(environment: ProcessInfo.processInfo.environment)
            || AgentHarness.directory != nil
    }

    /// The dock badge's share: agents waiting for the user.
    var attentionCount: Int { bridge.waitingAgentCount }

    func setup() {
        // A test host runs in the background: it never becomes the active
        // app, so it takes no keys and brings no window forward, Ghostty's
        // first terminal window included, and shows no Dock icon.
        guard !isTestHost else {
            NSApp.setActivationPolicy(.prohibited)
            return
        }

        if let harness {
            startHarness(harness)
            return
        }

        removeOldGlobalHooks()

        bridge.environmentPath = AgentEnvironmentResolver.fallbackPath
        AgentEnvironmentResolver.resolve { [weak self] path in
            self?.bridge.environmentPath = path
        }

        // The Dock badge follows the waiting count; it needs no permission
        // (flows.md 2.1). Wired before the bridge starts, because `start`
        // publishes the count.
        bridge.onWaitingCountChanged = { [weak self] _ in
            self?.onWaitingCountChanged?()
        }
        wireWorkspace()

        // Start the bridge (reconstructs state from disk)
        bridge.start(config: config)

        installAgentMenu()

        // Option-Space belongs to whichever app registers it first, so only
        // the production app claims it.
        if isProduction {
            registerSearchHotKey()
        }
    }

    /// `setup` for a harness run: in the background, like a test host, with
    /// no menu bar item, notification, badge, hot key or global Claude
    /// settings change. Agent terminals find `claude` and `codex` in the
    /// harness's `bin` first.
    private func startHarness(_ harness: AgentHarness) {
        NSApp.setActivationPolicy(.prohibited)
        let bin = harness.binDirectory.path
        bridge.environmentPath = bin + ":" + AgentEnvironmentResolver.fallbackPath
        AgentEnvironmentResolver.resolve { [weak self] path in
            self?.bridge.environmentPath = bin + ":" + path
        }
        wireWorkspace()
        bridge.start(config: config)
        installAgentMenu()
        harness.start(controller: self)
    }

    /// Ties the bridge and the configuration to the workspace: what a test
    /// of the real window needs of `setup`.
    func wireWorkspace() {
        bridge.onKeysReady = { [weak self] id in self?.deliverHeldKeys(of: id) }
        bridge.onKeysNotHeld = { [weak self] id in self?.dropHeldKeys(of: id) }
        bridge.onSurfaceDeath = { [weak self] id in
            // Its last screen is what its tile shows until it runs again.
            self?.saveScreen(of: id)
            self?.dropHeldKeys(of: id)
            self?.terminals?.removeSurface(id: id)
        }
        bridge.onSurfacePresentationChanged = { [weak self] _ in
            self?.updateViewingState()
        }
        bridge.isViewed = { [weak self] id in
            self?.currentlyViewedAgentID() == id
        }
        bridge.notifies = { [weak self] in self?.workspaceModel.notifiesWhenWaiting ?? false }
        bridge.project = { [weak self] id in
            self?.config.project(forAgent: id)
        }
        bridge.onConversationTitle = { [weak self] id, title in
            guard let self else { return }
            // A title that arrives while the person renames the agent waits,
            // and goes if they keep a name (flows.md 4.3).
            if self.workspaceModel.renaming?.agent == id {
                self.workspaceModel.renaming?.waitingTitle = title
                return
            }
            AgentWorkspaceTransactions.adoptTitle(title, of: id, config: self.config, bridge: self.bridge)
        }
        config.onReloaded = { [weak self] in
            guard let self else { return }
            self.bridge.reconcileWithConfig(self.config)
            self.reconcileWorkspace()
        }
        reconcileWorkspace()
    }

    /// Keeps the agent's terminal text, when it has a terminal.
    private func saveScreen(of id: UUID) {
        guard let text = terminals?.screen(id: id) else { return }
        bridge.saveScreen(text, of: id)
    }

    /// The workspace forgets what the configuration no longer has, and a
    /// view inside an agent that is gone or settled becomes home.
    private func reconcileWorkspace() {
        workspaceModel.reconcile(with: config) { [bridge] id in
            bridge.agents[id].map { $0.record.settledAt == nil } ?? false
        }
    }

    /// Claude hooks now travel in each agent's settings overlay, and Codex
    /// reports through each launch's notify program. Entries that older
    /// builds registered globally would record events a second time, so they
    /// go before the first launch. A failure leaves them in place, where the
    /// hook script ignores them because they carry no identity, so it is
    /// logged rather than stopping the app.
    private func removeOldGlobalHooks() {
        let claudeSettings = AgentConfig.claudeConfigDir.appendingPathComponent("settings.json")
        let codexHooks = AgentConfig.codexConfigDir.appendingPathComponent("hooks.json")
        let removals: [(URL, () throws -> Bool)] = [
            (claudeSettings, { [config, isProduction] in
                try ClaudeCodeProvider.removeGlobalHooks(
                    settingsFile: claudeSettings, root: config.root, isProduction: isProduction)
            }),
            (codexHooks, { [config, isProduction] in
                try CodexProvider.removeGlobalHooks(
                    hooksFile: codexHooks, root: config.root, isProduction: isProduction)
            }),
        ]
        for (file, remove) in removals {
            do {
                if try remove() {
                    Self.logger.info("removed old Clawddy hooks from \(file.path, privacy: .public)")
                }
            } catch {
                Self.logger.error(
                    "could not remove old Clawddy hooks from \(file.path, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    func shutdown() {
        harness?.stop()
        // Every running agent's last screen, for its tile at the next start.
        for id in bridge.agents.keys { saveScreen(of: id) }
        windowController?.stop()
        bridge.shutdown()
        // The last changes of agents.json are on disk before the app exits.
        config.waitForWrites()
        workspaceObservers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        if let ref = searchHotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
        }
    }

    func restoreWorkspaceWindow(
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        completionHandler(showWorkspace(activate: false), nil)
    }

    /// Routes a clicked agent notification to its agent, as the user's own
    /// choice: selected, its project opened as section 13 says, and its
    /// terminal given the keys. Returns false for notifications that are not
    /// Clawddy's.
    func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool {
        guard response.notification.request.identifier.hasPrefix("clawddy."),
              let rawID = response.notification.request.content
                .userInfo["clawddy_agent_id"] as? String,
              let id = UUID(uuidString: rawID),
              config.project(forAgent: id) != nil
        else { return agentTerminalNotification(response) }
        openAgent(id)
        return true
    }

    /// A notification an agent's program posted through its terminal
    /// (Ghostty's own, naming the surface): a click goes to that agent,
    /// shown or hidden, with its terminal's keys; Ghostty's own handling
    /// would only look for the surface in its terminal windows. False for
    /// any other surface.
    private func agentTerminalNotification(_ response: UNNotificationResponse) -> Bool {
        let userInfo = response.notification.request.content.userInfo
        guard let surfaceID = (userInfo["surface"] as? String).flatMap(UUID.init(uuidString:)),
              let stack = terminals?.stack,
              let id = stack.agent(ofSurface: surfaceID),
              let surface = stack.surface(id: id)
        else { return false }
        // Forgets the notification, without Ghostty's own move of the keys.
        surface.handleUserNotification(notification: response.notification, focus: false)
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, Ghostty.userNotificationActionShow:
            openAgent(id)
        default:
            break
        }
        return true
    }

    /// Foreground presentation for Clawddy notifications, aligned with the
    /// notification's urgency. Nil for notifications that are not Clawddy's.
    func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions? {
        guard notification.request.identifier.hasPrefix("clawddy.") else { return nil }
        let rawID = notification.request.content.userInfo["clawddy_agent_id"] as? String
        if let id = rawID.flatMap(UUID.init(uuidString:)), currentlyViewedAgentID() == id {
            return []
        }
        // Never a sound (flows.md, "No sounds").
        if notification.request.identifier.hasSuffix(".completed") {
            return [.badge, .list]
        }
        return [.banner, .badge, .list]
    }

    // MARK: - Menu, hot key

    private func registerSearchHotKey() {
        let hotKeyID = EventHotKeyID(signature: 0x4147_4E54, id: 1) // "AGNT"
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
                appDelegate.clawddy.showFind()
            }
            return noErr
        }

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(), handler, 1, &eventType, nil, &handlerRef)
        guard installStatus == noErr else {
            Self.logger.error("Unable to install Clawddy search hot-key handler: \(installStatus)")
            return
        }
        eventHandlerRef = handlerRef

        let registrationStatus = RegisterEventHotKey(
            49,
            UInt32(optionKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &searchHotKeyRef)
        if registrationStatus != noErr {
            Self.logger.warning("Unable to register Option-Space for agent search: \(registrationStatus)")
        }
    }

    /// Adds the Agent menu to the main menu, once.
    func installAgentMenu() {
        guard let mainMenu = NSApp.mainMenu,
              !mainMenu.items.contains(where: { $0.title == "Agent" })
        else { return }
        let menu = AgentCommand.menu(target: self, action: #selector(performCommand(_:)))
        menu.addItem(.separator())
        for title in Self.settingsMenus {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: Self.notifyTitle) { [weak self] in self?.toggleNotifications() })
        menu.delegate = self
        let root = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
        root.submenu = menu
        mainMenu.addItem(root)
        // Help ▸ Keys ⌘? (words.md "Other menus"); the controller hears its
        // menu open and close, like the Agent menu's.
        if let help = mainMenu.items.first(where: { $0.submenu?.title == "Help" })?.submenu,
           let item = help.items.first(where: { $0.keyEquivalent == "?" }) {
            item.title = AgentCommand.keys.title
            item.target = self
            item.action = #selector(performCommand(_:))
            item.representedObject = AgentCommand.keys
            help.delegate = self
        }
    }

    private static let settingsMenus = ["New agents use", "Start new agents"]
    private static let notifyTitle = "Notify when an agent is waiting"

    /// The Agent menu's settings, as they are now: the CLI new agents use,
    /// how they start, and whether waiting agents notify.
    private func refreshSettings(in menu: NSMenu) {
        let provider = workspaceModel.newAgentProvider
        let mode = preferences.defaultStartMode(for: provider)
        for item in menu.items {
            switch item.title {
            case Self.settingsMenus[0]:
                item.submenu?.items = AgentProviderID.allCases.map { choice in
                    let entry = NSMenuItem(title: choice.displayName) { [weak self] in self?.setNewAgentProvider(choice) }
                    entry.state = choice == provider ? .on : .off
                    return entry
                }
            case Self.settingsMenus[1]:
                item.submenu?.items = [(AgentStartMode.unrestricted, "Without permission checks"), (.standard, "With permission checks")]
                    .map { choice, title in
                        let entry = NSMenuItem(title: title) { [weak self] in self?.setStartMode(choice) }
                        entry.state = choice == mode ? .on : .off
                        return entry
                    }
            case Self.notifyTitle:
                item.state = workspaceModel.notifiesWhenWaiting ? .on : .off
            default:
                break
            }
        }
    }

    /// "Start new agents": how every new agent starts, whichever CLI.
    private func setStartMode(_ mode: AgentStartMode) {
        var preferences = preferences
        for provider in AgentProviderID.allCases { preferences.setDefaultStartMode(mode, for: provider) }
        do {
            try AgentPreferencesStore.save(preferences, to: config.root.preferencesFile)
            self.preferences = preferences
        } catch {
            Self.logger.error("could not save the start mode: \(error, privacy: .public)")
            say("Could not save the setting. \(error.localizedDescription)", for: 6)
        }
    }

    /// "Notify when an agent is waiting" (flows.md 6.11, off by default):
    /// turning it on asks the system for permission, in context.
    private func toggleNotifications() {
        workspaceModel.notifiesWhenWaiting.toggle()
        guard workspaceModel.notifiesWhenWaiting else { return }
        AgentPermissionRequests.notifications([.alert, .badge], for: "Notify when an agent is waiting")
    }

    // MARK: - Commands

    /// Where the keyboard is in the agent window, for its chords; nil while
    /// the agent window is not main, or a window other than it and the
    /// finder has the keys (a sheet, an alert, another panel): then no chord
    /// of the table acts (`docs/clawddy-design/shortcuts.md` rule 5).
    var keyContext: AgentKeyContext? {
        guard let window = workspaceWindow, window.isMainWindow else { return nil }
        // A harness or test drives the window in an app that is never
        // active, where no window is key.
        if let key = NSApp.keyWindow, key !== window { return nil }
        if let lineView = windowController?.line.textView, window.firstResponder === lineView { return .homeLine }
        if let field = windowController?.palettePanel.textView, window.firstResponder === field { return .palette }
        // Ghostty's search field over the shown terminal is the terminal's
        // own: its keys (next, previous, close) stay Ghostty's (last review
        // ruling 8).
        if let stack = terminals?.stack, let view = window.firstResponder as? NSView, view.isDescendant(of: stack) {
            return .inside
        }
        if AgentKeyEventRoutingPolicy.isTextEditingResponder(window.firstResponder) { return .textField }
        return workspaceModel.shownAgentID == nil ? .homeTiles : .inside
    }

    /// One key-down in the agent window, before any view or the menu sees
    /// it: true when it is a chord of the table for where the keyboard is,
    /// whose command then runs if it has an action where the keys are (F2's
    /// rename waits for S9). A chord the table names never goes on to a
    /// Ghostty binding (S7 review ruling 3).
    func performChord(_ event: NSEvent) -> Bool {
        guard let context = keyContext,
              let chord = AgentChord(event: event),
              let command = AgentChords.command(for: chord, in: context)
        else { return false }
        // The numbers over the tiles go with any chord.
        windowController?.grid.hideNumbers()
        action(for: command, in: context)?()
        return true
    }

    @objc private func performCommand(_ item: NSMenuItem) {
        guard let command = item.representedObject as? AgentCommand else { return }
        action(for: command, in: keyContext)?()
    }

    /// What `command` does where the keyboard is, or nil where it does
    /// nothing yet: the one place a later stage adds a command's action.
    /// `context` is nil for a menu item chosen while the agent window is
    /// not main.
    func action(for command: AgentCommand, in context: AgentKeyContext?) -> (() -> Void)? {
        switch command {
        case .newAgent:
            return { [weak self] in self?.newAgentCommand(provider: nil) }
        case .newAgentWith(let provider):
            return { [weak self] in self?.newAgentCommand(provider: provider) }
        case .addProject:
            return { [weak self] in
                self?.showWorkspace()
                self?.chooseProjectFolder()
            }
        case .nextWaiting:
            return { [weak self] in self?.walkNext() }
        case .previousAgent, .nextAgent:
            return { [weak self] in self?.step(command == .nextAgent ? 1 : -1) }
        case .previousProject, .nextProject:
            return { [weak self] in self?.stepProject(command == .nextProject ? 1 : -1) }
        case .agentAt(let place):
            return { [weak self] in self?.openAgent(at: place) }
        case .backToAllAgents:
            guard context == .inside || context == nil else { return nil }
            return { [weak self] in self?.goHome() }
        case .findAgent:
            return { [weak self] in
                guard let self else { return }
                // ⌘P again closes the palette, whichever mode.
                if self.windowController?.paletteShown == true { return self.closePalette() }
                self.showFind()
            }
        case .moveEarlier, .moveLater:
            guard context == .homeTiles else { return nil }
            return { [weak self] in self?.windowController?.grid.moveSelected(by: command == .moveEarlier ? -1 : 1) }
        case .removeProject:
            guard !config.projects.isEmpty else { return nil }
            return { [weak self] in
                guard let self, let project = self.workspaceModel.currentProjectID else { return }
                self.removeProject(project)
            }
        case .selectWorking:
            guard workspaceModel.currentProjectID != nil else { return nil }
            return { [weak self] in self?.selectWorking() }
        case .startFromFind:
            return { [weak self] in self?.startFromFind() }
        case .undo:
            return { [weak self] in self?.undo(in: context) }
        case .closeWindow:
            // The window closes; its agents keep running.
            return { [weak self] in self?.workspaceWindow?.performClose(nil) }
        case .keys:
            return { [weak self] in
                self?.showWorkspace()
                self?.windowController?.toggleKeys()
            }
        case .showAgents:
            return { [weak self] in self?.showWorkspace() }
        case .nothing:
            return {}
        case .smallerTiles, .largerTiles, .defaultTiles:
            guard context == .homeTiles || context == .homeLine else { return nil }
            return { [weak self] in
                self?.changeDensity(command == .smallerTiles ? 1 : command == .largerTiles ? -1 : nil)
            }
        case .selectAll:
            return { [weak self] in self?.windowController?.grid.selectAll() }
        case .copy:
            return { [weak self] in self?.copySentences() }
        case .rename:
            // The cursor tile at home, the agent shown inside (in the header).
            if let shown = workspaceModel.shownAgentID {
                return { [weak self] in self?.rename(shown, at: .header) }
            }
            guard let project = workspaceModel.currentProjectID, let cursor = workspaceModel.selection(in: project).cursor else { return nil }
            return { [weak self] in self?.rename(cursor, at: .tile) }
        case .interruptAndSend:
            guard context == .homeLine else { return nil }
            return { [weak self] in self?.lineSubmit(interrupting: true) }
        case .settle:
            return { [weak self] in self?.settleCommand() }
        case .markUnread:
            return { [weak self] in self?.markUnreadCommand() }
        }
    }

    /// The agents of the current project as the list shows them.
    private var listedAgents: [UUID] {
        guard let project = config.projects.first(where: { $0.id == workspaceModel.currentProjectID }) else { return [] }
        return project.agents.compactMap { bridge.agents[$0.id] }.filter { $0.record.settledAt == nil }.map(\.id)
    }

    /// The previous or next agent in the list, wrapping, from inside an
    /// agent; passing through starts nothing.
    private func step(_ offset: Int) {
        let ids = listedAgents
        guard !ids.isEmpty else { return }
        let index = workspaceModel.shownAgentID.flatMap(ids.firstIndex(of:))
        let next = index.map { ($0 + offset + ids.count) % ids.count } ?? (offset > 0 ? 0 : ids.count - 1)
        enter(ids[next], deliberately: false)
    }

    /// The previous or next project, wrapping, as it was left.
    private func stepProject(_ offset: Int) {
        let projects = config.projects
        guard !projects.isEmpty else { return }
        let index = projects.firstIndex { $0.id == workspaceModel.currentProjectID }
        let next = index.map { ($0 + offset + projects.count) % projects.count } ?? (offset > 0 ? 0 : projects.count - 1)
        switchProject(projects[next].id)
    }

    /// The agent in that place of the current project's list, opened on
    /// purpose.
    /// At home the places count settled places, and a settled or empty
    /// place does nothing; inside, the rows of the list.
    private func openAgent(at place: Int) {
        let ids = placeIDs
        guard ids.indices.contains(place - 1), bridge.agents[ids[place - 1]]?.isSettled == false else { return }
        openAgent(ids[place - 1])
    }

    /// Opens the agent on purpose (flows.md 4.5): its terminal has the keys,
    /// and its CLI starts at once if it is not running.
    func openAgent(_ id: UUID) {
        enter(id, deliberately: true)
    }

    /// Enters the agent (flows.md 3.3): its project becomes current, its
    /// terminal shows inside, the terminal has the keys, and it is looked
    /// at, which marks a finished, unread agent read. `deliberately` starts
    /// its CLI when it does not run; passing through does not.
    private func enter(_ id: UUID, deliberately: Bool, walking: Bool = false) {
        guard let project = config.project(forAgent: id), let agent = bridge.agents[id] else { return }
        // Entering another way ends the walk (flows.md 6.6).
        if !walking { endWalk() }
        // Entering by any path closes the palette (S7 review ruling 5).
        dismissPalette()
        // A settled agent opened again comes back to its place at home, and
        // a removed project with it to the end of the bar (flows.md 6.8).
        if config.isRemoved(project: project.id) { config.bringBack(project: project.id) }
        if agent.isSettled { bridge.unsettle(id: id) }
        leaveShownAgent(for: id)
        showWorkspace()
        workspaceModel.show(.inside(id), in: project.id)
        terminals?.show(id)
        if deliberately {
            activateAgent(id: id)
        } else {
            terminals?.focusTerminal()
            workspaceModel.setViewingShownAgent(true)
            updateViewingState()
        }
        // The views follow in the frame of the key.
        windowController?.render()
    }

    /// Back to all of the current project's agents (flows.md 3.3).
    private func goHome() {
        guard let project = workspaceModel.currentProjectID else { return }
        endWalk()
        let left = workspaceModel.shownAgentID
        leaveShownAgent(for: nil)
        workspaceModel.show(.home, in: project)
        if let left { workspaceModel.setSelection(.only(left), in: project) }
        windowController?.showHome(selecting: workspaceModel.selection(in: project))
    }

    /// Pinching (flows.md 3.3): apart on a selected tile at home enters it,
    /// on purpose; together inside goes back to all agents.
    private func pinch(apart: Bool) {
        if apart {
            guard workspaceModel.shownAgentID == nil, let project = workspaceModel.currentProjectID,
                  let cursor = workspaceModel.selection(in: project).cursor
            else { return }
            openAgent(cursor)
        } else if workspaceModel.shownAgentID != nil {
            goHome()
        }
    }

    /// One more row of tiles (`rows` 1), one fewer (-1), or the default
    /// (nil), for the current project (flows.md "Home"); at either end
    /// nothing.
    private func changeDensity(_ rows: Int?) {
        guard let project = workspaceModel.currentProjectID, let grid = windowController?.grid else { return }
        let next = rows.map { workspaceModel.density(in: project) + $0 } ?? 0
        workspaceModel.setDensity(grid.layout.clamped(next), in: project)
    }

    /// A printable key on the tiles (flows.md 4.4): with one tile selected,
    /// its terminal opens, on purpose, and the key arrives in its CLI's
    /// input, held while the CLI starts; never into a question's menu. With
    /// none or several selected it goes to the line (S7).
    private func typeOnTiles(_ event: NSEvent) {
        guard let project = workspaceModel.currentProjectID else { return }
        let selection = workspaceModel.selection(in: project)
        guard let id = selection.cursor, selection.selected.count == 1, let agent = bridge.agents[id] else {
            // None or several selected: the key lands in the line, through
            // its input context, so an input method and dead keys work.
            guard let line = windowController?.line.textView else { return }
            windowController?.focus(.line)
            line.keyDown(with: event)
            return
        }
        enter(id, deliberately: true)
        guard agent.record.state != .asks else { return }
        workspaceWindow?.sendEvent(event)
    }

    /// Makes the project current as it was left (flows.md 6.10): inside the
    /// agent it was left in, passed through, or home.
    func switchProject(_ id: UUID) {
        showWorkspace()
        dismissPalette()
        if id != workspaceModel.currentProjectID { workspaceModel.undo.endStarts() }
        endWalk()
        reconcileWorkspace()
        let left = workspaceModel.shownAgentID
        workspaceModel.switchTo(id)
        if let left, left != workspaceModel.shownAgentID { dropHeldKeys(of: left) }
        if let agent = workspaceModel.shownAgentID {
            enter(agent, deliberately: false)
        } else {
            // Home opens with no tile selected (ruling 2); a project with no
            // agents gives the line the keys (flows.md 9).
            workspaceModel.setSelection(AgentTileSelection(), in: id)
                windowController?.showHome(selecting: AgentTileSelection())
            if listedAgents.isEmpty { windowController?.focus(.line) }
        }
    }

    // MARK: - Keys held while a CLI starts

    /// The person leaves the agent shown for `next`: what they typed while
    /// its CLI started is not sent to a terminal they no longer see.
    private func leaveShownAgent(for next: UUID?) {
        guard let shown = workspaceModel.shownAgentID, shown != next else { return }
        dropHeldKeys(of: shown)
    }

    /// Keys typed for each agent whose CLI is starting, in order.
    private(set) var heldKeys: [UUID: [AgentHeldKey]] = [:]
    /// The clipboard a held ⌘V reads; tests give their own.
    var pasteboard = NSPasteboard.general

    /// Holds a key typed into the shown agent's screen while its CLI does
    /// not read its input; the first key typed for an agent whose CLI is not
    /// running starts it (flows.md 4.5, passing through). A key for a
    /// question or dialog its CLI shows is not held: the person must answer
    /// it, and keys typed before it are dropped rather than let one choose
    /// for them (probes.md, P2).
    private func holdKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command) || Self.isPaste(event),
              let window = workspaceWindow, let id = workspaceModel.shownAgentID,
              let agent = bridge.agents[id]
        else { return false }
        let responder = window.firstResponder
        guard responder === window || (responder as? Ghostty.SurfaceView).map({ terminals?.surface(id: id) === $0 }) == true
        else { return false }
        if heldKeys[id] == nil {
            // A key up whose key down went before goes on.
            guard event.type == .keyDown else { return false }
            // The first key typed for an agent whose CLI is not running
            // starts it.
            if agent.surfaceState != .opening && !agent.isRunning && agent.record.state != .asks {
                activateAgent(id: id)
            }
        }
        guard bridge.holdsKeys(for: id) else { return false }
        // A paste is what the clipboard holds when the person presses ⌘V
        // (last review ruling 6), not when the CLI is ready.
        if Self.isPaste(event) {
            guard event.type == .keyDown else { return true }
            heldKeys[id, default: []].append(.paste(pasteboard.string(forType: .string) ?? ""))
        } else {
            heldKeys[id, default: []].append(.key(event))
        }
        return true
    }

    /// ⌘V: a paste, held like a key.
    private static func isPaste(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers == "v"
    }

    /// The agent's CLI reads its input: its held keys go to its terminal, in
    /// the order typed.
    private func deliverHeldKeys(of id: UUID) {
        guard let held = heldKeys.removeValue(forKey: id), bridge.reaches(id), let surface = terminals?.surface(id: id) else { return }
        for key in held {
            guard case .key(let event) = key else {
                if case .paste(let text) = key, !text.isEmpty { surface.surfaceModel?.sendText(text) }
                continue
            }
            if let window = workspaceWindow, window.firstResponder === surface {
                window.sendEvent(event)
            } else if event.type == .keyDown {
                surface.keyDown(with: event)
            } else {
                surface.keyUp(with: event)
            }
        }
    }

    /// One key held while a CLI starts: a key event, or a paste with the
    /// text the clipboard held when it was pressed.
    enum AgentHeldKey {
        case key(NSEvent)
        case paste(String)

        /// A key press or a paste: what the harness counts.
        var isPress: Bool {
            if case .key(let event) = self { return event.type == .keyDown }
            return true
        }
    }

    /// Keys held for an agent whose CLI did not start, or that shows a
    /// dialog, are not sent, and the person is told.
    private func dropHeldKeys(of id: UUID) {
        guard heldKeys.removeValue(forKey: id) != nil else { return }
        Self.logger.info("What you typed while it was starting was not sent: \(id, privacy: .public)")
        say("What you typed while it was starting was not sent.", for: 6)
    }

    /// One sentence in the top bar's status line (words.md, "Status line"),
    /// with Undo after it when `undoable`.
    func say(_ text: String, for seconds: TimeInterval = 1.8, undoable: Bool = false) {
        harness?.notifier.announce(text)
        windowController?.topBar.say(text, for: seconds, undoable: undoable)
    }

    /// The project "New agent" starts in: the current one, else the first.
    private var newAgentProject: AgentProject? {
        config.projects.first { $0.id == workspaceModel.currentProjectID } ?? config.projects.first
    }

    /// The saved defaults for a new agent.
    private func savedNewAgentOptions() -> AgentCreationDraft {
        AgentCreationDraft(provider: workspaceModel.newAgentProvider, preferences: preferences)
    }

    // MARK: - Workspace window

    @discardableResult
    func showWorkspace(activate: Bool = true) -> NSWindow? {
        if workspaceWindow == nil {
            let terminals = AgentTerminalsController(ghostty: ghostty, bridge: bridge)
            let controller = AgentWindowController(
                terminals: terminals, config: config, bridge: bridge, model: workspaceModel)
            windowController = controller
            controller.actions = AgentWindowActions(
                enter: { [weak self] id in self?.openAgent(id) },
                home: { [weak self] in self?.goHome() },
                project: { [weak self] id in self?.switchProject(id) },
                projectMenu: { [weak self] id in self?.projectMenu(for: id) ?? NSMenu() },
                barMenu: { [weak self] in self?.barMenu() ?? NSMenu() },
                moveProject: { [weak self] id, index in self?.moveProject(id, to: index) },
                nextWaiting: { [weak self] in self?.walkNext() },
                find: { [weak self] in self?.showFind() },
                newAgent: { [weak self] in self?.newAgentCommand(provider: nil) },
                chooseFolder: { [weak self] in self?.chooseProjectFolder() },
                rowMenu: { [weak self] id in self?.rowMenu(for: id) ?? NSMenu() },
                typeOnTiles: { [weak self] event in self?.typeOnTiles(event) },
                select: { [weak self] selection in
                    guard let self, let project = self.workspaceModel.currentProjectID else { return }
                    self.workspaceModel.setSelection(selection, in: project)
                },
                reorder: { [weak self] ids in self?.reorder(ids) },
                lineSubmit: { [weak self] interrupting in self?.lineSubmit(interrupting: interrupting) },
                lineCommand: { [weak self] selector in self?.lineCommand(selector) ?? false },
                draft: { [weak self] text in
                    guard let self, let project = self.workspaceModel.currentProjectID else { return }
                    // Typing ends a start's undo; the send emptying the
                    // line does not.
                    if !text.isEmpty { self.workspaceModel.undo.endStarts() }
                    self.workspaceModel.setDraft(text, in: project)
                },
                showSettled: { [weak self] in self?.showFind(text: "settled ") },
                toLine: { [weak self] in self?.windowController?.focus(.line) },
                paletteCommand: { [weak self] selector in self?.paletteCommand(selector) ?? false },
                closePalette: { [weak self] in self?.closePalette() },
                undo: { [weak self] in self?.undo(in: nil) },
                latestSettle: { [weak self] in self?.latestSettle ?? [] },
                dropFolders: { [weak self] urls in self?.addProjects(urls) },
                dropFiles: { [weak self] in self?.say("Drop a folder, not a file", for: 3) },
                findChanged: { [weak self] in self?.runFind(keepingHighlight: false) },
                newAgentTextChanged: { [weak self] text in if !text.isEmpty { self?.workspaceModel.undo.endStarts() } },
                findHighlight: { [weak self] index in self?.highlightFind(index) },
                findRun: { [weak self] index in self?.runFindRow(index) },
                nameCommand: { [weak self] selector in self?.nameCommand(selector) ?? false },
                nameResigned: { [weak self] in self?.endRename(keep: true, refocus: false) },
                nameChanged: { [weak self] in self?.workspaceModel.undo.endStarts() },
                nameClickedAway: { [weak self] in self?.endRename(keep: true, refocus: true) },
                nameGone: { [weak self] in self?.endRename(keep: false, refocus: true) },
                renameShown: { [weak self] in
                    guard let self, let shown = self.workspaceModel.shownAgentID else { return }
                    self.rename(shown, at: .header)
                },
                copy: { [weak self] in self?.copySentences() },
                pinch: { [weak self] apart in self?.pinch(apart: apart) },
                cliMenu: { [weak self] in self?.cliMenu() ?? NSMenu() })
            let palette = ClawddyPalette(config: ghostty.config)
            let window = makeAgentWorkspaceWindow(controller: controller, background: palette.canvas.nsColor)
            window.performChord = { [weak self] event in self?.performChord(event) ?? false }
            window.holdsKey = { [weak self] event in self?.holdKey(event) ?? false }
            window.keyDuringDrag = { [weak controller] event in controller?.keyDuringDrag(event) ?? false }
            window.onFirstResponderChange = { [weak controller] in controller?.focusChanged() }
            window.onMouseDown = { [weak controller] event in controller?.windowMouseDown(event) }
            window.onUndo = { [weak self] in self?.undo(in: self?.keyContext) }
            window.undoMenu = { [weak self] in self?.undoMenu ?? ("Undo", false) }
            workspaceWindow = window
            controller.setPalette(palette)
            installWorkspaceObservers(for: window)
            reconcileWorkspace()
            controller.start()
            // The view kept from the last run: its terminal shows, passed
            // through, so nothing starts by being shown.
            if let id = workspaceModel.shownAgentID {
                terminals.show(id)
                terminals.focusTerminal()
                workspaceModel.setViewingShownAgent(true)
            } else {
                controller.showHome(selecting: AgentTileSelection())
                if listedAgents.isEmpty, newAgentProject != nil { controller.focus(.line) }
            }
            harness?.startSceneAgents(host: terminals)
            let cutOff = bridge.continueCutOffAgents(selected: workspaceModel.shownAgentID, host: terminals)
            if cutOff > 0 {
                say(cutOff == 1
                    ? "Restarted. Resuming 1 interrupted agent."
                    : "Restarted. Resuming \(cutOff) interrupted agents.", for: 7)
            }
            // An older build's state file that could not be read was moved
            // to the backups at this start (last review ruling 2).
            if let moved = bridge.movedStateFile, cutOff == 0 {
                Self.logger.error("state.json could not be read and was moved to \(moved.path, privacy: .public)")
                say(AgentNotices.movedStateFile, for: 12)
            }
        }

        // A test drives the window where it is; a harness, which stands in
        // for the screen, brings a closed window back off screen.
        if activate, !isTestHost {
            if let harness {
                harness.windowShown()
            } else {
                NSApp.activate(ignoringOtherApps: true)
                workspaceWindow?.makeKeyAndOrderFront(nil)
            }
        }
        return workspaceWindow
    }

    /// A tile's or a row's menu (words.md "Tile and row menu"): Open,
    /// Rename (F2), Mark as unread (⌘U), Settle (⌘D), each enabled only
    /// where it applies to that agent.
    func rowMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Open") { [weak self] in self?.openAgent(id) })
        let record = bridge.agents[id]?.record
        // The name is edited where it shows: on the tile at home, on the row
        // beside a terminal. At home a tile's Settle settles the selection
        // it is in, beside a terminal the row's agent.
        let place: AgentRenaming.Place = workspaceModel.shownAgentID == nil ? .tile : .row
        // swiftlint:disable:next large_tuple
        let items: [(String, AgentCommand, Bool, () -> Void)] = [
            ("Rename", .rename, true, { [weak self] in self?.rename(id, at: place) }),
            ("Mark as unread", .markUnread, record?.state == .finished && record?.unread == false,
             { [weak self] in self?.markUnread(id) }),
            ("Settle", .settle, record?.state != .working,
             { [weak self] in
                 guard let self else { return }
                 if self.workspaceModel.shownAgentID == nil { self.settleAtHome() } else { self.settle([id], from: .row) }
             }),
        ]
        for (title, command, enabled, run) in items {
            let item = NSMenuItem(title: title, run: run)
            if let key = AgentChords.chord(for: command)?.menuKey {
                item.keyEquivalent = key.equivalent
                item.keyEquivalentModifierMask = key.modifiers
            }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        return menu
    }

    /// The current project's agents in a new order, from the shown ones
    /// (tiles or rows) moved; settled agents keep their places among them
    /// (flows.md 3.5). Saved at once.
    private func reorder(_ shown: [UUID]) {
        guard let project = config.projects.first(where: { $0.id == workspaceModel.currentProjectID }) else { return }
        var moved = shown.makeIterator()
        let shownSet = Set(shown)
        let all = project.agents.map(\.id).map { shownSet.contains($0) ? (moved.next() ?? $0) : $0 }
        config.reorderAgents(in: project.id, all)
    }

    /// ⌘C on the tiles: the selected agents' sentences, one per line, each
    /// "<name>: <sentence>", in the project's order (flows.md, "Hover and
    /// pressed states").
    private func copySentences() {
        guard let text = sentencesToCopy() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        say("Copied")
    }

    /// What ⌘C copies now; nil with nothing selected.
    func sentencesToCopy() -> String? {
        guard let project = workspaceModel.currentProjectID else { return nil }
        let selected = workspaceModel.selection(in: project).selected
        let lines = listedAgents.filter(selected.contains).compactMap { id in
            bridge.agents[id].map { "\($0.name): \($0.sentence.text)" }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Asks for a folder and adds it as a project named after it, which
    /// then becomes current.
    private func chooseProjectFolder() {
        guard let window = workspaceWindow else { return }
        askForFolder(window) { [weak self] url in self?.addProject(at: url) }
    }

    /// Folders dropped on the window, each added in the dropped order; the
    /// last becomes current (flows.md 6.2).
    func addProjects(_ urls: [URL]) {
        showWorkspace(activate: false)
        for url in urls { addProject(at: url) }
    }

    /// Adds the folder as a project named after it, at the end of the bar,
    /// and makes it current: home, empty, the line with the keys. A folder
    /// already in the bar becomes current ("<project> is already here"); a
    /// removed project of that folder comes back to the bar. A second
    /// folder of one name is "<name> (<parent folder>)".
    private func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        if let known = config.project(atFolder: path) {
            if config.isRemoved(project: known.id) {
                config.bringBack(project: known.id)
                switchProject(known.id)
                say("Added \(known.name)")
            } else {
                switchProject(known.id)
                say("\(known.name) is already here")
            }
            return
        }
        let names = Set((config.projects + config.removedProjects).map(\.name))
        let base = url.lastPathComponent.isEmpty ? "Project" : url.lastPathComponent
        var name = names.contains(base) ? "\(base) (\(url.deletingLastPathComponent().lastPathComponent))" : base
        var suffix = 2
        while names.contains(name) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        if let id = config.addProject(name: name, workingDirectory: path) {
            switchProject(id)
            say("Added \(name)")
        }
    }

    /// Viewing can begin when the window becomes key or comes back from
    /// the Dock. Its end needs no notice: `isViewed` reads the window as it
    /// is when a completion arrives. The palette follows the app's
    /// configuration and Increase Contrast.
    private func installWorkspaceObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        let reference = ControllerReference(self)
        workspaceObservers.append(center.addObserver(
            forName: .ghosttyConfigDidChange,
            object: nil,
            queue: .main,
            using: { [reference] notification in
                // A surface's own configuration names the surface.
                guard notification.object == nil,
                      let config = notification.userInfo?[
                        Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config
                else { return }
                let palette = ClawddyPalette(config: config)
                Task { @MainActor in
                    reference.value?.windowController?.setPalette(palette)
                }
            }))
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let contrast = workspaceCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main,
            using: { [reference] _ in
                Task { @MainActor in
                    guard let controller = reference.value else { return }
                    controller.windowController?.setPalette(ClawddyPalette(config: controller.ghostty.config))
                }
            })
        workspaceObservers.append(contrast)
        // Whatever lets the person see the shown agent again may read it.
        let seen: [(NotificationCenter, Notification.Name, AnyObject?)] = [
            (center, NSWindow.didBecomeKeyNotification, window),
            (center, NSWindow.didDeminiaturizeNotification, window),
            (center, NSWindow.didChangeOcclusionStateNotification, window),
            (center, NSApplication.didBecomeActiveNotification, nil),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), nil),
        ]
        for (notifications, name, object) in seen {
            workspaceObservers.append(notifications.addObserver(
                forName: name,
                object: object,
                queue: .main,
                using: { [reference] _ in
                    Task { @MainActor in
                        reference.value?.updateViewingState()
                    }
                }))
        }
    }

    /// The agent whose completions count as seen now: the workspace
    /// model's viewed agent, checked against the screen and the window as
    /// they are.
    private func currentlyViewedAgentID() -> UUID? {
        guard let window = workspaceWindow, let terminals else { return nil }
        // A harness or test window stands in for the person at the screen.
        let standsIn = (window as? AgentWorkspaceWindow)?.actsAsKey == true
        return workspaceModel.viewedAgent(
            presentedAgentID: terminals.activeID,
            personCanSee: standsIn || (NSApp.isActive && !Self.sessionIsLocked),
            windowIsVisible: window.isVisible && window.occlusionState.contains(.visible),
            windowIsKey: window.isKeyWindow,
            windowIsMiniaturized: window.isMiniaturized)
    }

    /// The login session's screen is locked.
    private static var sessionIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Acknowledges the agent the person has just begun to view. Called
    /// after entering, presentation, death, and the window becoming key.
    private func updateViewingState() {
        guard let id = currentlyViewedAgentID() else { return }
        bridge.agentViewed(id)
    }

    /// Starts the shown agent's CLI, or shows its terminal when it runs, and
    /// gives that terminal the keys. An agent whose saved conversation is
    /// missing or unreadable starts a new one ("Type to start fresh.").
    private func activateAgent(id: UUID) {
        guard let terminals, let project = config.project(forAgent: id),
              workspaceModel.shownAgentID == id
        else { return }
        // Record intent before preparation starts. It stays pending while the
        // surface is being created and only becomes viewed once the bridge
        // reports the presented surface, so the first start and restarts are
        // focused and acknowledged without a second activation.
        workspaceModel.setViewingShownAgent(true)
        if bridge.agents[id]?.canOnlyStartFresh == true {
            bridge.startFresh(id: id, host: terminals, project: project)
        } else {
            bridge.activateAgent(id: id, host: terminals, project: project)
        }
        terminals.focusTerminal()
        updateViewingState()
    }
}

extension AgentQuitConfirmation {
    /// The quit confirmation when no terminal window needs one, and only
    /// while agents run: `notice`, what happens to them, with Quit and
    /// Cancel.
    static func alert(notice: String?) -> NSAlert? {
        guard let notice else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = notice
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert
    }

    /// Asks with `alert`, or quits at once when no agent runs. Called from
    /// `AppDelegate.terminate`, on the main thread.
    static func ask(notice: String?) -> NSApplication.TerminateReply {
        guard let alert = alert(notice: notice) else { return .terminateNow }
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

extension ClawddyController: NSMenuDelegate {
    /// The Agent menu: its settings as they are.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Agent" { refreshSettings(in: menu) }
    }

    func menuWillOpen(_ menu: NSMenu) { openMenus += 1 }
    func menuDidClose(_ menu: NSMenu) { openMenus = max(0, openMenus - 1) }
}

extension ClawddyController: NSMenuItemValidation {
    /// An Agent menu item is enabled exactly where it acts and applies: an
    /// item showing a chord only where the chord acts (so outside the agent
    /// window its key stays Ghostty's), every item only where its command
    /// has an action, and Settle, Mark as unread, Select every working agent
    /// and the places only when there is something for them.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = item.representedObject as? AgentCommand else { return true }
        if case .agentAt(let place) = command {
            // Named for the agent in that place of the view shown.
            let ids = placeIDs
            let id = ids.indices.contains(place - 1) ? ids[place - 1] : nil
            item.isHidden = id == nil
            item.title = id.flatMap { bridge.agents[$0]?.name } ?? command.title
        }
        // The window closed, or another window main: the commands that
        // make sense then act from the open menu and open the window first
        // (final review ruling 1); the rest wait for the window. Their keys
        // stay Ghostty's (shortcuts.md rule 5): a key's search of the menus
        // finds them disabled, since no menu is open then.
        guard let context = keyContext else { return openMenus > 0 && AgentCommand.opensWindow.contains(command) }
        if command.menuKey != nil, AgentChords.chord(for: command) != nil, !AgentChords.contexts(of: command).contains(context) {
            return false
        }
        guard action(for: command, in: context) != nil else { return false }
        return applies(command)
    }

    /// The places ⌘1–9 count: home's places (the model's order), or the
    /// list's rows inside.
    private var placeIDs: [UUID] {
        guard workspaceModel.shownAgentID == nil else { return listedAgents }
        guard let project = config.projects.first(where: { $0.id == workspaceModel.currentProjectID }) else { return [] }
        return workspaceModel.places(of: project, agents: bridge.agents).map(\.id)
    }

    /// Whether `command` has something to act on now.
    private func applies(_ command: AgentCommand) -> Bool {
        let project = workspaceModel.currentProjectID
        let targets: [UUID] = workspaceModel.shownAgentID.map { [$0] }
            ?? project.map { id in listedAgents.filter(workspaceModel.selection(in: id).selected.contains) } ?? []
        let cursor = workspaceModel.shownAgentID ?? project.flatMap { workspaceModel.selection(in: $0).cursor }
        switch command {
        case .settle:
            return targets.contains { bridge.agents[$0]?.record.state != .working }
        case .markUnread:
            return cursor.flatMap { bridge.agents[$0]?.record }.map { $0.state == .finished && !$0.unread } ?? false
        case .selectWorking:
            return listedAgents.contains { bridge.agents[$0]?.record.state == .working }
        case .agentAt(let place):
            let ids = placeIDs
            return ids.indices.contains(place - 1) && bridge.agents[ids[place - 1]]?.isSettled == false
        case .previousAgent, .nextAgent:
            return !listedAgents.isEmpty
        // With no project only ⌘O, ⌘N, ⌘P, ⌘? and ⌘Z act (flows.md 6.1).
        case .smallerTiles, .largerTiles, .defaultTiles:
            return project != nil
        case .previousProject, .nextProject:
            return !config.projects.isEmpty
        case .moveEarlier, .moveLater:
            return project.map { !workspaceModel.selection(in: $0).isEmpty } ?? false
        default:
            return true
        }
    }
}

// MARK: - The line and the floating new-agent line

extension ClawddyController {
    /// ⌘N, the plus button, "New <CLI> agent" for each CLI (flows.md 6.3, ruling 32): with no project, the folder panel;
    /// everywhere else, home included, the floating new-agent line with the
    /// keys; Escape gives them back to who had them (the tiles, the line or
    /// the terminal), the selection unchanged. Already open, it keeps its
    /// text and takes the keys; find open turns into it. `provider` ("New
    /// Codex agent") first sets new agents to use that CLI.
    func newAgentCommand(provider: AgentProviderID?) {
        if let provider { setNewAgentProvider(provider) }
        guard let project = newAgentProject, let windowController else {
            showWorkspace()
            chooseProjectFolder()
            return
        }
        showWorkspace()
        if windowController.paletteShown {
            if windowController.palettePanel.mode == .new { return windowController.focus(.palette) }
            // Find was open: its keys go back where they would have.
            dismissPalette()
        } else {
            paletteReturn = windowController.focused ?? (workspaceModel.shownAgentID == nil ? .tiles : .terminal)
        }
        floatingProject = project.id
        windowController.showNewAgentPalette(in: project)
        windowController.palettePanel.textView.setText(floatingDrafts[project.id] ?? "")
    }

    /// Sets the CLI new agents use (flows.md 6.3, "Choosing the CLI"): the
    /// one setting the chips, their key and the Agent menu change.
    func setNewAgentProvider(_ provider: AgentProviderID) {
        guard provider != workspaceModel.newAgentProvider else { return }
        workspaceModel.newAgentProvider = provider
        windowController?.newAgentProviderChanged()
    }

    /// Tab (`step` 1) or Shift-Tab (-1) in a new-agent line: the next or
    /// previous installed CLI, wrapping; none other installed, nothing.
    private func stepNewAgentProvider(_ step: Int) {
        let all = AgentProviderID.allCases
        guard let index = all.firstIndex(of: workspaceModel.newAgentProvider) else { return }
        for offset in 1..<all.count {
            let next = all[(index + step * offset + all.count * offset) % all.count]
            if isInstalled(next) { return setNewAgentProvider(next) }
        }
    }

    /// Not known to be missing: one still being checked counts as there.
    private func isInstalled(_ provider: AgentProviderID) -> Bool {
        if case .missing = bridge.providerHealth[provider]?.installation { return false }
        return true
    }

    /// The chip's menu: every CLI, the current one checked, one not
    /// installed dimmed.
    func cliMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for provider in AgentProviderID.allCases {
            let installed = isInstalled(provider)
            let item = NSMenuItem(title: installed ? provider.displayName : "\(provider.displayName) — not installed") { [weak self] in
                self?.setNewAgentProvider(provider)
            }
            item.state = provider == workspaceModel.newAgentProvider ? .on : .off
            item.isEnabled = installed
            menu.addItem(item)
        }
        return menu
    }

    /// A key command in the line (flows.md 3.2, shortcuts.md "Home, line"):
    /// Return sends, Escape and Up on the first line give the keys to the
    /// tiles; Escape never deletes text.
    func lineCommand(_ selector: Selector) -> Bool {
        guard let line = windowController?.line.textView, let project = workspaceModel.currentProjectID else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            lineSubmit(interrupting: false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            var selection = workspaceModel.selection(in: project)
            if line.string.isEmpty, let cursor = selection.cursor, selection.selected.count > 1 {
                selection = .only(cursor)
                workspaceModel.setSelection(selection, in: project)
            }
            windowController?.focus(.tiles)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard line.caretOnFirstLine else { return false }
            windowController?.focus(.tiles)
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // Text being composed keeps its keys.
            guard windowController?.lineStartsNewAgent == true, !line.hasMarkedText() else { return false }
            stepNewAgentProvider(selector == #selector(NSResponder.insertTab(_:)) ? 1 : -1)
            return true
        default:
            return false
        }
    }

    /// Return, the send disk, ⌘↩: with two or more tiles selected, the text
    /// goes to them all (`interrupting` working ones first); otherwise it
    /// starts a new agent with it as the task.
    func lineSubmit(interrupting: Bool) {
        guard let windowController, let project = config.projects.first(where: { $0.id == workspaceModel.currentProjectID }),
              !windowController.line.textView.hasMarkedText()
        else { return }
        let text = windowController.line.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let selection = workspaceModel.selection(in: project.id)
        if selection.selected.count > 1 {
            send(text, to: listedAgents.filter(selection.selected.contains), interrupting: interrupting)
        } else if start(text, in: project) {
            clearLine()
        }
    }

    /// Starts an agent from a task (flows.md 6.3): it exists at once, at the
    /// end of the grid, in view; its CLI waits its turn; the status line
    /// says so. False when it could not be made.
    @discardableResult
    private func start(_ task: String, in project: AgentProject) -> Bool {
        guard let terminals else { return false }
        let options = savedNewAgentOptions()
        guard let entry = bridge.startAgent(
            task: task, provider: options.provider, launchProfile: options.launchProfile,
            config: config, project: project, host: terminals)
        else { return false }
        workspaceModel.undo.push(.started(id: entry.id, name: entry.name, at: Date()))
        if workspaceModel.shownAgentID == nil { windowController?.reveal(agent: entry.id) }
        say("Started \(entry.name). ⌘Z cancels it.", for: 6)
        return true
    }

    /// Empties the line after a send: its draft too, and its undo history,
    /// so ⌘Z cannot bring back text that went.
    private func clearLine() {
        windowController?.line.textView.setText("")
        if let project = workspaceModel.currentProjectID { workspaceModel.setDraft("", in: project) }
    }

    /// One instruction to several agents, through the one send (flows.md
    /// 6.5): agents whose input holds text, or that ask or show a menu, are
    /// skipped and named. Then the line empties, the selection collapses to
    /// the cursor and the tiles have the keys. If every one refused, also
    /// when that is known only after the interrupts, it is as if the key
    /// had not been pressed (S7 review ruling 2): the text back in that
    /// project's line, the same tiles selected, the line with the keys if
    /// the person is still at that home.
    private func send(_ text: String, to ids: [UUID], interrupting: Bool) {
        guard let project = workspaceModel.currentProjectID else { return }
        let selection = workspaceModel.selection(in: project)
        var results: [UUID: AgentSendResult] = [:]
        var waiting = ids.count
        var settled = false
        let report = { [weak self] in
            guard let self, waiting == 0, settled else { return }
            self.reportSend(text, to: ids, results: results, project: project, selection: selection)
        }
        for id in ids {
            bridge.send(text, to: id, by: .person, interrupting: interrupting) { result in
                results[id] = result
                waiting -= 1
                report()
            }
        }
        let refusedAll = ids.allSatisfy { results[$0].map { $0 != .sent } ?? false }
        if !refusedAll {
            clearLine()
            workspaceModel.setSelection(selection.cursor.map { AgentTileSelection.only($0) } ?? AgentTileSelection(), in: project)
            windowController?.focus(.tiles)
        }
        settled = true
        report()
    }

    /// Says how a send to several went (`AgentSendReport`); if nothing went,
    /// puts everything back as it was before the key.
    private func reportSend(
        _ text: String, to ids: [UUID], results: [UUID: AgentSendResult], project: UUID, selection: AgentTileSelection
    ) {
        var skipped: [(AgentSendReport.Reason, [String])] = []
        for id in ids where results[id] != .sent {
            let reason: AgentSendReport.Reason = switch results[id] {
            case .holdsText: .typed
            case .menu where bridge.agents[id]?.record.state == .asks: .asking
            case .menu: .menu
            default: .notReady
            }
            let name = bridge.agents[id]?.name ?? ""
            if let at = skipped.firstIndex(where: { $0.0 == reason }) {
                skipped[at].1.append(name)
            } else {
                skipped.append((reason, [name]))
            }
        }
        let sent = ids.filter { results[$0] == .sent }.count
        let words = AgentSendReport.words(sent: sent, skipped: skipped)
        say(words.text, for: words.seconds)
        guard sent == 0 else { return }
        if workspaceModel.draft(in: project).isEmpty { workspaceModel.setDraft(text, in: project) }
        workspaceModel.setSelection(selection, in: project)
        guard workspaceModel.currentProjectID == project, workspaceModel.shownAgentID == nil, let windowController else { return }
        if windowController.line.textView.string.isEmpty { windowController.line.textView.setText(text) }
        windowController.grid.syncSelection()
        windowController.focus(.line)
    }

    /// A key command in the palette. Find: Up and Down move the
    /// highlight, Return runs it, Escape closes. The floating new-agent
    /// line: Return starts the agent and the field empties and stays open;
    /// Escape closes it and the keys go back to the terminal.
    func paletteCommand(_ selector: Selector) -> Bool {
        guard let windowController else { return false }
        let field = windowController.palettePanel.textView
        if windowController.palettePanel.mode == .find {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                runFindRow(findHighlight)
            case #selector(NSResponder.moveUp(_:)):
                highlightFind(max(0, findHighlight - 1))
            case #selector(NSResponder.moveDown(_:)):
                highlightFind(min(findRows.count - 1, findHighlight + 1))
            case #selector(NSResponder.cancelOperation(_:)):
                closePalette()
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                break
            default:
                return false
            }
            return true
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let project = newAgentProject else { return true }
            if start(text, in: project) {
                field.setText("")
                floatingDrafts[project.id] = nil
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closePalette()
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            guard !field.hasMarkedText() else { return false }
            stepNewAgentProvider(selector == #selector(NSResponder.insertTab(_:)) ? 1 : -1)
            return true
        default:
            return false
        }
    }

    /// Closes the palette, by Escape, ⌘P, a click outside or a row run; the
    /// keys go back to who had them before it opened (flows.md 5).
    func closePalette() {
        guard let windowController, windowController.paletteShown else { return }
        dismissPalette()
        windowController.focus(paletteReturn)
    }

    /// Hides the palette without moving the keys (entering an agent or
    /// switching project moves them itself). The floating line's text stays
    /// with the project it was typed in.
    private func dismissPalette() {
        guard let windowController, windowController.paletteShown else { return }
        if windowController.palettePanel.mode == .new, let project = floatingProject {
            floatingDrafts[project] = windowController.palettePanel.textView.string
        }
        windowController.hidePalette()
    }
}

// MARK: - Find

/// What a row of find runs.
enum FindTarget: Equatable {
    case agent(UUID)
    case command(AgentCommand)
    case project(UUID)
}

extension ClawddyController {
    /// ⌘P, the magnifier, "N settled", Option-Space: find opens with `text`
    /// in its field and the keys there; who had them gets them back when it
    /// closes (flows.md 6.8).
    func showFind(text: String = "") {
        showWorkspace()
        guard let windowController else { return }
        if !windowController.paletteShown { paletteReturn = windowController.focused ?? (workspaceModel.shownAgentID == nil ? .tiles : .terminal) }
        windowController.showFind(text: text)
        runFind(keepingHighlight: false)
    }

    /// Every agent find searches: those of the bar's projects and of the
    /// removed ones, settled agents too.
    private var searchSources: [AgentSearchSource] {
        (config.projects + config.removedProjects).flatMap { project in
            project.agents.compactMap { entry in
                bridge.agents[entry.id].map { agent in
                    AgentSearchSource(
                        id: entry.id, name: agent.name, project: project.name, projectID: project.id,
                        version: agent.searchVersion, record: { agent.record }, sentence: { agent.sentence.text })
                }
            }
        }
    }

    /// The commands find offers where the keys were before it opened, each
    /// with its key; then "Go to <project>" for each project.
    private var findCommands: [(title: String, key: String?, target: FindTarget)] {
        let context: AgentKeyContext = switch paletteReturn {
        case .line: .homeLine
        case .terminal: .inside
        default: .homeTiles
        }
        let commands = AgentCommand.paletteCommands.filter { action(for: $0, in: context) != nil }.map { command in
            (title: command.title, key: AgentChords.chord(for: command)?.description, target: FindTarget.command(command))
        }
        return commands + config.projects.map { (title: "Go to \($0.name)", key: nil, target: FindTarget.project($0.id)) }
    }

    /// Find's rows for the text in its field, in the key's own turn, so the
    /// rows shown are always the text's.
    func runFind(keepingHighlight: Bool) {
        guard let windowController else { return }
        let query = windowController.palettePanel.textView.string
        let hits = searchIndex.search(query, in: searchSources, currentProject: workspaceModel.currentProjectID)
        let commands = findCommands
        let searchTexts = commands.map { entry in
            if case .command(let command) = entry.target { return command.searchText }
            return entry.title
        }
        let chosen = AgentSearchIndex.commands(commands.map(\.title), searchTexts: searchTexts, matching: query)
        let now = Date()
        findRows = hits.map { hit in
            .agent(
                hit, state: AgentShownState.inFind(bridge.agents[hit.id]?.shownState ?? .finished, settled: hit.settled),
                age: AgentAge.short(now.timeIntervalSince(hit.changedAt)))
        } + chosen.map { .command(title: commands[$0.index].title, key: commands[$0.index].key, marks: $0.marks) }
        findTargets = hits.map { .agent($0.id) } + chosen.map { commands[$0.index].target }
        if !keepingHighlight { findHighlight = 0 }
        findHighlight = min(findHighlight, max(0, findRows.count - 1))
        windowController.showFindResults(findRows, highlighted: findHighlight)
    }

    /// The arrows or the pointer moved the highlight to `index`.
    func highlightFind(_ index: Int) {
        guard findRows.indices.contains(index), index != findHighlight else { return }
        findHighlight = index
        windowController?.showFindResults(findRows, highlighted: index)
    }

    /// Return or a click on a row: the palette closes, the keys go back,
    /// then an agent opens inside (a settled one comes back first, its
    /// project too), a command runs where the keys were, or a project
    /// becomes current.
    func runFindRow(_ index: Int) {
        guard findTargets.indices.contains(index) else { return }
        let target = findTargets[index]
        closePalette()
        switch target {
        case .agent(let id):
            openFromFind(id)
        case .command(let command):
            action(for: command, in: keyContext)?()
        case .project(let id):
            switchProject(id)
        }
    }

    /// An agent chosen in find: a settled agent comes back to home at its
    /// place, its removed project back to the bar, then it opens on purpose
    /// and its CLI starts (flows.md 6.8 step 5).
    func openFromFind(_ id: UUID) {
        openAgent(id)
    }

    /// ⌘↩ in find with text and no match: an agent starts with the text,
    /// as from the line (ruling 26): at home the palette closes and the keys
    /// land in the empty line, the selection collapsed to the cursor; inside
    /// a terminal the floating new-agent line stays open, empty.
    func startFromFind() {
        guard let windowController, windowController.palettePanel.mode == .find, findRows.isEmpty,
              !windowController.palettePanel.textView.hasMarkedText(), let project = newAgentProject
        else { return }
        let text = windowController.palettePanel.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if workspaceModel.shownAgentID != nil {
            guard start(text, in: project) else { return }
            paletteReturn = .terminal
            floatingProject = project.id
            windowController.showNewAgentPalette(in: project)
            return
        }
        windowController.hidePalette()
        var selection = workspaceModel.selection(in: project.id)
        if let cursor = selection.cursor { selection = .only(cursor) }
        workspaceModel.setSelection(selection, in: project.id)
        windowController.focus(.line)
        start(text, in: project)
    }
}

// MARK: - Settle, undo, projects

extension ClawddyController {
    /// Where a settle comes from.
    enum SettleSource { case home, inside, row }

    /// ⌘D and the Agent menu's Settle: at home the selected tiles, inside
    /// the agent shown (flows.md 6.7).
    func settleCommand() {
        if workspaceModel.shownAgentID == nil { settleAtHome() } else { settleShown() }
    }

    /// The selected tiles: one is settled unless it works; of several,
    /// those working, asking or stopped with a problem are skipped and the
    /// status line says so (ruling 11). Each place stays, the cursor moves
    /// to the next tile after the last settled.
    func settleAtHome() {
        guard let project = workspaceModel.currentProjectID else { return }
        let selection = workspaceModel.selection(in: project)
        let ids = listedAgents.filter(selection.selected.contains)
        guard !ids.isEmpty else { return say("Select an agent first") }
        settle(ids, from: .home)
    }

    /// The agent shown inside: settled, then home with its place in view
    /// and the cursor on the next agent; a working one is refused.
    func settleShown() {
        guard let id = workspaceModel.shownAgentID else { return }
        settle([id], from: .inside)
    }

    /// During the walk (S9): settles the agent shown in place, says
    /// "Settled <name>" with Undo in the top bar for 6 s, and calls
    /// `advance` to go on to the next waiting agent without visiting home
    /// (ruling 6). A working agent is refused as inside.
    func settleShownAndAdvance(_ advance: () -> Void) {
        guard let id = workspaceModel.shownAgentID, let agent = bridge.agents[id] else { return }
        guard agent.record.state != .working else { return say("Still working. Press ⎋ to interrupt it first.", for: 3) }
        guard bridge.settle(id: id), let project = config.project(forAgent: id) else { return }
        workspaceModel.undo.push(.settled([id], project: project.id))
        advance()
        say("Settled \(agent.name)", for: 6, undoable: true)
    }

    /// Settles `ids` (flows.md 6.7, rulings 11 and 27). The one place that
    /// decides what settling the agent being looked at does, by any path (its
    /// row's menu, the palette, the menu bar, ⌘D): in a walk it is settled in
    /// place and the walk goes on (ruling 6; settling does not end it);
    /// otherwise home, its settled place in view. No path leaves the person
    /// inside a settled agent.
    func settle(_ ids: [UUID], from source: SettleSource) {
        guard let project = workspaceModel.currentProjectID else { return }
        var source = source
        if source != .home, let shown = workspaceModel.shownAgentID, ids == [shown] {
            if workspaceModel.walk != nil { return settleShownAndAdvance { walkNext() } }
            source = .inside
        }
        let many = ids.count > 1
        let skips: (AgentRecord) -> Bool = { record in
            record.state == .working || (many && (record.state == .asks || record.state == .problem))
        }
        let records = ids.compactMap { id in bridge.agents[id].map { (id, $0.record) } }
        let chosen = records.filter { !skips($0.1) }.map(\.0)
        guard !chosen.isEmpty else {
            if records.allSatisfy({ $0.1.state == .working }) {
                return say(
                    source == .inside ? "Still working. Press ⎋ to interrupt it first."
                        : many ? "Still working. Open each and press ⎋ to interrupt." : "Still working. Open it and press ⎋ to interrupt.",
                    for: 3)
            }
            return say("None settled. All are working or need you.", for: 3)
        }
        // The next tile after the last settled that is not settled, else
        // the first.
        let live = listedAgents
        let after = live.firstIndex(of: chosen.last!).map { live[($0 + 1)...] }.flatMap { $0.first { !chosen.contains($0) } }
        let next = after ?? live.first { !chosen.contains($0) }
        let settled = chosen.filter { bridge.settle(id: $0) }
        guard !settled.isEmpty else { return }
        workspaceModel.undo.push(.settled(settled, project: project))
        switch source {
        case .home:
            workspaceModel.addSettledPlaces(settled)
            workspaceModel.setSelection(next.map(AgentTileSelection.only) ?? AgentTileSelection(), in: project)
            windowController?.showSettled(selecting: workspaceModel.selection(in: project))
        case .inside:
            // Home, the place in view, the cursor on the next agent.
            leaveShownAgent(for: nil)
            workspaceModel.show(.home, in: project)
            workspaceModel.addSettledPlaces(settled)
                let selection = next.map(AgentTileSelection.only) ?? AgentTileSelection()
            workspaceModel.setSelection(selection, in: project)
            windowController?.showHome(selecting: selection, revealing: settled[0])
        case .row:
            break
        }
        let skipped = ids.count - chosen.count
        if skipped > 0 {
            say("Settled \(settled.count). Skipped " + (skipped == 1 ? "1 that is working or needs you." : "\(skipped) that are working or need you."), for: 3)
        }
    }

    /// ⌘U and Mark as unread: the cursor tile at home, the agent shown
    /// inside (flows.md 6.12).
    func markUnreadCommand() {
        guard let project = workspaceModel.currentProjectID else { return }
        guard let id = workspaceModel.shownAgentID ?? workspaceModel.selection(in: project).cursor else {
            return say("Select an agent first")
        }
        markUnread(id)
    }

    func markUnread(_ id: UUID) {
        guard bridge.markUnread(id: id) else { return say("Only a finished agent can be marked unread") }
        // Inside, it stays unread until the person enters it again (flows.md
        // 6.12): looking at it no longer reads it.
        if workspaceModel.shownAgentID == id { workspaceModel.setViewingShownAgent(false) }
        say("Marked unread")
    }

    /// "Select every working agent here": home, every working agent of the
    /// project selected, the keys in the line (flows.md 6.5).
    func selectWorking() {
        guard let project = workspaceModel.currentProjectID else { return }
        if workspaceModel.shownAgentID != nil { goHome() }
        let working = listedAgents.filter { bridge.agents[$0]?.record.state == .working }
        var selection = AgentTileSelection()
        selection.selectAll(working)
        workspaceModel.setSelection(selection, in: project)
        windowController?.grid.syncSelection()
        windowController?.focus(.line)
    }

    /// "Remove project" (flows.md 6.2, ruling 33): in one step, no
    /// confirmation, every agent of the project settled, working ones
    /// included, and the project off the bar. When it was current, the view
    /// goes to the next project (the previous when it was last, the
    /// first-launch screen when it was the only one); otherwise the view
    /// stays. Nothing on disk is deleted. Undo brings it all back.
    func removeProject(_ id: UUID) {
        guard let project = config.projects.first(where: { $0.id == id }) else { return }
        let wasCurrent = id == workspaceModel.currentProjectID
        let view = workspaceModel.views[project.id] ?? .home
        let home = AgentProjectHome(
            selection: workspaceModel.selection(in: project.id),
            scroll: wasCurrent ? windowController?.homeScroll ?? 0 : 0)
        // Removing a project ends a walk (final review ruling 6).
        endWalk()
        if wasCurrent { leaveShownAgent(for: nil) }
        let settled = project.agents.map(\.id).filter { bridge.settle(id: $0, includingWorking: true) }
        guard let index = config.removeProject(id: project.id) else { return }
        workspaceModel.undo.push(.removedProject(project.id, index: index, agents: settled, view: view, home: home, wasCurrent: wasCurrent))
        let projects = config.projects
        if projects.isEmpty {
            workspaceModel.switchTo(nil)
            windowController?.showHome(selecting: AgentTileSelection())
        } else if wasCurrent {
            switchProject(projects[min(index, projects.count - 1)].id)
        }
        let count = settled.count
        say(count == 0 ? "Removed \(project.name)."
            : count == 1 ? "Removed \(project.name) and settled its agent." : "Removed \(project.name) and settled its \(count) agents.",
            for: 6, undoable: true)
    }

    /// Moves the project to `index` in the bar (ruling 33): the stored
    /// order, which the bar, the walk, find and ⇧⌘[ ⇧⌘] all read. Saved at
    /// once; not undone by ⌘Z (moving back undoes it), as tiles.
    func moveProject(_ id: UUID, to index: Int) {
        config.moveProject(id: id, to: index)
    }

    /// A project's menu in the top bar and in "N more" (rulings 33, 34,
    /// words.md "Project menu"): New agent in <project>; Move left; Move
    /// right (disabled at the ends); Show in Finder; Remove project; then
    /// Add a project folder… ⌘O.
    func projectMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let index = config.projects.firstIndex(where: { $0.id == id }) else { return menu }
        let project = config.projects[index]
        let last = config.projects.count - 1
        let newAgent = NSMenuItem(title: "New agent in \(project.name)") { [weak self] in
            guard let self else { return }
            if self.workspaceModel.currentProjectID != id { self.switchProject(id) }
            self.newAgentCommand(provider: nil)
        }
        let left = NSMenuItem(title: "Move left") { [weak self] in self?.moveProject(id, to: index - 1) }
        left.isEnabled = index > 0
        let right = NSMenuItem(title: "Move right") { [weak self] in self?.moveProject(id, to: index + 1) }
        right.isEnabled = index < last
        let finder = NSMenuItem(title: "Show in Finder") { [weak self] in
            guard let folder = project.workingDirectory else { return }
            self?.revealInFinder(URL(fileURLWithPath: folder, isDirectory: true))
        }
        finder.isEnabled = project.workingDirectory != nil
        let remove = NSMenuItem(title: "Remove project") { [weak self] in self?.removeProject(id) }
        for item in [newAgent, left, right, finder, remove] { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(addProjectItem())
        return menu
    }

    /// The top bar's empty part, right-clicked: Add a project folder… ⌘O.
    func barMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(addProjectItem())
        return menu
    }

    private func addProjectItem() -> NSMenuItem {
        let item = NSMenuItem(title: AgentCommand.addProject.title) { [weak self] in
            self?.showWorkspace()
            self?.chooseProjectFolder()
        }
        if let key = AgentChords.chord(for: .addProject)?.menuKey {
            item.keyEquivalent = key.equivalent
            item.keyEquivalentModifierMask = key.modifiers
        }
        return item
    }

    /// The actions that still apply: settled agents not brought back
    /// another way, a project still removed, a started agent still here.
    private func undoApplies(_ action: AgentUndoable) -> Bool {
        switch action {
        case .started(let id, _, _): bridge.agents[id] != nil
        case .settled(let ids, _): ids.contains { bridge.agents[$0]?.isSettled == true }
        case .removedProject(let id, _, _, _, _, _): config.isRemoved(project: id)
        }
    }

    /// A start can still be cancelled: within 6 s, its agent working.
    private func cancellable(_ id: UUID, _ at: Date) -> Bool {
        Date().timeIntervalSince(at) <= AgentBridge.cancelLimit && bridge.agents[id]?.record.state == .working
    }

    /// ⌘Z where starts happen: the empty home line, or the empty floating
    /// new-agent line.
    private func isStartPlace(_ context: AgentKeyContext?) -> Bool {
        switch context {
        case .homeLine: windowController?.line.textView.string.isEmpty == true
        case .palette: windowController?.palettePanel.mode == .new && windowController?.palettePanel.textView.string.isEmpty == true
        default: false
        }
    }

    /// The agents of the settle ⌘Z undoes now: their places show Undo.
    var latestSettle: Set<UUID> {
        if case .settled(let ids, _)? = workspaceModel.undo.peek(inStartPlace: false, applies: undoApplies, cancellable: cancellable) {
            return Set(ids)
        }
        return []
    }

    /// Edit ▸ Undo where the keys are: a field's text undo, else what ⌘Z
    /// undoes, greyed when nothing can be.
    var undoMenu: (title: String, enabled: Bool) {
        let context = keyContext
        if let field = undoField(context), !field.string.isEmpty || field.fieldUndo.canUndo {
            return ("Undo", field.fieldUndo.canUndo)
        }
        if context == .palette, windowController?.palettePanel.mode == .find { return ("Undo", false) }
        let next = workspaceModel.undo.peek(
            inStartPlace: isStartPlace(context), startsOnly: context == .palette, applies: undoApplies, cancellable: cancellable)
        return (next?.menuTitle ?? "Undo", next != nil)
    }

    private func undoField(_ context: AgentKeyContext?) -> AgentTextView? {
        switch context {
        case .homeLine: windowController?.line.textView
        case .palette: windowController?.palettePanel.textView
        default: nil
        }
    }

    /// ⌘Z (flows.md 3.4, rulings 8 and 10), the one owner of undo: text
    /// undo in a field holding text or with edits to undo, and only that in
    /// find; where starts happen, the last start cancelled within 6 s;
    /// anywhere, the last settle or project removal restored to its place,
    /// for as long as it is the last undoable action of the session.
    func undo(in context: AgentKeyContext?) {
        if let field = undoField(context), !field.string.isEmpty || field.fieldUndo.canUndo {
            field.fieldUndo.undo()
            return
        }
        if context == .palette, windowController?.palettePanel.mode == .find { return }
        switch workspaceModel.undo.take(
            inStartPlace: isStartPlace(context), startsOnly: context == .palette,
            applies: undoApplies, cancellable: cancellable) {
        case .undo(.started(let id, let name, _)):
            if bridge.cancelStart(id: id, config: config) {
                reconcileWorkspace()
                say("Cancelled \(name)")
            } else {
                say("Too late to cancel. Settle it instead.", for: 3)
            }
        case .tooLate:
            say("Too late to cancel. Settle it instead.", for: 3)
        case .undo(.settled(let ids, let project)):
            bringBack(ids, in: project)
        case .undo(.removedProject(let id, let index, let agents, let view, let home, let wasCurrent)):
            bringBack(project: id, at: index, agents: agents, view: view, home: home, current: wasCurrent)
        case .nothing:
            say("Nothing to undo")
        }
    }

    /// Undo of a settle: every agent of it still settled back, in its place
    /// and its earlier state, the first selected when home in its project
    /// shows; "Brought back <name>".
    private func bringBack(_ ids: [UUID], in project: UUID) {
        let back = ids.filter { bridge.agents[$0]?.isSettled == true }
        for id in back {
            bridge.unsettle(id: id)
            workspaceModel.closeSettledPlace(id)
        }
        // During a walk they are its next stops (final review ruling 5).
        workspaceModel.walk?.comeNext(back)
        if workspaceModel.currentProjectID == project, workspaceModel.shownAgentID == nil, let first = back.first {
            workspaceModel.setSelection(.only(first), in: project)
            windowController?.showSettled(selecting: .only(first))
        }
        say(back.count == 1 ? "Brought back \(bridge.agents[back[0]]?.name ?? "")" : "Brought back \(back.count) agents")
    }

    /// Undo of a project's removal: the project in its place in the bar,
    /// each agent its removal settled back as it was (its CLI still running
    /// within 60 s), and the project as it was left, current again when it
    /// was current (or none is).
    private func bringBack(
        project id: UUID, at index: Int, agents: [UUID], view: AgentProjectView, home: AgentProjectHome, current: Bool
    ) {
        guard config.bringBack(project: id, at: index) else { return }
        for agent in agents { bridge.unsettle(id: agent) }
        workspaceModel.setView(view, in: id)
        guard current || workspaceModel.currentProjectID == nil else {
            return say("Brought back \(config.projects.first { $0.id == id }?.name ?? "")")
        }
        switchProject(id)
        // Its home as it was left: selection and scroll (ruling 5 of the S8
        // review).
        if workspaceModel.shownAgentID == nil {
            var selection = home.selection
            selection.keep(listedAgents)
            workspaceModel.setSelection(selection, in: id)
            windowController?.showHome(selecting: selection)
            windowController?.scrollHome(to: home.scroll)
        }
        say("Brought back \(config.projects.first { $0.id == id }?.name ?? "")")
    }
}

// MARK: - The walk

extension ClawddyController {
    /// The agents waiting on the person, in the walk's order from `project`.
    private func waitingOrder(from project: UUID?) -> [AgentWalk.Waiting] {
        AgentWaitingOrder.agents(projects: config.projects, agents: bridge.agents, currentProject: project)
    }

    /// ⌘J, the waiting count, "Next waiting agent" (flows.md 6.6): the first
    /// press fixes the walk's order and remembers where it began; each press
    /// enters the next agent still waiting, passed through, so no CLI starts
    /// by itself (ruling 7); the press after the last returns to where it
    /// began. With no one waiting it says so and nothing moves.
    func walkNext() {
        showWorkspace()
        guard let windowController else { return }
        var walk = workspaceModel.walk ?? AgentWalk(
            origin: AgentWalk.Origin(
                project: workspaceModel.currentProjectID,
                view: workspaceModel.view,
                selection: workspaceModel.currentProjectID.map { workspaceModel.selection(in: $0) } ?? AgentTileSelection(),
                scroll: windowController.homeScroll,
                views: workspaceModel.views),
            waiting: waitingOrder(from: workspaceModel.currentProjectID),
            shown: workspaceModel.shownAgentID,
            at: Date())
        let waiting = waitingOrder(from: walk.origin.project)
        if let next = walk.advance(waiting: waiting, at: Date()) {
            workspaceModel.walk = walk
            enter(next, deliberately: false, walking: true)
            return
        }
        guard !walk.isEmpty else { return say("No one else is waiting") }
        // Where it began may be gone (final review ruling 6): then the
        // current project's home, and only that it was everyone.
        say(returnToStart(of: walk) ? "That was everyone. Back where you started." : "That was everyone.", for: 2.6)
    }

    /// The walk ends where the person is: every other project keeps the
    /// view it had when the walk began, as if the walk had not passed
    /// through it.
    private func endWalk() {
        guard let walk = workspaceModel.walk else { return }
        workspaceModel.walk = nil
        for project in config.projects where project.id != workspaceModel.currentProjectID {
            workspaceModel.setView(walk.origin.views[project.id] ?? .home, in: project.id)
        }
    }

    /// Back exactly where the walk began: inside the same agent, or at home
    /// with the same selection, scrolled as it was (flows.md 6.6 step 4).
    /// When that place is gone (its project removed, its agent settled),
    /// the current project's home instead, the cursor on the agent left;
    /// false then (final review ruling 6).
    @discardableResult
    private func returnToStart(of walk: AgentWalk) -> Bool {
        let origin = walk.origin
        let current = workspaceModel.currentProjectID
        let left = workspaceModel.shownAgentID
        leaveShownAgent(for: nil)
        workspaceModel.walk = nil
        for project in config.projects {
            workspaceModel.setView(origin.views[project.id] ?? .home, in: project.id)
        }
        reconcileWorkspace()
        let exists: Bool = switch origin.view {
        case .home: config.projects.contains { $0.id == origin.project }
        case .inside(let id): bridge.agents[id]?.isSettled == false && config.project(forAgent: id)?.id == origin.project
        }
        guard exists, let project = origin.project else {
            guard let project = current ?? config.projects.first?.id, config.projects.contains(where: { $0.id == project }) else { return false }
            workspaceModel.show(.home, in: project)
            let selection = left.flatMap { listedAgents.contains($0) ? AgentTileSelection.only($0) : nil } ?? AgentTileSelection()
            workspaceModel.setSelection(selection, in: project)
            windowController?.showHome(selecting: selection)
            return false
        }
        if case .inside(let id) = origin.view {
            enter(id, deliberately: false, walking: true)
            return true
        }
        workspaceModel.show(.home, in: project)
        var selection = origin.selection
        selection.keep(listedAgents)
        workspaceModel.setSelection(selection, in: project)
        windowController?.showHome(selecting: selection)
        windowController?.scrollHome(to: origin.scroll)
        return true
    }
}

// MARK: - Rename in place

extension ClawddyController {
    /// The name of `id` becomes editable where it shows (flows.md 6.9): on
    /// its tile, its row, or the header; all of it selected, the field with
    /// the keys. A name already being edited is kept first.
    func rename(_ id: UUID, at place: AgentRenaming.Place) {
        guard let agent = bridge.agents[id], let windowController else { return }
        if workspaceModel.renaming != nil { endRename(keep: true, refocus: false) }
        workspaceModel.renaming = AgentRenaming(agent: id, place: place, original: agent.name)
        guard windowController.beginRename(id, at: place, name: agent.name) else {
            workspaceModel.renaming = nil
            return
        }
    }

    /// A key command in the name being edited: Return keeps it, Escape
    /// restores the old one; Up and Down go to its start and end.
    func nameCommand(_ selector: Selector) -> Bool {
        guard let field = windowController?.nameField.textView else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            endRename(keep: true, refocus: true)
        case #selector(NSResponder.cancelOperation(_:)):
            endRename(keep: false, refocus: true)
        case #selector(NSResponder.moveUp(_:)):
            field.moveToBeginningOfDocument(nil)
        case #selector(NSResponder.moveDown(_:)):
            field.moveToEndOfDocument(nil)
        default:
            return false
        }
        return true
    }

    /// The edit ends. `keep`: the typed name is the agent's for good (an
    /// empty one keeps the old); else the old name stays. A title that waited
    /// is taken when no new name was kept. `refocus` (Return, Escape) gives
    /// the keys back to the tiles or the terminal; a click elsewhere has
    /// already put them where it went.
    func endRename(keep: Bool, refocus: Bool) {
        guard let renaming = workspaceModel.renaming, let windowController else { return }
        workspaceModel.renaming = nil
        let typed = windowController.nameField.name
        if keep, !typed.isEmpty, typed != renaming.original {
            if config.renameAgent(id: renaming.agent, newName: typed) {
                bridge.renameAgent(id: renaming.agent, newName: typed)
            }
        } else if let title = renaming.waitingTitle, bridge.agents[renaming.agent]?.autoNamed == true {
            AgentWorkspaceTransactions.adoptTitle(title, of: renaming.agent, config: config, bridge: bridge)
        }
        if refocus { windowController.focus(workspaceModel.shownAgentID == nil ? .tiles : .terminal) }
        windowController.endRename()
    }
}

/// Every permission the app asks the system for, in the order asked. The
/// app asks only for notifications, and only when the person turns them on,
/// never at launch (final review ruling 2); the harness reports this list so
/// a run can show it.
enum AgentPermissionRequests {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: [String] = []

    /// What was asked so far, each named by why.
    static var made: [String] { lock.withLock { asked } }

    /// Asks for notifications with `options`, because of `reason`.
    static func notifications(_ options: UNAuthorizationOptions, for reason: String) {
        lock.withLock { asked.append(reason) }
        UNUserNotificationCenter.current().requestAuthorization(options: options) { _, error in
            if let error {
                Logger(subsystem: "com.mitchellh.ghostty", category: "Clawddy")
                    .error("notification permission: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
