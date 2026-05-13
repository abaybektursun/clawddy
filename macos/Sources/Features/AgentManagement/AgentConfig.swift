import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentConfig")

// MARK: - Data Model

struct AgentEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
}

struct AgentProject: Codable, Identifiable {
    let id: UUID
    var name: String
    var tasks: [AgentTask]
    var workingDirectory: String?

    init(id: UUID = UUID(), name: String, tasks: [AgentTask] = [], workingDirectory: String? = nil) {
        self.id = id
        self.name = name
        self.tasks = tasks
        self.workingDirectory = workingDirectory
    }

    // Migration: decode missing `id` (pre-UUID schema) → generate fresh UUID.
    private enum CodingKeys: String, CodingKey { case id, name, tasks, workingDirectory }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.tasks = try c.decodeIfPresent([AgentTask].self, forKey: .tasks) ?? []
        self.workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
    }
}

struct AgentTask: Codable, Identifiable {
    let id: UUID
    var name: String
    var agents: [AgentEntry]

    init(id: UUID = UUID(), name: String, agents: [AgentEntry] = []) {
        self.id = id
        self.name = name
        self.agents = agents
    }

    // Migration: decode missing `id` → fresh UUID; agents from [String] (v1) or [AgentEntry] (v2+).
    private enum CodingKeys: String, CodingKey { case id, name, agents }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        if let entries = try? c.decode([AgentEntry].self, forKey: .agents) {
            self.agents = entries
        } else if let names = try? c.decode([String].self, forKey: .agents) {
            self.agents = names.map { AgentEntry(id: UUID(), name: $0) }
        } else {
            self.agents = []
        }
    }
}

private struct AgentConfigFile: Codable {
    var projects: [AgentProject]
}

// MARK: - Config Manager

@Observable
class AgentConfig {
    var projects: [AgentProject] = []
    var onReloaded: (() -> Void)?
    private var configDirWatcher: DispatchSourceFileSystemObject?
    /// Snapshot of last-loaded agents.json bytes. Used by the directory watcher
    /// to dedup spurious fires (including those caused by our own writes).
    private var lastConfigData: Data?

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
        lastConfigData = data
        projects = config.projects
        migrateStatusFiles()

        // Schema migration: if encoded form differs from on-disk bytes, structs
        // gained new fields (e.g. fresh UUIDs for legacy projects/tasks). Save
        // back so they persist.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let reEncoded = try? encoder.encode(AgentConfigFile(projects: projects)),
           reEncoded != data {
            logger.info("schema migration — persisting new UUIDs")
            save()
        }

        logger.info("load — \(config.projects.count) projects, \(self.allAgentEntries.count) agents")
        onReloaded?()
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
        let config = AgentConfigFile(projects: projects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else {
            logger.error("save failed — JSON encode error")
            return
        }
        // Update content cache BEFORE the write fires the watcher, so the
        // watcher's dedup (lastConfigData == data) suppresses our own write.
        lastConfigData = data
        Self.atomicWrite(data, to: Self.configURL)
    }

    // MARK: - Projects

    /// Add a project. Returns the new project's UUID on success, nil if empty or duplicate.
    @discardableResult
    func addProject(name: String) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !projects.contains(where: { $0.name == trimmed })
        else { return nil }
        let project = AgentProject(name: trimmed, tasks: [])
        projects.append(project)
        save()
        return project.id
    }

    func removeProject(id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }

    /// Rename by stable id. Rejects duplicate names. Returns true on success.
    @discardableResult
    func renameProject(id: UUID, newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let i = projects.firstIndex(where: { $0.id == id }),
              projects[i].name != trimmed,
              !projects.contains(where: { $0.name == trimmed && $0.id != id })
        else { return false }
        projects[i].name = trimmed
        save()
        return true
    }

    // MARK: - Tasks

    /// Add a task. Returns the new task's UUID on success, nil if empty or duplicate.
    @discardableResult
    func addTask(project: String, name: String) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              !trimmed.isEmpty,
              !projects[pi].tasks.contains(where: { $0.name == trimmed })
        else { return nil }
        let task = AgentTask(name: trimmed)
        projects[pi].tasks.append(task)
        save()
        return task.id
    }

    func removeTask(projectId: UUID, taskId: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectId }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.id == taskId })
        else { return }
        projects[pi].tasks.remove(at: ti)
        save()
    }

    /// Rename by stable id. Rejects duplicate names within project. Returns true on success.
    @discardableResult
    func renameTask(projectId: UUID, taskId: UUID, newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let pi = projects.firstIndex(where: { $0.id == projectId }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.id == taskId }),
              projects[pi].tasks[ti].name != trimmed,
              !projects[pi].tasks.contains(where: { $0.name == trimmed && $0.id != taskId })
        else { return false }
        projects[pi].tasks[ti].name = trimmed
        save()
        return true
    }

    // MARK: - Agents (UUID-based)

    /// Add agent, returning the created entry. Trims whitespace and rejects empty names.
    @discardableResult
    func addAgent(project: String, task: String, name: String) -> AgentEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.name == task }),
              !trimmed.isEmpty
        else { return nil }
        let entry = AgentEntry(id: UUID(), name: trimmed)
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
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for pi in projects.indices {
            for ti in projects[pi].tasks.indices {
                if let ai = projects[pi].tasks[ti].agents.firstIndex(where: { $0.id == id }) {
                    projects[pi].tasks[ti].agents[ai].name = trimmed
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
            BridgeMetrics.shared.recordConfigWatcherFire()
            guard let self else { return }
            // Content-based dedup: only reload if agents.json actually changed.
            // Compare raw bytes (definitive — no hash collisions).
            // This also suppresses our own writes (save() updates lastConfigData
            // before the kqueue event arrives).
            guard let data = try? Data(contentsOf: Self.configURL) else { return }
            guard data != self.lastConfigData else {
                BridgeMetrics.shared.recordConfigReloadDeduped()
                return
            }
            BridgeMetrics.shared.recordConfigReload()
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
