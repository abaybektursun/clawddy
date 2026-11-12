import AppKit
import SwiftUI
import GhosttyKit
@preconcurrency import UserNotifications
import os

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
    /// The agent's runtime state. Only `apply` assigns it, once per event and
    /// from the reducer's result, so an observer never sees part of an event.
    private(set) var runtime: AgentRuntimeSnapshot
    var metadata: AgentSessionMetadata?
    var metadataAvailability: AgentMetadataAvailability = .notStarted
    @ObservationIgnored var lastHookTime: Date?
    /// Monotonic presentation evidence used only when the user deliberately
    /// asks the workspace to choose among equally urgent agents. It never
    /// changes list order or steals focus as runtime state evolves.
    @ObservationIgnored var lastAuthoritativeChange: Date?

    var surfaceState: AgentSurfaceState { runtime.surfaceState }
    var processState: AgentProcessState { runtime.processState }
    var activityState: AgentActivityState { runtime.activityState }
    var interactionState: AgentInteractionState { runtime.interactionState }
    var telemetryHealth: AgentTelemetryHealth { runtime.telemetryHealth }
    var unreadCompletion: AgentCompletionID? { runtime.unreadCompletion }
    var lastAppliedCompletion: AgentCompletionID? { runtime.lastAppliedCompletion }
    var failureMessage: String? { runtime.failureMessage }
    var runtimeErrorMessage: String? { runtime.runtimeErrorMessage }
    var launchGeneration: UUID? { runtime.launchGeneration }
    var sessionID: String? { runtime.sessionID }
    var turnState: AgentTurnState { runtime.turnState }
    var missingSessionID: String? { runtime.missingSessionID }

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

    /// `runtime` is the state the agent starts from: its persisted
    /// completions, or its provider's sign-in state.
    init(entry: AgentEntry, runtime: AgentRuntimeSnapshot = AgentRuntimeSnapshot()) {
        id = entry.id
        name = entry.name
        provider = entry.provider
        launchProfile = entry.launchProfile
        self.runtime = runtime
    }

    var isUnread: Bool { unreadCompletion != nil }
    /// The saved session is missing or unreadable, so the agent can only
    /// start a new one.
    var canOnlyStartFresh: Bool { missingSessionID != nil || runtime.sessionUnreadable }
    var isStarting: Bool {
        surfaceState == .opening && processState == .launching
    }

    /// The one way the runtime state changes: one reducer application is at
    /// most one observable mutation, and none when it changes nothing.
    @discardableResult
    func apply(_ event: AgentRuntimeEvent, at now: Date) -> [AgentRuntimeEffect] {
        let result = AgentStateReducer.reduce(runtime, event: event)
        guard result.state != runtime else { return result.effects }
        let oldDisplayState = displayState
        runtime = result.state
        if displayState != oldDisplayState {
            lastAuthoritativeChange = now
        }
        return result.effects
    }
}

// MARK: - Aggregate State

enum AggregateState: Equatable {
    case idle
    case running(Int)
    case attention
}

// MARK: - Persisted Bridge State

/// `state.json`. Files the app wrote before P3.4 also hold
/// `lastAppliedCompletions` and `eventOffsets`, and before P3.6
/// `pendingRenames`; none of them is read any more.
private struct PersistedState: Codable {
    var unreadCompletions: [UUID: AgentCompletionID] = [:]

    private enum CodingKeys: String, CodingKey {
        case unreadCompletions
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unreadCompletions = try container.decodeIfPresent(
            [UUID: AgentCompletionID].self,
            forKey: .unreadCompletions) ?? [:]
    }
}

struct AgentPreparedSurfaceLaunch: Sendable {
    var provider: AgentProviderID
    var generation: UUID
    var scriptURL: URL
    var environment: [String: String]
    var metadataAvailability: AgentMetadataAvailability
    var integrationIssue: String?
    /// See `AgentPreparedLaunch.resumedSessionID`.
    var resumedSessionID: String?
}

enum AgentSurfaceLaunchOutcome: Sendable {
    case success(AgentPreparedSurfaceLaunch)
    case failure(
        AgentProviderIssue,
        provider: AgentProviderID,
        generation: UUID,
        integrationIssue: String?)
}

struct AgentLaunchCoordinator: Sendable {
    let providers: AgentProviderTable
    let root: AgentDataRoot

    /// `discardingSession` first forgets the agent's saved session, so the
    /// launch starts a new one.
    func prepare(
        _ initialRequest: AgentLaunchRequest,
        discardingSession: Bool = false
    ) -> AgentSurfaceLaunchOutcome {
        var request = initialRequest
        let agentID = request.agentID
        let name = request.name
        let provider = request.provider
        let generation = request.launchGeneration
        if discardingSession {
            do {
                try AgentSessionStore.discardSession(for: agentID, directory: root.statusDir)
            } catch {
                return .failure(
                    .launchPreparationFailed(
                        provider,
                        "The saved session could not be forgotten: \(error.localizedDescription)"),
                    provider: provider,
                    generation: generation,
                    integrationIssue: nil)
            }
        }
        do {
            request.session = try AgentSessionStore.session(
                for: agentID,
                provider: provider,
                directory: root.statusDir)
            request.pendingFork = try AgentSessionStore.pendingFork(
                for: agentID,
                provider: provider,
                directory: root.statusDir)
        } catch {
            // Starting a new session instead would leave the saved
            // conversation behind without a word.
            return .failure(
                .unreadableSession(provider, error.localizedDescription),
                provider: provider,
                generation: generation,
                integrationIssue: nil)
        }
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
        // process starts; the bridge rewrites the binding from each
        // `SessionStart` of the launch.
        if let session = prepared.newSession {
            do {
                try AgentSessionStore.write(session, for: agentID, directory: root.statusDir)
            } catch {
                return .failure(
                    .launchPreparationFailed(
                        provider,
                        "The new session's ID could not be saved: \(error.localizedDescription)"),
                    provider: provider,
                    generation: generation,
                    integrationIssue: nil)
            }
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
        do {
            try AgentConfig.atomicWrite(Data(script.utf8), to: scriptURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path)
        } catch {
            // A script left behind goes with the launch folder at the next
            // start.
            return .failure(
                .launchPreparationFailed(
                    provider,
                    "The launch script could not be created: \(error.localizedDescription)"),
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
            integrationIssue: integrationIssue,
            resumedSessionID: prepared.resumedSessionID))
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
    var onSurfaceDeath: ((UUID) -> Void)?
    /// Fires when the set of presented agent surfaces changes, after the
    /// presentation and after death teardown. The workspace owner owns
    /// `currentlyViewedAgentId`, so it must reconcile from the surface that
    /// actually exists rather than from launch intent.
    var onSurfacePresentationChanged: ((UUID) -> Void)?
    private(set) var currentlyViewedAgentId: UUID?

    /// Files of the data root that could not be read, saved or removed,
    /// each with what went wrong; the workspace shows them with the
    /// configuration issue. An entry stays until the same file is next
    /// saved or removed. The key of an agent's whole set of status files is
    /// `<status folder>/<agent id>`.
    private(set) var storageErrors: [URL: String] = [:]

    private var lastAggregateState: AggregateState?
    private var isTerminating = false
    /// Set when `state.json` could not be read at start. The file is then
    /// kept as it is, and nothing is saved over it until it is removed.
    private var stateFileUnreadable = false

    /// Brings the hook records to `ingest`, from `start` on.
    @ObservationIgnored private(set) var journal: AgentHookJournalSource?
    private var healthRefreshGenerations: [AgentProviderID: UUID] = [:]
    private var compactingTimers: [UUID: any AgentTimer] = [:]
    private var telemetryDelayTimers: [UUID: any AgentTimer] = [:]
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

    /// Compacting is provably bounded (~5-15s). If no PostCompact arrives
    /// within this window, the state is stale (e.g., user cancelled).
    private static let compactingTimeout: TimeInterval = 30
    /// An active turn with no provider fact for this long shows as delayed.
    private static let telemetryDelay: TimeInterval = 120

    /// The host of the last activation. The surfaces are its own; the bridge
    /// keeps only this weak reference, to present launches that finish
    /// preparing and to have closes confirmed.
    @ObservationIgnored private weak var surfaceHost: (any AgentSurfaceHost)?
    /// The last program-status report from each agent's current launch.
    /// Nothing derives agent state from it yet.
    @ObservationIgnored private(set) var lastProgramStatus: [UUID: Ghostty.Action.ProgramStatus] = [:]
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

        // Reconstruct agents from config. No terminal outlives the app, so
        // every agent starts not running; only an unread completion stays.
        for entry in config.allAgentEntries {
            let unread = persisted.unreadCompletions[entry.id]
            agents[entry.id] = AgentInstance(entry: entry, runtime: AgentRuntimeSnapshot(
                unreadCompletion: unread,
                lastAppliedCompletion: unread))
        }

        refreshProviderHealth()

        // From here on, each record a hook appends reaches `ingest`; what the
        // event files hold now is history and never applies.
        let journal = AgentHookJournalSource(
            statusDir: statusDir,
            scheduler: scheduler,
            io: io,
            diagnose: diagnose)
        journal.start(
            agents: { [weak self] in self?.agents.mapValues(\.provider) ?? [:] },
            observe: { [weak self] in self?.ingest($0) },
            statusLine: { [weak self] id, snapshot in self?.applyStatusLine(snapshot, to: id) })
        self.journal = journal

        // The restored state, unread completions included, reaches the
        // observers, which the owner attaches before calling `start`.
        updateAggregate()

        diagnose(.info, "started — \(agents.count) agents")
    }

    func shutdown() {
        isTerminating = true
        journal?.stop()
        for id in agents.keys { invalidateTimers(for: id) }
        removeAllLaunchScripts(synchronously: true)
        persistState(synchronously: true)
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
        for agent in agents.values where agent.provider == provider {
            let old = agent.runtime
            apply(.providerAuthentication(authentication), to: agent)
            changed = changed || agent.runtime != old
        }
        if changed { updateAggregate() }
    }

    /// The runtime of an agent that has never launched: it shows its
    /// provider's sign-in state.
    private func neverLaunchedRuntime(_ provider: AgentProviderID) -> AgentRuntimeSnapshot {
        AgentRuntimeSnapshot(
            interactionState: providerHealth[provider]?.authentication == .signedOut
                ? .authentication : .none)
    }

    // MARK: - Reconciliation (call after config.load())

    func reconcileWithConfig(_ config: AgentConfig) {
        let allEntries = config.allAgentEntries
        let configIds = Set(allEntries.map(\.id))

        // Add instances for new entries
        for entry in allEntries where agents[entry.id] == nil {
            agents[entry.id] = AgentInstance(entry: entry, runtime: neverLaunchedRuntime(entry.provider))
        }

        // Remove instances for deleted entries
        for id in agents.keys where !configIds.contains(id) {
            destroySurface(id: id)
            agents.removeValue(forKey: id)
        }

        // Sync editable values. Provider identity can replace only a runtime
        // that has never launched and has no persisted session identity.
        for entry in allEntries {
            if let agent = agents[entry.id] {
                let persistedProvider: AgentProviderID?
                do {
                    persistedProvider = try AgentSessionStore.persistedProvider(
                        for: entry.id,
                        directory: statusDir)
                } catch {
                    // An unreadable binding may name a session, so the agent
                    // counts as bound and keeps its provider.
                    diagnose(.error, "provider of \(entry.id) kept: \(error.localizedDescription)")
                    persistedProvider = agent.provider
                }
                switch AgentRuntimeProviderPolicy.decision(
                    current: agent.provider,
                    requested: entry.provider,
                    persistedProvider: persistedProvider,
                    surfaceState: agent.surfaceState,
                    processState: agent.processState) {
                case .unchanged:
                    break
                case .replaceInactiveRuntime:
                    var runtime = neverLaunchedRuntime(entry.provider)
                    if agent.unreadCompletion?.provider == entry.provider {
                        runtime.unreadCompletion = agent.unreadCompletion
                    }
                    if agent.lastAppliedCompletion?.provider == entry.provider {
                        runtime.lastAppliedCompletion = agent.lastAppliedCompletion
                    }
                    agents[entry.id] = AgentInstance(entry: entry, runtime: runtime)
                    continue
                case .preserveRuntimeAndRestoreConfig:
                    diagnose(
                        .error,
                        "rejected provider change for bound or active agent \(entry.id)")
                    _ = config.restoreProvider(id: entry.id, provider: agent.provider)
                }
                if agent.name != entry.name {
                    agent.name = entry.name
                }
                agent.launchProfile = entry.launchProfile
            }
        }
        updateAggregate()
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
        agents[entry.id] = AgentInstance(entry: entry, runtime: neverLaunchedRuntime(provider))
        return entry
    }

    // MARK: - Activation

    /// Starts or reveals an agent. This never declares the agent viewed:
    /// viewing requires a presented live surface and a key workspace window,
    /// which only the workspace owner can reconcile.
    func activateAgent(id: UUID, host: any AgentSurfaceHost, project: AgentProject) {
        activate(id: id, host: host, project: project, discardingSession: false)
    }

    /// Starts a new session for an agent whose saved session is missing or
    /// unreadable: the launch forgets the saved session before it reads it.
    func startFresh(id: UUID, host: any AgentSurfaceHost, project: AgentProject) {
        guard agents[id]?.canOnlyStartFresh == true else { return }
        activate(id: id, host: host, project: project, discardingSession: true)
    }

    private func activate(
        id: UUID,
        host: any AgentSurfaceHost,
        project: AgentProject,
        discardingSession: Bool
    ) {
        guard let agent = agents[id] else { return }
        surfaceHost = host

        if host.hasSurface(id: id), agent.processState == .exited {
            discardSurfaceForRestart(id: id, host: host, provider: agent.provider)
        }

        if host.hasSurface(id: id) {
            _ = host.showOrSwitch(
                projectName: project.name,
                agent: agent,
                focusTerminal: true,
                select: true,
                createConfig: { nil })
            return
        }

        // A second activation while background preparation is in flight only
        // reveals the existing launch state; it never creates a competing run.
        if agent.surfaceState == .opening, agent.processState == .launching {
            host.selectAgent(agent, projectName: project.name)
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
        agent.lastHookTime = nil
        host.selectAgent(agent, projectName: project.name)
        scheduleLaunchTimeout(agentID: id, generation: generation)

        let provider = agent.provider
        let name = agent.name
        let profile = agent.launchProfile
        let path = effectiveEnvironmentPath
        let workingDirectory = project.workingDirectory
        let projectName = project.name
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
        let diagnose = self.diagnose
        io.async { [weak self] in
            let outcome = launchCoordinator.prepare(
                launchRequest,
                discardingSession: discardingSession)
            io.onMainActor { [weak self] in
                guard let self, let host = self.surfaceHost else {
                    if case .success(let launch) = outcome {
                        io.global { Self.removeLaunchScript(at: launch.scriptURL, diagnose) }
                    }
                    return
                }
                self.finishSurfaceLaunch(
                    outcome,
                    agentID: id,
                    projectName: projectName,
                    workingDirectory: workingDirectory,
                    host: host)
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
        host: any AgentSurfaceHost
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
            var sessionUnreadable = false
            if case .unreadableSession = issue { sessionUnreadable = true }
            failLaunch(
                agent,
                generation: generation,
                message: issue.localizedDescription,
                sessionUnreadable: sessionUnreadable)

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
            let isNew = host.presentPreparedSurface(
                projectName: projectName,
                agent: agent
            ) {
                var surfaceConfig = Ghostty.SurfaceConfiguration()
                surfaceConfig.command = launch.scriptURL.path
                surfaceConfig.workingDirectory = workingDirectory
                surfaceConfig.environmentVariables = launch.environment
                return surfaceConfig
            }
            guard isNew else {
                // No terminal will run the launch script.
                removeLaunchScript(for: agentID)
                failLaunch(
                    agent,
                    generation: launch.generation,
                    message: "The agent's terminal could not be opened.")
                return
            }
            apply(
                .surfaceOpened(
                    generation: launch.generation,
                    resumedSessionID: launch.resumedSessionID),
                to: agent)
            onSurfacePresentationChanged?(agentID)
        }
    }

    private func failLaunch(
        _ agent: AgentInstance,
        generation: UUID,
        message: String,
        sessionUnreadable: Bool = false
    ) {
        apply(
            .launchFailed(generation: generation, message: message, sessionUnreadable: sessionUnreadable),
            to: agent)
        launchTimers[agent.id]?.invalidate()
        launchTimers.removeValue(forKey: agent.id)
        updateAggregate()
    }

    // MARK: - Fork

    func forkAgent(sourceId: UUID, config: AgentConfig, project: String, task: String) -> AgentEntry? {
        guard let source = agents[sourceId] else { return nil }

        // Read source session — abort if none
        guard providers.capabilities(source.provider).fork.isSupported else {
            diagnose(.error, "fork: \(source.provider.displayName) cannot fork")
            return nil
        }
        let sourceSession: AgentSessionBinding
        do {
            guard let session = try AgentSessionStore.session(
                for: sourceId,
                provider: source.provider,
                directory: statusDir)
            else {
                diagnose(.error, "fork: no session for source \(sourceId)")
                return nil
            }
            sourceSession = session
        } catch {
            reportStorageError(
                AgentSessionStore.sessionURL(sourceId, statusDir),
                "\(source.name) could not be forked: \(error.localizedDescription)")
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
        do {
            try AgentSessionStore.write(pending, for: entry.id, directory: statusDir)
        } catch {
            deleteAgent(id: entry.id, config: config)
            reportStorageError(
                AgentSessionStore.forkURL(entry.id, statusDir),
                "\(source.name) could not be forked: \(error.localizedDescription)")
            return nil
        }

        return entry
    }

    // MARK: - Rename

    /// Changes the agent's label at once, as `AgentConfig.renameAgent` stores
    /// it. Nothing reaches a running terminal: Claude takes the label as
    /// `--name` at its next launch, and Codex sessions are not renamed.
    func renameAgent(id: UUID, newName: String) {
        agents[id]?.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
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
        persistState()
        return true
    }

    func removeAgentRuntimes(ids: [UUID]) {
        ids.forEach { removeAgentRuntime(id: $0) }
        updateAggregate()
        persistState()
    }

    private func removeAgentRuntime(id: UUID) {
        let agentProvider = agents[id]?.provider ?? .claudeCode
        destroySurface(id: id)
        agents.removeValue(forKey: id)

        // Clean status files
        let cleanup = providers.cleanup
        let statusDir = statusDir
        store(
            statusDir.appendingPathComponent(id.uuidString),
            "The files of removed agent \(id) could not all be deleted"
        ) {
            try AgentSessionStore.removeAll(for: id, directory: statusDir)
            try cleanup(agentProvider, id)
        }
    }

    // MARK: - Status observations

    /// The one way an observation about an agent reaches its state: the
    /// records its hooks append to its event file, and its terminal's close
    /// and program-status reports. An observation from another launch, or
    /// about an agent that is gone, changes nothing.
    func ingest(_ observation: AgentStatusObservation) {
        guard !isTerminating else { return }
        let id = observation.agentID
        guard let agent = agents[id],
              let generation = agent.launchGeneration,
              observation.generation == generation
        else {
            switch observation.event {
            case .hook: diagnose(.debug, "ignored stale launch event for \(id)")
            case .surfaceClosed: diagnose(.debug, "ignored close of an earlier surface of \(id)")
            case .programStatus: diagnose(.debug, "ignored program status for \(id)")
            }
            return
        }
        switch observation.event {
        case .hook(let record):
            ingestHook(record, agent: agent, generation: generation)
        case .surfaceClosed(let processAlive):
            closeSurface(of: agent, generation: generation, processAlive: processAlive)
        case .programStatus(let report):
            // Recorded only; nothing derives agent state from it yet.
            lastProgramStatus[id] = report
            let kind = report.kind.map { String(describing: $0) } ?? "-"
            diagnose(
                .debug,
                "program status \(id) generation \(generation): \(report.state) kind=\(kind) id=\(report.id ?? "-")")
        }
    }

    private func ingestHook(
        _ record: AgentRawProviderEvent,
        agent: AgentInstance,
        generation: UUID
    ) {
        let id = agent.id
        guard record.provider == agent.provider else {
            diagnose(.error, "ignored provider-mismatched event for \(id)")
            return
        }
        guard record.hasSupportedSchema else {
            diagnose(
                .error,
                "ignored unsupported event schema for \(id): \(record.schemaVersion ?? -1)")
            return
        }
        let domainEvents = providers.normalize(record.provider, record)
        guard !domainEvents.isEmpty else { return }

        // A completion is known by the record's ID and its event's place in
        // the record.
        let eventID = record.eventID ?? UUID().uuidString
        var effects: [AgentRuntimeEffect] = []
        for (index, domainEvent) in domainEvents.enumerated() {
            effects += apply(
                .provider(
                    generation: generation,
                    provider: record.provider,
                    eventID: "\(eventID):\(index)",
                    event: domainEvent,
                    isViewed: currentlyViewedAgentId == id),
                to: agent)
            applyMetadata(record, domainEvent: domainEvent, provider: record.provider, to: agent)
        }
        agent.lastHookTime = scheduler.now
        perform(effects, of: agent)
        scheduleTelemetryDelay(for: agent)
    }

    /// What provider facts set in motion once applied: the launch's cleanup
    /// when the provider is seen alive or gone, notifications while the
    /// agent is not viewed, and saving the unread state.
    private func perform(_ effects: [AgentRuntimeEffect], of agent: AgentInstance) {
        let id = agent.id
        if effects.contains(.becameAlive) {
            launchTimers[id]?.invalidate()
            launchTimers.removeValue(forKey: id)
            removeLaunchScript(for: id)
            let provider = agent.provider
            integrationIssues[provider] = nil
            let root = root
            store(
                AgentSessionStore.forkURL(id, root.statusDir),
                "The fork marker of \(agent.name) could not be removed, so its next launch forks again"
            ) {
                try AgentSessionStore.clearPendingFork(for: id, directory: root.statusDir)
            }
            if provider == .codex {
                store(root.codexHookReviewMarker, "The Codex hook review notice could not be cleared") {
                    try CodexProvider.clearHookReviewRequired(root: root)
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
        updateCompactingTimer(for: agent)

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

        if effects.contains(.unreadChanged) {
            persistState()
        }
        updateAggregate()
    }

    /// An active turn that goes `telemetryDelay` without a provider fact
    /// shows as delayed until the next fact. Each fact starts the wait again.
    private func scheduleTelemetryDelay(for agent: AgentInstance) {
        telemetryDelayTimers.removeValue(forKey: agent.id)?.invalidate()
        guard case .active = agent.turnState,
              let generation = agent.launchGeneration
        else { return }
        telemetryDelayTimers[agent.id] = scheduler.timer(
            interval: Self.telemetryDelay,
            repeats: false
        ) { [weak self, weak agent] in
            guard let self, let agent else { return }
            self.telemetryDelayTimers.removeValue(forKey: agent.id)
            self.apply(.telemetryDelayed(generation: generation), to: agent)
            self.updateAggregate()
        }
    }

    /// Claude's latest status-line snapshot for the agent.
    private func applyStatusLine(_ snapshot: AgentSessionMetadata, to id: UUID) {
        guard let agent = agents[id],
              agent.metadata != snapshot || agent.metadataAvailability != .available
        else { return }
        agent.metadata = snapshot
        agent.metadataAvailability = .available
    }

    private func applyMetadata(
        _ rawEvent: AgentRawProviderEvent,
        domainEvent: AgentDomainEvent,
        provider: AgentProviderID,
        to agent: AgentInstance
    ) {
        // The one place the binding follows the provider: every `SessionStart`
        // of the current launch, whatever its source (startup, resume,
        // clear, compact, fork), names the session the next launch resumes.
        // After `/clear` that is the new session, not the one launched.
        if case .sessionStarted(let sessionID, _, _) = domainEvent,
           let sessionID,
           let generation = agent.launchGeneration {
            let binding = AgentSessionBinding(
                provider: provider,
                sessionID: sessionID,
                launchGeneration: generation)
            let agentID = agent.id
            let statusDir = statusDir
            store(
                AgentSessionStore.sessionURL(agentID, statusDir),
                "Session \(sessionID) of \(agent.name) could not be saved, so its next launch may not resume it"
            ) {
                try AgentSessionStore.write(binding, for: agentID, directory: statusDir)
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

    @discardableResult
    private func apply(
        _ event: AgentRuntimeEvent,
        to agent: AgentInstance
    ) -> [AgentRuntimeEffect] {
        agent.apply(event, at: scheduler.now)
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

    /// Agents whose provider is starting or running in a terminal; quitting
    /// stops them.
    var runningAgentCount: Int {
        agents.values.filter { $0.surfaceState == .open && $0.processState != .exited }.count
    }

    private func updateAggregate() {
        let current = aggregateState
        if lastAggregateState != current {
            lastAggregateState = current
            onAggregateStateChanged?(current)
        }
    }

    // MARK: - Surface Management

    /// The host reports that an agent's terminal closed, or that its process
    /// exited. `generation` is the launch the surface was created for: a
    /// close from an earlier launch changes nothing. A close that would kill
    /// a running process asks first, as for any Ghostty terminal.
    func surfaceClosed(id: UUID, generation: UUID?, processAlive: Bool) {
        ingest(AgentStatusObservation(
            agentID: id,
            generation: generation,
            source: .surface,
            event: .surfaceClosed(processAlive: processAlive)))
    }

    /// One program-status report from the terminal of an agent's launch. It
    /// arrives inside the app tick, so nothing it causes may free a surface.
    func programStatus(id: UUID, generation: UUID?, report: Ghostty.Action.ProgramStatus) {
        ingest(AgentStatusObservation(
            agentID: id,
            generation: generation,
            source: .surface,
            event: .programStatus(report)))
    }

    private func closeSurface(of agent: AgentInstance, generation: UUID, processAlive: Bool) {
        // A surface closes once, however many reports of it arrive.
        guard agent.surfaceState == .open else { return }
        let id = agent.id
        if processAlive, let surfaceHost {
            surfaceHost.confirmClose(id: id) { [weak self] in
                // Agreed, so nothing is left to ask; the launch may have
                // changed while the question was open.
                self?.surfaceClosed(id: id, generation: generation, processAlive: false)
            }
            return
        }
        diagnose(.info, "surface death: \(id)")
        destroySurface(id: id)
    }

    private func discardSurfaceForRestart(
        id: UUID,
        host: any AgentSurfaceHost,
        provider: AgentProviderID
    ) {
        lastProgramStatus.removeValue(forKey: id)
        invalidateTimers(for: id)
        removeLaunchScript(for: id)
        removeProviderFiles(of: id, provider: provider)
        host.removeSurface(id: id)
    }

    /// The provider's files for one launch of the agent, such as Claude's
    /// settings overlay.
    private func removeProviderFiles(of id: UUID, provider: AgentProviderID) {
        let cleanup = providers.cleanup
        store(
            root.runtimeDir.appendingPathComponent(id.uuidString),
            "The session settings of agent \(id) could not be removed"
        ) {
            try cleanup(provider, id)
        }
    }

    private func invalidateTimers(for id: UUID) {
        launchTimers.removeValue(forKey: id)?.invalidate()
        compactingTimers.removeValue(forKey: id)?.invalidate()
        telemetryDelayTimers.removeValue(forKey: id)?.invalidate()
    }

    private func destroySurface(id: UUID) {
        lastProgramStatus.removeValue(forKey: id)
        invalidateTimers(for: id)
        removeLaunchScript(for: id)
        if let provider = agents[id]?.provider {
            removeProviderFiles(of: id, provider: provider)
        }

        if let agent = agents[id] {
            apply(.surfaceDied(generation: agent.launchGeneration), to: agent)
        }
        onSurfaceDeath?(id)
        onSurfacePresentationChanged?(id)
        updateAggregate()
        persistState()
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

    /// The unread marks the last run saved; none when there is no file. A
    /// file that cannot be read is reported and kept as evidence: the run
    /// starts with no unread marks and saves none over it.
    private func loadPersistedState() -> PersistedState {
        let stateFile = root.stateFile
        do {
            return try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: stateFile))
        } catch CocoaError.fileReadNoSuchFile {
            return PersistedState()
        } catch {
            stateFileUnreadable = true
            reportStorageError(
                stateFile,
                "Unread marks could not be restored from \(stateFile.path) (\(AgentConfig.describeLoadFailure(error))). The file is kept as it is, and no unread marks are saved until it is removed.")
            return PersistedState()
        }
    }

    func persistState(synchronously: Bool = false) {
        let stateFile = root.stateFile
        if stateFileUnreadable {
            guard !FileManager.default.fileExists(atPath: stateFile.path) else { return }
            stateFileUnreadable = false
        }
        var state = PersistedState()
        state.unreadCompletions = Dictionary(uniqueKeysWithValues: agents.values.compactMap {
            guard let completion = $0.unreadCompletion else { return nil }
            return ($0.id, completion)
        })
        let saved = state
        store(stateFile, "Unread marks could not be saved", synchronously: synchronously) {
            try AgentConfig.atomicWrite(JSONEncoder().encode(saved), to: stateFile)
        }
    }

    /// Runs `work` on the IO queue and records how it went for `file`: a
    /// failure is reported and kept in `storageErrors`, which a later success
    /// for the same file clears.
    private func store(
        _ file: URL,
        _ failure: String,
        synchronously: Bool = false,
        _ work: @escaping @Sendable () throws -> Void
    ) {
        let io = self.io
        let diagnose = self.diagnose
        let run: @Sendable () -> Void = {
            var message: String?
            do {
                try work()
            } catch {
                message = "\(failure): \(error.localizedDescription)"
                diagnose(.error, message ?? failure)
            }
            io.onMainActor { [weak self, message] in
                guard let self, self.storageErrors[file] != message else { return }
                self.storageErrors[file] = message
            }
        }
        if synchronously {
            io.sync(run)
        } else {
            io.async(run)
        }
    }

    private func reportStorageError(_ file: URL, _ message: String) {
        diagnose(.error, message)
        storageErrors[file] = message
    }

    // MARK: - Cleanup

    private func removeLaunchScript(for id: UUID) {
        guard let url = launchScripts.removeValue(forKey: id) else { return }
        removeFileOffMain(url)
    }

    private func removeAllLaunchScripts(synchronously: Bool = false) {
        let urls = Array(launchScripts.values)
        launchScripts.removeAll()
        let diagnose = diagnose
        let remove: @Sendable () -> Void = {
            for url in urls {
                Self.removeLaunchScript(at: url, diagnose)
            }
        }
        if synchronously {
            io.sync(remove)
        } else {
            io.async(remove)
        }
    }

    private func removeFileOffMain(_ url: URL) {
        let diagnose = diagnose
        io.async { Self.removeLaunchScript(at: url, diagnose) }
    }

    /// A launch script that cannot be removed is reported; the next start
    /// empties the launch folder anyway.
    nonisolated private static func removeLaunchScript(at url: URL, _ diagnose: AgentDiagnosticsSink) {
        do {
            try FileManager.default.removeItemIfPresent(at: url)
        } catch {
            diagnose(.error, "launch script \(url.path) could not be removed: \(error.localizedDescription)")
        }
    }
}
