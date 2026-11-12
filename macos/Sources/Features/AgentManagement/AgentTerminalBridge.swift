import AppKit
import SwiftUI
import GhosttyKit
@preconcurrency import UserNotifications
import os

private let agentPollThrottle: TimeInterval = 0.2

// MARK: - Display State (derived, never stored)

enum DisplayState: Equatable, Sendable {
    case inactive
    case launching
    case idle
    case finished       // alive + idle + unread
    case thinking
    case working
    case permission
    case input
    case authentication
    case error
    case compacting
    case statusDelayed
    case statusUnavailable
    case failed
    case dead

    var color: Color {
        switch self {
        case .inactive:     return .secondary.opacity(0.3)
        case .launching:    return .secondary
        case .idle:         return .secondary
        case .finished:     return .yellow
        case .thinking:     return .blue
        case .working:      return .green
        case .permission, .input, .authentication, .statusDelayed,
                .statusUnavailable: return .orange
        case .error, .failed: return .red
        case .compacting:   return .purple
        case .dead:         return .secondary.opacity(0.3)
        }
    }

    var selectionTint: Color {
        switch self {
        case .finished:     return .yellow
        case .thinking:     return .blue
        case .working:      return .green
        case .permission, .input, .authentication: return .orange
        case .statusDelayed, .statusUnavailable: return .orange
        case .error, .failed: return .red
        case .compacting:   return .purple
        default:            return .accentColor
        }
    }

    var label: String {
        switch self {
        case .inactive:     return "Not Started"
        case .launching:    return "Starting"
        case .idle:         return "Ready"
        case .finished:     return "Completed"
        case .thinking:     return "Thinking"
        case .working:      return "Working"
        case .permission:   return "Waiting for You"
        case .input:        return "Input Required"
        case .authentication: return "Sign In Required"
        case .error:        return "Needs Attention"
        case .compacting:   return "Optimizing Context"
        case .statusDelayed: return "Status Delayed"
        case .statusUnavailable: return "Status Unavailable"
        case .failed:       return "Couldn't Start"
        case .dead:         return "Exited"
        }
    }

    /// Untouched agents are already communicated by the quiet empty-circle
    /// glyph. Repeating "Not Started" for every row overwhelms useful state
    /// changes in dense workspaces, while the detail header and accessibility
    /// value continue to expose the full lifecycle state.
    var showsListLabel: Bool {
        self != .inactive
    }

    var iconName: String? {
        switch self {
        case .inactive:     return nil
        case .launching:    return "circle.dotted"
        case .idle:         return "moon.fill"
        case .finished:     return "bell.badge.fill"
        case .thinking:     return "brain"
        case .working:      return "bolt.fill"
        case .permission:   return "exclamationmark.circle.fill"
        case .input:        return "keyboard.fill"
        case .authentication: return "person.crop.circle.badge.exclamationmark"
        case .error:        return "xmark.circle.fill"
        case .compacting:   return "arrow.triangle.2.circlepath"
        case .statusDelayed: return "clock.badge.exclamationmark"
        case .statusUnavailable: return "exclamationmark.circle"
        case .failed:       return "exclamationmark.triangle.fill"
        case .dead:         return "xmark"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .finished, .permission, .input, .authentication, .error, .failed: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .launching, .thinking, .working, .compacting: return true
        default: return false
        }
    }
}

// MARK: - Agent Instance (per-agent observable)

@Observable
@MainActor
final class AgentInstance: Identifiable {
    let id: UUID
    var name: String
    let provider: AgentProviderID
    var launchProfile: AgentLaunchProfile
    var surfaceState: AgentSurfaceState = .inactive
    var processState: AgentProcessState = .notStarted
    var activityState: AgentActivityState = .unknown
    var interactionState: AgentInteractionState = .none
    var telemetryHealth: AgentTelemetryHealth = .notStarted
    var unreadCompletion: AgentCompletionID?
    var lastAppliedCompletion: AgentCompletionID?
    var failureMessage: String?
    var runtimeErrorMessage: String?
    var launchGeneration: UUID?
    var sessionID: String?
    var turnState: AgentTurnState = .inactive
    var metadata: AgentSessionMetadata?
    var metadataAvailability: AgentMetadataAvailability = .notStarted
    @ObservationIgnored var lastHookTime: Date?
    @ObservationIgnored var launchTime: Date?
    /// Monotonic presentation evidence used only when the user deliberately
    /// asks the workspace to choose among equally urgent agents. It never
    /// changes list order or steals focus as runtime state evolves.
    @ObservationIgnored var lastAuthoritativeChange: Date?
    @ObservationIgnored var providerEventLedger = AgentProviderEventLedger()

    var displayState: DisplayState {
        if failureMessage != nil { return .failed }
        if runtimeErrorMessage != nil { return .error }
        switch interactionState {
        case .permission: return .permission
        case .input: return .input
        case .authentication: return .authentication
        case .none: break
        }
        // Completion is durable user-attention state. A provider or surface
        // exit must not hide work that the user has not reviewed yet.
        if unreadCompletion != nil { return .finished }
        switch surfaceState {
        case .inactive: return .inactive
        case .opening: return .launching
        case .failed: return .failed
        case .closed: return .dead
        case .open: break
        }
        if processState == .exited { return .dead }
        if telemetryHealth == .delayed { return .statusDelayed }
        switch activityState {
        case .unknown:
            if case .unavailable = telemetryHealth { return .statusUnavailable }
            return .launching
        case .idle: return .idle
        case .reasoning: return .thinking
        case .executing: return .working
        case .compacting: return .compacting
        }
    }

    init(entry: AgentEntry) {
        id = entry.id
        name = entry.name
        provider = entry.provider
        launchProfile = entry.launchProfile
    }

    var isUnread: Bool { unreadCompletion != nil }
    var isStarting: Bool {
        surfaceState == .opening && processState == .launching
    }

    var runtimeSnapshot: AgentRuntimeSnapshot {
        get {
            AgentRuntimeSnapshot(
                surfaceState: surfaceState,
                processState: processState,
                activityState: activityState,
                interactionState: interactionState,
                telemetryHealth: telemetryHealth,
                unreadCompletion: unreadCompletion,
                lastAppliedCompletion: lastAppliedCompletion,
                failureMessage: failureMessage,
                runtimeErrorMessage: runtimeErrorMessage,
                launchGeneration: launchGeneration,
                sessionID: sessionID,
                turnState: turnState)
        }
        set {
            surfaceState = newValue.surfaceState
            processState = newValue.processState
            activityState = newValue.activityState
            interactionState = newValue.interactionState
            telemetryHealth = newValue.telemetryHealth
            unreadCompletion = newValue.unreadCompletion
            lastAppliedCompletion = newValue.lastAppliedCompletion
            failureMessage = newValue.failureMessage
            runtimeErrorMessage = newValue.runtimeErrorMessage
            launchGeneration = newValue.launchGeneration
            sessionID = newValue.sessionID
            turnState = newValue.turnState
        }
    }
}

// MARK: - Aggregate State

enum AggregateState: Equatable {
    case idle
    case running(Int)
    case attention
}

// MARK: - Persisted Bridge State

private struct PersistedState: Codable {
    var unreadCompletions: [UUID: AgentCompletionID] = [:]
    var lastAppliedCompletions: [UUID: AgentCompletionID] = [:]
    var pendingRenames: [UUID: String] = [:]
    var eventOffsets: [UUID: Int] = [:]

    private enum CodingKeys: String, CodingKey {
        case unreadCompletions, unreadAgents, lastAppliedCompletions, pendingRenames, eventOffsets
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unreadCompletions = try container.decodeIfPresent(
            [UUID: AgentCompletionID].self,
            forKey: .unreadCompletions) ?? [:]
        lastAppliedCompletions = try container.decodeIfPresent(
            [UUID: AgentCompletionID].self,
            forKey: .lastAppliedCompletions) ?? [:]
        pendingRenames = try container.decodeIfPresent(
            [UUID: String].self,
            forKey: .pendingRenames) ?? [:]
        eventOffsets = try container.decodeIfPresent(
            [UUID: Int].self,
            forKey: .eventOffsets) ?? [:]
        // `unreadAgents` is intentionally decoded by AgentBridge.start because
        // only the current config knows the migrated provider identity.
        legacyUnreadAgents = try container.decodeIfPresent(
            Set<UUID>.self,
            forKey: .unreadAgents) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(unreadCompletions, forKey: .unreadCompletions)
        try container.encode(lastAppliedCompletions, forKey: .lastAppliedCompletions)
        try container.encode(pendingRenames, forKey: .pendingRenames)
        try container.encode(eventOffsets, forKey: .eventOffsets)
    }

    var legacyUnreadAgents: Set<UUID> = []
}

private struct AgentMetadataFileUpdate: Sendable {
    let data: Data
    let snapshot: AgentSessionMetadata?
}

struct AgentPreparedSurfaceLaunch: Sendable {
    var provider: AgentProviderID
    var generation: UUID
    var scriptURL: URL
    var environment: [String: String]
    var metadataAvailability: AgentMetadataAvailability
    var integrationIssue: String?
}

enum AgentSurfaceLaunchOutcome: Sendable {
    case success(AgentPreparedSurfaceLaunch)
    case failure(
        AgentProviderIssue,
        provider: AgentProviderID,
        generation: UUID,
        integrationIssue: String?)
}

private struct AgentAppHandle: @unchecked Sendable {
    var value: ghostty_app_t
}

private final class AgentDetailReference: @unchecked Sendable {
    weak var value: AgentDetailViewController?

    init(_ value: AgentDetailViewController) {
        self.value = value
    }
}

struct AgentLaunchCoordinator: Sendable {
    let providers: AgentProviderTable
    let root: AgentDataRoot

    func prepare(_ initialRequest: AgentLaunchRequest) -> AgentSurfaceLaunchOutcome {
        var request = initialRequest
        let agentID = request.agentID
        let name = request.name
        let provider = request.provider
        let generation = request.launchGeneration
        request.session = AgentSessionStore.session(
            for: agentID,
            provider: provider,
            directory: root.statusDir)
        request.pendingFork = AgentSessionStore.pendingFork(
            for: agentID,
            provider: provider,
            directory: root.statusDir)
        let prepared: AgentPreparedLaunch
        switch providers.prepareLaunch(request) {
        case .success(let launch): prepared = launch
        case .failure(let issue):
            return .failure(
                issue,
                provider: provider,
                generation: generation,
                integrationIssue: nil)
        }
        // A session ID the launch chose is the agent's binding before the
        // process starts; the `SessionStart` hook later writes the same one.
        if let session = prepared.newSession,
           !AgentSessionStore.write(session, for: agentID, directory: root.statusDir) {
            return .failure(
                .launchPreparationFailed(provider, "The new session's ID could not be saved."),
                provider: provider,
                generation: generation,
                integrationIssue: nil)
        }
        let integrationIssue: String?
        switch providers.prepareIntegration(provider) {
        case .success(let preparation): integrationIssue = preparation.notice
        case .failure(let issue): integrationIssue = issue.localizedDescription
        }

        // Agent identity is whatever the provider asked for: none for Claude,
        // whose hooks carry it as arguments; the CLAWDDY_* names for Codex.
        var environment = AgentTerminalEnvironmentPolicy.explicitEnvironment(
            from: prepared.environment)
        environment["HOME"] = AgentConfig.accountHomeDirectory.path
        environment["PATH"] = request.environmentPath
        let command = AgentTerminalEnvironmentPolicy.interactiveCommand(
            executableURL: prepared.executableURL,
            arguments: prepared.arguments)
        let exports = environment.sorted(by: { $0.key < $1.key }).map {
            "export \($0.key)=\(AgentHookRuntime.shellQuote($0.value))"
        }.joined(separator: "\n")
        let script = """
            #!/bin/zsh -l
            \(AgentTerminalEnvironmentPolicy.shellPrelude)
            \(exports)
            printf '\\033]2;%s\\007' \(AgentHookRuntime.shellQuote(name))
            clear
            \(command)
            command_status=$?
            \(AgentHookRuntime.exitEventCommand(
                provider: provider,
                agentID: agentID,
                generation: generation,
                statusDirectory: root.statusDir))
            printf '\\n\\033[33mAgent exited (status %s). Continuing in your login shell.\\033[0m\\n' "$command_status"
            exec "${SHELL:-/bin/zsh}" -l
            """
        let scriptURL = root.newLaunchScriptURL(agentID: agentID)
        guard AgentConfig.atomicWrite(Data(script.utf8), to: scriptURL) else {
            return .failure(
                .launchPreparationFailed(provider, "The launch script could not be created."),
                provider: provider,
                generation: generation,
                integrationIssue: integrationIssue)
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path)
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            return .failure(
                .launchPreparationFailed(
                    provider,
                    "The launch script could not be made executable."),
                provider: provider,
                generation: generation,
                integrationIssue: integrationIssue)
        }
        return .success(AgentPreparedSurfaceLaunch(
            provider: provider,
            generation: generation,
            scriptURL: scriptURL,
            environment: environment,
            metadataAvailability: prepared.metadataAvailability,
            integrationIssue: integrationIssue))
    }
}

// MARK: - Agent Bridge

@Observable
@MainActor
final class AgentBridge {
    private(set) var agents: [UUID: AgentInstance] = [:]
    private(set) var providerHealth: [AgentProviderID: AgentProviderHealth] = Dictionary(
        uniqueKeysWithValues: AgentProviderID.allCases.map {
            ($0, AgentProviderHealth())
        })

    var onAggregateStateChanged: ((AggregateState) -> Void)?
    var onSendText: ((UUID, String) -> Void)?
    var onSurfaceDeath: ((UUID) -> Void)?
    /// Fires when the set of presented agent surfaces changes, after the
    /// presentation and after death teardown. The workspace owner owns
    /// `currentlyViewedAgentId`, so it must reconcile from the surface that
    /// actually exists rather than from launch intent.
    var onSurfacePresentationChanged: ((UUID) -> Void)?
    private(set) var currentlyViewedAgentId: UUID?

    private var pendingRenames: [UUID: String] = [:]
    private var eventOffsets: [UUID: Int] = [:]
    private var metadataFileData: [UUID: Data] = [:]
    private var lastAggregateState: AggregateState?
    private var isTerminating = false

    private var heartbeatTimer: (any AgentTimer)?
    private var statusDirWatcher: DispatchSourceFileSystemObject?
    private var healthRefreshGenerations: [AgentProviderID: UUID] = [:]
    private var compactingTimers: [UUID: any AgentTimer] = [:]
    private var launchScripts: [UUID: URL] = [:]
    let root: AgentDataRoot
    private let providers: AgentProviderTable
    private let scheduler: any AgentScheduler
    private let io: any AgentIOExecutor
    private let notifier: any AgentNotifier
    private let diagnose: AgentDiagnosticsSink
    private var integrationIssues: [AgentProviderID: String] = [:]
    var environmentPath: String? {
        didSet {
            guard environmentPath != oldValue else { return }
            refreshProviderHealth()
        }
    }

    /// Throttle file watcher: hooks fire bursts (4 fs events per claude event,
    /// ×N agents = 100+/sec). Coalesce into one poll per window.
    private var pollPending = false
    private var pollInFlight = false
    private var pollAgainNeeded = false
    private var compactingJournals: Set<UUID> = []
    private static let journalCompactionThreshold = 1_048_576

    /// Compacting is provably bounded (~5-15s). If no PostCompact arrives
    /// within this window, the state is stale (e.g., user cancelled).
    private static let compactingTimeout: TimeInterval = 30

    private var surfaceViews: [UUID: Ghostty.SurfaceView] = [:]
    private var surfaceObservers: [UUID: NSObjectProtocol] = [:]
    private var launchTimers: [UUID: any AgentTimer] = [:]

    private var statusDir: URL { root.statusDir }

    init(
        root: AgentDataRoot,
        providers: AgentProviderTable,
        scheduler: any AgentScheduler = AgentRunLoopScheduler(),
        io: any AgentIOExecutor = AgentDispatchIO(),
        notifier: any AgentNotifier = AgentUserNotificationCenter(),
        diagnose: @escaping AgentDiagnosticsSink = AgentDiagnostics.unifiedLog
    ) {
        self.root = root
        self.providers = providers
        self.scheduler = scheduler
        self.io = io
        self.notifier = notifier
        self.diagnose = diagnose
    }

    // MARK: - Lifecycle

    func start(config: AgentConfig) {
        do {
            try root.resetLaunchDir()
        } catch {
            fatalError("Could not reset \(root.launchDir.path): \(error)")
        }
        let persisted = loadPersistedState()
        pendingRenames = persisted.pendingRenames
        eventOffsets = persisted.eventOffsets

        // Reconstruct agents from config
        for entry in config.allAgentEntries {
            let agent = AgentInstance(entry: entry)
            agent.unreadCompletion = persisted.unreadCompletions[entry.id]
            agent.lastAppliedCompletion = persisted.lastAppliedCompletions[entry.id]
                ?? agent.unreadCompletion
            if agent.unreadCompletion == nil, persisted.legacyUnreadAgents.contains(entry.id) {
                agent.unreadCompletion = AgentCompletionID(
                    provider: entry.provider,
                    sessionID: AgentSessionStore.session(
                        for: entry.id,
                        provider: entry.provider,
                        directory: statusDir)?.sessionID,
                    turnID: nil,
                    launchGeneration: UUID(),
                    eventID: "legacy-unread")
                agent.lastAppliedCompletion = agent.unreadCompletion
            }
            agents[entry.id] = agent
        }

        refreshProviderHealth()

        // File watcher for real-time state updates
        startStatusDirWatcher()

        // Heartbeat timer: infrequent fallback for edge cases (crashes without notification)
        heartbeatTimer = scheduler.timer(interval: 10.0, repeats: true) { [weak self] in
            self?.heartbeat()
        }

        // Opt-in diagnostics are available in the exact Release binary without
        // imposing queue traffic on ordinary production runs.
        BridgeMetrics.shared.start()
        updateMetricsSnapshot()

        // Consume any events that landed after the last persisted offset.
        requestStatusPoll(after: 0)

        diagnose(.info, "started — \(agents.count) agents")
    }

    func shutdown() {
        isTerminating = true
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        statusDirWatcher?.cancel()
        statusDirWatcher = nil
        for timer in launchTimers.values { timer.invalidate() }
        launchTimers.removeAll()
        for timer in compactingTimers.values { timer.invalidate() }
        compactingTimers.removeAll()
        for observer in surfaceObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
        surfaceObservers.removeAll()
        removeAllLaunchScripts(synchronously: true)
        persistState(synchronously: true)
        BridgeMetrics.shared.stop()
    }

    private var effectiveEnvironmentPath: String {
        if let environmentPath, !environmentPath.isEmpty { return environmentPath }
        if let inherited = ProcessInfo.processInfo.environment["PATH"], !inherited.isEmpty {
            return inherited
        }
        return "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    func refreshProviderHealth(_ targetProvider: AgentProviderID? = nil) {
        let path = effectiveEnvironmentPath
        let providers = targetProvider.map { [$0] } ?? AgentProviderID.allCases
        let io = self.io
        let probe = self.providers.probe
        for provider in providers {
            let refreshGeneration = UUID()
            healthRefreshGenerations[provider] = refreshGeneration
            io.probe { [weak self] in
                var health = probe(provider, path)
                io.onMainActor { [weak self] in
                    guard let self,
                          self.healthRefreshGenerations[provider] == refreshGeneration
                    else { return }
                    if let issue = self.integrationIssues[provider] {
                        health.integrationIssue = issue
                    }
                    self.providerHealth[provider] = health
                    self.reconcileInactiveAuthentication(
                        provider: provider,
                        authentication: health.authentication)
                }
            }
        }
    }

    func providerCapabilities(for provider: AgentProviderID) -> AgentProviderCapabilities {
        providers.capabilities(provider)
    }

    private func reconcileInactiveAuthentication(
        provider: AgentProviderID,
        authentication: AgentProviderAuthState
    ) {
        var changed = false
        for agent in agents.values where agent.provider == provider
            && agent.surfaceState == .inactive
            && agent.processState == .notStarted
            && agent.unreadCompletion == nil {
            let reconciled = AgentAuthenticationPresentation.reconciledInteraction(
                current: agent.interactionState,
                authentication: authentication)
            if reconciled != agent.interactionState {
                agent.interactionState = reconciled
                changed = true
            }
        }
        if changed { updateAggregate() }
    }

    // MARK: - Reconciliation (call after config.load())

    func reconcileWithConfig(_ config: AgentConfig) {
        let allEntries = config.allAgentEntries
        let configIds = Set(allEntries.map(\.id))

        // Add instances for new entries
        for entry in allEntries where agents[entry.id] == nil {
            let agent = AgentInstance(entry: entry)
            if providerHealth[entry.provider]?.authentication == .signedOut {
                agent.interactionState = .authentication
            }
            agents[entry.id] = agent
            BridgeMetrics.shared.recordMutAgentsDict()
        }

        // Remove instances for deleted entries
        for id in agents.keys where !configIds.contains(id) {
            destroySurface(id: id)
            agents.removeValue(forKey: id)
            BridgeMetrics.shared.recordMutAgentsDict()
            pendingRenames.removeValue(forKey: id)
            eventOffsets.removeValue(forKey: id)
            metadataFileData.removeValue(forKey: id)
        }

        // Sync editable values. Provider identity can replace only a runtime
        // that has never launched and has no persisted session identity.
        for entry in allEntries {
            if let agent = agents[entry.id] {
                let persistedProvider = AgentSessionStore.persistedProvider(
                    for: entry.id,
                    directory: statusDir)
                switch AgentRuntimeProviderPolicy.decision(
                    current: agent.provider,
                    requested: entry.provider,
                    persistedProvider: persistedProvider,
                    surfaceState: agent.surfaceState,
                    processState: agent.processState) {
                case .unchanged:
                    break
                case .replaceInactiveRuntime:
                    let replacement = AgentInstance(entry: entry)
                    if providerHealth[entry.provider]?.authentication == .signedOut {
                        replacement.interactionState = .authentication
                    }
                    if agent.unreadCompletion?.provider == entry.provider {
                        replacement.unreadCompletion = agent.unreadCompletion
                    }
                    if agent.lastAppliedCompletion?.provider == entry.provider {
                        replacement.lastAppliedCompletion = agent.lastAppliedCompletion
                    }
                    agents[entry.id] = replacement
                    BridgeMetrics.shared.recordMutAgentsDict()
                    continue
                case .preserveRuntimeAndRestoreConfig:
                    diagnose(
                        .error,
                        "rejected provider change for bound or active agent \(entry.id)")
                    _ = config.restoreProvider(id: entry.id, provider: agent.provider)
                }
                if agent.name != entry.name {
                    agent.name = entry.name
                    BridgeMetrics.shared.recordMutAgentName()
                }
                agent.launchProfile = entry.launchProfile
            }
        }
        updateAggregate()
        updateMetricsSnapshot()
        persistState()
    }

    // MARK: - Agent Creation (sync with config)

    func createAgent(
        name: String,
        provider: AgentProviderID = .claudeCode,
        launchProfile: AgentLaunchProfile = AgentLaunchProfile(),
        config: AgentConfig,
        project: String,
        task: String
    ) -> AgentEntry? {
        guard let entry = config.addAgent(
            project: project,
            task: task,
            name: name,
            provider: provider,
            launchProfile: launchProfile)
        else { return nil }
        let instance = AgentInstance(entry: entry)
        if providerHealth[provider]?.authentication == .signedOut {
            instance.interactionState = .authentication
        }
        agents[entry.id] = instance
        BridgeMetrics.shared.recordMutAgentsDict()
        updateMetricsSnapshot()
        return entry
    }

    // MARK: - Activation

    /// Starts or reveals an agent. This never declares the agent viewed:
    /// viewing requires a presented live surface and a key workspace window,
    /// which only the workspace owner can reconcile.
    func activateAgent(id: UUID, app: ghostty_app_t, detailVC: AgentDetailViewController,
                       project: AgentProject) {
        guard let agent = agents[id] else { return }

        if detailVC.hasSurface(id: id), agent.processState == .exited {
            discardSurfaceForRestart(id: id, detailVC: detailVC, provider: agent.provider)
        }

        if detailVC.hasSurface(id: id) {
            _ = detailVC.showOrSwitch(
                projectName: project.name,
                agent: agent,
                createConfig: { nil })
            return
        }

        // A second activation while background preparation is in flight only
        // reveals the existing launch state; it never creates a competing run.
        if agent.surfaceState == .opening, agent.processState == .launching {
            detailVC.selectAgent(agent, projectName: project.name)
            return
        }

        let generation = UUID()
        apply(.launchRequested(generation: generation), to: agent)
        if providerHealth[agent.provider]?.authentication == .signedOut {
            apply(
                .interactionRequired(
                    generation: generation,
                    interaction: .authentication),
                to: agent)
        }
        agent.launchTime = scheduler.now
        agent.lastHookTime = nil
        detailVC.selectAgent(agent, projectName: project.name)
        scheduleLaunchTimeout(agentID: id, generation: generation)

        let provider = agent.provider
        let name = agent.name
        let profile = agent.launchProfile
        let path = effectiveEnvironmentPath
        let workingDirectory = project.workingDirectory
        let projectName = project.name
        let appHandle = AgentAppHandle(value: app)
        let detailReference = AgentDetailReference(detailVC)
        let launchCoordinator = AgentLaunchCoordinator(
            providers: providers,
            root: root)
        let launchRequest = AgentLaunchRequest(
            agentID: id,
            name: name,
            provider: provider,
            launchProfile: profile,
            workingDirectory: workingDirectory,
            environmentPath: path,
            launchGeneration: generation,
            session: nil,
            pendingFork: nil)
        let io = self.io
        io.async { [weak self] in
            let outcome = launchCoordinator.prepare(launchRequest)
            io.onMainActor { [weak self] in
                guard let self, let detailVC = detailReference.value else {
                    if case .success(let launch) = outcome {
                        DispatchQueue.global(qos: .utility).async {
                            try? FileManager.default.removeItem(at: launch.scriptURL)
                        }
                    }
                    return
                }
                self.finishSurfaceLaunch(
                    outcome,
                    agentID: id,
                    projectName: projectName,
                    workingDirectory: workingDirectory,
                    app: appHandle.value,
                    detailVC: detailVC)
            }
        }
    }

    private func scheduleLaunchTimeout(agentID: UUID, generation: UUID) {
        launchTimers[agentID]?.invalidate()
        launchTimers[agentID] = scheduler.timer(interval: 10, repeats: false) { [weak self] in
            guard let self, let agent = self.agents[agentID],
                  agent.processState == .launching,
                  agent.launchGeneration == generation,
                  agent.lastHookTime == nil
            else { return }
            self.apply(.launchTimedOut(generation: generation), to: agent)
            self.launchTimers.removeValue(forKey: agentID)
            self.updateAggregate()
        }
    }

    private func finishSurfaceLaunch(
        _ outcome: AgentSurfaceLaunchOutcome,
        agentID: UUID,
        projectName: String,
        workingDirectory: String?,
        app: ghostty_app_t,
        detailVC: AgentDetailViewController
    ) {
        guard let agent = agents[agentID] else {
            if case .success(let launch) = outcome {
                removeFileOffMain(launch.scriptURL)
            }
            return
        }
        let integrationIssue: String?
        switch outcome {
        case .success(let launch): integrationIssue = launch.integrationIssue
        case .failure(_, _, _, let issue): integrationIssue = issue
        }
        integrationIssues[agent.provider] = integrationIssue
        if var health = providerHealth[agent.provider] {
            health.integrationIssue = integrationIssue
            providerHealth[agent.provider] = health
        }

        switch outcome {
        case .failure(let issue, let provider, let generation, _):
            guard agent.launchGeneration == generation,
                  agent.provider == provider
            else { return }
            apply(
                .launchFailed(generation: generation, message: issue.localizedDescription),
                to: agent)
            launchTimers[agentID]?.invalidate()
            launchTimers.removeValue(forKey: agentID)
            updateAggregate()

        case .success(let launch):
            guard agent.launchGeneration == launch.generation,
                  agent.provider == launch.provider,
                  agent.processState == .launching
            else {
                removeFileOffMain(launch.scriptURL)
                return
            }
            agent.metadataAvailability = launch.integrationIssue.map {
                .unavailable($0)
            } ?? launch.metadataAvailability
            removeLaunchScript(for: agentID)
            launchScripts[agentID] = launch.scriptURL
            let isNew = detailVC.presentPreparedSurface(
                projectName: projectName,
                agent: agent
            ) {
                var surfaceConfig = Ghostty.SurfaceConfiguration()
                surfaceConfig.command = launch.scriptURL.path
                surfaceConfig.workingDirectory = workingDirectory
                surfaceConfig.environmentVariables = launch.environment
                return (app, surfaceConfig)
            }
            guard isNew, let surface = detailVC.surfaceView(for: agentID) else {
                removeFileOffMain(launch.scriptURL)
                launchScripts.removeValue(forKey: agentID)
                return
            }
            surfaceViews[agentID] = surface
            apply(.surfaceOpened(generation: launch.generation), to: agent)
            BridgeMetrics.shared.recordSurfaceCreated()
            updateMetricsSnapshot()
            let observer = NotificationCenter.default.addObserver(
                forName: Ghostty.Notification.ghosttyCloseSurface,
                object: surface,
                queue: .main
            ) { [weak self] _ in
                BridgeMetrics.shared.recordProcessExitNotif()
                Task { @MainActor [weak self] in
                    self?.handleSurfaceDeath(id: agentID)
                }
            }
            surfaceObservers[agentID] = observer
            onSurfacePresentationChanged?(agentID)
        }
    }

    // MARK: - Fork

    func forkAgent(sourceId: UUID, config: AgentConfig, project: String, task: String) -> AgentEntry? {
        guard let source = agents[sourceId] else { return nil }

        // Read source session — abort if none
        guard providers.capabilities(source.provider).fork.isSupported,
              let sourceSession = AgentSessionStore.session(
                  for: sourceId,
                  provider: source.provider,
                  directory: statusDir)
        else {
            diagnose(.error, "fork: no session for source \(sourceId)")
            return nil
        }

        // Generate unique name
        let existingNames = Set(config.allAgentEntries.map(\.name))
        var forkName = "\(source.name)-fork"
        var suffix = 2
        while existingNames.contains(forkName) {
            forkName = "\(source.name)-fork-\(suffix)"
            suffix += 1
        }

        // Create agent (sync config + bridge)
        guard let entry = createAgent(
            name: forkName,
            provider: source.provider,
            launchProfile: source.launchProfile,
            config: config,
            project: project,
            task: task)
        else {
            return nil
        }

        let pending = AgentPendingFork(
            provider: source.provider,
            sourceSessionID: sourceSession.sessionID)
        guard AgentSessionStore.write(pending, for: entry.id, directory: statusDir) else {
            deleteAgent(id: entry.id, config: config)
            diagnose(.error, "fork: failed to persist source session for \(entry.id)")
            return nil
        }

        return entry
    }

    // MARK: - Rename

    func requestRename(id: UUID, newName: String) {
        let safeName = newName
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty,
              let agent = agents[id],
              agent.name != safeName
        else { return }
        agent.name = safeName
        BridgeMetrics.shared.recordMutAgentName()

        guard providers.capabilities(agent.provider).sessionRename.isSupported else {
            pendingRenames.removeValue(forKey: id)
            persistState()
            return
        }
        if isSafeForInput(agent.displayState) {
            diagnose(.info, "rename: sending /rename for \(id) immediately")
            onSendText?(id, "/rename \(safeName)\n")
        } else {
            diagnose(.info, "rename: deferring /rename for \(id)")
            pendingRenames[id] = safeName
            persistState()
        }
    }

    private func acknowledgeCompletion(id: UUID) {
        guard let agent = agents[id], agent.isUnread else { return }
        apply(.completionViewed, to: agent)
        updateAggregate()
        persistState()
    }

    func setCurrentlyViewedAgent(_ id: UUID?) {
        currentlyViewedAgentId = id
        guard let id else { return }
        acknowledgeCompletion(id: id)
        clearNotifications(for: id)
    }

    // MARK: - Deletion

    @discardableResult
    func deleteAgent(id: UUID, config: AgentConfig) -> Bool {
        guard config.removeAgent(id: id) else { return false }
        removeAgentRuntime(id: id)
        updateAggregate()
        updateMetricsSnapshot()
        persistState()
        return true
    }

    func removeAgentRuntimes(ids: [UUID]) {
        ids.forEach { removeAgentRuntime(id: $0) }
        updateAggregate()
        updateMetricsSnapshot()
        persistState()
    }

    private func removeAgentRuntime(id: UUID) {
        let agentProvider = agents[id]?.provider ?? .claudeCode
        BridgeMetrics.shared.recordSurfaceDestroyedDelete()
        destroySurface(id: id)
        agents.removeValue(forKey: id)
        BridgeMetrics.shared.recordMutAgentsDict()
        pendingRenames.removeValue(forKey: id)
        eventOffsets.removeValue(forKey: id)
        metadataFileData.removeValue(forKey: id)

        // Clean status files
        let cleanup = providers.cleanup
        let statusDir = statusDir
        io.async {
            AgentSessionStore.removeAll(for: id, directory: statusDir)
            cleanup(agentProvider, id)
        }
    }

    // MARK: - Heartbeat (infrequent correctness fallback)

    private func heartbeat() {
        guard !isTerminating else { return }
        BridgeMetrics.shared.recordHeartbeat()

        // Directory notifications accelerate updates but do not own
        // correctness. This heals dropped/coalesced FSEvents without
        // manufacturing any lifecycle state.
        requestStatusPoll(after: 0)

        // Check for process exits that the notification might have missed (e.g., crashes)
        for (id, surface) in surfaceViews where surface.processExited {
            handleSurfaceDeath(id: id)
        }
    }

    /// Evaluates telemetry confidence only after a complete journal
    /// reconciliation. This prevents a stale heartbeat from briefly replacing a
    /// completion event that is already on disk but has not been applied yet.
    private func updateTelemetryFreshness() {
        let now = scheduler.now
        var confidenceChanged = false
        for agent in agents.values {
            guard let generation = agent.launchGeneration,
                  AgentTelemetryFreshnessPolicy.isDelayed(
                    turnState: agent.turnState,
                    lastProviderEventAt: agent.lastHookTime,
                    now: now,
                    threshold: 120)
            else { continue }
            let oldHealth = agent.telemetryHealth
            apply(.telemetryDelayed(generation: generation), to: agent)
            confidenceChanged = confidenceChanged || oldHealth != agent.telemetryHealth
        }
        if confidenceChanged { updateAggregate() }
    }

    // MARK: - Event-Driven Polling (triggered by file watcher only)

    private func requestStatusPoll(after delay: TimeInterval = agentPollThrottle) {
        guard !isTerminating else { return }
        guard !pollPending, !pollInFlight else {
            pollAgainNeeded = true
            BridgeMetrics.shared.recordPollThrottled()
            return
        }
        pollPending = true
        scheduler.after(delay) { [weak self] in
            guard let self, !self.isTerminating else { return }
            self.pollPending = false
            self.pollInFlight = true
            BridgeMetrics.shared.recordPollFired()
            self.pollStatusFiles()
        }
    }

    private func pollStatusFiles() {
        guard !isTerminating else {
            pollInFlight = false
            return
        }

        let ids = Array(agents.keys)
        let compactingIDs = compactingJournals
        let offsets = eventOffsets
        let knownMetadataData = metadataFileData
        let statusDir = statusDir
        let providers = agents.mapValues(\.provider)
        let io = self.io
        let diagnose = self.diagnose
        io.async { [weak self] in
            var batches: [UUID: AgentEventJournalBatch] = [:]
            var metadataUpdates: [UUID: AgentMetadataFileUpdate] = [:]
            for id in ids {
                if !compactingIDs.contains(id) {
                    let url = statusDir.appendingPathComponent("\(id.uuidString).events")
                    let requestedOffset = offsets[id] ?? 0
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let size = attributes[.size] as? NSNumber,
                       let handle = try? FileHandle(forReadingFrom: url) {
                        let startOffset = requestedOffset <= size.intValue ? requestedOffset : 0
                        do {
                            try handle.seek(toOffset: UInt64(startOffset))
                            let data = try handle.readToEnd() ?? Data()
                            let relative = AgentEventJournal.read(data, from: 0)
                            let batch = AgentEventJournalBatch(
                                records: relative.records,
                                endOffset: startOffset + relative.endOffset)
                            if !batch.records.isEmpty || batch.endOffset != requestedOffset {
                                batches[id] = batch
                            }
                        } catch {
                            diagnose(.error, "journal read failed for \(id): \(error.localizedDescription)")
                        }
                        try? handle.close()
                    }
                }

                guard providers[id] == .claudeCode else { continue }
                let metadataURL = statusDir.appendingPathComponent("\(id.uuidString).metadata.json")
                guard let metadataData = try? Data(contentsOf: metadataURL),
                      metadataData != knownMetadataData[id]
                else { continue }
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: metadataURL.path)
                let observedAt = attributes?[.modificationDate] as? Date ?? Date()
                let snapshot = try? AgentSessionMetadata.decodeStatusLinePayload(
                    metadataData,
                    observedAt: observedAt)
                metadataUpdates[id] = AgentMetadataFileUpdate(
                    data: metadataData,
                    snapshot: snapshot)
            }
            io.onMainActor { [weak self] in
                self?.applyRawEvents(batches, metadataUpdates: metadataUpdates)
            }
        }
    }

    private func applyRawEvents(
        _ batches: [UUID: AgentEventJournalBatch],
        metadataUpdates: [UUID: AgentMetadataFileUpdate]
    ) {
        guard !isTerminating else {
            pollInFlight = false
            return
        }
        let startTime = CFAbsoluteTimeGetCurrent()
        var anyChanged = false
        var shouldPersist = false
        var compactionCandidates: [(UUID, Int)] = []

        for (id, update) in metadataUpdates {
            metadataFileData[id] = update.data
            guard let agent = agents[id], let snapshot = update.snapshot else {
                diagnose(.error, "invalid metadata snapshot for \(id)")
                continue
            }
            if agent.metadata != snapshot || agent.metadataAvailability != .available {
                agent.metadata = snapshot
                agent.metadataAvailability = .available
                shouldPersist = true
            }
        }

        for (id, batch) in batches {
            guard let agent = agents[id] else { continue }
            for (recordIndex, data) in batch.records.enumerated() {
                guard let rawEvent = try? JSONDecoder().decode(
                    AgentRawProviderEvent.self,
                    from: data)
                else { continue }
                let eventProvider: AgentProviderID
                if let taggedProvider = rawEvent.provider {
                    guard taggedProvider == agent.provider else {
                        diagnose(.error, "ignored provider-mismatched event for \(id)")
                        continue
                    }
                    eventProvider = taggedProvider
                } else {
                    // Untagged journals predate provider support and can only
                    // belong to migrated Claude Code agents.
                    guard agent.provider == .claudeCode else { continue }
                    eventProvider = .claudeCode
                }
                guard rawEvent.hasSupportedSchema(for: eventProvider) else {
                    diagnose(
                        .error,
                        "ignored unsupported event schema for \(id): \(rawEvent.schemaVersion ?? -1)")
                    continue
                }
                guard let currentGeneration = agent.launchGeneration else { continue }
                let eventGeneration: UUID
                if let taggedGeneration = rawEvent.launchGeneration {
                    guard taggedGeneration == currentGeneration else {
                        diagnose(.debug, "ignored stale launch event for \(id)")
                        continue
                    }
                    eventGeneration = taggedGeneration
                } else {
                    guard eventProvider == .claudeCode else { continue }
                    eventGeneration = currentGeneration
                }
                let domainEvents = providers.normalize(eventProvider, rawEvent)
                guard !domainEvents.isEmpty else { continue }

                let oldSnapshot = agent.runtimeSnapshot
                var effects: [AgentRuntimeEffect] = []
                var appliedNewProviderFact = false
                for (domainIndex, domainEvent) in domainEvents.enumerated() {
                    let providerEventID = rawEvent.eventID
                        .map { "\($0):\(domainIndex)" }
                        ?? "\(eventGeneration.uuidString):\(batch.endOffset):\(recordIndex):\(domainIndex)"
                    guard agent.providerEventLedger.shouldApply(
                        eventID: providerEventID,
                        generation: eventGeneration)
                    else { continue }
                    appliedNewProviderFact = true
                    effects += apply(
                        .provider(
                            generation: eventGeneration,
                            provider: eventProvider,
                            eventID: providerEventID,
                            event: domainEvent,
                            isViewed: currentlyViewedAgentId == id),
                        to: agent)
                    applyMetadata(
                        rawEvent,
                        domainEvent: domainEvent,
                        provider: eventProvider,
                        to: agent)
                }
                if oldSnapshot != agent.runtimeSnapshot {
                    anyChanged = true
                }

                if effects.contains(.becameAlive) {
                    launchTimers[id]?.invalidate()
                    launchTimers.removeValue(forKey: id)
                    removeLaunchScript(for: id)
                    let provider = agent.provider
                    integrationIssues[provider] = nil
                    let root = root
                    io.async {
                        AgentSessionStore.clearPendingFork(for: id, directory: root.statusDir)
                        if provider == .codex {
                            CodexProvider.clearHookReviewRequired(root: root)
                        }
                    }
                    refreshProviderHealth(provider)
                }
                if effects.contains(where: {
                    if case .providerExited = $0 { return true }
                    return false
                }) {
                    launchTimers[id]?.invalidate()
                    launchTimers.removeValue(forKey: id)
                    removeLaunchScript(for: id)
                }
                if appliedNewProviderFact {
                    agent.lastHookTime = scheduler.now
                }
                updateCompactingTimer(for: agent)

                let newDisplay = agent.displayState
                if effects.contains(.unreadChanged) {
                    shouldPersist = true
                }

                if currentlyViewedAgentId != id {
                    if effects.contains(.completed) {
                        postNotification(agentId: id, kind: .finished,
                            title: "Agent completed", body: "\(agent.name) is ready for review")
                    }
                    if effects.contains(.waitingForUser) {
                        postNotification(agentId: id, kind: .permission,
                            title: "Agent is waiting for you", body: "\(agent.name) needs your response")
                    }
                    if effects.contains(.failed) {
                        postNotification(agentId: id, kind: .error,
                            title: "Agent needs attention", body: "\(agent.name) encountered an error")
                    }
                }

                if isSafeForInput(newDisplay),
                   let pendingName = pendingRenames.removeValue(forKey: id) {
                    onSendText?(id, "/rename \(pendingName)\n")
                    shouldPersist = true
                }
            }
            eventOffsets[id] = batch.endOffset
            if batch.endOffset >= Self.journalCompactionThreshold {
                compactionCandidates.append((id, batch.endOffset))
            }
            BridgeMetrics.shared.recordMutLastEventContent()
            shouldPersist = true
        }

        if anyChanged {
            updateAggregate()
        }
        if shouldPersist {
            persistState()
        }
        for (id, offset) in compactionCandidates {
            scheduleJournalCompaction(id: id, acknowledgedOffset: offset)
        }

        let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        BridgeMetrics.shared.recordApplyRawEvents(durationMs: durationMs)
        finishStatusPoll()
    }

    private func finishStatusPoll() {
        pollInFlight = false
        updateTelemetryFreshness()
        guard pollAgainNeeded else { return }
        pollAgainNeeded = false
        requestStatusPoll(after: 0)
    }

    private func applyMetadata(
        _ rawEvent: AgentRawProviderEvent,
        domainEvent: AgentDomainEvent,
        provider: AgentProviderID,
        to agent: AgentInstance
    ) {
        if case .sessionStarted(let sessionID, _, _) = domainEvent,
           let sessionID,
           !sessionID.isEmpty,
           let generation = agent.launchGeneration {
            let binding = AgentSessionBinding(
                provider: provider,
                sessionID: sessionID,
                launchGeneration: generation)
            let agentID = agent.id
            let statusDir = statusDir
            io.async {
                _ = AgentSessionStore.write(binding, for: agentID, directory: statusDir)
            }
        }

        guard rawEvent.model != nil || rawEvent.permissionMode != nil || rawEvent.sessionID != nil
        else { return }
        var metadata = agent.metadata ?? AgentSessionMetadata(
            provider: provider,
            modelID: rawEvent.model,
            effortLevel: nil,
            sessionID: rawEvent.sessionID,
            runtimeVersion: runtimeVersion(for: provider),
            permissionMode: rawEvent.permissionMode)
        metadata.provider = provider
        metadata.modelID = rawEvent.model ?? metadata.modelID
        metadata.sessionID = rawEvent.sessionID ?? metadata.sessionID
        metadata.runtimeVersion = runtimeVersion(for: provider) ?? metadata.runtimeVersion
        metadata.permissionMode = rawEvent.permissionMode ?? metadata.permissionMode
        metadata.observedAt = scheduler.now
        agent.metadata = metadata
        agent.metadataAvailability = .available
    }

    private func runtimeVersion(for provider: AgentProviderID) -> String? {
        guard case .ready(_, let version) = providerHealth[provider]?.installation else {
            return nil
        }
        return version
    }

    private func scheduleJournalCompaction(id: UUID, acknowledgedOffset: Int) {
        guard compactingJournals.insert(id).inserted else { return }
        let url = statusDir.appendingPathComponent("\(id.uuidString).events")
        let lockURL = statusDir.appendingPathComponent("\(id.uuidString).events.lock")
        let io = self.io
        let diagnose = self.diagnose
        io.async { [weak self] in
            guard let self else { return }
            let compacted = AgentEventJournal.compact(
                url: url,
                lockURL: lockURL,
                acknowledgedOffset: acknowledgedOffset)
            if !compacted {
                diagnose(.debug, "journal compaction deferred for \(id)")
            }
            io.onMainQueue { [weak self] in
                guard let self else { return }
                if compacted, self.eventOffsets[id] == acknowledgedOffset {
                    self.eventOffsets[id] = 0
                    self.persistState()
                }
                self.compactingJournals.remove(id)
                self.requestStatusPoll(after: 0)
            }
        }
    }

    private func isSafeForInput(_ state: DisplayState) -> Bool {
        switch state {
        case .idle, .finished: return true
        default: return false
        }
    }

    @discardableResult
    private func apply(
        _ event: AgentRuntimeEvent,
        to agent: AgentInstance
    ) -> [AgentRuntimeEffect] {
        let old = agent.runtimeSnapshot
        let oldDisplayState = agent.displayState
        let result = AgentStateReducer.reduce(old, event: event)
        agent.runtimeSnapshot = result.state
        if agent.displayState != oldDisplayState {
            agent.lastAuthoritativeChange = scheduler.now
        }
        if old.processState != result.state.processState {
            BridgeMetrics.shared.recordMutProcessState()
        }
        if old.activityState != result.state.activityState
            || old.interactionState != result.state.interactionState {
            BridgeMetrics.shared.recordMutActivityState()
        }
        if old.unreadCompletion != result.state.unreadCompletion {
            BridgeMetrics.shared.recordMutIsUnread()
        }
        return result.effects
    }

    private func updateCompactingTimer(for agent: AgentInstance) {
        compactingTimers[agent.id]?.invalidate()
        compactingTimers.removeValue(forKey: agent.id)
        guard agent.activityState == .compacting,
              let generation = agent.launchGeneration
        else { return }

        compactingTimers[agent.id] = scheduler.timer(
            interval: Self.compactingTimeout,
            repeats: false
        ) { [weak self, weak agent] in
            guard let self, let agent,
                  agent.activityState == .compacting,
                  agent.launchGeneration == generation
            else { return }
            self.apply(.compactionExpired(generation: generation), to: agent)
            self.compactingTimers.removeValue(forKey: agent.id)
            self.updateAggregate()
            self.persistState()
        }
    }

    // MARK: - Aggregate

    var aggregateState: AggregateState {
        let states = agents.values.map(\.displayState)
        let activeCount = states.filter(\.isActive).count
        let needsAttention = states.contains(where: \.needsAttention)
        if needsAttention { return .attention }
        if activeCount > 0 { return .running(activeCount) }
        return .idle
    }

    private func updateAggregate() {
        let current = aggregateState
        if lastAggregateState != current {
            lastAggregateState = current
            BridgeMetrics.shared.recordMutLastAggregateState()
            BridgeMetrics.shared.recordAggregateChange()
            onAggregateStateChanged?(current)
        }
    }

    private func updateMetricsSnapshot() {
        BridgeMetrics.shared.updateSnapshot(
            agentCount: agents.count,
            surfaceCount: surfaceViews.count)
    }

    // MARK: - Surface Management

    func surfaceView(for id: UUID) -> Ghostty.SurfaceView? { surfaceViews[id] }

    private func discardSurfaceForRestart(
        id: UUID,
        detailVC: AgentDetailViewController,
        provider: AgentProviderID
    ) {
        surfaceViews.removeValue(forKey: id)
        if let observer = surfaceObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        launchTimers[id]?.invalidate()
        launchTimers.removeValue(forKey: id)
        compactingTimers[id]?.invalidate()
        compactingTimers.removeValue(forKey: id)
        removeLaunchScript(for: id)
        let cleanup = providers.cleanup
        io.async { cleanup(provider, id) }
        detailVC.removeSurface(id: id)
        updateMetricsSnapshot()
    }

    private func destroySurface(id: UUID) {
        surfaceViews.removeValue(forKey: id)
        updateMetricsSnapshot()
        launchTimers[id]?.invalidate()
        launchTimers.removeValue(forKey: id)
        compactingTimers[id]?.invalidate()
        compactingTimers.removeValue(forKey: id)
        removeLaunchScript(for: id)
        if let provider = agents[id]?.provider {
            let cleanup = providers.cleanup
            io.async { cleanup(provider, id) }
        }

        // Remove process exit observer
        if let observer = surfaceObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }

        if let agent = agents[id] {
            apply(.surfaceDied(generation: agent.launchGeneration), to: agent)
        }
        onSurfaceDeath?(id)
        onSurfacePresentationChanged?(id)
        updateAggregate()
        persistState()
    }

    private func handleSurfaceDeath(id: UUID) {
        diagnose(.info, "surface death: \(id)")
        BridgeMetrics.shared.recordSurfaceDestroyedExit()
        destroySurface(id: id)
    }

    // MARK: - Notifications

    private enum NotificationKind {
        case finished, permission, error

        var identifier: String {
            switch self {
            case .finished: return "completed"
            case .permission: return "waiting"
            case .error: return "error"
            }
        }
    }

    private func postNotification(agentId: UUID, kind: NotificationKind, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = agentId.uuidString
        content.userInfo = ["clawddy_agent_id": agentId.uuidString]

        switch kind {
        case .finished:
            content.sound = nil
            content.interruptionLevel = .passive
        case .permission:
            content.sound = .default
            content.interruptionLevel = .timeSensitive
        case .error:
            content.sound = .default
            content.interruptionLevel = .active
        }

        let request = UNNotificationRequest(
            identifier: "clawddy.\(agentId.uuidString).\(kind.identifier)",
            content: content, trigger: nil)
        notifier.post(request)
    }

    private func clearNotifications(for id: UUID) {
        let identifiers = [
            "clawddy.\(id.uuidString).completed",
            "clawddy.\(id.uuidString).waiting",
            "clawddy.\(id.uuidString).error",
        ]
        notifier.removeNotifications(withIdentifiers: identifiers)
    }

    // MARK: - Persistence

    private func loadPersistedState() -> PersistedState {
        guard let data = try? Data(contentsOf: root.stateFile),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    func persistState(synchronously: Bool = false) {
        var state = PersistedState()
        state.unreadCompletions = Dictionary(uniqueKeysWithValues: agents.values.compactMap {
            guard let completion = $0.unreadCompletion else { return nil }
            return ($0.id, completion)
        })
        state.lastAppliedCompletions = Dictionary(uniqueKeysWithValues: agents.values.compactMap {
            guard let completion = $0.lastAppliedCompletion else { return nil }
            return ($0.id, completion)
        })
        state.pendingRenames = pendingRenames
        state.eventOffsets = eventOffsets
        guard let data = try? JSONEncoder().encode(state) else { return }
        let stateFile = root.stateFile
        let write: @Sendable () -> Void = {
            _ = AgentConfig.atomicWrite(data, to: stateFile)
        }
        if synchronously {
            io.sync(write)
        } else {
            io.async(write)
        }
    }

    // MARK: - File Watcher

    private func startStatusDirWatcher() {
        let fd = open(statusDir.path, O_EVTONLY)
        guard fd >= 0 else {
            diagnose(.error, "failed to open status dir for watching")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            BridgeMetrics.shared.recordWatcherFire()
            self?.requestStatusPoll()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        statusDirWatcher = source
    }

    // MARK: - Cleanup

    private func removeLaunchScript(for id: UUID) {
        guard let url = launchScripts.removeValue(forKey: id) else { return }
        removeFileOffMain(url)
    }

    private func removeAllLaunchScripts(synchronously: Bool = false) {
        let urls = Array(launchScripts.values)
        launchScripts.removeAll()
        let remove: @Sendable () -> Void = {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if synchronously {
            io.sync(remove)
        } else {
            io.async(remove)
        }
    }

    private func removeFileOffMain(_ url: URL) {
        io.async {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
