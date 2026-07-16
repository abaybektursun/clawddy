import Foundation
import Observation
import os
import Darwin

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentConfig")

// MARK: - Data Model

struct AgentEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let provider: AgentProviderID
    var launchProfile: AgentLaunchProfile

    init(
        id: UUID = UUID(),
        name: String,
        provider: AgentProviderID = .claudeCode,
        launchProfile: AgentLaunchProfile = AgentLaunchProfile()
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.launchProfile = launchProfile
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, launchProfile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        // Every persisted agent created before provider support was a Claude
        // Code session. This default is the authoritative migration boundary.
        provider = try container.decodeIfPresent(AgentProviderID.self, forKey: .provider)
            ?? .claudeCode
        launchProfile = try container.decodeIfPresent(
            AgentLaunchProfile.self,
            forKey: .launchProfile) ?? AgentLaunchProfile()
    }
}

struct AgentProject: Codable, Identifiable, Sendable {
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

struct AgentTask: Codable, Identifiable, Sendable {
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

struct AgentConfigFile: Codable {
    static let currentSchemaVersion = 4

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
        resolveBaseDirectory(
            environment: ProcessInfo.processInfo.environment,
            defaultHomeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Resolve Clawddy's complete mutable data root. macOS does not guarantee
    /// that Foundation's home-directory APIs honor an inherited `HOME`, so a
    /// parallel app instance must use an explicit absolute override rather than
    /// relying on process environment emulation.
    static func resolveBaseDirectory(
        environment: [String: String],
        defaultHomeDirectory: URL
    ) -> URL {
        let fallback = defaultHomeDirectory
            .appendingPathComponent(".config/ghostty-agents", isDirectory: true)
        guard let rawValue = environment["GHOSTTY_AGENT_DATA_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty
        else { return fallback }

        let expanded = (rawValue as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return fallback }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
    /// The macOS account home from the user database. Terminal processes need
    /// this value so system services such as the login Keychain resolve in the
    /// same user context even when the app itself is launched with an isolated
    /// home directory.
    static var accountHomeDirectory: URL {
        if let record = getpwuid(getuid()),
           let directory = record.pointee.pw_dir {
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

    /// Codex stores configuration, authentication, sessions, and hooks under
    /// CODEX_HOME. Match the account's normal installation unless the caller
    /// explicitly selected another Codex home.
    static var codexConfigDir: URL {
        explicitCodexConfigDir ?? accountHomeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static var codexConfigEnvironmentOverride: URL? {
        explicitCodexConfigDir
    }

    private static var explicitCodexConfigDir: URL? {
        guard let rawValue = ProcessInfo.processInfo.environment["CODEX_HOME"]?
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
            let restoredProviderIdentity = Self.enforcePersistedProviderBindings(
                in: &projects,
                statusDirectory: Self.statusDir)

            if config.schemaVersion < AgentConfigFile.currentSchemaVersion
                || restoredProviderIdentity {
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
                    for ext in [
                        "session", "session.json", "state", "heartbeat", "forkFrom",
                        "fork.json", "lastEvent", "events", "events.lock", "json", "metadata.json",
                    ] {
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

    /// A provider becomes part of an agent's durable identity as soon as a
    /// resumable session or pending fork exists. This prevents an external
    /// config edit from attempting to resume one provider's session with
    /// another provider's CLI.
    @discardableResult
    static func enforcePersistedProviderBindings(
        in projects: inout [AgentProject],
        statusDirectory: URL
    ) -> Bool {
        var changed = false
        for projectIndex in projects.indices {
            for taskIndex in projects[projectIndex].tasks.indices {
                for agentIndex in projects[projectIndex].tasks[taskIndex].agents.indices {
                    let entry = projects[projectIndex].tasks[taskIndex].agents[agentIndex]
                    guard let provider = AgentSessionStore.persistedProvider(
                        for: entry.id,
                        directory: statusDirectory),
                          provider != entry.provider
                    else { continue }
                    projects[projectIndex].tasks[taskIndex].agents[agentIndex] = AgentEntry(
                        id: entry.id,
                        name: entry.name,
                        provider: provider,
                        launchProfile: entry.launchProfile)
                    changed = true
                    logger.warning(
                        "restored provider identity for agent \(entry.id) to \(provider.rawValue)")
                }
            }
        }
        return changed
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
    func addAgent(
        project: String,
        task: String,
        name: String,
        provider: AgentProviderID = .claudeCode,
        launchProfile: AgentLaunchProfile = AgentLaunchProfile()
    ) -> AgentEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.name == task }),
              !trimmed.isEmpty,
              !projects[pi].tasks[ti].agents.contains(where: {
                  $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
              })
        else { return nil }
        let entry = AgentEntry(
            id: UUID(),
            name: trimmed,
            provider: provider,
            launchProfile: launchProfile)
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

    /// Restores the immutable provider identity after an external edit attempts
    /// to retarget an agent that already has runtime or session identity.
    @discardableResult
    func restoreProvider(id: UUID, provider: AgentProviderID) -> Bool {
        for pi in projects.indices {
            for ti in projects[pi].tasks.indices {
                guard let ai = projects[pi].tasks[ti].agents.firstIndex(where: {
                    $0.id == id
                }) else { continue }
                let entry = projects[pi].tasks[ti].agents[ai]
                guard entry.provider != provider else { return true }
                return commitMutation {
                    projects[pi].tasks[ti].agents[ai] = AgentEntry(
                        id: entry.id,
                        name: entry.name,
                        provider: provider,
                        launchProfile: entry.launchProfile)
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
            for t in p.tasks where t.agents.contains(where: { $0.id == id }) {
                return t
            }
        }
        return nil
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
