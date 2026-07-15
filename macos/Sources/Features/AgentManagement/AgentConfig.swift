import Foundation
import Observation
import os
import Darwin

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
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var projects: [AgentProject]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projects
    }

    init(projects: [AgentProject]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.projects = projects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        projects = try container.decodeIfPresent([AgentProject].self, forKey: .projects) ?? []
    }
}

// MARK: - Config Manager

@Observable
class AgentConfig {
    var projects: [AgentProject] = []
    var errorMessage: String?
    var onReloaded: (() -> Void)?
    private var configDirWatcher: DispatchSourceFileSystemObject?
    /// Snapshot of last-loaded agents.json bytes. Used by the directory watcher
    /// to dedup spurious fires (including those caused by our own writes).
    private var lastConfigData: Data?

    static var baseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty-agents")
    }
    /// The macOS account home from the user database. Terminal processes need
    /// this value so system services such as the login Keychain resolve in the
    /// same user context even when the app itself is launched with an isolated
    /// home directory.
    static var accountHomeDirectory: URL {
        if let record = getpwuid(getuid()),
           let directory = record.pointee.pw_dir
        {
            return URL(
                fileURLWithPath: String(cString: directory),
                isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Claude's supported configuration root. This deliberately remains
    /// independent from the account home used for Keychain lookup.
    static var claudeConfigDir: URL {
        if let explicitClaudeConfigDir { return explicitClaudeConfigDir }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// Only override Claude's default when the caller requested it or the app
    /// itself has an alternate home. Explicitly setting the default path would
    /// create a distinct Claude profile even for an ordinary installation.
    static var claudeConfigEnvironmentOverride: URL? {
        if let explicitClaudeConfigDir { return explicitClaudeConfigDir }
        let appHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard appHome.path != accountHomeDirectory.standardizedFileURL.path else {
            return nil
        }
        return claudeConfigDir
    }

    private static var explicitClaudeConfigDir: URL? {
        guard let rawValue = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty
        else { return nil }
        return URL(
            fileURLWithPath: (rawValue as NSString).expandingTildeInPath,
            isDirectory: true)
    }
    static var configURL: URL { baseDir.appendingPathComponent("agents.json") }
    static var statusDir: URL { baseDir.appendingPathComponent("status") }
    static var hooksDir: URL { baseDir.appendingPathComponent("hooks") }
    static var stateURL: URL { baseDir.appendingPathComponent("state.json") }

    /// Flat list of all agent entries across all projects and tasks.
    var allAgentEntries: [AgentEntry] {
        projects.flatMap { $0.tasks.flatMap(\.agents) }
    }

    var persistenceErrorMessage: String? {
        guard errorMessage?.hasPrefix("Agents configuration could not be saved") == true
        else { return nil }
        return errorMessage
    }

    init() {
        do {
            try ensureDirs()
            try ensureHookScript()
            if !Self.hooksInstalled() { try installHooks() }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("setup failed: \(error.localizedDescription)")
        }
        load()
        if FileManager.default.fileExists(atPath: Self.baseDir.path) {
            watchConfigDir()
        }
    }

    deinit {
        configDirWatcher?.cancel()
    }

    // MARK: - Load / Save

    func load() {
        guard FileManager.default.fileExists(atPath: Self.configURL.path) else { return }
        do {
            let data = try Data(contentsOf: Self.configURL)
            let config = try JSONDecoder().decode(AgentConfigFile.self, from: data)
            lastConfigData = data
            projects = config.projects
            errorMessage = nil
            migrateStatusFiles()

            if config.schemaVersion < AgentConfigFile.currentSchemaVersion {
                logger.info("schema migration from v\(config.schemaVersion)")
                save()
            }

            logger.info("load — \(config.projects.count) projects, \(self.allAgentEntries.count) agents")
            onReloaded?()
        } catch {
            errorMessage = "Agents configuration could not be loaded: \(error.localizedDescription)"
            logger.error("load failed: \(error.localizedDescription)")
        }
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
                    for ext in ["session", "state", "heartbeat", "forkFrom", "lastEvent", "events", "json"] {
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

    @discardableResult
    func save() -> Bool {
        logger.info("save — \(self.projects.count) projects")
        let config = AgentConfigFile(projects: projects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(config)
        } catch {
            errorMessage = "Agents configuration could not be saved: \(error.localizedDescription)"
            logger.error("save encode failed: \(error.localizedDescription)")
            return false
        }
        guard Self.atomicWrite(data, to: Self.configURL) else {
            errorMessage = "Agents configuration could not be saved. Check the file permissions and available storage."
            return false
        }
        // Update the cache only after the durable replacement succeeds.
        lastConfigData = data
        if errorMessage?.hasPrefix("Agents configuration could not be saved") == true {
            errorMessage = nil
        }
        return true
    }

    private func commitMutation(_ mutation: () -> Void) -> Bool {
        let previous = projects
        mutation()
        guard save() else {
            projects = previous
            return false
        }
        return true
    }

    // MARK: - Projects

    /// Add a project. Returns the new project's UUID on success, nil if empty or duplicate.
    @discardableResult
    func addProject(name: String, workingDirectory: String? = nil) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !projects.contains(where: { $0.name == trimmed })
        else { return nil }
        let project = AgentProject(
            name: trimmed,
            tasks: [],
            workingDirectory: workingDirectory)
        guard commitMutation({ projects.append(project) }) else { return nil }
        return project.id
    }

    @discardableResult
    func removeProject(id: UUID) -> Bool {
        guard projects.contains(where: { $0.id == id }) else { return false }
        return commitMutation { projects.removeAll { $0.id == id } }
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
        return commitMutation { projects[i].name = trimmed }
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
        guard commitMutation({ projects[pi].tasks.append(task) }) else { return nil }
        return task.id
    }

    @discardableResult
    func removeTask(projectId: UUID, taskId: UUID) -> Bool {
        guard let pi = projects.firstIndex(where: { $0.id == projectId }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.id == taskId })
        else { return false }
        return commitMutation { projects[pi].tasks.remove(at: ti) }
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
        return commitMutation { projects[pi].tasks[ti].name = trimmed }
    }

    // MARK: - Agents (UUID-based)

    /// Add agent, returning the created entry. Trims whitespace and rejects empty names.
    @discardableResult
    func addAgent(project: String, task: String, name: String) -> AgentEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.name == task }),
              !trimmed.isEmpty,
              !projects[pi].tasks[ti].agents.contains(where: {
                  $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
              })
        else { return nil }
        let entry = AgentEntry(id: UUID(), name: trimmed)
        guard commitMutation({ projects[pi].tasks[ti].agents.append(entry) }) else { return nil }
        return entry
    }

    /// Add a pre-built entry (e.g., for fork with specific UUID).
    @discardableResult
    func addAgent(_ entry: AgentEntry, project: String, task: String) -> Bool {
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.name == task }),
              !projects[pi].tasks[ti].agents.contains(where: { $0.id == entry.id })
        else { return false }
        return commitMutation { projects[pi].tasks[ti].agents.append(entry) }
    }

    @discardableResult
    func removeAgent(id: UUID) -> Bool {
        guard allAgentEntries.contains(where: { $0.id == id }) else { return false }
        return commitMutation {
            for pi in projects.indices {
                for ti in projects[pi].tasks.indices {
                    projects[pi].tasks[ti].agents.removeAll { $0.id == id }
                }
            }
        }
    }

    @discardableResult
    func renameAgent(id: UUID, newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        for pi in projects.indices {
            for ti in projects[pi].tasks.indices {
                if let ai = projects[pi].tasks[ti].agents.firstIndex(where: { $0.id == id }) {
                    guard !projects[pi].tasks[ti].agents.contains(where: {
                        $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                    }) else { return false }
                    return commitMutation {
                        projects[pi].tasks[ti].agents[ai].name = trimmed
                    }
                }
            }
        }
        return false
    }

    @discardableResult
    func setWorkingDirectory(_ path: String, forProject id: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return false }
        return commitMutation { projects[index].workingDirectory = path }
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

    static let hookScript = """
        #!/bin/sh
        [ -z "$GHOSTTY_AGENT_NAME" ] && cat > /dev/null && exit 0
        DIR="${GHOSTTY_AGENT_STATUS_DIR:-$HOME/.config/ghostty-agents/status}"
        mkdir -p "$DIR" 2>/dev/null
        INPUT_FLAT=$(cat | tr -d '\\n')
        SID=$(echo "$INPUT_FLAT" | sed -n 's/.*"session_id" *: *"\\([^"]*\\)".*/\\1/p')
        EVENT=$(echo "$INPUT_FLAT" | sed -n 's/.*"hook_event_name" *: *"\\([^"]*\\)".*/\\1/p')
        if [ -n "$SID" ]; then
            echo "$SID" > "$DIR/$GHOSTTY_AGENT_NAME.session.$$"
            mv "$DIR/$GHOSTTY_AGENT_NAME.session.$$" "$DIR/$GHOSTTY_AGENT_NAME.session"
        fi
        LOCK="$DIR/$GHOSTTY_AGENT_NAME.events.lock"
        EVENTS="$DIR/$GHOSTTY_AGENT_NAME.events"
        EVENT_LINE="{\\"hook_event_name\\":\\"$EVENT\\",\\"session_id\\":\\"$SID\\"}"
        export EVENTS EVENT_LINE
        /usr/bin/lockf -s -t 5 -k "$LOCK" /bin/sh -c 'printf "%s\\n" "$EVENT_LINE" >> "$EVENTS"'
        """

    private static let hookedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "Stop", "StopFailure",
        "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "SessionEnd",
    ]

    private func ensureHookScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.hooksDir, withIntermediateDirectories: true)

        let url = Self.hooksDir.appendingPathComponent("clawddy-hook.sh")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if existing == Self.hookScript { return }

        try Self.hookScript.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        // Clean old per-event scripts
        for old in ["on-session-start.sh", "on-prompt.sh", "on-tool.sh",
                     "on-permission.sh", "on-stop.sh", "on-error.sh"] {
            try? fm.removeItem(at: Self.hooksDir.appendingPathComponent(old))
        }
    }

    private static var claudeSettingsURL: URL {
        claudeConfigDir.appendingPathComponent("settings.json")
    }

    static func hooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any]
        else { return false }
        let expectedPath = hooksDir.appendingPathComponent("clawddy-hook.sh").path
        return hookedEvents.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let commands = group["hooks"] as? [[String: Any]] else { return false }
                return commands.contains { ($0["command"] as? String) == expectedPath }
            }
        }
    }

    private func installHooks() throws {
        let fm = FileManager.default
        let url = Self.claudeSettingsURL

        // Ensure .claude directory exists
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            settings = json
        }

        // Backup
        let backupURL = url.deletingLastPathComponent().appendingPathComponent("settings.json.clawddy-backup")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: url, to: backupURL)
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
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Private

    private func ensureDirs() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: Self.baseDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(
            at: Self.statusDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.baseDir.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.statusDir.path)
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

    @discardableResult
    static func atomicWrite(_ data: Data, to url: URL) -> Bool {
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
            return true
        } catch {
            logger.error("atomicWrite failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}

// Module-level convenience
@discardableResult
func atomicWrite(_ data: Data, to url: URL) -> Bool {
    AgentConfig.atomicWrite(data, to: url)
}
