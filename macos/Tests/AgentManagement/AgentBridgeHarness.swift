import Combine
import Foundation
import GhosttyKit
import os
import Testing
import UserNotifications
@testable import Ghostty

// Drives a real `AgentBridge` through its seams: a data root in a fresh
// temporary folder, a clock that moves only when a test advances it, IO that
// runs at once on the main thread, and fakes for the surface host, the
// notification center and provider probes. Nothing here reads or writes the
// real home folder or starts a provider CLI.

/// A clock that moves only when a test advances it.
@MainActor
final class ManualScheduler: AgentScheduler {
    private(set) var now: Date
    private var scheduled: [ScheduledCall] = []

    init(now: Date) {
        self.now = now
    }

    func timer(
        interval: TimeInterval,
        repeats: Bool,
        _ action: @escaping @MainActor () -> Void
    ) -> any AgentTimer {
        let call = ScheduledCall(at: now + interval, every: repeats ? interval : nil, action)
        scheduled.append(call)
        return call
    }

    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        scheduled.append(ScheduledCall(at: now + delay, every: nil, action))
    }

    /// Whether a timer that repeats is scheduled.
    var hasRepeatingTimer: Bool {
        scheduled.contains { $0.interval != nil && !$0.isCancelled }
    }

    /// Moves the clock forward, running every timer and delayed call that
    /// falls due on the way at its own time: earliest first, and in the order
    /// they were scheduled when due together.
    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = scheduled
            .filter({ !$0.isCancelled && $0.fireDate <= end })
            .min(by: { $0.fireDate < $1.fireDate }) {
            now = next.fireDate
            if let interval = next.interval {
                next.fireDate += interval
            } else {
                scheduled.removeAll { $0 === next }
            }
            next.action()
        }
        now = end
    }
}

private final class ScheduledCall: AgentTimer {
    var fireDate: Date
    let interval: TimeInterval?
    let action: @MainActor () -> Void
    private(set) var isCancelled = false

    init(at fireDate: Date, every interval: TimeInterval?, _ action: @escaping @MainActor () -> Void) {
        self.fireDate = fireDate
        self.interval = interval
        self.action = action
    }

    func invalidate() { isCancelled = true }
}

/// Runs the bridge's IO work at once on the calling thread. The bridge calls
/// it from the main actor, so all of it runs on the main thread in call
/// order. `hold()` keeps `async` work back until `release()`, so a test can
/// act while a launch is being prepared.
final class InlineIO: AgentIOExecutor, @unchecked Sendable {
    private var held: [@Sendable () -> Void]?

    func hold() { held = [] }

    func release() {
        let work = held ?? []
        held = nil
        work.forEach { $0() }
    }

    func async(_ work: @escaping @Sendable () -> Void) {
        if held != nil {
            held?.append(work)
        } else {
            work()
        }
    }

    func sync(_ work: @Sendable () -> Void) { work() }
    func probe(_ work: @escaping @Sendable () -> Void) { work() }
    func global(_ work: @escaping @Sendable () -> Void) { work() }
    func onMainActor(_ work: @escaping @MainActor () -> Void) { MainActor.assumeIsolated(work) }
    func onMainQueue(_ work: @escaping @MainActor () -> Void) { MainActor.assumeIsolated(work) }
}

@MainActor
final class RecordingNotifier: AgentNotifier {
    private(set) var posted: [UNNotificationRequest] = []
    private(set) var removed: [[String]] = []
    private(set) var announced: [String] = []

    func post(_ request: UNNotificationRequest) { posted.append(request) }
    func removeNotifications(withIdentifiers identifiers: [String]) { removed.append(identifiers) }
    func announce(_ message: String) { announced.append(message) }
}

/// Every message the bridge reported, in order. The sink may be called from
/// any thread.
final class DiagnosticsRecord: Sendable {
    private let entries = OSAllocatedUnfairLock<[String]>(initialState: [])

    var messages: [String] { entries.withLock { $0 } }

    var sink: AgentDiagnosticsSink {
        { [entries] _, message in entries.withLock { $0.append(message) } }
    }
}

/// The real provider table on the harness root, except that probes return
/// `health` without running a CLI, launches are prepared by `prepareLaunch`,
/// and launch requests and cleanups are recorded. The default launch runs
/// `/usr/bin/true` and reads nothing, where the real Claude launch reads the
/// user's Claude settings. It names no session of its own, so each
/// `SessionStart` binds at once, as for a resumed session; a test of a new
/// or forked Claude session, whose binding waits for its first turn, uses
/// `useRealClaudeLaunch`. Used from the main thread only: the harness runs
/// all IO inline.
final class FakeProviders: @unchecked Sendable {
    let real: AgentProviderTable
    var health = AgentProviderHealth(
        installation: .ready(executable: "/usr/bin/true", version: "test"),
        authentication: .signedIn)
    var prepareLaunch: @Sendable (AgentLaunchRequest) -> Result<AgentPreparedLaunch, AgentProviderIssue> = { _ in
        .success(AgentPreparedLaunch(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            environment: [:],
            metadataAvailability: .waiting))
    }
    private(set) var launchRequests: [AgentLaunchRequest] = []
    private(set) var cleanups: [UUID] = []

    init(real: AgentProviderTable) {
        self.real = real
    }

    var table: AgentProviderTable {
        var table = real
        for provider in AgentProviderID.allCases {
            let cleanup = real[provider].cleanup
            table[provider].probe = { _ in self.health }
            table[provider].prepareLaunch = { request in
                self.launchRequests.append(request)
                return self.prepareLaunch(request)
            }
            table[provider].cleanup = { id in
                self.cleanups.append(id)
                try cleanup(id)
            }
        }
        return table
    }
}

/// Stands in for a terminal: the object a test posts its close and
/// program-status notifications with, and whose `childExited` it sends when
/// the process exits without a close, as Ghostty publishes
/// `childExitedMessage`.
@MainActor
final class FakeSurface {
    let childExited = PassthroughSubject<Void, Never>()
    /// The titles its program sets, as Ghostty publishes the surface's.
    let title = PassthroughSubject<String, Never>()
    let configuration: Ghostty.SurfaceConfiguration
    /// The launch the surface was created for.
    let generation: UUID?
    fileprivate var observers: [AnyCancellable] = []

    init(configuration: Ghostty.SurfaceConfiguration, generation: UUID?) {
        self.configuration = configuration
        self.generation = generation
    }
}

/// Presents agent terminals as `AgentDetailViewController` does, without
/// creating a terminal: a surface exists from its creation until
/// `removeSurface`, and is observed for the bridge the same way.
@MainActor
final class FakeSurfaceHost: AgentSurfaceHost {
    enum Call: Equatable {
        case show(UUID)
        case present(UUID)
        case confirmClose(UUID)
        case remove(UUID)
    }

    /// Makes `presentPreparedSurface` create nothing and return false.
    var refusesPresent = false
    /// Where the surfaces' closes and program status are reported.
    weak var bridge: AgentBridge?
    private(set) var calls: [Call] = []
    private(set) var surfaces: [UUID: FakeSurface] = [:]
    private var pendingClose: (@MainActor () -> Void)?

    func hasSurface(id: UUID) -> Bool { surfaces[id] != nil }

    func showOrSwitch(
        agent: AgentInstance,
        focusTerminal: Bool,
        select: Bool,
        createConfig: () -> Ghostty.SurfaceConfiguration?
    ) -> Bool {
        calls.append(.show(agent.id))
        return create(agent, createConfig)
    }

    func presentPreparedSurface(
        agent: AgentInstance,
        createConfig: () -> Ghostty.SurfaceConfiguration?
    ) -> Bool {
        calls.append(.present(agent.id))
        guard !refusesPresent else { return false }
        return create(agent, createConfig)
    }

    /// Records the question; `answerClose` gives the user's answer.
    func confirmClose(id: UUID, then close: @escaping @MainActor () -> Void) {
        calls.append(.confirmClose(id))
        pendingClose = close
    }

    /// Answers the open close question: Close when `confirmed`, else Cancel.
    func answerClose(confirmed: Bool) {
        let close = pendingClose
        pendingClose = nil
        if confirmed { close?() }
    }

    /// What each terminal shows, as `screen` reads it.
    var screens: [UUID: String] = [:]
    /// What was put into each terminal, in order.
    private(set) var inputs: [UUID: [AgentTerminalInput]] = [:]
    /// Called after each input, to show what the CLI does with it.
    var onInput: ((UUID, AgentTerminalInput) -> Void)?

    func screen(id: UUID) -> String? { surfaces[id] == nil ? nil : screens[id] ?? "" }

    func input(_ input: AgentTerminalInput, to id: UUID) {
        inputs[id, default: []].append(input)
        onInput?(id, input)
    }

    func removeSurface(id: UUID) {
        calls.append(.remove(id))
        surfaces.removeValue(forKey: id)?.observers.forEach { $0.cancel() }
    }

    private func create(
        _ agent: AgentInstance,
        _ createConfig: () -> Ghostty.SurfaceConfiguration?
    ) -> Bool {
        guard surfaces[agent.id] == nil, let configuration = createConfig() else { return false }
        let surface = FakeSurface(configuration: configuration, generation: agent.launchGeneration)
        if let bridge {
            surface.observers = observeAgentSurface(
                surface,
                childExited: surface.childExited,
                title: surface.title,
                agentID: agent.id,
                generation: agent.launchGeneration,
                bridge: bridge)
        }
        surfaces[agent.id] = surface
        return true
    }
}

/// `arguments` as a launch script's command line quotes them.
func shellCommand(_ arguments: [String]) -> String {
    arguments.map(AgentHookRuntime.shellQuote).joined(separator: " ")
}

/// A bridge on a temporary root with one project, wired as
/// `ClawddyController` wires it. Add agents, then `start()`; call `remove()`
/// at the end.
@MainActor
final class AgentBridgeHarness {
    static let projectName = "Project"

    let folder: URL
    let root: AgentDataRoot
    let scheduler: ManualScheduler
    let io = InlineIO()
    let notifier = RecordingNotifier()
    private(set) var host = FakeSurfaceHost()
    let diagnostics = DiagnosticsRecord()
    let providers: FakeProviders
    private(set) var config: AgentConfig
    private(set) var bridge: AgentBridge
    /// What the window shows and its one record of viewing, as
    /// `ClawddyController` keeps them.
    private(set) var workspace: AgentWorkspaceModel
    /// Whether the workspace window is key. It is visible and not
    /// minimized throughout, and its screen presents the shown agent.
    private(set) var windowIsKey = true
    private(set) var waitingCounts: [Int] = []
    private(set) var surfaceDeaths: [UUID] = []
    private(set) var presentationChanges: [UUID] = []

    /// `now` is where the harness's clock starts.
    init(now: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) throws {
        scheduler = ManualScheduler(now: now)
        workspace = AgentWorkspaceModel(defaults: nil)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-bridge-tests-\(UUID().uuidString)", isDirectory: true)
        root = AgentDataRoot(url: folder.appendingPathComponent("root", isDirectory: true))
        for name in ["bin", "home", "tmp"] {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
        providers = FakeProviders(real: AgentProviderTable(
            root: root,
            codexConfigFile: folder.appendingPathComponent("home/.codex/config.toml")))
        config = AgentConfig(root: root)
        bridge = AgentBridge(
            root: root,
            providers: providers.table,
            scheduler: scheduler,
            io: io,
            notifier: notifier,
            diagnose: diagnostics.sink)
        wire()
        try #require(config.addProject(name: Self.projectName) != nil)
    }

    /// An empty folder: no provider executable is found on this PATH.
    var binFolder: URL { folder.appendingPathComponent("bin", isDirectory: true) }

    /// Launches go through the real Claude provider, which finds a stand-in
    /// `claude` in `binFolder` that exits at once, and which names the
    /// session a new or forked launch creates. Unlike the default launch it
    /// reads the user's Claude settings, as the provider's own tests do; it
    /// writes only under the harness root.
    func useRealClaudeLaunch() throws {
        let executable = binFolder.appendingPathComponent("claude")
        try Data("#!/bin/sh\n[ \"$1\" = agents ] && echo '[]'\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let claude = ClaudeCodeProvider(root: root)
        providers.prepareLaunch = { claude.prepareLaunch($0) }
    }

    @discardableResult
    func addAgent(_ name: String, provider: AgentProviderID = .claudeCode) throws -> UUID {
        try #require(config.addAgent(
            project: Self.projectName,
            name: name,
            provider: provider)).id
    }

    /// Starts the bridge and runs the read it requests at start.
    func start() {
        bridge.start(config: config)
        scheduler.advance(by: 0)
    }

    /// Quits and relaunches: shuts the bridge down, runs `betweenRuns`, then
    /// starts a new config and bridge on the same root, with a new host that
    /// has no terminals. The callback records start empty again.
    func restart(_ betweenRuns: () throws -> Void = {}) throws {
        bridge.shutdown()
        config.waitForWrites()
        try betweenRuns()
        config = AgentConfig(root: root)
        host = FakeSurfaceHost()
        workspace = AgentWorkspaceModel(defaults: nil)
        waitingCounts = []
        surfaceDeaths = []
        presentationChanges = []
        bridge = AgentBridge(
            root: root,
            providers: providers.table,
            scheduler: scheduler,
            io: io,
            notifier: notifier,
            diagnose: diagnostics.sink)
        wire()
        start()
    }

    func remove() {
        bridge.shutdown()
        config.waitForWrites()
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Issue.record(error)
        }
    }

    /// Wires the bridge as `ClawddyController` does: every callback is set
    /// before `start`, which publishes the waiting count.
    private func wire() {
        host.bridge = bridge
        bridge.environmentPath = binFolder.path
        bridge.onWaitingCountChanged = { [weak self] in self?.waitingCounts.append($0) }
        bridge.onSurfaceDeath = { [weak self] id in
            self?.surfaceDeaths.append(id)
            self?.host.removeSurface(id: id)
        }
        bridge.onSurfacePresentationChanged = { [weak self] in self?.presentationChanges.append($0) }
        bridge.isViewed = { [weak self] id in self?.viewedAgent() == id }
        bridge.project = { [weak self] id in self?.config.project(forAgent: id) }
        bridge.onConversationTitle = { [weak self] id, title in
            guard let self else { return }
            AgentWorkspaceTransactions.adoptTitle(title, of: id, config: self.config, bridge: self.bridge)
        }
        config.onReloaded = { [weak self] in
            guard let self else { return }
            self.bridge.reconcileWithConfig(self.config)
            self.reconcileWorkspace()
        }
    }

    /// The workspace forgets what the configuration no longer has, as the
    /// controller's does.
    func reconcileWorkspace() {
        workspace.reconcile(with: config) { [bridge] id in bridge.agents[id]?.record.settledAt == nil }
    }

    /// The agent whose completions count as seen, read as the controller
    /// reads it.
    private func viewedAgent() -> UUID? {
        let presented = workspace.shownAgentID
        return workspace.viewedAgent(
            presentedAgentID: presented,
            personCanSee: true,
            windowIsVisible: true,
            windowIsKey: windowIsKey,
            windowIsMiniaturized: false)
    }

    /// Acknowledges what the user has just begun to view, as the controller
    /// does after a selection or the window becoming key.
    private func updateViewing() {
        if let id = viewedAgent() { bridge.agentViewed(id) }
    }

    // MARK: Driving

    func agent(_ id: UUID) throws -> AgentInstance {
        try #require(bridge.agents[id])
    }

    func generation(_ id: UUID) throws -> UUID {
        try #require(agent(id).launchGeneration)
    }

    func activate(_ id: UUID, host: (any AgentSurfaceHost)? = nil) throws {
        let project = try #require(config.project(forAgent: id))
        bridge.activateAgent(id: id, host: host ?? self.host, project: project)
    }

    /// The person enters the agent, as `ClawddyController` handles it: it
    /// is shown inside, and viewed once its terminal is open.
    func view(_ id: UUID) {
        guard let project = config.project(forAgent: id) else { return }
        workspace.show(.inside(id), in: project.id)
        if host.hasSurface(id: id) { workspace.setViewingShownAgent(true) }
        updateViewing()
    }

    /// The workspace window becomes key, or stops being key, as when the
    /// user switches to another app and back.
    func setWindowKey(_ key: Bool) {
        windowIsKey = key
        if key { updateViewing() }
    }

    /// Activates the agent and brings it up as its provider does: it
    /// reports `idle` in its terminal once ready, and Claude's
    /// `SessionStart` hook binds the session.
    func launch(_ id: UUID, session: String = "session-1") throws {
        try activate(id)
        if try agent(id).provider == .claudeCode {
            try osc(id, "state=idle:app=claude-code")
            try hook(id, "SessionStart", session: session)
        } else {
            try osc(id, "state=idle:app=codex")
        }
    }

    /// One event record exactly as the hook script writes it: every field a
    /// string, and "" for a field the payload did not carry.
    func record(
        _ event: String,
        generation: UUID,
        provider: AgentProviderID = .claudeCode,
        session: String = "session-1",
        turn: String = "",
        trigger: String = "",
        text: String? = nil,
        eventID: String = UUID().uuidString
    ) -> String {
        let escaped = text.map {
            $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        let texts = escaped.map { ",\"text\":\"\($0)\"" } ?? ""
        return #"{"schemaVersion":1,"eventID":"\#(eventID)","provider":"\#(provider.rawValue)","launchGeneration":"\#(generation.uuidString)","hookEventName":"\#(event)","sessionID":"\#(session)","turnID":"\#(turn)","model":"","permissionMode":"","trigger":"\#(trigger)""# + texts + "}"
    }

    /// Appends `text` to the agent's event file as it is.
    func appendRaw(_ id: UUID, _ text: String) throws {
        let url = statusFile(id, "events")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func append(_ id: UUID, _ line: String) throws {
        try appendRaw(id, line + "\n")
    }

    /// Appends one record for the agent's current launch, as its hook would,
    /// and polls.
    func hook(
        _ id: UUID,
        _ event: String,
        session: String = "session-1",
        turn: String = "",
        trigger: String = "",
        text: String? = nil,
        eventID: String = UUID().uuidString
    ) throws {
        let provider = try agent(id).provider
        let launch = try generation(id)
        try append(id, record(
            event,
            generation: launch,
            provider: provider,
            session: session,
            turn: turn,
            trigger: trigger,
            text: text,
            eventID: eventID))
        poll()
    }

    /// One OSC 7501 report, given as the body `cli-facts.md` captures
    /// (`state=done:app=claude-code:msg=<base64>`), posted by the agent's
    /// terminal as Ghostty delivers it.
    func osc(_ id: UUID, _ body: String) throws {
        let surface = try #require(host.surfaces[id])
        NotificationCenter.default.post(
            name: .ghosttyDidReceiveProgramStatus,
            object: surface,
            userInfo: [Notification.Name.ProgramStatusKey: try programStatus(body)])
    }

    /// The agent starts a turn: `working`, standing for its provider's
    /// turn-start delay.
    func startTurn(_ id: UUID) throws {
        let provider = try agent(id).provider
        try osc(id, "state=working:app=\(provider == .codex ? "codex" : "claude-code")")
        scheduler.advance(by: providers.table[provider].reports.turnStartDelay)
    }

    /// Claude starts a turn and completes it with a bare `done`.
    func completeTurn(_ id: UUID) throws {
        try startTurn(id)
        try osc(id, "state=done:app=claude-code")
    }

    // MARK: Captured timelines

    /// Zero of a captured timeline, the spawn; `spawn()` sets it to now.
    private var spawnTime: Date?

    func spawn() { spawnTime = scheduler.now }

    /// Moves the clock forward to `seconds` after the spawn, running every
    /// timer that falls due on the way.
    func at(_ seconds: TimeInterval) throws {
        let delta = try #require(spawnTime).addingTimeInterval(seconds).timeIntervalSince(scheduler.now)
        try #require(delta >= -0.000_001, "the timeline runs forward")
        scheduler.advance(by: max(delta, 0))
    }

    /// The report at `seconds` on the timeline.
    func osc(_ id: UUID, at seconds: TimeInterval, _ body: String) throws {
        try at(seconds)
        try osc(id, body)
    }

    /// The hook record that reaches the bridge at `seconds` on the timeline:
    /// its capture time plus the event file's delay.
    func hook(_ id: UUID, at seconds: TimeInterval, _ event: String, session: String = "session-1", trigger: String = "") throws {
        try at(seconds)
        try hook(id, event, session: session, trigger: trigger)
    }

    /// The provider returns with `status`: its launch script prints the exit
    /// report in the agent's terminal, as every launch script does.
    func providerExited(_ id: UUID, status: Int) throws {
        try osc(id, exitReport(status))
    }

    /// The agent's terminal closes with no process left in it, as Ghostty
    /// closes it when the launch script ends or the process dies; what the
    /// bridge does next runs at once.
    func terminalClosed(_ id: UUID) throws {
        bridge.surfaceClosed(id: id, generation: try generation(id), processAlive: false)
        scheduler.advance(by: 0)
    }

    /// The provider returns with `status` and its terminal closes, as the
    /// launch script ends.
    func providerQuit(_ id: UUID, status: Int) throws {
        try providerExited(id, status: status)
        try terminalClosed(id)
    }

    /// Reads the status folder now, as the watcher asks the journal source
    /// to after a change.
    func poll() {
        bridge.journal?.read()
    }

    /// Rewrites the project's agents in `agents.json` as an editor would, then
    /// loads the file as the config watcher does.
    func editConfigExternally(_ edit: (inout [AgentEntry]) -> Void) throws {
        var projects = config.projects
        edit(&projects[0].agents)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        config.waitForWrites()
        try encoder.encode(AgentConfigFile(projects: projects)).write(to: root.agentsFile, options: .atomic)
        config.load()
    }

    // MARK: Inspecting

    func statusFile(_ id: UUID, _ suffix: String) -> URL {
        root.statusDir.appendingPathComponent("\(id.uuidString).\(suffix)")
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func launchScripts() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.launchDir.path)
    }

    /// The one launch script there is: the current launch's, which stays
    /// until its provider is seen alive or gone.
    func launchScript() throws -> String {
        let names = try launchScripts()
        try #require(names.count == 1)
        return try String(contentsOf: root.launchDir.appendingPathComponent(names[0]), encoding: .utf8)
    }

    func size(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
    }

    /// The agents whose stored record is unread, as the files say.
    func recordedUnread() throws -> Set<UUID> {
        Set(try config.allAgentEntries.map(\.id).filter {
            try AgentRecord.load($0, from: root.statusDir)?.unread == true
        })
    }

    func binding(_ id: UUID) throws -> AgentSessionBinding {
        try JSONDecoder().decode(AgentSessionBinding.self, from: Data(contentsOf: statusFile(id, "session.json")))
    }
}

/// The report Ghostty delivers for one OSC 7501 body as `cli-facts.md`
/// captures it: `key=value` pairs joined by `:`, with `msg` and `title` in
/// base64. In the app the terminal core decodes it.
func programStatus(_ body: String) throws -> Ghostty.Action.ProgramStatus {
    var fields: [Substring: Substring] = [:]
    for pair in body.split(separator: ":") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        fields[parts[0]] = parts.count == 2 ? parts[1] : ""
    }
    func text(_ key: Substring) throws -> String? {
        guard let value = fields[key] else { return nil }
        return try #require(String(data: try #require(Data(base64Encoded: String(value))), encoding: .utf8))
    }
    let states: [Substring: Ghostty.Action.ProgramStatus.State] = [
        "idle": .idle, "working": .working, "done": .done,
        "blocked": .blocked, "error": .error, "clear": .clear,
    ]
    let kinds: [Substring: Ghostty.Action.ProgramStatus.Kind] = [
        "permission": .permission, "question": .question, "auth": .auth,
    ]
    return Ghostty.Action.ProgramStatus(
        state: try #require(fields["state"].flatMap { states[$0] }),
        kind: try fields["kind"].map { try #require(kinds[$0]) },
        progress: nil,
        id: fields["id"].map(String.init),
        app: fields["app"].map(String.init),
        title: try text("title"),
        message: try text("msg"))
}

/// The body of the report a launch script prints when its provider returns
/// with `status`: the record `clawddy` cleared, with the status in decimal,
/// base64, as its message.
func exitReport(_ status: Int) -> String {
    "state=clear:id=clawddy:msg=\(Data(String(status).utf8).base64EncodedString())"
}

/// Yields to the main actor until `condition` holds, at most `limit` times.
@MainActor
func yieldToMainActor(until condition: () -> Bool, limit: Int = 100) async {
    for _ in 0..<limit where !condition() {
        await Task.yield()
    }
}

extension AgentInstance {
    /// What runs under an agent, as the engine's tests check it: its
    /// terminal, its CLI and what the CLI reports doing. The window shows
    /// none of this but the screen's quiet line; its states are the record's.
    enum Terminal: Equatable {
        case notRunning, starting, failed, noStatus, idle, busy, compacting
    }

    var terminal: Terminal {
        switch surfaceState {
        case .inactive, .closed: return .notRunning
        case .opening: return .starting
        case .failed: return .failed
        case .open: break
        }
        if processState == .exited { return .notRunning }
        switch activityState {
        case .unknown:
            if case .unavailable = telemetryHealth { return .noStatus }
            return .starting
        case .idle: return .idle
        case .reasoning, .executing: return .busy
        case .compacting: return .compacting
        }
    }
}
