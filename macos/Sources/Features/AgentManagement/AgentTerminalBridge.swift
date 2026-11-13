import AppKit
import SwiftUI
import GhosttyKit
@preconcurrency import UserNotifications
import os

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
    /// When the source of the agent's turn activity (its provider table's
    /// `turnActivity`) last reported in this launch; nil until it first does.
    @ObservationIgnored var lastActivityReport: Date?
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
    /// presentation and after death teardown. The workspace owner decides
    /// what is viewed, so it must reconcile from the surface that actually
    /// exists rather than from launch intent.
    var onSurfacePresentationChanged: ((UUID) -> Void)?
    /// Whether the user is looking at the agent now, answered by the
    /// workspace owner from its one record of viewing. A completion that
    /// arrives while its agent is viewed leaves no unread mark, and nothing
    /// is notified about a viewed agent.
    var isViewed: (UUID) -> Bool = { _ in false }

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
    private var turnStartTimers: [UUID: any AgentTimer] = [:]
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
    /// How long a `working` report with no turn under way must stand before
    /// the turn starts. The `working` blips of `/clear`, `/exit` and the
    /// `/exit` confirmation end within 14 to 63 ms; a turn's failure can come
    /// 106 ms after its `working`, and starts the turn at once.
    static let turnStartDelay: TimeInterval = 0.25

    /// The host of the last activation. The surfaces are its own; the bridge
    /// keeps only this weak reference, to present launches that finish
    /// preparing and to have closes confirmed.
    @ObservationIgnored private weak var surfaceHost: (any AgentSurfaceHost)?
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
        for provider in providers {
            let refreshGeneration = UUID()
            healthRefreshGenerations[provider] = refreshGeneration
            let probe = self.providers[provider].probe
            io.probe { [weak self] in
                var health = probe(path)
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
            removeAgent(id: id)
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
                    // The old provider's files go with its runtime.
                    removeAgent(id: entry.id)
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
    /// which only the workspace owner can judge.
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
        agent.lastActivityReport = nil
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

    /// A launch whose source of turn activity has not reported within 10 s
    /// shows that its status is unavailable, as while Claude waits at its
    /// folder trust dialog, before which it reports nothing.
    private func scheduleLaunchTimeout(agentID: UUID, generation: UUID) {
        launchTimers[agentID]?.invalidate()
        launchTimers[agentID] = scheduler.timer(interval: 10, repeats: false) { [weak self] in
            guard let self, let agent = self.agents[agentID],
                  agent.processState == .launching,
                  agent.launchGeneration == generation,
                  agent.lastActivityReport == nil
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

    /// The workspace owner reports that the user now looks at the agent:
    /// its completion is acknowledged and its notifications are cleared.
    func agentViewed(_ id: UUID) {
        acknowledgeCompletion(id: id)
        clearNotifications(for: id)
    }

    // MARK: - Deletion

    @discardableResult
    func deleteAgent(id: UUID, config: AgentConfig) -> Bool {
        guard config.removeAgent(id: id) else { return false }
        removeAgent(id: id)
        updateAggregate()
        persistState()
        return true
    }

    /// Deletes the project and every agent in it.
    @discardableResult
    func deleteProject(id: UUID, config: AgentConfig) -> Bool {
        guard let project = config.projects.first(where: { $0.id == id }) else { return false }
        let ids = project.tasks.flatMap(\.agents).map(\.id)
        guard config.removeProject(id: id) else { return false }
        removeAgents(ids)
        return true
    }

    /// Deletes the task and every agent in it.
    @discardableResult
    func deleteTask(projectID: UUID, taskID: UUID, config: AgentConfig) -> Bool {
        guard let task = config.projects.first(where: { $0.id == projectID })?
            .tasks.first(where: { $0.id == taskID })
        else { return false }
        let ids = task.agents.map(\.id)
        guard config.removeTask(projectId: projectID, taskId: taskID) else { return false }
        removeAgents(ids)
        return true
    }

    private func removeAgents(_ ids: [UUID]) {
        for id in ids { removeAgent(id: id) }
        updateAggregate()
        persistState()
    }

    /// The one way an agent goes, whatever removed it: Delete, deleting its
    /// project or task, an edit of `agents.json` that drops it, or a provider
    /// change that replaces its runtime. Its terminal closes, its runtime is
    /// dropped, and every `<agent id>.*` file in the status folder and its
    /// runtime folder are deleted. No other agent's file is touched.
    private func removeAgent(id: UUID) {
        destroySurface(id: id)
        agents.removeValue(forKey: id)
        let kept = storageErrors.filter { !$0.key.lastPathComponent.hasPrefix(id.uuidString) }
        if kept.count != storageErrors.count { storageErrors = kept }
        let root = root
        store(
            root.statusDir.appendingPathComponent(id.uuidString),
            "The files of removed agent \(id) could not all be deleted"
        ) {
            try root.removeFiles(ofAgent: id)
        }
    }

    // MARK: - Status observations

    /// The one way an observation about an agent reaches its state: the
    /// records its hooks append to its event file, and its terminal's close
    /// and program-status reports. An observation from another launch, about
    /// an agent that is gone, a record the provider's table does not allow
    /// in the event file, or a program-status report other than the launch
    /// script's exit report from a provider whose table names its hooks as
    /// the source of turn activity, changes nothing.
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
            ingestProgramStatus(report, agent: agent, generation: generation)
        }
    }

    /// One report a program made in the agent's terminal. It arrives inside
    /// the app tick: nothing here frees a surface.
    private func ingestProgramStatus(
        _ report: Ghostty.Action.ProgramStatus,
        agent: AgentInstance,
        generation: UUID
    ) {
        let id = agent.id
        // Every launch script reports its provider's exit, Codex's included.
        if report.id == AgentLaunchCoordinator.exitReportID {
            ingestExitReport(report, agent: agent, generation: generation)
            return
        }
        guard providers[agent.provider].turnActivity == .surface else {
            // Codex reports too, but its turn activity comes from its hooks.
            diagnose(.debug, "ignored program status for \(id): the \(agent.provider.displayName) table names its hooks")
            return
        }
        // Only the program's own record counts. A record beneath it never
        // changes the agent's state.
        guard report.id == nil else { return }
        let kind = report.kind.map { String(describing: $0) } ?? "-"
        diagnose(.debug, "program status \(id) generation \(generation): \(report.state) kind=\(kind)")
        agent.lastActivityReport = scheduler.now
        let effects = apply(
            .provider(
                generation: generation,
                provider: agent.provider,
                eventID: UUID().uuidString,
                event: .programStatus(report),
                isViewed: isViewed(id)),
            to: agent)
        perform(effects, of: agent)
    }

    /// The report the launch script prints once the provider has returned:
    /// `state=clear` on the record `exitReportID`, with the exit status in
    /// decimal as its message. It ends the launch; from then on nothing its
    /// terminal reports changes the agent until the next launch, so a
    /// provider started by hand in the login shell that follows cannot bring
    /// the agent back. `ingest` takes it only from the agent's own terminal
    /// for the current launch. Any program running in that terminal could
    /// print the same bytes; that is accepted, because it can only end its
    /// own agent's launch. Anything else on that record is ignored.
    private func ingestExitReport(
        _ report: Ghostty.Action.ProgramStatus,
        agent: AgentInstance,
        generation: UUID
    ) {
        guard report.state == .clear, let status = report.message.flatMap({ Int($0) }) else {
            diagnose(
                .error,
                "ignored \(report.state) on record \(AgentLaunchCoordinator.exitReportID) for \(agent.id): an exit report is a clear with a decimal exit status as its message, here \(report.message ?? "none")")
            return
        }
        diagnose(.info, "provider of \(agent.id) exited with status \(status), generation \(generation)")
        let effects = apply(
            .provider(
                generation: generation,
                provider: agent.provider,
                eventID: UUID().uuidString,
                event: .providerExited(status: status),
                isViewed: isViewed(agent.id)),
            to: agent)
        perform(effects, of: agent)
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
        let entry = providers[record.provider]
        guard let meaning = entry.meaning(ofRecord: record.hookEventName) else {
            diagnose(
                .debug,
                "ignored \(record.hookEventName) for \(id): not in the \(record.provider.displayName) table")
            return
        }
        let domainEvents = meaning(record)

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
                    isViewed: isViewed(id)),
                to: agent)
            applyMetadata(record, domainEvent: domainEvent, provider: record.provider, to: agent)
        }
        if entry.turnActivity == .hookJournal {
            agent.lastActivityReport = scheduler.now
        }
        perform(effects, of: agent)
        if entry.turnActivity == .hookJournal {
            scheduleTelemetryDelay(for: agent)
        }
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
        updateTurnStartTimer(for: agent)

        if effects.contains(.completed) {
            alert(agent, .finished, title: "Agent completed", body: "\(agent.name) is ready for review")
        }
        if effects.contains(.waitingForUser) {
            alert(agent, .permission, title: "Agent is waiting for you", body: "\(agent.name) needs your response")
        }
        if effects.contains(.failed) {
            alert(agent, .error, title: "Agent needs attention", body: "\(agent.name) encountered an error")
        }

        if effects.contains(.unreadChanged) {
            persistState()
        }
        updateAggregate()
    }

    /// An active turn that goes `telemetryDelay` without a fact from the
    /// source of its turn activity shows as delayed until the next one. Each
    /// fact starts the wait again.
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
        let sessionID: String?
        switch domainEvent {
        case .sessionStarted(let started, _, _): sessionID = started
        case .sessionBound(let bound): sessionID = bound
        default: sessionID = nil
        }
        if let sessionID, let generation = agent.launchGeneration {
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

    /// A compaction the event file reports ends after 30 s at most, since its
    /// `PostCompact` may never come. A program that reports its own activity
    /// ends it with its next report.
    private func updateCompactingTimer(for agent: AgentInstance) {
        compactingTimers[agent.id]?.invalidate()
        compactingTimers.removeValue(forKey: agent.id)
        guard agent.activityState == .compacting,
              providers[agent.provider].turnActivity == .hookJournal,
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

    /// While a `working` report may still prove a blip, its turn waits; it
    /// starts when the report has stood for `turnStartDelay`, counted from
    /// the first `working`. Waiting this way, rather than starting the turn
    /// and undoing it, leaves the screen, the unread mark and the
    /// notifications untouched by a blip.
    private func updateTurnStartTimer(for agent: AgentInstance) {
        let id = agent.id
        guard agent.turnState == .starting, let generation = agent.launchGeneration else {
            turnStartTimers.removeValue(forKey: id)?.invalidate()
            return
        }
        guard turnStartTimers[id] == nil else { return }
        turnStartTimers[id] = scheduler.timer(
            interval: Self.turnStartDelay,
            repeats: false
        ) { [weak self, weak agent] in
            guard let self, let agent else { return }
            self.turnStartTimers.removeValue(forKey: id)
            self.perform(self.apply(.turnStartSettled(generation: generation), to: agent), of: agent)
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
        invalidateTimers(for: id)
        removeLaunchScript(for: id)
        removeProviderFiles(of: id, provider: provider)
        host.removeSurface(id: id)
    }

    /// The provider's files for one launch of the agent, such as Claude's
    /// settings overlay.
    private func removeProviderFiles(of id: UUID, provider: AgentProviderID) {
        let cleanup = providers[provider].cleanup
        store(
            root.runtimeDir.appendingPathComponent(id.uuidString),
            "The session settings of agent \(id) could not be removed"
        ) {
            try cleanup(id)
        }
    }

    private func invalidateTimers(for id: UUID) {
        launchTimers.removeValue(forKey: id)?.invalidate()
        compactingTimers.removeValue(forKey: id)?.invalidate()
        turnStartTimers.removeValue(forKey: id)?.invalidate()
        telemetryDelayTimers.removeValue(forKey: id)?.invalidate()
    }

    private func destroySurface(id: UUID) {
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

    /// Announces a completion, a wait or a failure to VoiceOver, and, while
    /// the agent is not viewed, posts it as a user notification. The
    /// announcement is made for a viewed agent too, whose terminal holds a
    /// VoiceOver user's focus while the status changes elsewhere on screen.
    private func alert(_ agent: AgentInstance, _ kind: NotificationKind, title: String, body: String) {
        notifier.announce(body)
        guard !isViewed(agent.id) else { return }
        postNotification(agentId: agent.id, kind: kind, title: title, body: body)
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
