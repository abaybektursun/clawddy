import AppKit
import SwiftUI
import GhosttyKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentBridge")

// MARK: - Process State (app-controlled)

enum ProcessState: Codable, Equatable {
    case inactive       // no terminal surface
    case launching      // surface created, waiting for first hook
    case alive          // claude confirmed running (hook received)
    case dead           // surface destroyed or process exited
}

// MARK: - Claude State (hook-controlled)

enum ClaudeState: Codable, Equatable {
    case unknown
    case idle           // Stop / SessionStart / PostCompact / SessionEnd
    case thinking       // UserPromptSubmit
    case working        // PreToolUse / PostToolUse
    case permission     // PermissionRequest
    case error          // StopFailure / PostToolUseFailure
    case compacting     // PreCompact
}

// MARK: - Display State (derived, never stored)

enum DisplayState: Equatable {
    case inactive
    case launching
    case idle
    case finished       // alive + idle + unread
    case thinking
    case working
    case permission
    case error
    case compacting
    case dead

    var color: Color {
        switch self {
        case .inactive:     return .secondary.opacity(0.3)
        case .launching:    return .secondary
        case .idle:         return .secondary
        case .finished:     return .yellow
        case .thinking:     return .blue
        case .working:      return .green
        case .permission:   return .orange
        case .error:        return .red
        case .compacting:   return .purple
        case .dead:         return .secondary.opacity(0.3)
        }
    }

    var selectionTint: Color {
        switch self {
        case .finished:     return .yellow
        case .thinking:     return .blue
        case .working:      return .green
        case .permission:   return .orange
        case .error:        return .red
        case .compacting:   return .purple
        default:            return .accentColor
        }
    }

    var label: String {
        switch self {
        case .inactive:     return ""
        case .launching:    return "launching"
        case .idle:         return "idle"
        case .finished:     return "finished"
        case .thinking:     return "thinking"
        case .working:      return "working"
        case .permission:   return "permission"
        case .error:        return "error"
        case .compacting:   return "compacting"
        case .dead:         return "exited"
        }
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
        case .error:        return "xmark.circle.fill"
        case .compacting:   return "arrow.triangle.2.circlepath"
        case .dead:         return "xmark"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .finished, .permission, .error: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .thinking, .working: return true
        default: return false
        }
    }
}

// MARK: - Agent Instance (per-agent observable)

@Observable
final class AgentInstance: Identifiable {
    let id: UUID
    var name: String
    var processState: ProcessState = .inactive
    var claudeState: ClaudeState = .unknown
    var isUnread: Bool = false
    @ObservationIgnored var lastHookTime: Date?
    @ObservationIgnored var launchTime: Date?

    var displayState: DisplayState {
        switch processState {
        case .inactive:  return .inactive
        case .dead:      return .dead
        case .launching: return .launching
        case .alive:
            if isUnread && claudeState == .idle { return .finished }
            switch claudeState {
            case .unknown:    return .launching
            case .idle:       return .idle
            case .thinking:   return .thinking
            case .working:    return .working
            case .permission: return .permission
            case .error:      return .error
            case .compacting: return .compacting
            }
        }
    }

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
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
    var unreadAgents: Set<UUID> = []
    var pendingRenames: [UUID: String] = [:]
}

// MARK: - Agent Bridge

@Observable
final class AgentBridge {
    private(set) var agents: [UUID: AgentInstance] = [:]

    var onAggregateStateChanged: ((AggregateState) -> Void)?
    var onSendText: ((UUID, String) -> Void)?
    var onSurfaceDeath: ((UUID) -> Void)?
    var currentlyViewedAgentId: UUID?

    private var pendingRenames: [UUID: String] = [:]
    private var lastAggregateState: AggregateState?
    private var isTerminating = false

    private var heartbeatTimer: Timer?
    private var statusDirWatcher: DispatchSourceFileSystemObject?
    private let ioQueue = DispatchQueue(label: "clawddy.io", qos: .utility)
    private var lastEventContent: [UUID: Data] = [:]

    /// Throttle file watcher: hooks fire bursts (4 fs events per claude event,
    /// ×N agents = 100+/sec). Coalesce into one poll per window.
    private static let pollThrottle: TimeInterval = 0.2
    private var pollPending = false

    /// Compacting is provably bounded (~5-15s). If no PostCompact arrives
    /// within this window, the state is stale (e.g., user cancelled).
    private static let compactingTimeout: TimeInterval = 30

    private var surfaceViews: [UUID: Ghostty.SurfaceView] = [:]
    private var surfaceWrappers: [UUID: SurfaceScrollView] = [:]
    private var surfaceObservers: [UUID: NSObjectProtocol] = [:]
    private var launchTimers: [UUID: Timer] = [:]

    private var statusDir: URL { AgentConfig.statusDir }

    // MARK: - Lifecycle

    func start(config: AgentConfig) {
        cleanStaleScripts()
        let persisted = loadPersistedState()
        pendingRenames = persisted.pendingRenames

        // Reconstruct agents from config
        for entry in config.allAgentEntries {
            let agent = AgentInstance(id: entry.id, name: entry.name)
            agent.processState = .inactive
            agent.claudeState = .unknown
            agent.isUnread = persisted.unreadAgents.contains(entry.id)
            agents[entry.id] = agent
        }

        // File watcher for real-time state updates
        startStatusDirWatcher()

        // Heartbeat timer: infrequent fallback for edge cases (crashes without notification)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.heartbeat()
        }

        // Surgical metrics for diagnosing freezes
        BridgeMetrics.shared.start(
            agentCount: { [weak self] in self?.agents.count ?? 0 },
            surfaceCount: { [weak self] in self?.surfaceViews.count ?? 0 }
        )

        logger.info("started — \(self.agents.count) agents")
    }

    func shutdown() {
        isTerminating = true
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        statusDirWatcher?.cancel()
        statusDirWatcher = nil
        for timer in launchTimers.values { timer.invalidate() }
        launchTimers.removeAll()
        for observer in surfaceObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
        surfaceObservers.removeAll()
        persistState()
    }

    // MARK: - Reconciliation (call after config.load())

    func reconcileWithConfig(_ config: AgentConfig) {
        let allEntries = config.allAgentEntries
        let configIds = Set(allEntries.map(\.id))

        // Add instances for new entries
        for entry in allEntries where agents[entry.id] == nil {
            let agent = AgentInstance(id: entry.id, name: entry.name)
            agent.processState = .inactive
            agents[entry.id] = agent
            BridgeMetrics.shared.recordMutAgentsDict()
        }

        // Remove instances for deleted entries
        for id in agents.keys where !configIds.contains(id) {
            destroySurface(id: id)
            agents.removeValue(forKey: id)
            BridgeMetrics.shared.recordMutAgentsDict()
            pendingRenames.removeValue(forKey: id)
            lastEventContent.removeValue(forKey: id)
        }

        // Sync display names — only mutate if actually different
        for entry in allEntries {
            if let agent = agents[entry.id], agent.name != entry.name {
                agent.name = entry.name
                BridgeMetrics.shared.recordMutAgentName()
            }
        }
    }

    // MARK: - Agent Creation (sync with config)

    func createAgent(name: String, config: AgentConfig, project: String, task: String) -> AgentEntry? {
        guard let entry = config.addAgent(project: project, task: task, name: name) else { return nil }
        let instance = AgentInstance(id: entry.id, name: entry.name)
        instance.processState = .inactive
        agents[entry.id] = instance
        BridgeMetrics.shared.recordMutAgentsDict()
        return entry
    }

    // MARK: - Activation

    func activateAgent(id: UUID, app: ghostty_app_t, detailVC: AgentDetailViewController,
                       project: AgentProject) {
        guard let agent = agents[id] else { return }

        let needsNewSurface = !detailVC.hasSurface(id: id)

        if needsNewSurface {
            agent.processState = .launching
            agent.claudeState = .unknown
            BridgeMetrics.shared.recordMutProcessState()
            BridgeMetrics.shared.recordMutClaudeState()
            agent.launchTime = Date()
            agent.lastHookTime = nil

            // One-shot launch timeout instead of polling
            launchTimers[id]?.invalidate()
            launchTimers[id] = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) {
                [weak self] _ in
                guard let self, let agent = self.agents[id],
                      agent.processState == .launching, agent.lastHookTime == nil
                else { return }
                agent.processState = .alive
                agent.claudeState = .idle
                BridgeMetrics.shared.recordMutProcessState()
                BridgeMetrics.shared.recordMutClaudeState()
                self.launchTimers.removeValue(forKey: id)
            }
        }

        let isNew = detailVC.showOrSwitch(id: id, displayName: agent.name, projectName: project.name) {
            let command = self.buildCommand(agent: agent)
            let name = agent.name.replacingOccurrences(of: "'", with: "'\\''")
            let script = """
                #!/bin/zsh -l
                export GHOSTTY_AGENT_NAME='\(id.uuidString)'
                printf '\\033]2;%s\\007' '\(name)'
                clear
                \(command)
                """

            let scriptPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("clawddy-\(id.uuidString).sh").path
            FileManager.default.createFile(atPath: scriptPath, contents: script.data(using: .utf8))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

            var surfaceConfig = Ghostty.SurfaceConfiguration()
            surfaceConfig.command = scriptPath
            surfaceConfig.workingDirectory = project.workingDirectory
            surfaceConfig.environmentVariables = ["GHOSTTY_AGENT_NAME": id.uuidString]
            return (app, surfaceConfig)
        }

        if isNew, let surface = detailVC.surfaceView(for: id) {
            surfaceViews[id] = surface
            if let wrapper = detailVC.surfaceWrapper(for: id) {
                surfaceWrappers[id] = wrapper
            }
            BridgeMetrics.shared.recordSurfaceCreated()

            // Observe process exit notification from Zig backend — immediate detection
            let observer = NotificationCenter.default.addObserver(
                forName: Ghostty.Notification.ghosttyCloseSurface, object: surface,
                queue: .main
            ) { [weak self] _ in
                BridgeMetrics.shared.recordProcessExitNotif()
                self?.handleSurfaceDeath(id: id)
            }
            surfaceObservers[id] = observer
        }

        // Track which agent is being viewed + clear unread
        currentlyViewedAgentId = id
        markRead(id: id)
    }

    // MARK: - Command Building

    private func buildCommand(agent: AgentInstance) -> String {
        let name = agent.name.replacingOccurrences(of: "'", with: "'\\''")

        // Priority 1: resume existing session
        if let sessionId = readSessionFile(agent.id) {
            return "claude --resume '\(sessionId)' --dangerously-skip-permissions"
        }
        // Priority 2: fork from source
        if let sourceId = readForkSource(agent.id) {
            return "claude --resume '\(sourceId)' --fork-session --name '\(name)' --dangerously-skip-permissions"
        }
        // Priority 3: fresh start
        return "claude --name '\(name)' --dangerously-skip-permissions"
    }

    // MARK: - Fork

    func forkAgent(sourceId: UUID, config: AgentConfig, project: String, task: String) -> AgentEntry? {
        guard let source = agents[sourceId] else { return nil }

        // Read source session — abort if none
        guard let sourceSessionId = readSessionFile(sourceId) else {
            logger.warning("fork: no session for source \(sourceId)")
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
        guard let entry = createAgent(name: forkName, config: config, project: project, task: task) else {
            return nil
        }

        // Write .forkFrom marker
        let forkUrl = statusDir.appendingPathComponent("\(entry.id.uuidString).forkFrom")
        atomicWrite(sourceSessionId.data(using: .utf8)!, to: forkUrl)

        return entry
    }

    // MARK: - Rename

    func requestRename(id: UUID, newName: String) {
        guard let agent = agents[id], agent.name != newName else { return }
        agent.name = newName
        BridgeMetrics.shared.recordMutAgentName()

        if isSafeForInput(agent.displayState) {
            logger.info("rename: sending /rename for \(id) immediately")
            onSendText?(id, "/rename \(newName)\n")
        } else {
            logger.info("rename: deferring /rename for \(id)")
            pendingRenames[id] = newName
            persistState()
        }
    }

    func markRead(id: UUID) {
        guard let agent = agents[id], agent.isUnread else { return }
        agent.isUnread = false
        BridgeMetrics.shared.recordMutIsUnread()
        updateAggregate()
        persistState()
    }

    // MARK: - Deletion

    func deleteAgent(id: UUID, config: AgentConfig) {
        BridgeMetrics.shared.recordSurfaceDestroyedDelete()
        destroySurface(id: id)
        agents.removeValue(forKey: id)
        BridgeMetrics.shared.recordMutAgentsDict()
        pendingRenames.removeValue(forKey: id)
        lastEventContent.removeValue(forKey: id)
        config.removeAgent(id: id)

        // Clean status files
        ioQueue.async {
            let dir = AgentConfig.statusDir
            for ext in ["session", "forkFrom", "lastEvent"] {
                try? FileManager.default.removeItem(
                    at: dir.appendingPathComponent("\(id.uuidString).\(ext)"))
            }
        }

        updateAggregate()
        persistState()
    }

    // MARK: - Heartbeat (infrequent fallback)

    private func heartbeat() {
        guard !isTerminating else { return }
        BridgeMetrics.shared.recordHeartbeat()

        // Check for process exits that the notification might have missed (e.g., crashes)
        for (id, surface) in surfaceViews {
            if surface.processExited {
                handleSurfaceDeath(id: id)
            }
        }
    }

    // MARK: - Event-Driven Polling (triggered by file watcher only)

    private func pollStatusFiles() {
        guard !isTerminating else { return }

        // Background: read raw event file data
        let ids = Array(agents.keys)
        ioQueue.async { [weak self] in
            guard let self else { return }
            var rawEvents: [UUID: Data] = [:]
            for id in ids {
                let url = self.statusDir.appendingPathComponent("\(id.uuidString).lastEvent")
                if let data = try? Data(contentsOf: url) {
                    rawEvents[id] = data
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.applyRawEvents(rawEvents)
            }
        }
    }

    private func applyRawEvents(_ rawEvents: [UUID: Data]) {
        let startTime = CFAbsoluteTimeGetCurrent()
        var anyChanged = false

        for (id, data) in rawEvents {
            guard let agent = agents[id] else { continue }

            // Dedup: skip if file content hasn't changed since last read
            if data == lastEventContent[id] { continue }
            lastEventContent[id] = data
            BridgeMetrics.shared.recordMutLastEventContent()

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let newClaude = parseClaudeState(from: json)
            if newClaude == .unknown { continue }

            let oldDisplay = agent.displayState
            let oldClaude = agent.claudeState

            // Process state transition: launching → alive on first valid hook
            if agent.processState == .launching {
                agent.processState = .alive
                BridgeMetrics.shared.recordMutProcessState()
                launchTimers[id]?.invalidate()
                launchTimers.removeValue(forKey: id)
                let forkUrl = statusDir.appendingPathComponent("\(id.uuidString).forkFrom")
                if FileManager.default.fileExists(atPath: forkUrl.path) {
                    ioQueue.async { try? FileManager.default.removeItem(at: forkUrl) }
                }
            }

            // Only mutate if actually different
            if agent.claudeState != newClaude {
                agent.claudeState = newClaude
                BridgeMetrics.shared.recordMutClaudeState()
                anyChanged = true
            }
            agent.lastHookTime = Date()

            let newDisplay = agent.displayState

            // Unread tracking
            if oldClaude.isActiveState && newClaude == .idle {
                if currentlyViewedAgentId != id && !agent.isUnread {
                    agent.isUnread = true
                    BridgeMetrics.shared.recordMutIsUnread()
                }
            }
            if newClaude.isActiveState && agent.isUnread {
                agent.isUnread = false
                BridgeMetrics.shared.recordMutIsUnread()
            }

            // Notifications
            if oldDisplay.isActive && (newDisplay == .idle || newDisplay == .finished) {
                postNotification(agentId: id, kind: .finished,
                    title: "Agent finished", body: "\(agent.name) is ready")
            }
            if newDisplay == .permission && oldDisplay != .permission {
                postNotification(agentId: id, kind: .permission,
                    title: "Permission needed", body: "\(agent.name) is waiting for approval")
            }
            if newDisplay == .error && oldDisplay != .error {
                postNotification(agentId: id, kind: .error,
                    title: "Agent error", body: "\(agent.name) encountered an error")
            }

            // Flush pending rename if safe
            if isSafeForInput(newDisplay),
               let pendingName = pendingRenames.removeValue(forKey: id) {
                onSendText?(id, "/rename \(pendingName)\n")
            }
        }

        // Staleness: expire compacting state when no new event arrives within bound
        for (_, agent) in agents {
            guard agent.claudeState == .compacting,
                  let hookTime = agent.lastHookTime,
                  Date().timeIntervalSince(hookTime) > Self.compactingTimeout
            else { continue }
            agent.claudeState = .idle
            BridgeMetrics.shared.recordMutClaudeState()
            anyChanged = true
        }

        if anyChanged {
            updateAggregate()
        }

        let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        BridgeMetrics.shared.recordApplyRawEvents(durationMs: durationMs)
    }

    // MARK: - State Parsing

    private func parseClaudeState(from json: [String: Any]) -> ClaudeState {
        guard let event = json["hook_event_name"] as? String, !event.isEmpty else { return .unknown }
        switch event {
        case "SessionStart":       return .idle
        case "UserPromptSubmit":   return .thinking
        case "PreToolUse":         return .working
        case "PostToolUse":        return .working
        case "PostToolUseFailure": return .error
        case "PermissionRequest":  return .permission
        case "Stop":               return .idle
        case "StopFailure":        return .error
        case "PreCompact":         return .compacting
        case "PostCompact":        return .idle
        case "SessionEnd":         return .idle
        default:                   return .unknown
        }
    }

    private func isSafeForInput(_ state: DisplayState) -> Bool {
        switch state {
        case .idle, .finished, .thinking, .working: return true
        default: return false
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

    // MARK: - Surface Management

    func surfaceView(for id: UUID) -> Ghostty.SurfaceView? { surfaceViews[id] }

    private func destroySurface(id: UUID) {
        surfaceViews.removeValue(forKey: id)
        surfaceWrappers.removeValue(forKey: id)
        launchTimers[id]?.invalidate()
        launchTimers.removeValue(forKey: id)

        // Remove process exit observer
        if let observer = surfaceObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }

        if let agent = agents[id] {
            if agent.processState != .dead {
                agent.processState = .dead
                BridgeMetrics.shared.recordMutProcessState()
            }
            if agent.claudeState != .unknown {
                agent.claudeState = .unknown
                BridgeMetrics.shared.recordMutClaudeState()
            }
        }
        onSurfaceDeath?(id)
    }

    private func handleSurfaceDeath(id: UUID) {
        logger.info("surface death: \(id)")
        BridgeMetrics.shared.recordSurfaceDestroyedExit()
        destroySurface(id: id)
    }

    // MARK: - File I/O (called from ioQueue)

    /// Characters allowed in session IDs: alphanumeric, hyphen, underscore.
    /// Rejects anything that could be a shell metacharacter.
    private static let safeIdCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    private func readSessionFile(_ id: UUID) -> String? {
        let url = statusDir.appendingPathComponent("\(id.uuidString).session")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy(Self.safeIdCharacters.contains)
        else { return nil }
        return trimmed
    }

    private func readForkSource(_ id: UUID) -> String? {
        let url = statusDir.appendingPathComponent("\(id.uuidString).forkFrom")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy(Self.safeIdCharacters.contains)
        else { return nil }
        return trimmed
    }

    // MARK: - Notifications

    private enum NotificationKind {
        case finished, permission, error
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
            content.sound = .defaultCritical
            content.interruptionLevel = .timeSensitive
        case .error:
            content.sound = .default
            content.interruptionLevel = .active
        }

        let request = UNNotificationRequest(
            identifier: "clawddy.\(agentId.uuidString).\(UUID().uuidString)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    private func loadPersistedState() -> PersistedState {
        guard let data = try? Data(contentsOf: AgentConfig.stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    func persistState() {
        var state = PersistedState()
        state.unreadAgents = Set(agents.values.filter(\.isUnread).map(\.id))
        state.pendingRenames = pendingRenames
        guard let data = try? JSONEncoder().encode(state) else { return }
        ioQueue.async { AgentConfig.atomicWrite(data, to: AgentConfig.stateURL) }
    }

    // MARK: - File Watcher

    private func startStatusDirWatcher() {
        let fd = open(statusDir.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.error("failed to open status dir for watching")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            BridgeMetrics.shared.recordWatcherFire()
            guard let self, !self.pollPending else {
                BridgeMetrics.shared.recordPollThrottled()
                return
            }
            self.pollPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollThrottle) { [weak self] in
                guard let self else { return }
                self.pollPending = false
                BridgeMetrics.shared.recordPollFired()
                self.pollStatusFiles()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        statusDirWatcher = source
    }

    // MARK: - Cleanup

    private func cleanStaleScripts() {
        let tmp = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
        for file in files where file.hasPrefix("clawddy-") && file.hasSuffix(".sh") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(file))
        }
    }
}

// MARK: - ClaudeState helpers

extension ClaudeState {
    var isActiveState: Bool {
        switch self {
        case .thinking, .working: return true
        default: return false
        }
    }
}
