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
    var name: String { didSet { if name != oldValue { searchVersion += 1 } } }
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
    /// When this run created the agent; nil for an agent it read from the
    /// configuration, which keeps no creation date.
    let createdAt: Date?
    /// When the agent was last active: when its event file last changed, as
    /// the bridge reads it at start, then when a record of it last reached
    /// the bridge; nil while it has never run. Kept here, so the sidebar
    /// never reads the disk for it.
    var lastActive: Date?
    /// Its terminal's title shows Codex's working spinner.
    @ObservationIgnored var titleSpins = false
    /// The session binding this run last wrote for it.
    @ObservationIgnored var savedBinding: AgentSessionBinding?
    /// Its terminal's text when its CLI last ended or the app last quit:
    /// what its tile and its terminal area show while it does not run.
    var savedScreen = ""
    /// Its launch waits its turn: as many CLIs as start at once are
    /// starting (`AgentBridge.startConcurrency`).
    var waitsToStart = false
    /// Its record says it is settled, and that it waits on the person: kept
    /// apart from `runtime`, so what follows only these (the list of the
    /// project's agents, the waiting counts) is not woken by every report
    /// of every agent.
    private(set) var isSettled = false
    private(set) var isWaiting = false
    /// Where it stands among the agents waiting on the person (its state's
    /// rank, then when it began to wait), nil while it does not wait. Set
    /// only by a transition, never by a report of activity, so the waiting
    /// order is not woken by every step of every agent.
    private(set) var waitingKey: AgentWaitingKey?
    /// Runs when it begins or stops waiting on the person: the bridge keeps
    /// its count of waiting agents from these transitions alone.
    @ObservationIgnored var onWaitingChanged: ((AgentInstance) -> Void)?

    var surfaceState: AgentSurfaceState { runtime.surfaceState }
    var processState: AgentProcessState { runtime.processState }
    var activityState: AgentActivityState { runtime.activityState }
    var telemetryHealth: AgentTelemetryHealth { runtime.telemetryHealth }
    var lastAppliedCompletion: AgentCompletionID? { runtime.lastAppliedCompletion }
    var launchGeneration: UUID? { runtime.launchGeneration }
    var sessionID: String? { runtime.sessionID }
    var turnState: AgentTurnState { runtime.turnState }
    var missingSessionID: String? { runtime.missingSessionID }
    /// The agent's stored record (`AgentRecord`).
    var record: AgentRecord { runtime.record }
    /// Its name is Clawddy's or its CLI's, which a conversation's title may
    /// replace; a name the person gave never is (`flows.md` 4.3).
    var autoNamed: Bool { record.nameSource != .person }

    /// `runtime` is the state the agent starts from: its record, and its
    /// provider's sign-in state.
    init(entry: AgentEntry, runtime: AgentRuntimeSnapshot = AgentRuntimeSnapshot(), createdAt: Date? = nil) {
        id = entry.id
        name = entry.name
        provider = entry.provider
        launchProfile = entry.launchProfile
        self.runtime = runtime
        self.createdAt = createdAt
        isSettled = runtime.record.settledAt != nil
        isWaiting = runtime.record.isWaitingOnYou
        waitingKey = AgentWaitingKey(runtime.record)
    }

    /// Bumped whenever what find reads of it (its record's words, its
    /// name, when it last changed, whether it is settled) may have changed,
    /// so find folds its words again only then and never copies its record
    /// to find out.
    @ObservationIgnored private(set) var searchVersion = 0

    /// A finished turn the person has not opened, or a turn a quit or crash
    /// cut off.
    var isUnread: Bool { record.unread || record.cutOff }
    /// Its provider runs in its terminal: quitting or removing it stops it.
    var isRunning: Bool { surfaceState == .open && processState != .exited }
    /// The saved session is missing or unreadable, so the agent can only
    /// start a new one.
    var canOnlyStartFresh: Bool { missingSessionID != nil || runtime.sessionUnreadable }

    /// The one way the state changes: one reducer application is at most one
    /// observable mutation, and none when it changes nothing. `rules` are
    /// its provider table entry's `reports`.
    @discardableResult
    func apply(_ event: AgentRuntimeEvent, rules: AgentReportRules = .standard, at now: Date) -> [AgentRuntimeEffect] {
        let result = AgentStateReducer.reduce(runtime, event: event, rules: rules, at: now)
        guard result.state != runtime else { return result.effects }
        let wasWaiting = record.isWaitingOnYou
        let before = record
        runtime = result.state
        let waits = record.isWaitingOnYou
        if waits != wasWaiting {
            isWaiting = waits
            onWaitingChanged?(self)
        }
        if (record.settledAt != nil) != isSettled { isSettled = record.settledAt != nil }
        let key = AgentWaitingKey(record)
        if key != waitingKey { waitingKey = key }
        if !AgentRecord.findsSame(result.state.record, before) { searchVersion += 1 }
        return result.effects
    }
}

/// A send to an agent whose CLI starts, waiting for its input.
struct AgentPendingSend {
    var text: String
    var sender: AgentRecord.Prompt.Sender
    var interrupting: Bool
    var done: @MainActor (AgentSendResult) -> Void
}

/// A launch asked for that waits its turn to start.
struct AgentPendingLaunch {
    var id: UUID
    var generation: UUID
    var project: AgentProject
    var discardingSession: Bool
    var firstPrompt: String?
    var notice: String?
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

    /// Fires with the number of agents waiting for the user when it
    /// changes, and once at `start`: the menu bar item and the dock badge.
    var onWaitingCountChanged: ((Int) -> Void)?
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
    /// "Notify when an agent is waiting" is on (flows.md 6.11).
    var notifies: () -> Bool = { true }
    /// The agent's project: its folder for a launch, its name for its
    /// notifications.
    var project: (UUID) -> AgentProject? = { _ in nil }
    /// Fires with a name for an agent whose name is Clawddy's, from the title
    /// its provider gave the conversation; the owner saves it
    /// (`AgentWorkspaceTransactions.adoptTitle`).
    var onConversationTitle: ((UUID, String) -> Void)?
    /// Fires at an agent's CLI's first status report: the keys held for it
    /// go now, in order.
    var onKeysReady: ((UUID) -> Void)?
    /// Fires when the keys held for an agent's start must not be sent: its
    /// launch failed or ran out of time, it asks something, or it shows a
    /// screen with no report past `holdLimit` (a trust or update dialog).
    var onKeysNotHeld: ((UUID) -> Void)?

    /// Files of the data root that could not be read, saved or removed,
    /// each with what went wrong; the workspace shows them with the
    /// configuration issue. An entry stays until the same file is next
    /// saved or removed. The key of an agent's whole set of status files is
    /// `<status folder>/<agent id>`.
    private(set) var storageErrors: [URL: String] = [:]
    /// Files whose last write failed: what the agent holds in memory is
    /// newer, stays the truth, and is written again with the next change
    /// and at quit; the top bar says so until it is written (last review
    /// ruling 1).
    private(set) var unsavedFiles: Set<URL> = []
    /// The backups folder an unreadable `state.json` of an older build was
    /// moved to at this start, if it was.
    private(set) var movedStateFile: URL?

    private var lastWaitingCount: Int?
    /// The agents waiting on the person, kept from their transitions
    /// (`AgentInstance.onWaitingChanged`), so counting them costs nothing
    /// per report.
    @ObservationIgnored private var waiting: Set<UUID> = []
    private var isTerminating = false
    /// Agents whose record could not be read at start: the file is kept as
    /// it is, and nothing is saved over it until it is removed.
    private var unreadableRecords: Set<UUID> = []
    /// The agents whose turn the last quit or crash cut off, not yet
    /// continued (`continueCutOffAgents`), in the configuration's order.
    private var restorePending: [UUID] = []
    /// Launches asked for and waiting their turn, first to start first
    /// (`startWaitingLaunches`).
    private var waitingLaunches: [AgentPendingLaunch] = []
    /// The agents whose launch has begun and whose CLI does not read its
    /// input yet: at most `startConcurrency`.
    private var starting: Set<UUID> = []
    /// The running conversations listed once for the launches of one burst
    /// (`AgentLiveSessions`); a new burst takes a new listing.
    private var liveSessions = AgentLiveSessions()
    /// When a paused agent's usage limit resets.
    private var limitTimers: [UUID: any AgentTimer] = [:]
    /// Sends waiting for their agent's `idle` after an interrupt; called with
    /// whether it came.
    /// Called with nil when the `idle` came, else with how the send ended.
    private var pendingInterrupts: [UUID: (token: UUID, resume: @MainActor (AgentSendResult?) -> Void)] = [:]
    /// Sends to agents whose CLI was starting, waiting for its input to be
    /// ready; given up when its start fails.
    private var pendingSends: [UUID: [AgentPendingSend]] = [:]

    /// Brings the hook records to `ingest`, from `start` on.
    @ObservationIgnored private(set) var journal: AgentHookJournalSource?
    private var healthRefreshGenerations: [AgentProviderID: UUID] = [:]
    private var turnStartTimers: [UUID: any AgentTimer] = [:]
    private var signInTimers: [UUID: any AgentTimer] = [:]
    private var launchScripts: [UUID: URL] = [:]
    /// Where each launch's script writes its provider's exit status
    /// (`AgentLaunchCoordinator.exitStatusURL`), with the launch it belongs
    /// to: read only when that launch's terminal goes without the person or
    /// the app closing it, and removed on every path that ends or replaces
    /// the launch. Kept after the script itself is removed.
    private var exitStatusFiles: [UUID: (generation: UUID, url: URL)] = [:]
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

    /// How many CLIs start at once: a burst of starts, a restart's
    /// continuations and the person's opens all wait their turn beyond it,
    /// so none starves the others of the machine and none runs out of time.
    static let startConcurrency = 3
    /// How long a CLI has to come to read its input (flows.md 4.5).
    static let startLimit: TimeInterval = 30
    /// How long keys typed into a starting CLI that has drawn a screen wait
    /// for its first report: about twice the slowest normal start (Codex,
    /// 1.44 s; Claude, 0.83 s; probes.md P5), at least 3 s.
    static let holdLimit: TimeInterval = 3
    /// How long a new agent's start can be cancelled (flows.md 6.3).
    static let cancelLimit: TimeInterval = 6
    /// The message the app sends to continue a turn a restart cut off.
    static let restartLabel = "[Sent by Clawddy after a restart, not typed by you]"
    static let continueMessage = restartLabel + " Continue where you left off. Your last turn was cut short."
    /// What the terminal shows before the CLI resumes the conversation.
    static let continueNotice = "── Clawddy restarted and resumed this conversation ──"

    /// The host of the last activation. The surfaces are its own; the bridge
    /// keeps only this weak reference, to present launches that finish
    /// preparing and to have closes confirmed.
    @ObservationIgnored private weak var surfaceHost: (any AgentSurfaceHost)?
    private var launchTimers: [UUID: any AgentTimer] = [:]
    /// Watches each starting CLI for a screen with no report (`holdLimit`).
    private var holdTimers: [UUID: any AgentTimer] = [:]
    /// Agents whose start showed a screen with no report: keys go straight
    /// to their terminal, so the person can answer it.
    private var keysPassThrough: Set<UUID> = []
    /// The continuation each restarted agent's launch carries, recorded once
    /// its terminal runs it.
    private var pendingContinuations: [UUID: String] = [:]

    private var statusDir: URL { root.statusDir }

    init(
        root: AgentDataRoot,
        providers: AgentProviderTable,
        scheduler: any AgentScheduler = AgentRunLoopScheduler(),
        io: any AgentIOExecutor = AgentDispatchIO(),
        notifier: any AgentNotifier,
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
        // The marks an older build kept in `state.json` become records once.
        // A `state.json` that cannot be read is moved to the backups and the
        // person is told (last review ruling 2); a record that cannot be
        // read stops only its own agent (`addAgent`).
        if config.isLoaded {
            do {
                movedStateFile = try AgentStateFold.fold(
                    root: root,
                    agents: config.allAgentEntries.map(\.id),
                    lastActive: { [weak self] in self?.lastRecordDate(of: $0) },
                    now: scheduler.now)
            } catch {
                fatalError(error.localizedDescription)
            }
        }

        // No terminal outlives the app, so every agent starts not running,
        // from its record; those whose turn was cut off continue.
        for entry in config.allAgentEntries {
            addAgent(entry)
        }
        for agent in agents.values { apply(.appStarted, to: agent) }
        restorePending = config.allAgentEntries.map(\.id).filter { agents[$0]?.record.cutOff == true }

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
        updateWaitingCount()

        diagnose(.info, "started — \(agents.count) agents, \(restorePending.count) cut off by the last run")
    }

    /// Each record was written with its last change, so a turn under way
    /// stays working in it, and the next start finds it cut off, as after a
    /// crash.
    func shutdown() {
        isTerminating = true
        // A record or last screen whose write failed is written once more
        // from memory (last review ruling 1); the wait below covers it.
        for agent in agents.values {
            if unsavedFiles.contains(AgentRecord.url(agent.id, statusDir)) { saveRecord(of: agent) }
            if unsavedFiles.contains(AgentTail.savedScreenURL(agent.id, statusDir)) { storeScreen(agent.savedScreen, of: agent) }
        }
        journal?.stop()
        for id in agents.keys { invalidateTimers(for: id) }
        limitTimers.values.forEach { $0.invalidate() }
        settleTimers.values.forEach { $0.invalidate() }
        removeAllLaunchScripts(synchronously: true)
    }

    /// Brings in an agent of the configuration from its record, or a new
    /// record dated from its last activity. A saved session found missing
    /// or unreadable, which only Start Fresh replaces, comes back with it.
    private func addAgent(_ entry: AgentEntry, createdAt: Date? = nil, record initial: AgentRecord? = nil) {
        var runtime = AgentRuntimeSnapshot()
        let lastActive = lastRecordDate(of: entry.id)
        if let initial {
            runtime.record = initial
        } else {
            do {
                if let record = try AgentRecord.load(entry.id, from: statusDir) {
                    runtime.record = record
                } else {
                    runtime.record.changedAt = lastActive ?? scheduler.now
                }
            } catch {
                // That agent alone stops, naming the file; it runs nothing on
                // a record made up of defaults (`reaches`).
                unreadableRecords.insert(entry.id)
                let file = AgentRecord.url(entry.id, statusDir)
                let reason = AgentConfig.describeLoadFailure(error)
                runtime.record.state = .problem
                runtime.record.problem = AgentRecord.Problem(
                    kind: .launch,
                    text: "Its record \(file.path) could not be read (\(reason)). The file is kept as it is; repair or remove it and open Clawddy again.")
                reportStorageError(
                    file,
                    "The record of \(entry.name) could not be read (\(reason)). The file is kept as it is, and nothing is saved over it until it is removed.")
            }
        }
        do {
            if let missing = try AgentSessionStore.missingSession(for: entry.id, directory: statusDir) {
                runtime.missingSessionID = missing
            }
        } catch {
            runtime.sessionUnreadable = true
            runtime.record.state = .problem
            runtime.record.problem = AgentRecord.Problem(
                kind: .launch,
                text: AgentProviderIssue.unreadableSession(entry.provider, error.localizedDescription).localizedDescription)
        }
        let agent = AgentInstance(entry: entry, runtime: runtime, createdAt: createdAt)
        agent.lastActive = lastActive
        agent.savedScreen = loadScreen(of: entry)
        agents[entry.id] = agent
        if agent.isWaiting { waiting.insert(agent.id) }
        agent.onWaitingChanged = { [weak self] agent in
            if agent.isWaiting { self?.waiting.insert(agent.id) } else { self?.waiting.remove(agent.id) }
            self?.updateWaitingCount()
        }
        if initial != nil { saveRecord(of: agent) }
        if agent.record.state == .paused { scheduleLimitReset(for: agent) }
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
                }
            }
        }
    }

    // MARK: - Reconciliation (call after config.load())

    func reconcileWithConfig(_ config: AgentConfig) {
        let allEntries = config.allAgentEntries
        let configIds = Set(allEntries.map(\.id))

        // Add instances for new entries, from their records.
        for entry in allEntries where agents[entry.id] == nil {
            addAgent(entry)
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
                    // The old provider's files go with its runtime; the
                    // record stays the agent's.
                    let record = agent.record
                    removeAgent(id: entry.id)
                    addAgent(entry, record: record)
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
        updateWaitingCount()
    }

    // MARK: - Agent Creation (sync with config)

    func createAgent(
        name: String,
        provider: AgentProviderID = .claudeCode,
        launchProfile: AgentLaunchProfile = AgentLaunchProfile(),
        config: AgentConfig,
        project: String,
        after previous: UUID? = nil,
        nameSource: AgentRecord.NameSource = .person
    ) -> AgentEntry? {
        guard let entry = config.addAgent(
            project: project,
            name: name,
            provider: provider,
            launchProfile: launchProfile,
            after: previous)
        else { return nil }
        var record = AgentRecord()
        record.changedAt = scheduler.now
        record.nameSource = nameSource
        addAgent(entry, createdAt: scheduler.now, record: record)
        return entry
    }

    // MARK: - Activation

    /// Starts an agent, or shows its terminal when it has one. It never
    /// selects the agent, which is the workspace owner's to do, nor declares
    /// it viewed: viewing requires a presented live surface and a key
    /// workspace window, which only the workspace owner can judge.
    func activateAgent(id: UUID, host: any AgentSurfaceHost, project: AgentProject) {
        activate(id: id, host: host, project: project, discardingSession: false, first: true)
    }

    /// Continues, once, the agents whose turn the last quit or crash cut
    /// off (flows.md 6.14): `selected` first when it is one, then the rest in
    /// the configuration's order, waiting their turn to start
    /// (`startConcurrency`). Each CLI resumes its conversation with
    /// `continueMessage` as its first prompt, marked as the app's, after a
    /// dim `continueNotice`; a fourth continuation in a row is not sent, and
    /// the agent stops with a problem. Agents in any other state start
    /// nothing until opened. None of this changes the selection.
    /// Returns how many it continues: the status line's "Restarted.
    /// Resuming N interrupted agents."
    @discardableResult
    func continueCutOffAgents(selected: UUID?, host: any AgentSurfaceHost) -> Int {
        surfaceHost = host
        // One the person opened, or a scene started, is on its way.
        restorePending.removeAll { id in
            guard let agent = agents[id] else { return true }
            return agent.surfaceState == .opening || agent.isRunning
        }
        let count = restorePending.count
        if let selected, let at = restorePending.firstIndex(of: selected) {
            restorePending.insert(restorePending.remove(at: at), at: 0)
        }
        let pending = restorePending
        restorePending = []
        for id in pending { continueCutOff(id, host: host) }
        return count
    }

    /// Asks for the launch that continues one cut-off agent.
    private func continueCutOff(_ id: UUID, host: any AgentSurfaceHost) {
        guard let agent = agents[id], let project = project(id) else { return }
        // The fourth in a row is not sent: the reducer stops it instead.
        guard agent.record.mayContinue else {
            apply(.continuedByApp(prompt: Self.continueMessage), to: agent)
            return
        }
        // Cut off before its CLI had a conversation (Codex binds one at its
        // first turn's end): it starts again from its first instruction,
        // labelled as the app's.
        let prompt: String
        if agent.sessionID != nil || hasSavedSession(agent) {
            prompt = Self.continueMessage
        } else if let instruction = agent.record.firstInstruction {
            prompt = Self.restartLabel + " " + instruction
        } else {
            apply(.notContinued, to: agent)
            return
        }
        // Recorded when its terminal runs the launch, not before.
        pendingContinuations[id] = prompt
        activate(
            id: id, host: host, project: project, discardingSession: false,
            firstPrompt: prompt, notice: Self.continueNotice)
        if agent.surfaceState != .opening && !agent.isRunning { pendingContinuations[id] = nil }
    }

    /// The agent has a saved conversation to resume. One that cannot be read
    /// counts: its launch says so (`AgentProviderIssue.unreadableSession`).
    private func hasSavedSession(_ agent: AgentInstance) -> Bool {
        do {
            return try AgentSessionStore.session(for: agent.id, provider: agent.provider, directory: statusDir) != nil
        } catch {
            return true
        }
    }

    /// Its launch is under way: its CLI does not yet read its input, and has
    /// not failed, gone, or started asking the person something (a dialog at
    /// start-up): an agent that asks has started, and holds no start slot.
    private func isComingUp(_ id: UUID) -> Bool {
        guard let agent = agents[id], agent.record.problem == nil, agent.record.state != .asks,
              !agent.runtime.inputReady
        else { return false }
        return agent.surfaceState == .opening || agent.isRunning
    }

    /// How long a settled agent's CLI keeps running, so that undo is
    /// instant (flows.md 6.7); the harness shortens it for its tests.
    var settledCLIEnd: TimeInterval = 60
    private var settleTimers: [UUID: any AgentTimer] = [:]

    /// Settles the agent (flows.md 6.7): off home and the list, findable,
    /// its record and session kept. A working agent only when
    /// `includingWorking` (its project removed). Its CLI ends
    /// `settledCLIEnd` later; a working turn it cuts is recorded as
    /// interrupted, and a working settled agent is never continued after a
    /// restart. False when it was not settled.
    @discardableResult
    func settle(id: UUID, includingWorking: Bool = false) -> Bool {
        guard let agent = agents[id], agent.record.settledAt == nil else { return false }
        apply(.settled(includingWorking: includingWorking), to: agent)
        guard agent.record.settledAt != nil else { return false }
        stopEverythingPending(for: agent)
        settleTimers.removeValue(forKey: id)?.invalidate()
        // Settled, it is silent: no limit reset fires for it (ruling 2).
        limitTimers.removeValue(forKey: id)?.invalidate()
        settleTimers[id] = scheduler.timer(interval: settledCLIEnd, repeats: false) { [weak self] in
            self?.endSettledCLI(id)
        }
        updateWaitingCount()
        return true
    }

    /// Settled means stopped (last review ruling 5): its launch waiting its
    /// turn is taken off the queue, a launch being prepared ends unopened
    /// (`finishSurfaceLaunch` asks `reaches`), and no restart continuation,
    /// interrupt-and-send or send held for its start is left to reach it.
    private func stopEverythingPending(for agent: AgentInstance) {
        let id = agent.id
        pendingContinuations[id] = nil
        restorePending.removeAll { $0 == id }
        pendingInterrupts.removeValue(forKey: id)?.resume(.notReady)
        for send in pendingSends.removeValue(forKey: id) ?? [] { send.done(.notReady) }
        let queued = waitingLaunches.contains { $0.id == id }
        waitingLaunches.removeAll { $0.id == id }
        // A launch that has not opened a terminal yet is called off.
        if agent.processState == .launching, agent.surfaceState == .opening, queued || starting.contains(id) {
            agent.waitsToStart = false
            starting.remove(id)
            apply(.surfaceDied(generation: agent.launchGeneration, byUser: true), to: agent)
            startWaitingLaunches()
        }
    }

    /// Whether anything may launch, send to or type into the agent: never
    /// a settled one, nor one whose record could not be read, which would
    /// run on defaults (last review rulings 2 and 5). Every launch and send
    /// path asks this one question.
    func reaches(_ id: UUID) -> Bool {
        guard let agent = agents[id] else { return false }
        return agent.record.settledAt == nil && !unreadableRecords.contains(id)
    }

    /// Brings a settled agent back, in the state it had (undo, or opening it
    /// from find): its CLI runs on if it still does, else it resumes when
    /// next opened.
    func unsettle(id: UUID) {
        guard let agent = agents[id], agent.record.settledAt != nil else { return }
        settleTimers.removeValue(forKey: id)?.invalidate()
        apply(.unsettled, to: agent)
        scheduleLimitReset(for: agent)
        updateWaitingCount()
    }

    private func endSettledCLI(_ id: UUID) {
        settleTimers[id] = nil
        guard let agent = agents[id], agent.record.settledAt != nil,
              agent.isRunning || agent.surfaceState == .opening
        else { return }
        destroySurface(id: id, byUser: true)
    }

    /// Mark as unread (flows.md 6.12): a finished agent becomes finished,
    /// unread, and waits on the person. False for any other state.
    @discardableResult
    func markUnread(id: UUID) -> Bool {
        guard let agent = agents[id], agent.record.state == .finished, agent.record.settledAt == nil else { return false }
        apply(.markedUnread, to: agent)
        updateWaitingCount()
        return agent.record.unread
    }

    /// Starts a new session for an agent whose saved session is missing or
    /// unreadable: the launch forgets the saved session before it reads it.
    func startFresh(id: UUID, host: any AgentSurfaceHost, project: AgentProject) {
        guard agents[id]?.canOnlyStartFresh == true else { return }
        activate(id: id, host: host, project: project, discardingSession: true, first: true)
    }

    // MARK: - Starting and typing

    /// Starts a new agent in `project` with `task` as its first instruction,
    /// which its CLI takes on the command line (probes.md, P5): it exists at
    /// once, working, named from the task until its CLI titles it
    /// (flows.md 6.3, 4.3).
    func startAgent(
        task: String,
        provider: AgentProviderID,
        launchProfile: AgentLaunchProfile,
        config: AgentConfig,
        project: AgentProject,
        host: any AgentSurfaceHost
    ) -> AgentEntry? {
        let name = AgentNames.free(
            AgentRecord.name(fromInstruction: task), among: project.agents)
        var record = AgentRecord()
        record.state = .working
        record.changedAt = scheduler.now
        record.nameSource = .firstInstruction
        guard let entry = config.addAgent(
            project: project.name, name: name, provider: provider, launchProfile: launchProfile)
        else { return nil }
        addAgent(entry, createdAt: scheduler.now, record: record)
        activate(id: entry.id, host: host, project: project, discardingSession: false, firstPrompt: task)
        if let agent = agents[entry.id] { apply(.sent(prompt: task, by: .person), to: agent) }
        return entry
    }

    /// Cancels a start within `cancelLimit` of it, while the agent still
    /// works: the agent goes, its CLI with it. False when it is too late.
    @discardableResult
    func cancelStart(id: UUID, config: AgentConfig) -> Bool {
        guard let agent = agents[id], let created = agent.createdAt,
              scheduler.now.timeIntervalSince(created) <= Self.cancelLimit,
              agent.record.state == .working
        else { return false }
        return deleteAgents([id], config: config)
    }

    /// The one way text goes into an agent's CLI: pasted into its input line
    /// and submitted with Return at once (probes.md, P2), then recorded as
    /// sent by `sender`. Nothing is typed before the CLI reads its input, on
    /// top of text the person left in that line, or into a question or menu.
    /// `interrupting` stops a working agent first: Escape, its `idle`, and the
    /// line cleared of what the interrupt gave back (Claude: Escape twice;
    /// Codex: Control-C), then the text starts a turn at once. A working CLI
    /// sent to without interrupting queues the text itself.
    func send(
        _ text: String,
        to id: UUID,
        by sender: AgentRecord.Prompt.Sender,
        interrupting: Bool = false,
        done: @escaping @MainActor (AgentSendResult) -> Void
    ) {
        guard let agent = agents[id], reaches(id) else { return done(.notReady) }
        // No CLI runs: it starts with the text as its first prompt, as a new
        // agent does (flows.md 6.5 step 3).
        if let host = surfaceHost, !host.hasSurface(id: id) || agent.processState == .exited, agent.surfaceState != .opening,
           !agent.isRunning, agent.record.state != .asks, !agent.canOnlyStartFresh, let project = project(id) {
            activate(id: id, host: host, project: project, discardingSession: false, firstPrompt: text)
            guard agent.processState == .launching else { return done(.notReady) }
            apply(.sent(prompt: text, by: sender), to: agent)
            return done(.sent)
        }
        // Its CLI starts: the text waits for its input to be ready.
        if agent.processState == .launching, agent.record.state != .asks, agent.record.problem == nil {
            pendingSends[id, default: []].append(AgentPendingSend(text: text, sender: sender, interrupting: interrupting, done: done))
            return
        }
        if let refusal = refusal(id, checkingLine: !interrupting) { return done(refusal) }
        guard let host = surfaceHost else { return done(.notReady) }
        // What the person typed into its input is never interrupted away:
        // the agent is skipped before any Escape reaches it (S7 review
        // ruling 1). A line that cannot be read while it works is read
        // again after the interrupt.
        if interrupting, case .holdsText = inputLine(of: agent, in: host) { return done(.holdsText) }
        guard interrupting, agent.record.state == .working else {
            if let refusal = refusal(id, checkingLine: true) { return done(refusal) }
            submit(text, to: agent, in: host, by: sender)
            return done(.sent)
        }
        // One wait per agent: a later interrupting send takes its place.
        pendingInterrupts.removeValue(forKey: id)?.resume(.replaced)
        host.input(.escape, to: id)
        let token = UUID()
        pendingInterrupts[id] = (token, { [weak self] ended in
            guard let self else { return }
            if let ended { return done(ended) }
            // The given-back prompt is drawn with the `idle`.
            self.scheduler.after(0.1) { [weak self] in
                guard let self else { return }
                if let refusal = self.refusal(id, checkingLine: false) { return done(refusal) }
                self.clearInputLine(of: id, in: host) { [weak self] in
                    guard let self else { return }
                    // Everything a plain send checks, again: nothing is pasted
                    // on a guess.
                    if let refusal = self.refusal(id, checkingLine: true) { return done(refusal) }
                    guard let agent = self.agents[id] else { return done(.notReady) }
                    self.submit(text, to: agent, in: host, by: sender)
                    done(.sent)
                }
            }
        })
        scheduler.after(2) { [weak self] in
            guard let self, self.pendingInterrupts[id]?.token == token else { return }
            self.pendingInterrupts.removeValue(forKey: id)?.resume(.notReady)
        }
    }

    private func deliverPendingSends(of id: UUID) {
        guard let pending = pendingSends.removeValue(forKey: id) else { return }
        for send in pending {
            if agents[id]?.runtime.inputReady == true {
                self.send(send.text, to: id, by: send.sender, interrupting: send.interrupting, done: send.done)
            } else {
                send.done(agents[id]?.record.state == .asks ? .menu : .notReady)
            }
        }
    }

    /// Why text cannot go into the agent's CLI now, or nil when it can: its
    /// CLI runs, has a terminal, reads its input, asks nothing, and (with
    /// `checkingLine`) shows an empty input line. A line that cannot be read
    /// is a menu or a dialog.
    private func refusal(_ id: UUID, checkingLine: Bool) -> AgentSendResult? {
        guard let agent = agents[id], reaches(id), let host = surfaceHost, host.hasSurface(id: id),
              agent.runtime.inputReady, agent.processState == .running
        else { return .notReady }
        guard agent.record.state != .asks else { return .menu }
        guard checkingLine else { return nil }
        switch inputLine(of: agent, in: host) {
        case .none: return .menu
        case .holdsText: return .holdsText
        case .empty: return nil
        }
    }

    /// An interrupting send waiting for its agent's `idle` ends, refused, when
    /// the agent asks or its CLI goes.
    private func endInterruptWait(of agent: AgentInstance) {
        guard pendingInterrupts[agent.id] != nil else { return }
        if agent.record.state == .asks {
            pendingInterrupts.removeValue(forKey: agent.id)?.resume(.menu)
        } else if agent.processState == .exited || !agent.isRunning {
            pendingInterrupts.removeValue(forKey: agent.id)?.resume(.notReady)
        }
    }

    private func submit(_ text: String, to agent: AgentInstance, in host: any AgentSurfaceHost, by sender: AgentRecord.Prompt.Sender) {
        host.input(.paste(text), to: agent.id)
        host.input(.enter, to: agent.id)
        apply(.sent(prompt: text, by: sender), to: agent)
    }

    private func inputLine(of agent: AgentInstance, in host: any AgentSurfaceHost) -> AgentInputLine {
        AgentInputLine.read(host.screen(id: agent.id) ?? "", provider: agent.provider, prompted: agent.runtime.prompted)
    }

    /// Empties the input line after an interrupt gave a prompt back: Claude
    /// clears on Escape twice within half a second (never on an empty line,
    /// where it rewinds), Codex on Control-C (probes.md, P2). agy gives back
    /// no prompt, only the messages queued while it worked (`cli-facts.md`,
    /// agy): text the person holds, which is never wiped, so the send that
    /// follows refuses it. Control-C never goes to agy: with no turn running
    /// it arms its exit, and a second one ends it, typed text and all.
    private func clearInputLine(of id: UUID, in host: any AgentSurfaceHost, done: @escaping @MainActor () -> Void) {
        guard let agent = agents[id], case .holdsText = inputLine(of: agent, in: host) else { return done() }
        switch agent.provider {
        case .claudeCode:
            host.input(.escape, to: id)
            scheduler.after(0.1) { host.input(.escape, to: id) }
        case .codex:
            host.input(.interrupt, to: id)
        case .antigravity:
            return done()
        }
        scheduler.after(0.3) { done() }
    }

    /// Asks for the agent's launch, or shows its terminal when it has one.
    /// The launch waits its turn (`startWaitingLaunches`); `first` puts it
    /// ahead of those waiting: the person opened it.
    private func activate(
        id: UUID,
        host: any AgentSurfaceHost,
        project: AgentProject,
        discardingSession: Bool,
        firstPrompt: String? = nil,
        notice: String? = nil,
        first: Bool = false
    ) {
        guard let agent = agents[id], reaches(id) else { return }
        surfaceHost = host

        // A missing or unreadable saved session can only be replaced, which
        // Start Fresh does. Any other activation, from the list, the palette
        // or a notification, shows the agent's terminal if it has one; the
        // terminal area offers Start fresh. It launches nothing.
        if agent.canOnlyStartFresh && !discardingSession {
            if host.hasSurface(id: id) {
                _ = host.showOrSwitch(
                    agent: agent,
                    focusTerminal: true,
                    select: true,
                    createConfig: { nil })
            }
            return
        }

        // The provider has exited and its terminal is about to close.
        if host.hasSurface(id: id), agent.processState == .exited {
            discardSurfaceForRestart(id: id, host: host, provider: agent.provider)
        }

        if host.hasSurface(id: id) {
            _ = host.showOrSwitch(
                agent: agent,
                focusTerminal: true,
                select: true,
                createConfig: { nil })
            return
        }

        // A second activation while its launch waits or is prepared never
        // creates a competing run; the person's open moves it to the front.
        if agent.surfaceState == .opening, agent.processState == .launching {
            if first, let at = waitingLaunches.firstIndex(where: { $0.id == id }), at > 0 {
                waitingLaunches.insert(waitingLaunches.remove(at: at), at: 0)
            }
            return
        }

        let generation = UUID()
        apply(.launchRequested(generation: generation, prompted: firstPrompt != nil), to: agent)
        keysPassThrough.remove(id)
        agent.lastActivityReport = nil
        // Nothing waits or starts: a new burst, which lists the running
        // conversations afresh.
        starting = starting.filter(isComingUp)
        if waitingLaunches.isEmpty, starting.isEmpty { liveSessions = AgentLiveSessions() }
        let launch = AgentPendingLaunch(
            id: id, generation: generation, project: project,
            discardingSession: discardingSession, firstPrompt: firstPrompt, notice: notice)
        if first { waitingLaunches.insert(launch, at: 0) } else { waitingLaunches.append(launch) }
        agent.waitsToStart = true
        startWaitingLaunches()
    }

    /// Begins the launches waiting their turn, first come first, while
    /// fewer than `startConcurrency` CLIs are starting; each one that comes
    /// up, fails or goes lets the next begin (`apply`).
    private func startWaitingLaunches() {
        guard !isTerminating else { return }
        starting = starting.filter(isComingUp)
        while starting.count < Self.startConcurrency, !waitingLaunches.isEmpty {
            let launch = waitingLaunches.removeFirst()
            guard let agent = agents[launch.id], reaches(launch.id), agent.launchGeneration == launch.generation,
                  agent.processState == .launching, agent.surfaceState == .opening
            else { continue }
            agent.waitsToStart = false
            starting.insert(launch.id)
            begin(launch, of: agent)
        }
    }

    /// Prepares the launch off the main thread and opens its terminal. Its
    /// time to start (`startLimit`) runs from here, not from the wait.
    private func begin(_ launch: AgentPendingLaunch, of agent: AgentInstance) {
        let id = launch.id
        let generation = launch.generation
        let project = launch.project
        let discardingSession = launch.discardingSession
        scheduleLaunchTimeout(agentID: id, generation: generation)

        let provider = agent.provider
        let name = agent.name
        let profile = agent.launchProfile
        let path = effectiveEnvironmentPath
        let workingDirectory = project.workingDirectory
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
            namedByUser: !agent.autoNamed,
            firstPrompt: launch.firstPrompt,
            notice: launch.notice,
            liveSessions: liveSessions)
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
                    workingDirectory: workingDirectory,
                    host: host)
            }
        }
    }

    /// Whether keys typed into the agent's terminal are held now: its CLI
    /// starts, has not reported yet, asks nothing, and has not shown a screen
    /// past `holdLimit`.
    func holdsKeys(for id: UUID) -> Bool {
        guard let agent = agents[id], !keysPassThrough.contains(id) else { return false }
        return agent.processState == .launching
            && (agent.surfaceState == .opening || agent.surfaceState == .open)
            && agent.record.state != .asks
    }

    /// The keys held for the agent's start are not sent, and from now on
    /// keys reach its terminal.
    private func endHold(_ id: UUID) {
        holdTimers.removeValue(forKey: id)?.invalidate()
        guard keysPassThrough.insert(id).inserted else { return }
        onKeysNotHeld?(id)
    }

    /// A starting CLI that has drawn a screen but sent no report within
    /// `holdLimit` shows something only the person can answer.
    private func scheduleHoldLimit(agentID: UUID, generation: UUID) {
        holdTimers.removeValue(forKey: agentID)?.invalidate()
        let opened = scheduler.now
        holdTimers[agentID] = scheduler.timer(interval: 0.5, repeats: true) { [weak self] in
            guard let self else { return }
            guard let agent = self.agents[agentID], agent.launchGeneration == generation,
                  agent.processState == .launching
            else {
                self.holdTimers.removeValue(forKey: agentID)?.invalidate()
                return
            }
            guard self.scheduler.now.timeIntervalSince(opened) >= Self.holdLimit - 0.01,
                  let screen = self.surfaceHost?.screen(id: agentID),
                  !screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            self.diagnose(.info, "\(agentID) shows a screen with no report after \(Self.holdLimit) s: keys go to it")
            self.endHold(agentID)
        }
    }

    /// A launch whose CLI has not come to read its input within
    /// `startLimit` stops with a problem. One stuck with nothing on its
    /// screen for the person has its terminal closed, so the agent is truly
    /// stopped and typing or opening it starts it afresh (final review
    /// ruling 11); one showing a screen the person must answer (a trust or
    /// update dialog, keys passing to it) keeps it, and its first report
    /// still makes it ready.
    private func scheduleLaunchTimeout(agentID: UUID, generation: UUID) {
        launchTimers[agentID]?.invalidate()
        launchTimers[agentID] = scheduler.timer(interval: Self.startLimit, repeats: false) { [weak self] in
            guard let self, let agent = self.agents[agentID], agent.launchGeneration == generation else { return }
            self.launchTimers.removeValue(forKey: agentID)
            let showsSomething = self.keysPassThrough.contains(agentID)
            let effects = self.apply(.launchTimedOut(generation: generation), to: agent)
            guard effects.contains(.failed) else { return self.perform(effects, of: agent) }
            self.endHold(agentID)
            self.perform(effects, of: agent)
            if !showsSomething { self.destroySurface(id: agentID, byUser: true) }
        }
    }

    private func finishSurfaceLaunch(
        _ outcome: AgentSurfaceLaunchOutcome,
        agentID: UUID,
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
            var problem = AgentRecord.Problem(kind: .launch, text: issue.localizedDescription)
            var missingSessionID: String?
            switch issue {
            case .unreadableSession: sessionUnreadable = true
            case .executableMissing: problem = AgentRecord.Problem(kind: .notInstalled)
            case .sessionOpenElsewhere: problem = AgentRecord.Problem(kind: .openElsewhere)
            case .sessionMissing(_, let session):
                problem = AgentRecord.Problem(kind: .conversationMissing)
                missingSessionID = session
            case .integrationFailed, .launchPreparationFailed: break
            }
            failLaunch(
                agent, generation: generation, problem: problem,
                sessionUnreadable: sessionUnreadable, missingSessionID: missingSessionID)

        case .success(let launch):
            guard reaches(agentID), agent.launchGeneration == launch.generation,
                  agent.provider == launch.provider,
                  agent.processState == .launching
            else {
                removeFileOffMain(launch.scriptURL)
                return
            }
            agent.metadataAvailability = launch.integrationIssue.map {
                .unavailable($0)
            } ?? launch.metadataAvailability
            // No view says why the header will show no model or context.
            if case .unavailable(let reason) = agent.metadataAvailability {
                diagnose(.default, "\(agentID) reports no model or context: \(reason)")
            }
            removeLaunchScript(for: agentID)
            removeExitStatusFile(for: agentID)
            launchScripts[agentID] = launch.scriptURL
            exitStatusFiles[agentID] = (launch.generation, AgentLaunchCoordinator.exitStatusURL(script: launch.scriptURL))
            let isNew = host.presentPreparedSurface(
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
                removeExitStatusFile(for: agentID)
                failLaunch(
                    agent,
                    generation: launch.generation,
                    problem: AgentRecord.Problem(kind: .launch, text: "Its terminal could not be opened."))
                return
            }
            apply(
                .surfaceOpened(
                    generation: launch.generation,
                    resumedSessionID: launch.resumedSessionID,
                    newSessionID: launch.newSessionID),
                to: agent)
            // The continuation is on its CLI's command line: sent now.
            if let prompt = pendingContinuations.removeValue(forKey: agentID) {
                apply(.continuedByApp(prompt: prompt), to: agent)
            }
            scheduleHoldLimit(agentID: agentID, generation: launch.generation)
            onSurfacePresentationChanged?(agentID)
        }
    }

    private func failLaunch(
        _ agent: AgentInstance,
        generation: UUID,
        problem: AgentRecord.Problem,
        sessionUnreadable: Bool = false,
        missingSessionID: String? = nil
    ) {
        let effects = apply(
            .launchFailed(
                generation: generation, problem: problem,
                sessionUnreadable: sessionUnreadable, missingSessionID: missingSessionID),
            to: agent)
        if effects.contains(.sessionMissing) { recordMissingSession(of: agent) }
        launchTimers[agent.id]?.invalidate()
        launchTimers.removeValue(forKey: agent.id)
        pendingContinuations[agent.id] = nil
        endHold(agent.id)
        updateWaitingCount()
    }

    // MARK: - Rename

    /// The name the user gave the agent, as `AgentConfig.renameAgent` stores
    /// it: shown at once, and never replaced by a conversation's title.
    /// Nothing reaches a running terminal: Claude takes the name as `--name`
    /// at its next launch, which names its conversation for good, and Codex
    /// sessions are not renamed.
    func renameAgent(id: UUID, newName: String) {
        guard let agent = agents[id] else { return }
        agent.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        apply(.named(by: .person), to: agent)
    }

    /// Shows a name Clawddy gave the agent, as `AgentConfig` stores it: a
    /// conversation's title (`source` `.cli`), or a name a move numbered,
    /// whose source does not change.
    func showName(id: UUID, name: String, source: AgentRecord.NameSource? = nil) {
        guard let agent = agents[id] else { return }
        agent.name = name
        if let source { apply(.named(by: source), to: agent) }
    }

    /// The title the program in an agent's terminal set, for the launch the
    /// terminal was made for. While the agent's name is Clawddy's and its
    /// provider runs, a title that names the conversation
    /// (`AgentConversationTitle`) is offered as its name.
    func surfaceTitle(id: UUID, generation: UUID?, title: String) {
        if let agent = agents[id], agent.launchGeneration == generation { noteCodexTitle(title, of: agent) }
        guard let agent = agents[id], agent.autoNamed, agent.isRunning,
              agent.launchGeneration == generation,
              let name = AgentConversationTitle.name(from: title, folder: project(id)?.workingDirectory),
              name != agent.name
        else { return }
        onConversationTitle?(id, name)
    }

    /// Codex spins a braille frame before its title while it works
    /// (probes.md, P2: `⠙ <folder>`); the spinning stopping during a turn is
    /// the turn's end, as a bare `done` would say. Its notify, when it comes,
    /// then ends nothing (`turnsEndedWithoutNotify`).
    private func noteCodexTitle(_ title: String, of agent: AgentInstance) {
        guard agent.provider == .codex, let generation = agent.launchGeneration else { return }
        let spinning = title.unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } ?? false
        defer { agent.titleSpins = spinning }
        guard agent.titleSpins, !spinning, case .active = agent.turnState else { return }
        let done = Ghostty.Action.ProgramStatus(
            state: .done, kind: nil, progress: nil, id: nil, app: "codex", title: nil, message: nil)
        perform(apply(.provider(
            generation: generation, provider: .codex, eventID: UUID().uuidString,
            event: .programStatus(done), isViewed: isViewed(agent.id)), to: agent), of: agent)
    }

    private func acknowledgeCompletion(id: UUID) {
        guard let agent = agents[id], agent.record.unread else { return }
        apply(.opened, to: agent)
        updateWaitingCount()
    }

    /// The workspace owner reports that the user now looks at the agent:
    /// its completion is acknowledged and its notifications are cleared.
    func agentViewed(_ id: UUID) {
        acknowledgeCompletion(id: id)
        clearNotifications(for: id)
    }

    // MARK: - Deletion

    /// Deletes agents for good, in one save of the configuration: a start
    /// cancelled within its time. Nothing else deletes an agent; settling
    /// and removing a project keep everything.
    @discardableResult
    func deleteAgents(_ ids: [UUID], config: AgentConfig) -> Bool {
        guard config.removeAgents(Set(ids)) else { return false }
        removeAgents(ids)
        return true
    }

    private func removeAgents(_ ids: [UUID]) {
        for id in ids { removeAgent(id: id) }
        updateWaitingCount()
    }

    /// The one way an agent goes, whatever removed it: a cancelled start, an
    /// edit of `agents.json` that drops it, or a provider
    /// change that replaces its runtime. Its terminal closes, its runtime is
    /// dropped, and every `<agent id>.*` file in the status folder and its
    /// runtime folder are deleted. No other agent's file is touched.
    private func removeAgent(id: UUID) {
        settleTimers.removeValue(forKey: id)?.invalidate()
        destroySurface(id: id, byUser: true)
        limitTimers.removeValue(forKey: id)?.invalidate()
        agents.removeValue(forKey: id)
        waiting.remove(id)
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
        // A record in its event file: the agent was active.
        if case .hook = observation.event { agents[id]?.lastActive = scheduler.now }
        // What its CLI reported was lost: say so, whatever the launch.
        if case .unreadableRecord = observation.event, let agent = agents[id] {
            perform(apply(.reportFailed, to: agent), of: agent)
            return
        }
        guard let agent = agents[id],
              let generation = agent.launchGeneration,
              observation.generation == generation
        else {
            switch observation.event {
            case .hook: diagnose(.debug, "ignored stale launch event for \(id)")
            case .surfaceClosed: diagnose(.debug, "ignored close of an earlier surface of \(id)")
            case .programStatus: diagnose(.debug, "ignored program status for \(id)")
            case .unreadableRecord: break
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
        case .unreadableRecord:
            break
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
        if report.state == .idle { pendingInterrupts.removeValue(forKey: id)?.resume(nil) }
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
        providerExited(agent, status: status, generation: generation)
    }

    /// Its provider exited with `status`, as its launch script reported in
    /// the terminal or wrote to its exit status file.
    private func providerExited(_ agent: AgentInstance, status: Int, generation: UUID) {
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
        // The hook script could not record an event of the agent's.
        if record.hookEventName == AgentHookRuntime.failureRecordName {
            diagnose(.error, "hook of \(id) failed: \(record.text ?? "")")
            perform(apply(.reportFailed, to: agent), of: agent)
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
        for (index, meant) in domainEvents.enumerated() {
            // A usage limit's reset time is in the status line, not the hook.
            var domainEvent = meant
            if case .turnFailed(var failure) = meant, failure.isUsageLimit {
                failure.resetsAt = agent.metadata?.limitResetsAt
                domainEvent = .turnFailed(failure)
            }
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
        perform(effects, of: agent)
    }

    /// What provider facts set in motion once applied: the launch's cleanup
    /// when the provider is seen alive or gone, notifications while the
    /// agent is not viewed, and saving the unread state.
    private func perform(_ effects: [AgentRuntimeEffect], of agent: AgentInstance) {
        let id = agent.id
        if effects.contains(.becameAlive) {
            // The start limit runs until its input is ready (`.inputReady`).
            removeLaunchScript(for: id)
            let provider = agent.provider
            integrationIssues[provider] = nil
            refreshProviderHealth(provider)
        }
        if effects.contains(.sessionSaved), let sessionID = agent.sessionID {
            saveBinding(sessionID, of: agent)
        }
        if effects.contains(.sessionMissing) { recordMissingSession(of: agent) }
        if effects.contains(where: {
            if case .providerExited = $0 { return true }
            return false
        }) {
            launchTimers[id]?.invalidate()
            launchTimers.removeValue(forKey: id)
            removeLaunchScript(for: id)
        }
        updateTurnStartTimer(for: agent)
        updateSignInTimer(for: agent)

        if effects.contains(.completed) {
            alert(agent, .finished)
        }
        if effects.contains(.waitingForUser) {
            alert(agent, .permission)
        }
        if effects.contains(.failed) {
            alert(agent, .error)
        }
        if effects.contains(.inputSettling), let generation = agent.launchGeneration {
            scheduler.after(3) { [weak self, weak agent] in
                guard let self, let agent else { return }
                self.perform(self.apply(.inputSettled(generation: generation), to: agent), of: agent)
            }
        }
        if effects.contains(.inputReady) || effects.contains(.startedAsking) {
            launchTimers.removeValue(forKey: id)?.invalidate()
        }
        // Keys held for its start: delivered at its first report, unless it
        // asks something or shows its sign-in, which the person must answer
        // themselves.
        if effects.contains(.becameAlive) || effects.contains(.waitingForUser) {
            holdTimers.removeValue(forKey: id)?.invalidate()
            if agent.record.state == .asks || agent.record.problem?.kind == .loginExpired {
                endHold(id)
            } else if effects.contains(.becameAlive) {
                onKeysReady?(id)
            }
        }
        scheduleLimitReset(for: agent)
        updateWaitingCount()
    }

    /// The agent's binding records that its session is missing, so it offers
    /// only Start Fresh, after a restart too.
    private func recordMissingSession(of agent: AgentInstance) {
        guard let missing = agent.missingSessionID else { return }
        let id = agent.id
        let statusDir = statusDir
        store(
            AgentSessionStore.sessionURL(id, statusDir),
            "The missing session \(missing) of \(agent.name) could not be recorded, so after a restart its next start tries to resume it once more"
        ) {
            try AgentSessionStore.markMissing(missing, for: id, directory: statusDir)
        }
    }

    /// A paused agent whose usage limit gave a reset time is reset then, or
    /// at once when that time has passed.
    private func scheduleLimitReset(for agent: AgentInstance) {
        let id = agent.id
        limitTimers.removeValue(forKey: id)?.invalidate()
        guard agent.record.settledAt == nil, agent.record.state == .paused, let resetsAt = agent.record.limit?.resetsAt else { return }
        limitTimers[id] = scheduler.timer(
            interval: max(0, resetsAt.timeIntervalSince(scheduler.now)),
            repeats: false
        ) { [weak self, weak agent] in
            guard let self, let agent else { return }
            self.limitTimers.removeValue(forKey: id)
            self.perform(self.apply(.usageLimitReset, to: agent), of: agent)
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
        // The binding follows the provider: every `SessionStart` of the
        // current launch, whatever its source (startup, resume, clear,
        // compact), names the session the next launch resumes. After
        // `/clear` that is the new session, not the one launched. A session
        // the launch created is not on disk before its first turn, which
        // saves the binding then (`perform`).
        let sessionID: String?
        if case .sessionBound(let bound) = domainEvent { sessionID = bound } else { sessionID = nil }
        if let sessionID, !agent.runtime.sessionUnsaved {
            saveBinding(sessionID, of: agent)
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

    /// Makes `sessionID`, a session on disk, the one the agent's next launch
    /// resumes.
    private func saveBinding(_ sessionID: String, of agent: AgentInstance) {
        guard let generation = agent.launchGeneration else { return }
        let binding = AgentSessionBinding(
            provider: agent.provider,
            sessionID: sessionID,
            launchGeneration: generation)
        let agentID = agent.id
        let statusDir = statusDir
        let file = AgentSessionStore.sessionURL(agentID, statusDir)
        // agy names its conversation in every record: written once, and
        // again only when it changes or its last write failed.
        guard binding != agent.savedBinding || storageErrors[file] != nil else { return }
        agent.savedBinding = binding
        store(
            file,
            "Session \(sessionID) of \(agent.name) could not be saved, so its next launch may not resume it"
        ) {
            try AgentSessionStore.write(binding, for: agentID, directory: statusDir)
        }
    }

    private func runtimeVersion(for provider: AgentProviderID) -> String? {
        guard case .ready(_, let version) = providerHealth[provider]?.installation else {
            return nil
        }
        return version
    }

    /// Applies `event` to the agent; an agent being brought back that is
    /// now up, or has failed, lets the next one start.
    @discardableResult
    private func apply(
        _ event: AgentRuntimeEvent,
        to agent: AgentInstance
    ) -> [AgentRuntimeEffect] {
        let before = agent.record.durable
        let effects = agent.apply(event, rules: providers[agent.provider].reports, at: scheduler.now)
        if agent.record.durable != before { saveRecord(of: agent) }
        // A launch that waited its turn and was stopped meanwhile waits no
        // more.
        if agent.waitsToStart, agent.processState != .launching {
            agent.waitsToStart = false
            waitingLaunches.removeAll { $0.id == agent.id }
        }
        endInterruptWait(of: agent)
        if starting.contains(agent.id), !isComingUp(agent.id) {
            scheduler.after(0) { [weak self] in self?.startWaitingLaunches() }
        }
        // Sends waiting for its start: delivered once it reads its input,
        // given up when the start fails or it asks.
        if pendingSends[agent.id] != nil, agent.runtime.inputReady || !isComingUp(agent.id) {
            let id = agent.id
            scheduler.after(0) { [weak self] in self?.deliverPendingSends(of: id) }
        }
        return effects
    }

    /// While a `working` report may still prove a blip, its turn waits; it
    /// starts when the report has stood for the provider's
    /// `turnStartDelay`, counted from the first `working`. A prompt starts it
    /// at once (its `UserPromptSubmit` record), as do a request and a
    /// failure, which can come 106 ms after its `working`. Commands that
    /// submit no prompt report a `working` too: `/clear`, `/exit` and the
    /// `/exit` confirmation for 14 to 63 ms, `/resume` with its argument for
    /// 280 to 434 ms (`cli-facts.md`, flows capture), and Codex at start-up. Waiting this way, rather than starting the turn
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
            interval: providers[agent.provider].reports.turnStartDelay,
            repeats: false
        ) { [weak self, weak agent] in
            guard let self, let agent else { return }
            self.turnStartTimers.removeValue(forKey: id)
            self.perform(self.apply(.turnStartSettled(generation: generation), to: agent), of: agent)
        }
    }

    /// A sign-in report that must stand (`AgentReportRules.signInStandTime`)
    /// counts once it has stood that long, counted from its arrival; any
    /// other report replaces it, and its time with it.
    private func updateSignInTimer(for agent: AgentInstance) {
        let id = agent.id
        guard agent.runtime.pendingSignIn != nil, let generation = agent.launchGeneration else {
            signInTimers.removeValue(forKey: id)?.invalidate()
            return
        }
        guard signInTimers[id] == nil else { return }
        signInTimers[id] = scheduler.timer(
            interval: providers[agent.provider].reports.signInStandTime,
            repeats: false
        ) { [weak self, weak agent] in
            guard let self, let agent else { return }
            self.signInTimers.removeValue(forKey: id)
            self.perform(self.apply(.signInSettled(generation: generation), to: agent), of: agent)
        }
    }

    // MARK: - Aggregate

    /// When the agent was last active (`AgentInstance.lastActive`).
    func lastActive(of id: UUID) -> Date? {
        agents[id]?.lastActive
    }

    /// When the agent's event file last changed; nil when it has never run,
    /// and when the file's date cannot be read, which is logged.
    private func lastRecordDate(of id: UUID) -> Date? {
        do {
            return try AgentHookJournalSource.lastRecordDate(of: id, in: statusDir)
        } catch {
            diagnose(.error, "last activity of \(id) unreadable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Agents waiting for the user: the count of the menu bar item and the
    /// dock badge. Only a waiting agent asks for attention: Done is unread,
    /// not a request, and a problem has its own mark.
    var waitingAgentCount: Int { waiting.count }

    /// Agents whose provider is starting or running in a terminal; quitting
    /// stops them.
    var runningAgentCount: Int {
        agents.values.filter(\.isRunning).count
    }

    /// What quitting does to the running agents, in one sentence; nil when
    /// none runs (`AgentQuitConfirmation`).
    var quitNotice: String? {
        let working = agents.values.filter { $0.record.state == .working && $0.record.settledAt == nil }
        let waiting = agents.values.filter { $0.waitsToStart && $0.record.state != .working && $0.record.settledAt == nil }
        return AgentQuitConfirmation.notice(working: working.count, waitingToStart: waiting.count)
    }

    private func updateWaitingCount() {
        let current = waitingAgentCount
        if lastWaitingCount != current {
            lastWaitingCount = current
            onWaitingCountChanged?(current)
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

    /// A close the user asks for, while the provider runs, is confirmed and
    /// stops the agent on purpose. Any other close takes a terminal whose
    /// provider has exited, or that died under it.
    private func closeSurface(of agent: AgentInstance, generation: UUID, processAlive: Bool) {
        // A surface closes once, however many reports of it arrive.
        guard agent.surfaceState == .open else { return }
        let id = agent.id
        if processAlive, let surfaceHost {
            surfaceHost.confirmClose(id: id) { [weak self] in
                // The launch may have changed while the question was open.
                guard let self, let agent = self.agents[id],
                      agent.launchGeneration == generation, agent.surfaceState == .open
                else { return }
                self.destroySurface(id: id, byUser: true)
            }
            return
        }
        diagnose(.info, "surface death: \(id)")
        destroySurface(id: id, byUser: false)
    }

    private func discardSurfaceForRestart(
        id: UUID,
        host: any AgentSurfaceHost,
        provider: AgentProviderID
    ) {
        invalidateTimers(for: id)
        removeLaunchScript(for: id)
        removeExitStatusFile(for: id)
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
        holdTimers.removeValue(forKey: id)?.invalidate()
        turnStartTimers.removeValue(forKey: id)?.invalidate()
        signInTimers.removeValue(forKey: id)?.invalidate()
    }

    /// The agent's terminal goes, `byUser` when the user stops it. A
    /// provider that went without the user stops with a problem; it is not
    /// started again by itself (`docs/clawddy-design/flows.md` 2.2).
    private func destroySurface(id: UUID, byUser: Bool) {
        invalidateTimers(for: id)
        // An exit report the terminal had not read when Ghostty told of the
        // process's exit is in the launch script's exit status file.
        if !byUser, let agent = agents[id], let generation = agent.launchGeneration, agent.processState != .exited,
           let file = exitStatusFiles[id], file.generation == generation,
           let data = FileManager.default.contents(atPath: file.url.path),
           let status = String(bytes: data, encoding: .utf8).flatMap({ Int($0) }) {
            providerExited(agent, status: status, generation: generation)
        }
        removeExitStatusFile(for: id)
        removeLaunchScript(for: id)
        if let provider = agents[id]?.provider {
            removeProviderFiles(of: id, provider: provider)
        }
        if let agent = agents[id] {
            let effects = apply(
                .surfaceDied(generation: agent.launchGeneration, byUser: byUser, isViewed: isViewed(id)), to: agent)
            if effects.contains(.failed) { alert(agent, .error) }
        }
        onSurfaceDeath?(id)
        onSurfacePresentationChanged?(id)
        updateWaitingCount()
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
    /// Both say the agent's name, then its sentence (words.md,
    /// "Notification"); a finished turn whose message has not arrived yet
    /// says "Finished".
    private func alert(_ agent: AgentInstance, _ kind: NotificationKind) {
        // A settled agent is silent (ruling 2); its record still takes what
        // its CLI reports, so undo shows the truth.
        guard agent.record.settledAt == nil else { return }
        let said = agent.sentence
        let sentence = kind == .finished && said.isAppWritten ? AgentShownState.finished.name : said.text
        notifier.announce("\(agent.name), \(sentence)")
        guard !isViewed(agent.id), notifies() else { return }
        postNotification(agentId: agent.id, kind: kind, title: agent.name, body: sentence)
    }

    /// The agent's name as its title, its project as its subtitle and its
    /// headline as its body. A completion is passive; a wait is
    /// time-sensitive. None makes a sound (the brief: no sounds).
    private func postNotification(agentId: UUID, kind: NotificationKind, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = project(agentId)?.name ?? ""
        content.body = body
        content.threadIdentifier = agentId.uuidString
        content.userInfo = ["clawddy_agent_id": agentId.uuidString]

        switch kind {
        case .finished:
            content.interruptionLevel = .passive
        case .permission:
            content.interruptionLevel = .timeSensitive
        case .error:
            content.interruptionLevel = .active
        }
        content.sound = nil

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

    /// Keeps `text`, the agent's terminal as its CLI ended or the app quit,
    /// in `<agent id>.screen.txt` (0600), and on the agent.
    func saveScreen(_ text: String, of id: UUID) {
        guard let agent = agents[id], !text.isEmpty, agent.savedScreen != text else { return }
        agent.savedScreen = text
        // Written on the IO queue, never waited for: quitting waits for the
        // queue (`shutdown`), so the last screens are on disk before exit.
        storeScreen(text, of: agent)
    }

    private func storeScreen(_ text: String, of agent: AgentInstance) {
        let file = AgentTail.savedScreenURL(agent.id, statusDir)
        store(file, "The last screen of \(agent.name) could not be saved", saving: true) {
            try AgentConfig.atomicWrite(Data(text.utf8), to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// The screen saved for the agent, or none.
    private func loadScreen(of entry: AgentEntry) -> String {
        let file = AgentTail.savedScreenURL(entry.id, statusDir)
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return ""
        } catch {
            reportStorageError(file, "The last screen of \(entry.name) could not be read: \(error.localizedDescription)")
            return ""
        }
    }

    /// Writes the agent's record as one atomic replacement, never over a
    /// record that could not be read. What is durable, and when
    /// (`AgentRecord.durable`): every change a restart, find or the tiles
    /// depend on (state, prompts, messages, the question, the problem,
    /// settling, unread, names) is queued for writing in the turn of the
    /// change, in order, and none is ever merged away; the IO queue writes
    /// it within milliseconds, and `shutdown` waits for it. The step a
    /// working CLI reports, which changes many times a second and which a
    /// restart clears anyway, is never written. The main thread never waits
    /// for the disk.
    private func saveRecord(of agent: AgentInstance) {
        let id = agent.id
        guard agents[id] === agent, !unreadableRecords.contains(id) else { return }
        let record = agent.record.durable
        let statusDir = statusDir
        store(AgentRecord.url(id, statusDir), "The record of \(agent.name) could not be saved", saving: true) {
            try AgentRecord.save(record, for: id, in: statusDir)
        }
    }

    /// Runs `work` on the IO queue and records how it went for `file`: a
    /// failure is reported and kept in `storageErrors`, which a later success
    /// for the same file clears.
    private func store(
        _ file: URL,
        _ failure: String,
        saving: Bool = false,
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
                guard let self else { return }
                if saving, (message != nil) != self.unsavedFiles.contains(file) {
                    if message != nil { self.unsavedFiles.insert(file) } else { self.unsavedFiles.remove(file) }
                }
                guard self.storageErrors[file] != message else { return }
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

    private func removeExitStatusFile(for id: UUID) {
        guard let file = exitStatusFiles.removeValue(forKey: id) else { return }
        removeFileOffMain(file.url)
    }

    private func removeAllLaunchScripts(synchronously: Bool = false) {
        let urls = Array(launchScripts.values) + exitStatusFiles.values.map(\.url)
        launchScripts.removeAll()
        exitStatusFiles.removeAll()
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
