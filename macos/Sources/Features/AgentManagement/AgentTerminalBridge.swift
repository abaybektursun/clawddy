import AppKit
import SwiftUI
import GhosttyKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentBridge")

enum AgentState: Equatable {
    case notStarted
    case terminalOnly
    case claudeActive(Int?)
    case claudeIdle(Int?)

    var color: Color {
        switch self {
        case .notStarted:   return .secondary.opacity(0.4)
        case .terminalOnly: return .secondary
        case .claudeActive: return .green
        case .claudeIdle:   return .yellow
        }
    }

    var label: String {
        switch self {
        case .notStarted:   return "idle"
        case .terminalOnly: return "terminal"
        case .claudeActive: return "active"
        case .claudeIdle:   return "idle"
        }
    }

    var iconName: String? {
        switch self {
        case .claudeActive: return "bolt.fill"
        case .claudeIdle:   return "moon.fill"
        case .terminalOnly: return "terminal"
        case .notStarted:   return nil
        }
    }

    var contextPercent: Int? {
        switch self {
        case .claudeActive(let pct): return pct
        case .claudeIdle(let pct):   return pct
        default: return nil
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
        let activeCount = states.filter {
            if case .claudeActive = $0 { return true }
            return false
        }.count
        let needsAttention = states.contains { state in
            if case .claudeActive(let pct) = state, let p = pct, p >= 80 { return true }
            if case .claudeIdle(let pct) = state, let p = pct, p >= 80 { return true }
            return false
        }
        if needsAttention { return .attention }
        if activeCount > 0 { return .running(activeCount) }
        return .idle
    }

    private var timer: Timer?
    private var statusWatcher: DispatchSourceFileSystemObject?
    private var notifiedHighContext: Set<String> = []
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
        removeFile("\(key).heartbeat")
    }

    func stopTracking(agent key: String) {
        logger.info("stopTracking: \(key) (activeKeys=\(self.activeSurfaceKeys.count))")
        activeSurfaceKeys.remove(key)
        agentStates.removeValue(forKey: key)
        removeFile("\(key).heartbeat")
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

        // File I/O on background queue
        pollQueue.async { [weak self] in
            guard let self else { return }
            var newStates: [String: AgentState] = [:]
            for key in keys {
                if let heartbeatAge = self.readHeartbeatAge(for: key) {
                    let pct = self.readContextPercent(for: key)
                    newStates[key] = heartbeatAge < 10 ? .claudeActive(pct) : .claudeIdle(pct)
                } else {
                    newStates[key] = .terminalOnly
                }
            }

            // Publish on main queue
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
            let oldState = oldStates[key]

            if case .claudeActive = oldState, case .claudeIdle = newState {
                postNotification(title: "Agent finished", body: "\(key) is now idle")
            }

            let pct: Int? = {
                switch newState {
                case .claudeActive(let p): return p
                case .claudeIdle(let p): return p
                default: return nil
                }
            }()
            if let p = pct, p >= 80, !notifiedHighContext.contains(key) {
                notifiedHighContext.insert(key)
                postNotification(title: "High context usage", body: "\(key) is at \(p)% context")
            }
            if let p = pct, p < 80 {
                notifiedHighContext.remove(key)
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

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Status Files

    private var statusDir: URL { AgentConfig.statusDir }

    private func readHeartbeatAge(for name: String) -> TimeInterval? {
        let url = statusDir.appendingPathComponent("\(name).heartbeat")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(modDate)
    }

    private func readContextPercent(for name: String) -> Int? {
        let url = statusDir.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ctx = json["context_window"] as? [String: Any],
              let pct = ctx["used_percentage"] as? Double
        else { return nil }
        return Int(pct)
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
