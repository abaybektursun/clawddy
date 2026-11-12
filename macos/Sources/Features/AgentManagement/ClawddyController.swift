import AppKit
import Carbon
import GhosttyKit
import SwiftUI
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
    /// Open for the life of the process; holds the data root's lock.
    private let rootLock: FileHandle
    let config: AgentConfig
    let bridge: AgentBridge
    let workspaceModel: AgentWorkspaceModel
    private(set) lazy var settingsController = SettingsController(
        preferencesFile: config.root.preferencesFile)

    /// Fires whenever aggregate agent state changes; the app resyncs its badge.
    var onAggregateStateChanged: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var workspaceWindow: NSWindow?
    private var detailVC: AgentDetailViewController?
    private var searchPanel: AgentSearchPanel?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var explicitlyViewedAgentID: UUID?
    private var searchHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(ghostty: Ghostty.App) {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        isTestHost = AgentDataRoot.isRunningTests(environment: environment)
        let isProduction = AgentDataRoot.isProductionBundle(Bundle.main.bundleIdentifier)
        self.isProduction = isProduction
        let root = AgentDataRoot.resolve(
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
        // Before the lock, which creates the root.
        Self.seedDevCopyOnFirstStart(root, homeDirectory: home)
        rootLock = Self.lockOrExit(root)
        Self.logger.info("data root \(root.url.path, privacy: .public)")

        self.ghostty = ghostty
        config = AgentConfig(root: root)
        bridge = AgentBridge(
            root: root,
            providers: AgentProviderTable(registry: AgentProviderRegistry(
                root: root,
                codexHooksFile: AgentConfig.codexConfigDir.appendingPathComponent("hooks.json"),
                isProduction: isProduction)))
        workspaceModel = AgentWorkspaceModel(defaults: isTestHost ? nil : .standard)
        super.init()
    }

    /// The dev identity's first start copies the live Claude agents in, each
    /// as a fork of its live session, so the dev app never resumes a session
    /// the live app may be running. The live root is only read. A failed
    /// seed stops the app: starting empty would hide the failure, and the
    /// next start would not seed again.
    private static func seedDevCopyOnFirstStart(_ root: AgentDataRoot, homeDirectory: URL) {
        let fm = FileManager.default
        let production = AgentDataRoot.production(homeDirectory: homeDirectory)
        guard AgentDataRoot.seedsDevCopy(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            rootExists: fm.fileExists(atPath: root.url.path),
            productionConfigExists: fm.fileExists(atPath: production.agentsFile.path))
        else { return }
        do {
            let report = try seedAgentDevCopy(from: production, to: root)
            Self.logger.info(
                "seeded \(root.url.path, privacy: .public) from \(production.url.path, privacy: .public): \(report.agents) Claude agents, \(report.forkMarkers) fork markers")
        } catch {
            fatalError("Could not seed \(root.url.path) from \(production.url.path): \(error)")
        }
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

    var hasAgents: Bool { !config.projects.isEmpty }

    var attentionCount: Int {
        bridge.agents.values.filter { $0.displayState.needsAttention }.count
    }

    func setup() {
        guard !isTestHost else { return }

        removeOldClaudeGlobalHooks()

        bridge.environmentPath = AgentEnvironmentResolver.fallbackPath
        AgentEnvironmentResolver.resolve { [weak self] path in
            self?.bridge.environmentPath = path
        }

        // Wire callbacks. They and the status item exist before the bridge
        // starts, because `start` publishes the aggregate state.
        bridge.onAggregateStateChanged = { [weak self] state in
            self?.updateStatusIcon(state)
            self?.onAggregateStateChanged?()
        }
        bridge.onSendText = { [weak self] id, text in
            self?.detailVC?.sendText(text, toAgent: id)
        }
        bridge.onSurfaceDeath = { [weak self] id in
            self?.detailVC?.removeSurface(id: id)
        }
        bridge.onSurfacePresentationChanged = { [weak self] _ in
            self?.updateViewingState()
        }
        config.onReloaded = { [weak self] in
            guard let self else { return }
            self.bridge.reconcileWithConfig(self.config)
            self.workspaceModel.reconcile(with: self.config)
        }
        workspaceModel.reconcile(with: config)

        // Status bar item
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Clawddy")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.toolTip = "Clawddy Agents"
            button.setAccessibilityLabel("Clawddy Agents")
        }
        item.autosaveName = "ClawddyAgentStatusItem"
        statusItem = item

        // Start the bridge (reconstructs state from disk)
        bridge.start(config: config)

        setupMenu()

        // Option-Space belongs to whichever app registers it first, so only
        // the production app claims it.
        if isProduction {
            registerSearchHotKey()
        }
    }

    /// Claude hooks now travel in each agent's settings overlay. Entries that
    /// older builds registered globally would record every event a second
    /// time, so they go before the first launch. A failure leaves them in
    /// place, where the hook script ignores them because they carry no
    /// identity, so it is logged rather than stopping the app.
    private func removeOldClaudeGlobalHooks() {
        let settingsFile = AgentConfig.claudeConfigDir.appendingPathComponent("settings.json")
        do {
            if try ClaudeCodeProvider.removeGlobalHooks(
                settingsFile: settingsFile,
                root: config.root,
                isProduction: isProduction) {
                Self.logger.info("removed old Clawddy hooks from \(settingsFile.path, privacy: .public)")
            }
        } catch {
            Self.logger.error(
                "could not remove old Clawddy hooks from \(settingsFile.path, privacy: .public): \(error, privacy: .public)")
        }
    }

    func shutdown() {
        bridge.shutdown()
        workspaceObservers.forEach(NotificationCenter.default.removeObserver)
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

    /// Routes a tapped agent notification to the workspace. Returns false for
    /// notifications that are not Clawddy's.
    func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool {
        guard response.notification.request.identifier.hasPrefix("clawddy."),
              let rawID = response.notification.request.content
                .userInfo["clawddy_agent_id"] as? String,
              let id = UUID(uuidString: rawID),
              let project = config.project(forAgent: id)
        else { return false }
        showWorkspace()
        revealAgent(id: id, project: project)
        if detailVC?.hasSurface(id: id) == true {
            activateAgent(id: id, project: project)
        }
        return true
    }

    /// Foreground presentation for Clawddy notifications, aligned with the
    /// notification's urgency. Nil for notifications that are not Clawddy's.
    func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions? {
        guard notification.request.identifier.hasPrefix("clawddy.") else { return nil }
        let rawID = notification.request.content.userInfo["clawddy_agent_id"] as? String
        let id = rawID.flatMap(UUID.init(uuidString:))
        if id == bridge.currentlyViewedAgentId, workspaceWindow?.isVisible == true {
            return []
        }
        if notification.request.identifier.hasSuffix(".completed") {
            return [.badge, .list]
        }
        return [.banner, .sound, .badge, .list]
    }

    // MARK: - Status item, menu, hot key

    private func updateStatusIcon(_ state: AggregateState) {
        guard let button = statusItem?.button else { return }
        switch state {
        case .idle:
            button.image = NSImage(
                systemSymbolName: "terminal",
                accessibilityDescription: "Clawddy"
            )
            button.contentTintColor = nil
            button.setAccessibilityValue("Idle")
        case .running(let count):
            let config = NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])
            button.image = NSImage(
                systemSymbolName: "terminal.fill",
                accessibilityDescription: "Clawddy — \(count) active"
            )?.withSymbolConfiguration(config)
            button.contentTintColor = nil
            button.setAccessibilityValue("\(count) running")
        case .attention:
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            button.image = NSImage(
                systemSymbolName: "terminal.fill",
                accessibilityDescription: "Clawddy — needs attention"
            )?.withSymbolConfiguration(config)
            button.contentTintColor = nil
            button.setAccessibilityValue("Needs attention")
        }
    }

    private func registerSearchHotKey() {
        let hotKeyID = EventHotKeyID(signature: 0x4147_4E54, id: 1) // "AGNT"
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
                appDelegate.clawddy.toggleSearch()
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

    @objc private func statusItemClicked() {
        showWorkspace()
    }

    @objc private func showWorkspaceCommand() {
        showWorkspace()
    }

    @objc private func searchAgentsCommand() {
        toggleSearch()
    }

    @objc private func startSelectedAgentCommand() {
        showWorkspace()
        guard let id = workspaceModel.selectedAgentID,
              let project = config.project(forAgent: id)
        else { return }
        activateAgent(id: id, project: project)
    }

    @objc private func focusAgentTerminalCommand() {
        detailVC?.focusTerminal()
    }

    @objc private func showSelectedAgentDetailsCommand() {
        showWorkspace()
        detailVC?.showAgentDetails()
    }

    private func setupMenu() {
        guard let mainMenu = NSApp.mainMenu,
              !mainMenu.items.contains(where: { $0.title == "Agent" })
        else { return }

        let root = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Agent")
        root.submenu = menu

        let open = NSMenuItem(
            title: "Open Agent Workspace",
            action: #selector(showWorkspaceCommand),
            keyEquivalent: "a")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        menu.addItem(open)

        let search = NSMenuItem(
            title: "Search Agents…",
            action: #selector(searchAgentsCommand),
            keyEquivalent: "k")
        search.keyEquivalentModifierMask = [.command]
        search.target = self
        menu.addItem(search)
        menu.addItem(.separator())

        let start = NSMenuItem(
            title: "Start or Focus Selected Agent",
            action: #selector(startSelectedAgentCommand),
            keyEquivalent: "\r")
        start.keyEquivalentModifierMask = [.command]
        start.target = self
        menu.addItem(start)

        let details = NSMenuItem(
            title: "Show Agent Details",
            action: #selector(showSelectedAgentDetailsCommand),
            keyEquivalent: "i")
        details.keyEquivalentModifierMask = [.command]
        details.target = self
        menu.addItem(details)

        let focus = NSMenuItem(
            title: "Focus Agent Terminal",
            action: #selector(focusAgentTerminalCommand),
            keyEquivalent: "3")
        focus.keyEquivalentModifierMask = [.command]
        focus.target = self
        menu.addItem(focus)

        mainMenu.addItem(root)
    }

    // MARK: - Workspace window

    @discardableResult
    func showWorkspace(activate: Bool = true) -> NSWindow? {
        if workspaceWindow == nil {
            let detailVC = AgentDetailViewController(ghostty: ghostty, bridge: bridge)
            self.detailVC = detailVC

            let navigationView = AgentInteractiveHostingView(rootView: AgentNavigationView(
                config: config,
                bridge: bridge,
                model: workspaceModel,
                onSelectScope: { [weak self] scope in
                    self?.selectAgentScope(scope)
                }
            ))

            let agentListView = AgentInteractiveHostingView(rootView: AgentListView(
                config: config,
                bridge: bridge,
                model: workspaceModel,
                onSelectAgent: { [weak self] id, project, intent in
                    self?.selectAgent(id: id, project: project, intent: intent)
                },
                onReconcileSelection: { [weak self] visibleIDs, fallbackID in
                    self?.reconcileAgentSelection(
                        visibleAgentIDs: visibleIDs,
                        fallbackAgentID: fallbackID)
                },
                onActivateAgent: { [weak self] id, project in
                    self?.activateAgent(id: id, project: project)
                },
                onForkAgent: { [weak self] sourceId, project, taskName in
                    guard let self else { return }
                    if let entry = self.bridge.forkAgent(
                        sourceId: sourceId, config: self.config,
                        project: project.name, task: taskName) {
                        let scope = self.config.task(forAgent: entry.id).map {
                            AgentWorkspaceModel.Scope.task(
                                projectID: project.id,
                                taskID: $0.id)
                        }
                        self.activateAgent(id: entry.id, project: project, scope: scope)
                    }
                },
                onDeleteAgent: { [weak self] id in
                    guard let self else { return }
                    self.bridge.deleteAgent(id: id, config: self.config)
                    if self.workspaceModel.selectedAgentID == id {
                        self.applyAgentSelection(.reveal(scope: nil, agentID: nil))
                    }
                }
            ))

            let controller = AgentWorkspaceController(
                navigationView: navigationView,
                agentListView: agentListView,
                detailViewController: detailVC,
                onFilterChanged: { [weak self] in self?.workspaceModel.searchQuery = $0 },
                onFocusTerminal: { [weak detailVC] in detailVC?.focusTerminal() },
                canFocusTerminal: { [weak detailVC] in
                    detailVC?.hasActiveSurface == true
                },
                onShowAgentDetails: { [weak detailVC] in detailVC?.showAgentDetails() },
                canShowAgentDetails: { [weak self] in
                    self?.workspaceModel.selectedAgentID != nil
                })
            let window = makeAgentWorkspaceWindow(
                controller: controller,
                appearance: NSAppearance(ghosttyConfig: ghostty.config))
            window.onFirstResponderChanged = { [weak detailVC] in
                detailVC?.workspaceFirstResponderDidChange()
            }
            // Wired once: the header starts whichever agent it displays.
            detailVC.onStartAgent = { [weak self] id in
                guard let self, let project = self.config.project(forAgent: id) else { return }
                self.activateAgent(id: id, project: project)
            }

            detailVC.setBackgroundColor(NSColor(ghostty.config.backgroundColor))
            workspaceWindow = window
            installWorkspaceObservers(for: window)
            if let selectedID = workspaceModel.selectedAgentID,
               let project = config.project(forAgent: selectedID) {
                selectAgent(id: selectedID, project: project)
            }
        }

        if activate {
            NSApp.activate(ignoringOtherApps: true)
            workspaceWindow?.makeKeyAndOrderFront(nil)
        }
        return workspaceWindow
    }

    // MARK: - Selection

    private func selectAgent(
        id: UUID,
        project _: AgentProject,
        intent: AgentSelectionIntent = .reveal
    ) {
        let action: AgentWorkspaceSelectionAction = intent == .inspect
            ? .userSelectedAgent(id)
            : .reveal(scope: nil, agentID: id)
        applyAgentSelection(action)
    }

    private func selectAgentScope(_ scope: AgentWorkspaceModel.Scope) {
        applyAgentSelection(.userSelectedScope(
            scope,
            agentID: mostImportantAgentID(for: scope)))
    }

    private func reconcileAgentSelection(
        visibleAgentIDs: [UUID],
        fallbackAgentID: UUID?
    ) {
        applyAgentSelection(.reconcile(
            visibleAgentIDs: Set(visibleAgentIDs),
            fallbackAgentID: fallbackAgentID))
    }

    private func applyAgentSelection(_ action: AgentWorkspaceSelectionAction) {
        switch workspaceModel.apply(action) {
        case .none:
            return
        case .present(nil, _):
            renderPlaceholder()
        case .present(let id?, let intent):
            guard let project = config.project(forAgent: id),
                  let agent = bridge.agents[id],
                  let detailVC
            else {
                renderPlaceholder()
                return
            }
            renderSelection(
                id: id,
                agent: agent,
                project: project,
                detailVC: detailVC,
                intent: intent)
        }
    }

    private func renderSelection(
        id: UUID,
        agent: AgentInstance,
        project: AgentProject,
        detailVC: AgentDetailViewController,
        intent: AgentSelectionIntent
    ) {
        if explicitlyViewedAgentID != id {
            explicitlyViewedAgentID = nil
            bridge.setCurrentlyViewedAgent(nil)
        }
        if intent == .inspect, let task = config.task(forAgent: id) {
            workspaceModel.recordExplicitSelection(
                agentID: id,
                projectID: project.id,
                taskID: task.id)
        }
        detailVC.selectAgent(agent, projectName: project.name)
        if intent == .inspect, detailVC.hasSurface(id: id) {
            explicitlyViewedAgentID = id
        }
        updateViewingState()
        workspaceWindow?.title = "\(project.name) — \(agent.name)"
    }

    private func renderPlaceholder() {
        explicitlyViewedAgentID = nil
        bridge.setCurrentlyViewedAgent(nil)
        detailVC?.showPlaceholder()
        workspaceWindow?.title = "Clawddy"
    }

    private func revealAgent(id: UUID, project: AgentProject) {
        let scope = config.task(forAgent: id).map {
            AgentWorkspaceModel.Scope.task(projectID: project.id, taskID: $0.id)
        }
        applyAgentSelection(.reveal(scope: scope, agentID: id))
    }

    private func mostImportantAgentID(for scope: AgentWorkspaceModel.Scope) -> UUID? {
        var candidates: [AgentImportanceCandidate] = []
        var configurationRank = 0
        for project in config.projects {
            for task in project.tasks {
                for entry in task.agents {
                    defer { configurationRank += 1 }
                    guard let instance = bridge.agents[entry.id],
                          AgentWorkspaceProjection.includes(
                            instance,
                            project: project,
                            task: task,
                            scope: scope),
                          AgentWorkspaceProjection.matchesSearch(
                            entry,
                            project: project,
                            task: task,
                            instance: instance,
                            query: workspaceModel.searchQuery)
                    else { continue }
                    candidates.append(AgentImportanceCandidate(
                        id: entry.id,
                        state: instance.displayState,
                        lastAuthoritativeChange: instance.lastAuthoritativeChange,
                        configurationRank: configurationRank))
                }
            }
        }
        return AgentImportance.mostImportant(
            in: candidates,
            preferredID: workspaceModel.preferredAgentID(for: scope))
    }

    private func installWorkspaceObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        let reference = ControllerReference(self)
        for name in [
            NSWindow.willCloseNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
        ] {
            workspaceObservers.append(center.addObserver(
                forName: name,
                object: window,
                queue: .main,
                using: { [reference] _ in
                    Task { @MainActor in
                        reference.value?.bridge.setCurrentlyViewedAgent(nil)
                    }
                }))
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
            workspaceObservers.append(center.addObserver(
                forName: name,
                object: window,
                queue: .main,
                using: { [reference] _ in
                    Task { @MainActor in
                        reference.value?.updateViewingState()
                    }
                }))
        }
    }

    /// Reconciles the bridge's viewed agent from the surface the workspace
    /// actually presents. Activation intent survives asynchronous launch
    /// preparation in `explicitlyViewedAgentID`, but it only becomes viewing
    /// once that pane owns a live surface and the window can show it. Called
    /// after selection, presentation, death, and window key transitions.
    private func updateViewingState() {
        guard let window = workspaceWindow, let detailVC else {
            bridge.setCurrentlyViewedAgent(nil)
            return
        }
        let presentedID = detailVC.activeID
        bridge.setCurrentlyViewedAgent(AgentViewingPolicy.viewedAgentID(
            in: AgentViewingContext(
                explicitAgentID: explicitlyViewedAgentID,
                selectedAgentID: workspaceModel.selectedAgentID,
                presentedAgentID: presentedID,
                presentedSurfaceIsLive: presentedID.map(detailVC.hasSurface(id:)) ?? false,
                windowIsVisible: window.isVisible,
                windowIsKey: window.isKeyWindow,
                windowIsMiniaturized: window.isMiniaturized)))
    }

    private func activateAgent(
        id: UUID,
        project: AgentProject,
        scope: AgentWorkspaceModel.Scope? = nil
    ) {
        guard let detailVC else { return }
        applyAgentSelection(.reveal(scope: scope, agentID: id))
        guard detailVC.activeID == id else { return }
        // Record intent before preparation starts. It stays pending while the
        // surface is being created and only becomes viewed once the bridge
        // reports the presented surface, so the first start and restarts are
        // focused and acknowledged without a second activation.
        explicitlyViewedAgentID = id
        bridge.activateAgent(id: id, host: detailVC, project: project)
        updateViewingState()
        if let agent = bridge.agents[id] {
            workspaceWindow?.title = "\(project.name) — \(agent.name)"
        }
    }

    // MARK: - Search palette

    func toggleSearch() {
        if let panel = searchPanel, panel.isVisible {
            panel.hide()
            return
        }

        if searchPanel == nil {
            let view = AgentCommandPaletteView(
                config: config,
                bridge: bridge,
                onSelectAgent: { [weak self] id, project in
                    self?.searchPanel?.commitSelection()
                    self?.showWorkspace()
                    self?.revealAgent(id: id, project: project)
                    if self?.detailVC?.hasSurface(id: id) == true {
                        self?.activateAgent(id: id, project: project)
                    }
                },
                onDismiss: { [weak self] in
                    self?.searchPanel?.hide()
                }
            )
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 540, height: 320)
            // Let SwiftUI's .shadow extend past the host's rectangular bounds
            // into the transparent panel area; otherwise the shadow gets
            // clipped flat and appears as a sharp dark rectangle.
            host.clipsToBounds = false
            searchPanel = AgentSearchPanel(contentView: host)
        }

        searchPanel?.showCentered()
    }
}

extension ClawddyController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(startSelectedAgentCommand), #selector(showSelectedAgentDetailsCommand):
            return workspaceModel.selectedAgentID != nil
        case #selector(focusAgentTerminalCommand):
            return detailVC?.hasActiveSurface == true
        default:
            return true
        }
    }
}
