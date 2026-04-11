import Foundation
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentConfig")

// MARK: - Data Model

struct AgentEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
}

struct AgentProject: Codable, Identifiable {
    var name: String
    var tasks: [AgentTask]
    var workingDirectory: String?
    var id: String { name }
}

struct AgentTask: Codable, Identifiable {
    var name: String
    var agents: [AgentEntry]
    var id: String { name }

    // Migration: decode from [String] (v1) or [AgentEntry] (v2+)
    private enum CodingKeys: String, CodingKey { case name, agents }

    init(name: String, agents: [AgentEntry] = []) {
        self.name = name
        self.agents = agents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        if let entries = try? container.decode([AgentEntry].self, forKey: .agents) {
            agents = entries
        } else if let names = try? container.decode([String].self, forKey: .agents) {
            agents = names.map { AgentEntry(id: UUID(), name: $0) }
        } else {
            agents = []
        }
    }
}

private struct AgentConfigFile: Codable {
    var projects: [AgentProject]
}

// MARK: - Config Manager

class AgentConfig: ObservableObject {
    @Published var projects: [AgentProject] = []
    private var configDirWatcher: DispatchSourceFileSystemObject?
    private var suppressWatch = false

    static var baseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty-agents")
    }
    static var configURL: URL { baseDir.appendingPathComponent("agents.json") }
    static var statusDir: URL { baseDir.appendingPathComponent("status") }
    static var hooksDir: URL { baseDir.appendingPathComponent("hooks") }
    static var stateURL: URL { baseDir.appendingPathComponent("state.json") }

    /// Flat list of all agent entries across all projects and tasks.
    var allAgentEntries: [AgentEntry] {
        projects.flatMap { $0.tasks.flatMap(\.agents) }
    }

    init() {
        ensureDirs()
        ensureHookScript()
        if !Self.hooksInstalled() { installHooks() }
        load()
        watchConfigDir()
    }

    deinit {
        configDirWatcher?.cancel()
    }

    // MARK: - Load / Save

    func load() {
        guard FileManager.default.fileExists(atPath: Self.configURL.path),
              let data = try? Data(contentsOf: Self.configURL),
              let config = try? JSONDecoder().decode(AgentConfigFile.self, from: data)
        else { return }
        projects = config.projects
        migrateStatusFiles()
        save()
        logger.info("load — \(config.projects.count) projects, \(self.allAgentEntries.count) agents")
    }

    /// Migrate old v1 status files (keyed by sanitized name) to UUID-keyed names.
    /// Safe to run every load — skips if new file already exists.
    private func migrateStatusFiles() {
        let fm = FileManager.default
        for project in projects {
            for task in project.tasks {
                for entry in task.agents {
                    let oldKey = Self.v1AgentKey(project: project.name, task: task.name, agent: entry.name)
                    let newKey = entry.id.uuidString
                    for ext in ["session", "state", "heartbeat", "forkFrom", "lastEvent", "json"] {
                        let oldURL = Self.statusDir.appendingPathComponent("\(oldKey).\(ext)")
                        let newURL = Self.statusDir.appendingPathComponent("\(newKey).\(ext)")
                        if fm.fileExists(atPath: oldURL.path) && !fm.fileExists(atPath: newURL.path) {
                            try? fm.moveItem(at: oldURL, to: newURL)
                            logger.info("migrated \(oldKey).\(ext) → \(newKey).\(ext)")
                        }
                    }
                }
            }
        }
    }

    private static func v1AgentKey(project: String, task: String, agent: String) -> String {
        "\(project)/\(task)/\(agent)"
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
    }

    func save() {
        logger.info("save — \(self.projects.count) projects")
        suppressWatch = true
        let config = AgentConfigFile(projects: projects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(config)
        Self.atomicWrite(data, to: Self.configURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.suppressWatch = false
        }
    }

    // MARK: - Projects

    func addProject(name: String) {
        guard !name.isEmpty, !projects.contains(where: { $0.name == name }) else { return }
        projects.append(AgentProject(name: name, tasks: []))
        save()
    }

    func removeProject(name: String) {
        projects.removeAll { $0.name == name }
        save()
    }

    func renameProject(old: String, new: String) {
        guard let i = projects.firstIndex(where: { $0.name == old }),
              !projects.contains(where: { $0.name == new })
        else { return }
        projects[i].name = new
        save()
    }

    // MARK: - Tasks

    func addTask(project: String, name: String) {
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              !name.isEmpty,
              !projects[pi].tasks.contains(where: { $0.name == name })
        else { return }
        projects[pi].tasks.append(AgentTask(name: name))
        save()
    }

    func removeTask(project: String, name: String) {
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.name == name })
        else { return }
        projects[pi].tasks.remove(at: ti)
        save()
    }

    func renameTask(project: String, old: String, new: String) {
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.name == old }),
              !projects[pi].tasks.contains(where: { $0.name == new })
        else { return }
        projects[pi].tasks[ti].name = new
        save()
    }

    // MARK: - Agents (UUID-based)

    /// Add agent, returning the created entry.
    @discardableResult
    func addAgent(project: String, task: String, name: String) -> AgentEntry? {
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.name == task }),
              !name.isEmpty
        else { return nil }
        let entry = AgentEntry(id: UUID(), name: name)
        projects[pi].tasks[ti].agents.append(entry)
        save()
        return entry
    }

    /// Add a pre-built entry (e.g., for fork with specific UUID).
    func addAgent(_ entry: AgentEntry, project: String, task: String) {
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.name == task })
        else { return }
        projects[pi].tasks[ti].agents.append(entry)
        save()
    }

    func removeAgent(id: UUID) {
        for pi in projects.indices {
            for ti in projects[pi].tasks.indices {
                projects[pi].tasks[ti].agents.removeAll { $0.id == id }
            }
        }
        save()
    }

    func renameAgent(id: UUID, newName: String) {
        for pi in projects.indices {
            for ti in projects[pi].tasks.indices {
                if let ai = projects[pi].tasks[ti].agents.firstIndex(where: { $0.id == id }) {
                    projects[pi].tasks[ti].agents[ai].name = newName
                    save()
                    return
                }
            }
        }
    }

    /// Find the project containing this agent.
    func project(forAgent id: UUID) -> AgentProject? {
        projects.first { p in p.tasks.contains { t in t.agents.contains { $0.id == id } } }
    }

    /// Find the task containing this agent.
    func task(forAgent id: UUID) -> AgentTask? {
        for p in projects {
            for t in p.tasks {
                if t.agents.contains(where: { $0.id == id }) { return t }
            }
        }
        return nil
    }

    // MARK: - Universal Hook Script

    private static let hookScript = """
        #!/bin/sh
        [ -z "$GHOSTTY_AGENT_NAME" ] && cat > /dev/null && exit 0
        DIR="$HOME/.config/ghostty-agents/status"
        mkdir -p "$DIR" 2>/dev/null
        INPUT_FLAT=$(cat | tr -d '\\n')
        SID=$(echo "$INPUT_FLAT" | sed -n 's/.*"session_id" *: *"\\([^"]*\\)".*/\\1/p')
        EVENT=$(echo "$INPUT_FLAT" | sed -n 's/.*"hook_event_name" *: *"\\([^"]*\\)".*/\\1/p')
        if [ -n "$SID" ]; then
            echo "$SID" > "$DIR/$GHOSTTY_AGENT_NAME.session.$$"
            mv "$DIR/$GHOSTTY_AGENT_NAME.session.$$" "$DIR/$GHOSTTY_AGENT_NAME.session"
        fi
        echo "{\\"hook_event_name\\":\\"$EVENT\\",\\"session_id\\":\\"$SID\\"}" > "$DIR/$GHOSTTY_AGENT_NAME.lastEvent.$$"
        mv "$DIR/$GHOSTTY_AGENT_NAME.lastEvent.$$" "$DIR/$GHOSTTY_AGENT_NAME.lastEvent"
        """

    private static let hookedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "Stop", "StopFailure",
        "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "SessionEnd",
    ]

    private func ensureHookScript() {
        let fm = FileManager.default
        try! fm.createDirectory(at: Self.hooksDir, withIntermediateDirectories: true)

        let url = Self.hooksDir.appendingPathComponent("clawddy-hook.sh")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if existing == Self.hookScript { return }

        try! Self.hookScript.write(to: url, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        // Clean old per-event scripts
        for old in ["on-session-start.sh", "on-prompt.sh", "on-tool.sh",
                     "on-permission.sh", "on-stop.sh", "on-error.sh"] {
            try? fm.removeItem(at: Self.hooksDir.appendingPathComponent(old))
        }
    }

    private static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static func hooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let str = String(data: data, encoding: .utf8)
        else { return false }
        return str.contains("clawddy-hook.sh")
    }

    private func installHooks() {
        let fm = FileManager.default
        let url = Self.claudeSettingsURL

        // Ensure .claude directory exists
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        // Backup
        let backupURL = url.deletingLastPathComponent().appendingPathComponent("settings.json.clawddy-backup")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: url, to: backupURL)
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Remove ALL old clawddy/ghostty-agents hooks
        for key in hooks.keys {
            if var eventArray = hooks[key] as? [[String: Any]] {
                eventArray.removeAll { group in
                    guard let innerHooks = group["hooks"] as? [[String: Any]] else { return false }
                    return innerHooks.contains { ($0["command"] as? String)?.contains("ghostty-agents/hooks/") == true }
                }
                hooks[key] = eventArray.isEmpty ? nil : eventArray
            }
        }

        // Install universal hook for all events
        let scriptPath = Self.hooksDir.appendingPathComponent("clawddy-hook.sh").path
        for event in Self.hookedEvents {
            var eventArray = hooks[event] as? [[String: Any]] ?? []
            eventArray.append(["hooks": [["type": "command", "command": scriptPath, "timeout": 5]]])
            hooks[event] = eventArray
        }

        settings["hooks"] = hooks
        let data = try! JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: url, options: .atomic)
    }

    // MARK: - Private

    private func ensureDirs() {
        let fm = FileManager.default
        try! fm.createDirectory(at: Self.baseDir, withIntermediateDirectories: true)
        try! fm.createDirectory(at: Self.statusDir, withIntermediateDirectories: true)
    }

    /// Watch the config DIRECTORY (not the file). Handles atomic external edits
    /// that replace the inode, and fresh installs where the file doesn't exist yet.
    private func watchConfigDir() {
        let dirPath = Self.baseDir.path
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, !self.suppressWatch else { return }
            self.load()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configDirWatcher = source
    }

    // MARK: - Atomic Write

    static func atomicWrite(_ data: Data, to url: URL) {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItem(at: url, withItemAt: tmp,
                    backupItemName: nil, resultingItemURL: nil)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            logger.error("atomicWrite failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

// Module-level convenience
func atomicWrite(_ data: Data, to url: URL) {
    AgentConfig.atomicWrite(data, to: url)
}
