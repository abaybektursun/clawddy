import AppKit
import SwiftUI
import GhosttyKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentBridge")

enum AgentState: Equatable {
    case notStarted        // no terminal surface
    case terminalOnly      // terminal running, claude not active
    case idle              // claude waiting for user input (acknowledged)
    case finished          // claude just finished, user hasn't seen it yet
    case thinking          // user submitted prompt, claude processing
    case working           // claude using tools
    case needsPermission   // claude waiting for permission approval
    case error             // tool failure or API error

    var color: Color {
        switch self {
        case .notStarted:       return .secondary.opacity(0.3)
        case .terminalOnly:     return .secondary.opacity(0.5)
        case .idle:             return .secondary
        case .finished:         return .yellow
        case .thinking:         return .blue
        case .working:          return .green
        case .needsPermission:  return .orange
        case .error:            return .red
        }
    }

    /// The tint applied to the selected row's Liquid Glass background.
    /// Selecting an agent amplifies its current state visually.
    var selectionTint: Color {
        switch self {
        case .notStarted, .terminalOnly, .idle: return .accentColor
        case .finished:         return .yellow
        case .thinking:         return .blue
        case .working:          return .green
        case .needsPermission:  return .orange
        case .error:            return .red
        }
    }

    var label: String {
        switch self {
        case .notStarted:       return ""
        case .terminalOnly:     return "shell"
        case .idle:             return "idle"
        case .finished:         return "finished"
        case .thinking:         return "thinking"
        case .working:          return "working"
        case .needsPermission:  return "permission"
        case .error:            return "error"
        }
    }

    var iconName: String? {
        switch self {
        case .thinking:         return "brain"
        case .working:          return "bolt.fill"
        case .needsPermission:  return "exclamationmark.circle.fill"
        case .error:            return "xmark.circle.fill"
        case .finished:         return "bell.badge.fill"
        case .idle:             return "moon.fill"
        case .terminalOnly:     return "terminal"
        case .notStarted:       return nil
        }
    }

    /// Whether this state counts as "active" for aggregate purposes.
    var isActive: Bool {
        switch self {
        case .thinking, .working: return true
        default: return false
        }
    }

    /// Whether this state needs user attention (drives dock badge + menu bar tint).
    var needsAttention: Bool {
        switch self {
        case .needsPermission, .error, .finished: return true
        default: return false
        }
    }
}

enum AggregateState {
    case idle
    case running(Int)
    case attention
}

/// Manages agent-to-terminal mapping, state monitoring, and script generation.
/// Surfaces are owned by AgentDetailViewController; this class tracks keys and states.
class AgentTerminalBridge: ObservableObject {
    @Published var agentStates: [String: AgentState] = [:]

    /// Keys of agents that have active surfaces in the detail VC.
    private(set) var activeSurfaceKeys: Set<String> = []

    var onAggregateStateChanged: ((AggregateState) -> Void)?

    var aggregateState: AggregateState {
        let states = agentStates.values
        let activeCount = states.filter(\.isActive).count
        let needsAttention = states.contains(where: \.needsAttention)
        if needsAttention { return .attention }
        if activeCount > 0 { return .running(activeCount) }
        return .idle
    }

    private var timer: Timer?
    private var statusWatcher: DispatchSourceFileSystemObject?
    private var lastAggregateState: AggregateState?
    private var watcherThrottled = false
    private let pollQueue = DispatchQueue(label: "com.mitchellh.ghostty.agentpoll", qos: .utility)

    /// Agents that have finished but the user hasn't viewed them yet.
    /// When an agent in this set has state .idle, it's surfaced as .finished instead.
    private var unreadAgents: Set<String> = []

    init() {
        logger.info("init — starting poll timer (3s) and status watcher")
        // Clean stale agent scripts from previous builds
        Self.cleanStaleScripts()
        // Safety net poll — the file watcher should fire on every state change,
        // but this catches anything missed (e.g., if a write happens during throttle).
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.schedulePoll()
        }
        watchStatusDirectory()
    }

    private static func cleanStaleScripts() {
        let tmp = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
        for file in files where file.hasPrefix("ghostty-agent-") && file.hasSuffix(".sh") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(file))
        }
    }

    func state(for key: String) -> AgentState {
        agentStates[key] ?? .notStarted
    }

    /// Mark an agent's finished work as seen by the user.
    /// Called when the user activates/views the agent.
    func markRead(_ key: String) {
        guard unreadAgents.contains(key) else { return }
        unreadAgents.remove(key)
        // If the agent was being shown as .finished, refresh it to .idle
        if agentStates[key] == .finished {
            agentStates[key] = .idle
            // Aggregate may have changed (one fewer attention)
            let current = aggregateState
            if !aggregateStateEqual(lastAggregateState, current) {
                lastAggregateState = current
                onAggregateStateChanged?(current)
            }
        }
    }

    // MARK: - Surface Tracking

    func markSurfaceActive(_ key: String) {
        logger.info("markSurfaceActive: \(key)")
        activeSurfaceKeys.insert(key)
        schedulePoll()
    }

    func markSurfaceRemoved(_ key: String) {
        logger.info("markSurfaceRemoved: \(key)")
        activeSurfaceKeys.remove(key)
        agentStates.removeValue(forKey: key)
        removeFile("\(key).state")
    }

    func stopTracking(agent key: String) {
        logger.info("stopTracking: \(key) (activeKeys=\(self.activeSurfaceKeys.count))")
        activeSurfaceKeys.remove(key)
        agentStates.removeValue(forKey: key)
        unreadAgents.remove(key)
        removeFile("\(key).state")
        removeFile("\(key).session")
        removeFile("\(key).forkFrom")
    }

    func clearSession(agent key: String) {
        removeFile("\(key).session")
    }

    func rekey(old: String, new: String) {
        if activeSurfaceKeys.remove(old) != nil {
            activeSurfaceKeys.insert(new)
        }
        if let state = agentStates.removeValue(forKey: old) {
            agentStates[new] = state
        }
        if unreadAgents.remove(old) != nil {
            unreadAgents.insert(new)
        }
    }

    // MARK: - Script Generation

    func writeAgentScript(key: String, displayName: String) -> String {
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-agent-\(key).sh").path

        let escapedKey = key.replacingOccurrences(of: "'", with: "'\\''")
        let escapedDisplay = displayName.replacingOccurrences(of: "'", with: "'\\''")
        let statusDir = "$HOME/.config/ghostty-agents/status"
        let content = """
            #!/bin/zsh -l
            export GHOSTTY_AGENT_NAME='\(escapedKey)'
            printf '\\033]2;%s\\007' '\(escapedDisplay)'
            clear
            SESSION_FILE="\(statusDir)/$GHOSTTY_AGENT_NAME.session"
            FORK_FILE="\(statusDir)/$GHOSTTY_AGENT_NAME.forkFrom"
            if [ -f "$SESSION_FILE" ]; then
              # Normal resume of existing session
              claude --resume "$(cat "$SESSION_FILE")" --permission-mode auto
              rm -f "$SESSION_FILE"
            elif [ -f "$FORK_FILE" ]; then
              # First launch: fork from source agent's session, with our own name
              SOURCE_ID=$(cat "$FORK_FILE")
              rm -f "$FORK_FILE"
              claude --resume "$SOURCE_ID" --fork-session --name '\(escapedDisplay)' --permission-mode auto
            else
              # Fresh start
              claude --name '\(escapedDisplay)' --permission-mode auto
            fi
            exec zsh -l
            """
        FileManager.default.createFile(atPath: scriptPath, contents: content.data(using: .utf8))
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return scriptPath
    }

    /// Read a source agent's session ID so a new agent can fork from it.
    func sessionID(for key: String) -> String? {
        let url = statusDir.appendingPathComponent("\(key).session")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Mark a new agent to fork from a source session on first launch.
    func markForkSource(key: String, sourceSessionID: String) {
        let url = statusDir.appendingPathComponent("\(key).forkFrom")
        try? sourceSessionID.write(to: url, atomically: true, encoding: .utf8)
        logger.info("markForkSource: \(key) will fork from \(sourceSessionID)")
    }

    // MARK: - State Polling

    private func schedulePoll() {
        let keys = activeSurfaceKeys
        if keys.isEmpty { return }

        pollQueue.async { [weak self] in
            guard let self else { return }
            var newStates: [String: AgentState] = [:]
            for key in keys {
                newStates[key] = self.readAgentState(for: key)
            }

            DispatchQueue.main.async { [weak self] in
                self?.applyStates(newStates)
            }
        }
    }

    private func applyStates(_ rawStates: [String: AgentState]) {
        let oldStates = agentStates

        // Compute display states: if an agent was previously active and is now idle,
        // mark it as unread and surface it as .finished until the user views it.
        // If an agent goes back to active, clear unread.
        var newStates: [String: AgentState] = [:]
        for (key, raw) in rawStates {
            let oldState = oldStates[key] ?? .notStarted

            if raw.isActive {
                // Agent is active again — clear any unread
                unreadAgents.remove(key)
                newStates[key] = raw
            } else if raw == .idle && oldState.isActive {
                // Just transitioned active → idle — mark as unread/finished
                unreadAgents.insert(key)
                newStates[key] = .finished
            } else if raw == .idle && unreadAgents.contains(key) {
                // Already unread — keep showing as finished
                newStates[key] = .finished
            } else {
                newStates[key] = raw
            }
        }

        if newStates != oldStates {
            agentStates = newStates
        }

        for (key, newState) in newStates {
            let oldState = oldStates[key] ?? .notStarted

            // Agent finished working → idle/finished
            if oldState.isActive && (newState == .finished || newState == .idle) {
                postNotification(
                    agentKey: key,
                    kind: .finished,
                    title: "Agent finished",
                    body: "\(key) is ready for next prompt"
                )
            }

            // Agent needs permission
            if newState == .needsPermission && oldState != .needsPermission {
                postNotification(
                    agentKey: key,
                    kind: .permission,
                    title: "Permission needed",
                    body: "\(key) is waiting for approval"
                )
            }

            // Agent hit an error
            if newState == .error && oldState != .error {
                postNotification(
                    agentKey: key,
                    kind: .error,
                    title: "Agent error",
                    body: "\(key) encountered an error"
                )
            }
        }

        let current = aggregateState
        if !aggregateStateEqual(lastAggregateState, current) {
            lastAggregateState = current
            onAggregateStateChanged?(current)
        }
    }

    private func aggregateStateEqual(_ a: AggregateState?, _ b: AggregateState) -> Bool {
        guard let a else { return false }
        switch (a, b) {
        case (.idle, .idle): return true
        case (.running(let x), .running(let y)): return x == y
        case (.attention, .attention): return true
        default: return false
        }
    }

    private enum NotificationKind {
        case finished      // passive — quiet, just appears in notification center
        case permission    // timeSensitive — bypasses Focus, persistent
        case error         // active — default banner, plays sound
    }

    private func postNotification(
        agentKey: String,
        kind: NotificationKind,
        title: String,
        body: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Group notifications per agent in Notification Center
        content.threadIdentifier = agentKey
        // Pass agent key so the tap handler knows which agent to focus
        content.userInfo = ["clawddy_agent_key": agentKey]

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
            identifier: "clawddy.\(agentKey).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Status Files

    private var statusDir: URL { AgentConfig.statusDir }

    /// Read the agent state from the `.state` file written by hooks.
    /// File contains a single keyword: thinking, working, permission, idle, error
    private func readAgentState(for name: String) -> AgentState {
        let url = statusDir.appendingPathComponent("\(name).state")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return .terminalOnly
        }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "thinking":    return .thinking
        case "working":     return .working
        case "permission":  return .needsPermission
        case "idle":        return .idle
        case "error":       return .error
        default:            return .terminalOnly
        }
    }

    private func removeFile(_ name: String) {
        let url = statusDir.appendingPathComponent(name)
        pollQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func watchStatusDirectory() {
        let fd = open(statusDir.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.error("watchStatusDirectory — failed to open fd")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, !self.watcherThrottled else { return }
            self.watcherThrottled = true
            // Short throttle: feels instant but coalesces rapid PostToolUse bursts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.watcherThrottled = false
                self?.schedulePoll()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        statusWatcher = source
        logger.info("watchStatusDirectory — watching \(self.statusDir.path)")
    }
}
