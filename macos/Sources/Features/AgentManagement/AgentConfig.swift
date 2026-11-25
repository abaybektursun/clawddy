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
}

struct AgentProject: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// In the order the user arranged them.
    var agents: [AgentEntry]
    var workingDirectory: String?

    init(id: UUID = UUID(), name: String, agents: [AgentEntry] = [], workingDirectory: String? = nil) {
        self.id = id
        self.name = name
        self.agents = agents
        self.workingDirectory = workingDirectory
    }
}

/// A structural configuration error. These are thrown instead of falling back
/// to an empty model: an unreadable entry must fail the whole load so the
/// previous in-memory model (and the on-disk bytes) survive, rather than
/// letting a later save persist the loss.
struct AgentConfigFormatError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AgentConfigFile: Codable {
    static let currentSchemaVersion = 6

    var schemaVersion: Int
    var projects: [AgentProject]
    /// Projects the person removed (flows.md 6.2): off the top bar, their
    /// agents settled and kept, nothing on disk deleted.
    var removedProjects: [AgentProject]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projects, removedProjects
    }

    init(projects: [AgentProject], removedProjects: [AgentProject] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.projects = projects
        self.removedProjects = removedProjects
    }

    /// Every key the app has always written is required, and only the
    /// current schema is read. The migration preflight aborts on any other
    /// shape, so the live data never needs an old format's defaults.
    /// `removedProjects` is absent from a file no project was ever removed
    /// from.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AgentConfigFormatError(
                message: "Configuration has schemaVersion \(schemaVersion); this version reads \(Self.currentSchemaVersion).")
        }
        projects = try container.decode([AgentProject].self, forKey: .projects)
        removedProjects = try container.decodeIfPresent([AgentProject].self, forKey: .removedProjects) ?? []
    }
}

// MARK: - Config Manager

@Observable
class AgentConfig {
    /// The projects in the top bar, in the person's order.
    var projects: [AgentProject] = []
    /// The projects the person removed: their agents stay, settled and
    /// findable, until a project comes back (`bringBack`).
    var removedProjects: [AgentProject] = []
    var errorMessage: String?
    var onReloaded: (() -> Void)?
    private var configDirWatcher: DispatchSourceFileSystemObject?
    /// What `agents.json` holds as far as we know: the bytes last read, or
    /// last written by a write that succeeded (never one that is only
    /// queued or failed). The directory watcher compares the file with it.
    private var lastConfigData: Data?
    /// A write of `agents.json` failed and none succeeded since: memory is
    /// newer than the file and stays the truth (last review ruling 1). The
    /// next change and quitting write it again; nothing reloads the file
    /// over it meanwhile.
    private(set) var unsaved = false
    /// Whether the last write of `agents.json` failed; touched only on
    /// `writes`, so quitting can know before the main thread hears of it.
    @ObservationIgnored private var lastWriteFailed = false
    /// Non-nil while the configuration file on disk could not be decoded. Writes
    /// are refused until a load succeeds so a malformed file is never replaced
    /// by a partial in-memory model.
    private var loadFailure: Error?
    @ObservationIgnored let root: AgentDataRoot
    /// Writes of `agents.json`, in the order of the changes, off the main
    /// thread (the records' rule, s7): quitting waits for them
    /// (`waitForWrites`).
    @ObservationIgnored private let writes = DispatchQueue(label: "com.mitchellh.ghostty.clawddy.agents-json")
    /// Writes queued and not yet done; the file watcher ignores the file
    /// meanwhile, so an earlier write never reloads over a newer model.
    @ObservationIgnored private var pendingWrites = 0

    private struct AccountIdentity: Sendable {
        var homeDirectory: URL
        var userName: String
    }

    /// Resolve the effective macOS account identity once from the user database.
    /// Provider CLIs use these conventional values to locate per-user config and
    /// credential records; the actual Keychain security identity remains the
    /// subprocess's inherited effective UID and audit session.
    private static let accountIdentity: AccountIdentity = {
        if let record = getpwuid(geteuid()) {
            let passwordRecord = record.pointee
            if let directory = passwordRecord.pw_dir,
               let userName = passwordRecord.pw_name {
                return AccountIdentity(
                    homeDirectory: URL(
                        fileURLWithPath: String(cString: directory),
                        isDirectory: true),
                    userName: String(cString: userName))
            }
        }
        return AccountIdentity(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            userName: NSUserName())
    }()

    static var accountHomeDirectory: URL { accountIdentity.homeDirectory }
    static var accountUserName: String { accountIdentity.userName }

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

    /// Every agent, those of removed projects too.
    var allAgentEntries: [AgentEntry] {
        (projects + removedProjects).flatMap(\.agents)
    }

    /// The configuration on disk was read, or there is none; false while it
    /// cannot be read, when `projects` is not what the file holds.
    var isLoaded: Bool { loadFailure == nil }

    var persistenceErrorMessage: String? {
        guard errorMessage?.hasPrefix("Agents configuration could not be saved") == true
        else { return nil }
        return errorMessage
    }

    init(root: AgentDataRoot) {
        self.root = root
        do {
            try ensureDirs()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("setup failed: \(error.localizedDescription)")
        }
        load()
        if FileManager.default.fileExists(atPath: root.url.path) {
            watchConfigDir()
        }
    }

    deinit {
        configDirWatcher?.cancel()
    }

    // MARK: - Load / Save

    func load() {
        guard FileManager.default.fileExists(atPath: root.agentsFile.path) else {
            // Nothing on disk can be clobbered, so a previous failure no longer
            // blocks writes (e.g. the user deleted the broken file).
            if loadFailure != nil {
                loadFailure = nil
                clearLoadErrorMessage()
            }
            return
        }
        do {
            let data = try Data(contentsOf: root.agentsFile)
            let config = try JSONDecoder().decode(AgentConfigFile.self, from: data)
            // Only a fully decoded file clears the failure and replaces the
            // observable model; a partial decode never reaches this point.
            loadFailure = nil
            lastConfigData = data
            projects = config.projects
            removedProjects = config.removedProjects
            errorMessage = nil
            let rebound = Self.enforcePersistedProviderBindings(in: &projects, statusDirectory: root.statusDir)
            if Self.enforcePersistedProviderBindings(in: &removedProjects, statusDirectory: root.statusDir) || rebound {
                save()
            }

            logger.info("load — \(config.projects.count) projects, \(self.allAgentEntries.count) agents")
            onReloaded?()
        } catch {
            // Keep the previous valid model and the raw file untouched. Saving
            // is blocked until a later load succeeds or the file is removed.
            loadFailure = error
            errorMessage = "Agents configuration could not be loaded: \(Self.describeLoadFailure(error))"
            logger.error("load failed: \(Self.describeLoadFailure(error))")
        }
    }

    /// Turns a decode failure into a message that names the offending record
    /// (for example `projects[0].agents[1].name`) so the user can fix
    /// the file instead of losing the agents it still contains.
    static func describeLoadFailure(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "\(codingPathDescription(context.codingPath + [key])) is missing"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "\(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private func clearLoadErrorMessage() {
        if errorMessage?.hasPrefix("Agents configuration could not be loaded") == true {
            errorMessage = nil
        }
    }

    private static func codingPathDescription(_ path: [CodingKey]) -> String {
        guard !path.isEmpty else { return "the configuration root" }
        var result = ""
        for key in path {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                if !result.isEmpty { result += "." }
                result += key.stringValue
            }
        }
        return result
    }

    /// A provider becomes part of an agent's durable identity as soon as a
    /// resumable session exists. This prevents an external
    /// config edit from attempting to resume one provider's session with
    /// another provider's CLI.
    @discardableResult
    static func enforcePersistedProviderBindings(
        in projects: inout [AgentProject],
        statusDirectory: URL
    ) -> Bool {
        var changed = false
        for projectIndex in projects.indices {
            for agentIndex in projects[projectIndex].agents.indices {
                let entry = projects[projectIndex].agents[agentIndex]
                let persisted: AgentProviderID?
                do {
                    persisted = try AgentSessionStore.persistedProvider(
                        for: entry.id,
                        directory: statusDirectory)
                } catch {
                    // The agent's next launch stops on the same file and
                    // shows why.
                    logger.error(
                        "provider identity of agent \(entry.id) not checked: \(error.localizedDescription)")
                    continue
                }
                guard let provider = persisted, provider != entry.provider else { continue }
                projects[projectIndex].agents[agentIndex] = AgentEntry(
                    id: entry.id,
                    name: entry.name,
                    provider: provider,
                    launchProfile: entry.launchProfile)
                changed = true
                logger.warning(
                    "restored provider identity for agent \(entry.id) to \(provider.rawValue)")
            }
        }
        return changed
    }

    @discardableResult
    func save() -> Bool {
        if let loadFailure {
            // Refuse to replace a file that failed to decode: the on-disk bytes
            // are the only copy of the entries this model does not contain.
            // A removed file has nothing left to protect.
            guard !FileManager.default.fileExists(atPath: root.agentsFile.path) else {
                let reason = Self.describeLoadFailure(loadFailure)
                errorMessage = "Agents configuration could not be saved because the existing configuration could not be loaded: \(reason)"
                logger.error("save blocked by load failure: \(reason)")
                return false
            }
            self.loadFailure = nil
            clearLoadErrorMessage()
        }
        logger.info("save — \(self.projects.count) projects")
        let config = AgentConfigFile(projects: projects, removedProjects: removedProjects)
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
        // A refusal over an unreadable file no longer holds.
        if errorMessage?.hasPrefix("Agents configuration could not be saved because") == true { errorMessage = nil }
        // Written in order on the write queue, never waited for on a key
        // (final review part 2). Only a write that succeeded says what the
        // file holds; a failed one leaves memory as the truth, shown to the
        // person until a later write succeeds (last review ruling 1).
        pendingWrites += 1
        let file = root.agentsFile
        writes.async { [weak self] in
            var failure: String?
            do {
                try Self.atomicWrite(data, to: file)
            } catch {
                failure = error.localizedDescription
                logger.error("save failed: \(error.localizedDescription)")
            }
            self?.lastWriteFailed = failure != nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingWrites -= 1
                if let failure {
                    self.unsaved = true
                    self.errorMessage = "Agents configuration could not be saved: \(failure)"
                } else {
                    self.lastConfigData = data
                    self.unsaved = false
                    if self.persistenceErrorMessage != nil { self.errorMessage = nil }
                }
                // An edit made by someone else while ours were queued is
                // noticed now that they are done.
                if self.pendingWrites == 0 { self.reloadIfChangedElsewhere() }
            }
        }
        return true
    }

    /// Returns once every queued write of `agents.json` is on disk: at quit,
    /// and before reading the file back. When the last write failed, what
    /// memory holds is written once more first.
    func waitForWrites() {
        if writes.sync(execute: { lastWriteFailed }) { save() }
        writes.sync {}
    }

    private func commitMutation(_ mutation: () -> Void) -> Bool {
        let previous = (projects, removedProjects)
        mutation()
        guard save() else {
            (projects, removedProjects) = previous
            return false
        }
        return true
    }

    // MARK: - Projects

    /// Add a project, at the end or directly after the project `previous`.
    /// Returns the new project's UUID on success, nil if empty or duplicate.
    @discardableResult
    func addProject(name: String, workingDirectory: String? = nil, after previous: UUID? = nil) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !(projects + removedProjects).contains(where: { $0.name == trimmed })
        else { return nil }
        let project = AgentProject(
            name: trimmed,
            workingDirectory: workingDirectory)
        let index = previous.flatMap { id in projects.firstIndex { $0.id == id } }.map { $0 + 1 } ?? projects.count
        guard commitMutation({ projects.insert(project, at: index) }) else { return nil }
        return project.id
    }

    /// Takes the project off the bar and keeps it, with its agents, among
    /// the removed projects (flows.md 6.2). Its place in the bar, for undo;
    /// nil when it is not in the bar or the save failed.
    @discardableResult
    func removeProject(id: UUID) -> Int? {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return nil }
        return commitMutation { removedProjects.append(projects.remove(at: index)) } ? index : nil
    }

    /// Puts a removed project back in the bar at `index` (its old place, for
    /// undo), else at the end. False when it is not removed or the save
    /// failed.
    @discardableResult
    func bringBack(project id: UUID, at index: Int? = nil) -> Bool {
        guard let removed = removedProjects.firstIndex(where: { $0.id == id }) else { return false }
        return commitMutation {
            let project = removedProjects.remove(at: removed)
            projects.insert(project, at: min(index ?? projects.count, projects.count))
        }
    }

    /// Moves the project to `index` in the bar's order (ruling 33), saved
    /// at once: the one order of projects, which everything reads. False
    /// when it is not in the bar or the save failed.
    @discardableResult
    func moveProject(id: UUID, to index: Int) -> Bool {
        guard let from = projects.firstIndex(where: { $0.id == id }) else { return false }
        let to = min(max(index, 0), projects.count - 1)
        guard from != to else { return true }
        return commitMutation { projects.insert(projects.remove(at: from), at: to) }
    }

    /// The project, in the bar or removed, whose folder is `path`.
    func project(atFolder path: String) -> AgentProject? {
        (projects + removedProjects).first { $0.workingDirectory == path }
    }

    // MARK: - Agents (UUID-based)

    /// Add an agent to the project, directly after its agent `previous`,
    /// else at the end, returning the created entry. Trims whitespace and
    /// rejects an empty name or one the project already has, ignoring case.
    @discardableResult
    func addAgent(
        project: String,
        name: String,
        provider: AgentProviderID = .claudeCode,
        launchProfile: AgentLaunchProfile = AgentLaunchProfile(),
        after previous: UUID? = nil
    ) -> AgentEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              !trimmed.isEmpty,
              !projects[pi].agents.contains(where: {
                  $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
              })
        else { return nil }
        let entry = AgentEntry(
            id: UUID(),
            name: trimmed,
            provider: provider,
            launchProfile: launchProfile)
        let index = previous
            .flatMap { id in projects[pi].agents.firstIndex { $0.id == id } }
            .map { $0 + 1 } ?? projects[pi].agents.endIndex
        guard commitMutation({ projects[pi].agents.insert(entry, at: index) }) else { return nil }
        return entry
    }

    /// Removes the agents in one save. False when none of them is here.
    @discardableResult
    func removeAgents(_ ids: Set<UUID>) -> Bool {
        guard allAgentEntries.contains(where: { ids.contains($0.id) }) else { return false }
        return commitMutation {
            for pi in projects.indices {
                projects[pi].agents.removeAll { ids.contains($0.id) }
            }
            for pi in removedProjects.indices {
                removedProjects[pi].agents.removeAll { ids.contains($0.id) }
            }
        }
    }

    @discardableResult
    func renameAgent(id: UUID, newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        for pi in projects.indices {
            // Two agents may have the same name (flows.md 4.3).
            if let ai = projects[pi].agents.firstIndex(where: { $0.id == id }) {
                return commitMutation {
                    projects[pi].agents[ai].name = trimmed
                }
            }
        }
        return false
    }

    /// Puts the project's agents in `ids`' order (flows.md 3.5), saved at
    /// once; `ids` must be exactly the project's agents. False when it is not
    /// or the save fails.
    @discardableResult
    func reorderAgents(in projectID: UUID, _ ids: [UUID]) -> Bool {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return false }
        let agents = projects[pi].agents
        guard Set(ids) == Set(agents.map(\.id)), ids.count == agents.count else { return false }
        guard ids != agents.map(\.id) else { return true }
        let byID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        return commitMutation {
            projects[pi].agents = ids.compactMap { byID[$0] }
        }
    }

    /// Restores the immutable provider identity after an external edit attempts
    /// to retarget an agent that already has runtime or session identity.
    @discardableResult
    func restoreProvider(id: UUID, provider: AgentProviderID) -> Bool {
        for pi in projects.indices {
            guard let ai = projects[pi].agents.firstIndex(where: { $0.id == id }) else { continue }
            let entry = projects[pi].agents[ai]
            guard entry.provider != provider else { return true }
            return commitMutation {
                projects[pi].agents[ai] = AgentEntry(
                    id: entry.id,
                    name: entry.name,
                    provider: provider,
                    launchProfile: entry.launchProfile)
            }
        }
        return false
    }

    /// The project holding this agent, in the bar or removed.
    func project(forAgent id: UUID) -> AgentProject? {
        (projects + removedProjects).first { $0.agents.contains { $0.id == id } }
    }

    /// The agent's project is removed.
    func isRemoved(project id: UUID) -> Bool {
        removedProjects.contains { $0.id == id }
    }

    // MARK: - Private

    private func ensureDirs() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(
            at: root.statusDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.url.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.statusDir.path)
    }

    /// Watch the config DIRECTORY (not the file). Handles atomic external edits
    /// that replace the inode, and fresh installs where the file doesn't exist yet.
    private func watchConfigDir() {
        let dirPath = root.url.path
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in self?.reloadIfChangedElsewhere() }
        source.setCancelHandler { close(fd) }
        source.resume()
        configDirWatcher = source
    }

    /// Reads `agents.json` again when it holds something other than what we
    /// know it holds: someone else edited it. Never while a write of ours
    /// is queued (it is checked again when they are done), and never while
    /// memory holds a change a failed write left unsaved.
    private func reloadIfChangedElsewhere() {
        guard pendingWrites == 0, !unsaved else { return }
        // Compare raw bytes (definitive — no hash collisions).
        let changed: Bool
        do {
            changed = try Data(contentsOf: root.agentsFile) != lastConfigData
        } catch CocoaError.fileReadNoSuchFile {
            changed = false
        } catch {
            // `load` reports why the file cannot be read.
            changed = true
        }
        guard changed else { return }
        load()
    }

    // MARK: - Atomic Write

    /// Replaces `url` with `data` in one step: the bytes go to a temporary
    /// file beside it, reach the disk, and only then take its place, keeping
    /// the permissions of the file they replace. Throws what failed; the
    /// temporary file of a failed write is removed.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try data.write(to: tmp)
            // The handle closes its descriptor when it is released, also
            // when `synchronize` throws.
            let handle = try FileHandle(forWritingTo: tmp)
            try handle.synchronize()
            try handle.close()
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItem(
                    at: url, withItemAt: tmp, backupItemName: nil, resultingItemURL: nil)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            do {
                try fm.removeItemIfPresent(at: tmp)
            } catch let cleanup {
                logger.error("could not remove \(tmp.path): \(cleanup.localizedDescription)")
            }
            throw error
        }
    }
}

extension FileManager {
    /// Removes the item at `url`. An item that is already gone is not an
    /// error; every other failure throws.
    func removeItemIfPresent(at url: URL) throws {
        do {
            try removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Gone already, which is what was asked for.
        }
    }
}
