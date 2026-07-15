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
    case unconfirmed    // surface exists, but lifecycle status is unavailable
    case failed         // the surface or launch script could not be created
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
        case .permission, .statusUnavailable: return .orange
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
        case .permission:   return .orange
        case .statusUnavailable: return .orange
        case .error, .failed: return .red
        case .compacting:   return .purple
        default:            return .accentColor
        }
    }

    var label: String {
        switch self {
        case .inactive:     return "Ready"
        case .launching:    return "Starting"
        case .idle:         return "Ready"
        case .finished:     return "Completed"
        case .thinking:     return "Thinking"
        case .working:      return "Working"
        case .permission:   return "Waiting for You"
        case .error:        return "Needs Attention"
        case .compacting:   return "Optimizing Context"
        case .statusUnavailable: return "Status Unavailable"
        case .failed:       return "Couldn't Start"
        case .dead:         return "Exited"
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
        case .statusUnavailable: return "exclamationmark.circle"
        case .failed:       return "exclamationmark.triangle.fill"
        case .dead:         return "xmark"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .finished, .permission, .error, .failed: return true
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
    var failureMessage: String?
    var metadata: AgentSessionMetadata?
    var metadataAvailability: AgentMetadataAvailability = .notStarted
    @ObservationIgnored var lastHookTime: Date?
    @ObservationIgnored var launchTime: Date?

    var displayState: DisplayState {
        switch processState {
        case .inactive:  return .inactive
        case .dead:      return .dead
        case .launching: return .launching
        case .unconfirmed: return .statusUnavailable
        case .failed:    return .failed
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

    var runtimeSnapshot: AgentRuntimeSnapshot {
        get {
            AgentRuntimeSnapshot(
                processState: processState,
                claudeState: claudeState,
                isUnread: isUnread,
                failureMessage: failureMessage)
        }
        set {
            processState = newValue.processState
            claudeState = newValue.claudeState
            isUnread = newValue.isUnread
            failureMessage = newValue.failureMessage
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
    var unreadAgents: Set<UUID> = []
    var pendingRenames: [UUID: String] = [:]
    var eventOffsets: [UUID: Int] = [:]
}

private struct AgentMetadataFileUpdate: @unchecked Sendable {
    let data: Data
    let snapshot: AgentSessionMetadata?
}

// MARK: - Agent Bridge

@Observable
final class AgentBridge {
    private(set) var agents: [UUID: AgentInstance] = [:]

    var onAggregateStateChanged: ((AggregateState) -> Void)?
    var onSendText: ((UUID, String) -> Void)?
    var onSurfaceDeath: ((UUID) -> Void)?
    private(set) var currentlyViewedAgentId: UUID?

    private var pendingRenames: [UUID: String] = [:]
    private var eventOffsets: [UUID: Int] = [:]
    private var metadataFileData: [UUID: Data] = [:]
    private var lastAggregateState: AggregateState?
    private var isTerminating = false

    private var heartbeatTimer: Timer?
    private var statusDirWatcher: DispatchSourceFileSystemObject?
    private let ioQueue = DispatchQueue(label: "clawddy.io", qos: .utility)
    private var compactingTimers: [UUID: Timer] = [:]
    private var launchScripts: [UUID: URL] = [:]
    var environmentPath: String?

    /// Throttle file watcher: hooks fire bursts (4 fs events per claude event,
    /// ×N agents = 100+/sec). Coalesce into one poll per window.
    private static let pollThrottle: TimeInterval = 0.2
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
    private var launchTimers: [UUID: Timer] = [:]

    private var statusDir: URL { AgentConfig.statusDir }

    // MARK: - Lifecycle

    func start(config: AgentConfig) {
        cleanStaleScripts()
        let persisted = loadPersistedState()
        pendingRenames = persisted.pendingRenames
        eventOffsets = persisted.eventOffsets

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
        #if DEBUG
        BridgeMetrics.shared.start()
        updateMetricsSnapshot()
        #endif

        // Consume any events that landed after the last persisted offset.
        requestStatusPoll(after: 0)

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
        for timer in compactingTimers.values { timer.invalidate() }
        compactingTimers.removeAll()
        for observer in surfaceObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
        surfaceObservers.removeAll()
        removeAllLaunchScripts()
        persistState(synchronously: true)
        BridgeMetrics.shared.stop()
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
            eventOffsets.removeValue(forKey: id)
            metadataFileData.removeValue(forKey: id)
        }

        // Sync display names — only mutate if actually different
        for entry in allEntries {
            if let agent = agents[entry.id], agent.name != entry.name {
                agent.name = entry.name
                BridgeMetrics.shared.recordMutAgentName()
            }
        }
        updateAggregate()
        updateMetricsSnapshot()
        persistState()
    }

    // MARK: - Agent Creation (sync with config)

    func createAgent(name: String, config: AgentConfig, project: String, task: String) -> AgentEntry? {
        guard let entry = config.addAgent(project: project, task: task, name: name) else { return nil }
        let instance = AgentInstance(id: entry.id, name: entry.name)
        instance.processState = .inactive
        agents[entry.id] = instance
        BridgeMetrics.shared.recordMutAgentsDict()
        updateMetricsSnapshot()
        return entry
    }

    // MARK: - Activation

    func activateAgent(id: UUID, app: ghostty_app_t, detailVC: AgentDetailViewController,
                       project: AgentProject) {
        guard let agent = agents[id] else { return }

        let needsNewSurface = !detailVC.hasSurface(id: id)

        if needsNewSurface {
            apply(.launchRequested, to: agent)
            agent.launchTime = Date()
            agent.lastHookTime = nil

            // One-shot launch timeout instead of polling
            launchTimers[id]?.invalidate()
            launchTimers[id] = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) {
                [weak self] _ in
                guard let self, let agent = self.agents[id],
                      agent.processState == .launching, agent.lastHookTime == nil
                else { return }
                self.apply(.launchTimedOut, to: agent)
                self.launchTimers.removeValue(forKey: id)
                self.updateAggregate()
            }
        }

        let isNew = detailVC.showOrSwitch(
            id: id,
            displayName: agent.name,
            projectName: project.name,
            agent: agent
        ) {
            let command = self.buildCommand(
                agent: agent,
                workingDirectory: project.workingDirectory)
            let name = agent.name.replacingOccurrences(of: "'", with: "'\\''")
            // Claude needs the macOS account home to resolve the user's login
            // Keychain. Its supported config root and Clawddy's telemetry root
            // remain explicit so alternate-home installations stay isolated.
            let home = AgentConfig.accountHomeDirectory.path
                .replacingOccurrences(of: "'", with: "'\\''")
            let claudeConfigExport: String
            if let url = AgentConfig.claudeConfigEnvironmentOverride {
                let path = url.path.replacingOccurrences(of: "'", with: "'\\''")
                claudeConfigExport = "export CLAUDE_CONFIG_DIR='\(path)'"
            } else {
                claudeConfigExport = ""
            }
            let statusDir = AgentConfig.statusDir.path
                .replacingOccurrences(of: "'", with: "'\\''")
            let script = """
                #!/bin/zsh -l
                export HOME='\(home)'
                \(claudeConfigExport)
                export GHOSTTY_AGENT_STATUS_DIR='\(statusDir)'
                export GHOSTTY_AGENT_NAME='\(id.uuidString)'
                printf '\\033]2;%s\\007' '\(name)'
                clear
                \(command)
                command_status=$?
                printf '\\n\\033[33mAgent exited (status %s). Continuing in your login shell.\\033[0m\\n' "$command_status"
                exec "${SHELL:-/bin/zsh}" -l
                """

            let scriptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("clawddy-\(id.uuidString)-\(UUID().uuidString).sh")
            guard let data = script.data(using: .utf8),
                  AgentConfig.atomicWrite(data, to: scriptURL)
            else {
                self.apply(.launchFailed("The launch script could not be created."), to: agent)
                self.updateAggregate()
                return nil
            }
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: scriptURL.path)
            } catch {
                try? FileManager.default.removeItem(at: scriptURL)
                self.apply(
                    .launchFailed("The launch script could not be made executable."),
                    to: agent)
                self.updateAggregate()
                return nil
            }
            self.removeLaunchScript(for: id)
            self.launchScripts[id] = scriptURL

            var surfaceConfig = Ghostty.SurfaceConfiguration()
            surfaceConfig.command = scriptURL.path
            surfaceConfig.workingDirectory = project.workingDirectory
            var environment = [
                "HOME": AgentConfig.accountHomeDirectory.path,
                "GHOSTTY_AGENT_STATUS_DIR": AgentConfig.statusDir.path,
                "GHOSTTY_AGENT_NAME": id.uuidString,
            ]
            if let url = AgentConfig.claudeConfigEnvironmentOverride {
                environment["CLAUDE_CONFIG_DIR"] = url.path
            }
            if let environmentPath = self.environmentPath {
                environment["PATH"] = environmentPath
            }
            surfaceConfig.environmentVariables = environment
            return (app, surfaceConfig)
        }

        if isNew, let surface = detailVC.surfaceView(for: id) {
            surfaceViews[id] = surface
            BridgeMetrics.shared.recordSurfaceCreated()
            updateMetricsSnapshot()

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
        setCurrentlyViewedAgent(id)
    }

    // MARK: - Command Building

    private func buildCommand(agent: AgentInstance, workingDirectory: String?) -> String {
        let name = agent.name.replacingOccurrences(of: "'", with: "'\\''")
        let preparation = AgentMetadataRuntime.prepare(
            agentID: agent.id,
            workingDirectory: workingDirectory)
        let settingsArgument: String
        if let settingsURL = preparation.settingsURL {
            settingsArgument = " --settings \(AgentMetadataRuntime.shellQuote(settingsURL.path))"
            agent.metadataAvailability = .waiting
        } else {
            settingsArgument = ""
            agent.metadataAvailability = .unavailable(
                preparation.unavailableReason ?? "Session metadata is unavailable.")
        }

        // Priority 1: resume existing session
        if let sessionId = readSessionFile(agent.id) {
            return "claude --resume '\(sessionId)' --dangerously-skip-permissions\(settingsArgument)"
        }
        // Priority 2: fork from source
        if let sourceId = readForkSource(agent.id) {
            return "claude --resume '\(sourceId)' --fork-session --name '\(name)' --dangerously-skip-permissions\(settingsArgument)"
        }
        // Priority 3: fresh start
        return "claude --name '\(name)' --dangerously-skip-permissions\(settingsArgument)"
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
        guard let marker = sourceSessionId.data(using: .utf8),
              atomicWrite(marker, to: forkUrl)
        else {
            deleteAgent(id: entry.id, config: config)
            logger.error("fork: failed to persist source session for \(entry.id)")
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

        if isSafeForInput(agent.displayState) {
            logger.info("rename: sending /rename for \(id) immediately")
            onSendText?(id, "/rename \(safeName)\n")
        } else {
            logger.info("rename: deferring /rename for \(id)")
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
        BridgeMetrics.shared.recordSurfaceDestroyedDelete()
        destroySurface(id: id)
        agents.removeValue(forKey: id)
        BridgeMetrics.shared.recordMutAgentsDict()
        pendingRenames.removeValue(forKey: id)
        eventOffsets.removeValue(forKey: id)
        metadataFileData.removeValue(forKey: id)

        // Clean status files
        ioQueue.async {
            let dir = AgentConfig.statusDir
            for ext in ["session", "forkFrom", "lastEvent", "events", "metadata.json"] {
                try? FileManager.default.removeItem(
                    at: dir.appendingPathComponent("\(id.uuidString).\(ext)"))
            }
            AgentMetadataRuntime.remove(agentID: id)
        }
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

    private func requestStatusPoll(after delay: TimeInterval = AgentBridge.pollThrottle) {
        guard !isTerminating else { return }
        guard !pollPending, !pollInFlight else {
            pollAgainNeeded = true
            BridgeMetrics.shared.recordPollThrottled()
            return
        }
        pollPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
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
        ioQueue.async { [weak self] in
            guard let self else { return }
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
                            logger.error("journal read failed for \(id): \(error.localizedDescription)")
                        }
                        try? handle.close()
                    }
                }

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
            DispatchQueue.main.async { [weak self] in
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
                logger.error("invalid metadata snapshot for \(id)")
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
            for data in batch.records {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let newClaude = parseClaudeState(from: json)
                if newClaude == .unknown { continue }

                let oldSnapshot = agent.runtimeSnapshot
                let effects = apply(
                    .hook(newClaude, isViewed: currentlyViewedAgentId == id),
                    to: agent)
                if oldSnapshot != agent.runtimeSnapshot {
                    anyChanged = true
                }

                if effects.contains(.becameAlive) {
                    launchTimers[id]?.invalidate()
                    launchTimers.removeValue(forKey: id)
                    removeLaunchScript(for: id)
                    let forkURL = statusDir.appendingPathComponent("\(id.uuidString).forkFrom")
                    if FileManager.default.fileExists(atPath: forkURL.path) {
                        ioQueue.async { try? FileManager.default.removeItem(at: forkURL) }
                    }
                }
                agent.lastHookTime = Date()
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
                    if effects.contains(.failed), newClaude == .error {
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
        guard pollAgainNeeded else { return }
        pollAgainNeeded = false
        requestStatusPoll(after: 0)
    }

    private func scheduleJournalCompaction(id: UUID, acknowledgedOffset: Int) {
        guard compactingJournals.insert(id).inserted else { return }
        let url = statusDir.appendingPathComponent("\(id.uuidString).events")
        let lockURL = statusDir.appendingPathComponent("\(id.uuidString).events.lock")
        ioQueue.async { [weak self] in
            guard let self else { return }
            let compacted = AgentEventJournal.compact(
                url: url,
                lockURL: lockURL,
                acknowledgedOffset: acknowledgedOffset)
            if !compacted {
                logger.debug("journal compaction deferred for \(id)")
            }
            DispatchQueue.main.async { [weak self] in
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
        case .idle, .finished: return true
        default: return false
        }
    }

    @discardableResult
    private func apply(
        _ event: AgentRuntimeEvent,
        to agent: AgentInstance
    ) -> Set<AgentRuntimeEffect> {
        let old = agent.runtimeSnapshot
        let result = AgentStateReducer.reduce(old, event: event)
        agent.runtimeSnapshot = result.state
        if old.processState != result.state.processState {
            BridgeMetrics.shared.recordMutProcessState()
        }
        if old.claudeState != result.state.claudeState {
            BridgeMetrics.shared.recordMutClaudeState()
        }
        if old.isUnread != result.state.isUnread {
            BridgeMetrics.shared.recordMutIsUnread()
        }
        return result.effects
    }

    private func updateCompactingTimer(for agent: AgentInstance) {
        compactingTimers[agent.id]?.invalidate()
        compactingTimers.removeValue(forKey: agent.id)
        guard agent.claudeState == .compacting else { return }

        compactingTimers[agent.id] = Timer.scheduledTimer(
            withTimeInterval: Self.compactingTimeout,
            repeats: false
        ) { [weak self, weak agent] _ in
            guard let self, let agent, agent.claudeState == .compacting else { return }
            self.apply(.compactionExpired, to: agent)
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

    private func destroySurface(id: UUID) {
        surfaceViews.removeValue(forKey: id)
        updateMetricsSnapshot()
        launchTimers[id]?.invalidate()
        launchTimers.removeValue(forKey: id)
        compactingTimers[id]?.invalidate()
        compactingTimers.removeValue(forKey: id)
        removeLaunchScript(for: id)
        AgentMetadataRuntime.remove(agentID: id)

        // Remove process exit observer
        if let observer = surfaceObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }

        if let agent = agents[id] {
            apply(.surfaceDied, to: agent)
        }
        onSurfaceDeath?(id)
        updateAggregate()
        persistState()
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
        deliverNotification(request)
    }

    private func deliverNotification(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request) { error in
                    if let error {
                        logger.error("notification failed: \(error.localizedDescription)")
                    }
                }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        logger.error("notification authorization failed: \(error.localizedDescription)")
                    } else if granted {
                        center.add(request) { error in
                            if let error {
                                logger.error("notification failed: \(error.localizedDescription)")
                            }
                        }
                    }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private func clearNotifications(for id: UUID) {
        let identifiers = [
            "clawddy.\(id.uuidString).completed",
            "clawddy.\(id.uuidString).waiting",
            "clawddy.\(id.uuidString).error",
        ]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    // MARK: - Persistence

    private func loadPersistedState() -> PersistedState {
        guard let data = try? Data(contentsOf: AgentConfig.stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    func persistState(synchronously: Bool = false) {
        var state = PersistedState()
        state.unreadAgents = Set(agents.values.filter(\.isUnread).map(\.id))
        state.pendingRenames = pendingRenames
        state.eventOffsets = eventOffsets
        guard let data = try? JSONEncoder().encode(state) else { return }
        let write = { _ = AgentConfig.atomicWrite(data, to: AgentConfig.stateURL) }
        if synchronously {
            ioQueue.sync(execute: write)
        } else {
            ioQueue.async(execute: write)
        }
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
            self?.requestStatusPoll()
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

    private func removeLaunchScript(for id: UUID) {
        guard let url = launchScripts.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func removeAllLaunchScripts() {
        let urls = launchScripts.values
        launchScripts.removeAll()
        for url in urls {
            try? FileManager.default.removeItem(at: url)
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
