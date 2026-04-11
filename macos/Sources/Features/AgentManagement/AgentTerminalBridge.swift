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

final class AgentInstance: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var sessionId: String?
    @Published var processState: ProcessState = .inactive
    @Published var claudeState: ClaudeState = .unknown
    @Published var isUnread: Bool = false
    @Published var lastHookTime: Date?
    var launchTime: Date?

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

final class AgentBridge: ObservableObject {
    @Published private(set) var agents: [UUID: AgentInstance] = [:]

    var onAggregateStateChanged: ((AggregateState) -> Void)?
    var onSendText: ((UUID, String) -> Void)?

    private var pendingRenames: [UUID: String] = [:]
    private var lastAggregateState: AggregateState?
    private var isTerminating = false

    private var timer: Timer?
    private var statusDirWatcher: DispatchSourceFileSystemObject?
    private var pollScheduled = false
    private let ioQueue = DispatchQueue(label: "clawddy.io", qos: .utility)

    private var surfaceViews: [UUID: Ghostty.SurfaceView] = [:]
    private var surfaceWrappers: [UUID: SurfaceScrollView] = [:]

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

        // Start watchers
        startStatusDirWatcher()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.schedulePoll()
        }

        logger.info("started — \(self.agents.count) agents")
    }

    func shutdown() {
        isTerminating = true
        timer?.invalidate()
        timer = nil
        statusDirWatcher?.cancel()
        statusDirWatcher = nil
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
        }

        // Remove instances for deleted entries
        for id in agents.keys where !configIds.contains(id) {
            destroySurface(id: id)
            agents.removeValue(forKey: id)
            pendingRenames.removeValue(forKey: id)
        }

        // Sync display names
        for entry in allEntries {
            agents[entry.id]?.name = entry.name
        }
    }

    // MARK: - Agent Creation (sync with config)

    func createAgent(name: String, config: AgentConfig, project: String, task: String) -> AgentEntry? {
        guard let entry = config.addAgent(project: project, task: task, name: name) else { return nil }
        let instance = AgentInstance(id: entry.id, name: entry.name)
        instance.processState = .inactive
        agents[entry.id] = instance
        return entry
    }

    // MARK: - Activation

    func activateAgent(id: UUID, app: ghostty_app_t, detailVC: AgentDetailViewController,
                       project: AgentProject) {
        guard let agent = agents[id] else { return }

        // Reset state for fresh launch
        agent.processState = .launching
        agent.claudeState = .unknown
        agent.launchTime = Date()
        agent.lastHookTime = nil

        // Build command in Swift — script is a dumb launcher
        let command = buildCommand(agent: agent)
        let name = agent.name.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
            #!/bin/zsh -l
            export GHOSTTY_AGENT_NAME='\(id.uuidString)'
            printf '\\033]2;%s\\007' '\(name)'
            clear
            \(command)
            exec zsh -l
            """

        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-\(id.uuidString).sh").path
        FileManager.default.createFile(atPath: scriptPath, contents: script.data(using: .utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        var surfaceConfig = Ghostty.SurfaceConfiguration()
        surfaceConfig.command = scriptPath
        surfaceConfig.workingDirectory = project.workingDirectory
        surfaceConfig.environmentVariables = ["GHOSTTY_AGENT_NAME": id.uuidString]

        let isNew = detailVC.showOrSwitch(id: id, displayName: agent.name, projectName: project.name) {
            return (app, surfaceConfig)
        }

        if isNew, let surface = detailVC.surfaceView(for: id) {
            surfaceViews[id] = surface
            if let wrapper = detailVC.surfaceWrapper(for: id) {
                surfaceWrappers[id] = wrapper
            }
        }

        // Clear unread when viewing
        markRead(id: id)
    }

    // MARK: - Command Building

    private func buildCommand(agent: AgentInstance) -> String {
        let name = agent.name.replacingOccurrences(of: "'", with: "'\\''")

        // Priority 1: resume existing session
        if let sessionId = readSessionFile(agent.id) {
            return "claude --resume '\(sessionId)' --permission-mode auto"
        }
        // Priority 2: fork from source
        if let sourceId = readForkSource(agent.id) {
            return "claude --resume '\(sourceId)' --fork-session --name '\(name)' --permission-mode auto"
        }
        // Priority 3: fresh start
        return "claude --name '\(name)' --permission-mode auto"
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
        guard let agent = agents[id] else { return }
        agent.name = newName

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
        updateAggregate()
        persistState()
    }

    // MARK: - Deletion

    func deleteAgent(id: UUID, config: AgentConfig, detailVC: AgentDetailViewController) {
        destroySurface(id: id)
        detailVC.removeSurface(id: id)
        agents.removeValue(forKey: id)
        pendingRenames.removeValue(forKey: id)
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

    // MARK: - Polling

    func schedulePoll() {
        guard !isTerminating else { return }

        // Main thread: check process exits
        for (id, surface) in surfaceViews {
            if surface.processExited {
                handleSurfaceDeath(id: id)
            }
        }

        // Launch timeout: 10s with no hook
        for (_, agent) in agents {
            if agent.processState == .launching,
               agent.lastHookTime == nil,
               let t = agent.launchTime,
               Date().timeIntervalSince(t) > 10 {
                agent.processState = .alive
                agent.claudeState = .idle
            }
        }

        // Ensure status dir exists
        try? FileManager.default.createDirectory(at: statusDir, withIntermediateDirectories: true)

        // Background: read event files
        let ids = Array(agents.keys)
        ioQueue.async { [self] in
            var events: [UUID: [String: Any]] = [:]
            for id in ids {
                events[id] = readLastEvent(for: id)
            }
            DispatchQueue.main.async { [weak self] in
                self?.applyEvents(events)
            }
        }
    }

    private func applyEvents(_ events: [UUID: [String: Any]]) {
        for (id, json) in events {
            guard let agent = agents[id] else { continue }
            let newClaude = parseClaudeState(from: json)
            if newClaude == .unknown { continue }  // no valid event, skip

            let oldDisplay = agent.displayState
            let oldClaude = agent.claudeState

            // Update session ID from every event (they all carry it)
            if let sid = json["session_id"] as? String, !sid.isEmpty {
                agent.sessionId = sid
            }

            // Process state transition: launching → alive on first valid hook
            if agent.processState == .launching {
                agent.processState = .alive
                // Delete .forkFrom on first hook (fork confirmed)
                let forkUrl = statusDir.appendingPathComponent("\(id.uuidString).forkFrom")
                if FileManager.default.fileExists(atPath: forkUrl.path) {
                    ioQueue.async { try? FileManager.default.removeItem(at: forkUrl) }
                }
            }

            // Claude state update
            agent.claudeState = newClaude
            agent.lastHookTime = Date()

            let newDisplay = agent.displayState

            // Unread tracking
            if oldClaude.isActiveState && newClaude == .idle {
                // Agent just finished work
                let isCurrentlyViewed = false  // TODO: check if this is the active surface
                if !isCurrentlyViewed {
                    agent.isUnread = true
                }
            }
            if newClaude.isActiveState {
                agent.isUnread = false
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

        updateAggregate()
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
            onAggregateStateChanged?(current)
        }
    }

    // MARK: - Surface Management

    func surfaceView(for id: UUID) -> Ghostty.SurfaceView? { surfaceViews[id] }

    private func destroySurface(id: UUID) {
        surfaceViews.removeValue(forKey: id)
        surfaceWrappers.removeValue(forKey: id)
        if let agent = agents[id] {
            agent.processState = .dead
            agent.claudeState = .unknown
        }
    }

    private func handleSurfaceDeath(id: UUID) {
        logger.info("surface death: \(id)")
        destroySurface(id: id)
    }

    // MARK: - File I/O (called from ioQueue)

    private func readLastEvent(for id: UUID) -> [String: Any]? {
        let url = statusDir.appendingPathComponent("\(id.uuidString).lastEvent")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private func readSessionFile(_ id: UUID) -> String? {
        let url = statusDir.appendingPathComponent("\(id.uuidString).session")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readForkSource(_ id: UUID) -> String? {
        let url = statusDir.appendingPathComponent("\(id.uuidString).forkFrom")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        let data = try! JSONEncoder().encode(state)
        ioQueue.async { atomicWrite(data, to: AgentConfig.stateURL) }
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
            guard let self, !self.pollScheduled else { return }
            self.pollScheduled = true
            DispatchQueue.main.async {
                self.pollScheduled = false
                self.schedulePoll()
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
