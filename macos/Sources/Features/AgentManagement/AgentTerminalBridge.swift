import AppKit
import SwiftUI
import GhosttyKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentBridge")

enum AgentState: Equatable {
    case notStarted        // no terminal surface
    case terminalOnly      // terminal running, claude not active
    case idle              // claude waiting for user input
    case thinking          // user submitted prompt, claude processing
    case working           // claude using tools
    case needsPermission   // claude waiting for permission approval
    case error             // tool failure or API error

    var color: Color {
        switch self {
        case .notStarted:       return .secondary.opacity(0.3)
        case .terminalOnly:     return .secondary.opacity(0.5)
        case .idle:             return .secondary
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

    /// Whether this state needs user attention.
    var needsAttention: Bool {
        switch self {
        case .needsPermission, .error: return true
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

    init() {
        logger.info("init — starting poll timer (5s) and status watcher")
        // Clean stale agent scripts from previous builds
        Self.cleanStaleScripts()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
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
        removeFile("\(key).state")
        removeFile("\(key).session")
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
            if [ -f "$SESSION_FILE" ]; then
              claude --resume "$(cat "$SESSION_FILE")" --permission-mode auto
              rm -f "$SESSION_FILE"
            else
              claude --name '\(escapedDisplay)' --permission-mode auto
            fi
            exec zsh -l
            """
        FileManager.default.createFile(atPath: scriptPath, contents: content.data(using: .utf8))
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return scriptPath
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

    private func applyStates(_ newStates: [String: AgentState]) {
        let oldStates = agentStates

        if newStates != oldStates {
            agentStates = newStates
        }

        for (key, newState) in newStates {
            let oldState = oldStates[key] ?? .notStarted

            // Agent finished working → idle
            if oldState.isActive && newState == .idle {
                postNotification(title: "Agent finished", body: "\(key) is now idle")
            }

            // Agent needs permission
            if newState == .needsPermission && oldState != .needsPermission {
                postNotification(title: "Permission needed", body: "\(key) is waiting for approval", sound: .defaultCritical)
            }

            // Agent hit an error
            if newState == .error && oldState != .error {
                postNotification(title: "Agent error", body: "\(key) encountered an error")
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

    private func postNotification(title: String, body: String, sound: UNNotificationSound = .default) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
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
