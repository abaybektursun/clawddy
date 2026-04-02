import AppKit
import GhosttyKit

enum AgentState: Equatable {
    case notStarted
    case terminalOnly
    case claudeActive(Int?)
    case claudeIdle(Int?)
}

/// Manages agent-to-terminal mapping, state monitoring, and script generation.
/// Surfaces are owned by AgentDetailViewController; this class tracks keys and states.
class AgentTerminalBridge: ObservableObject {
    @Published var agentStates: [String: AgentState] = [:]

    /// Keys of agents that have active surfaces in the detail VC.
    private(set) var activeSurfaceKeys: Set<String> = []

    private var timer: Timer?
    private var statusWatcher: DispatchSourceFileSystemObject?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.pollStates() }
        }
        watchStatusDirectory()
    }

    func state(for key: String) -> AgentState {
        agentStates[key] ?? .notStarted
    }

    // MARK: - Surface Tracking

    func markSurfaceActive(_ key: String) {
        activeSurfaceKeys.insert(key)
        pollStates()
    }

    func markSurfaceRemoved(_ key: String) {
        activeSurfaceKeys.remove(key)
        agentStates.removeValue(forKey: key)
        removeFile("\(key).heartbeat")
    }

    func stopTracking(agent key: String) {
        activeSurfaceKeys.remove(key)
        agentStates.removeValue(forKey: key)
        removeFile("\(key).heartbeat")
        removeFile("\(key).session")
    }

    func clearSession(agent key: String) {
        removeFile("\(key).session")
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
              claude --resume "$(cat "$SESSION_FILE")" --permission-mode auto && exit 0
              # Resume failed (stale session) — remove and start fresh
              rm -f "$SESSION_FILE"
            fi
            exec claude --name '\(escapedDisplay)' --permission-mode auto
            """
        FileManager.default.createFile(atPath: scriptPath, contents: content.data(using: .utf8))
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return scriptPath
    }

    // MARK: - State Polling

    private func pollStates() {
        var newStates: [String: AgentState] = [:]
        for key in activeSurfaceKeys {
            if let heartbeatAge = readHeartbeatAge(for: key) {
                let pct = readContextPercent(for: key)
                newStates[key] = heartbeatAge < 10 ? .claudeActive(pct) : .claudeIdle(pct)
            } else {
                newStates[key] = .terminalOnly
            }
        }
        agentStates = newStates
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
        try? FileManager.default.removeItem(at: url)
    }

    private func watchStatusDirectory() {
        let fd = open(statusDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.pollStates()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        statusWatcher = source
    }
}
