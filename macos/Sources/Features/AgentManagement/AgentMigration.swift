import Foundation

// The migration of a Clawddy data root: `planAgentMigration` is a pure
// function of a snapshot of the root, and a thin IO layer reads the snapshot,
// backs up, and applies the plan in commit-point order. The format rules are
// in docs/clawddy-refactor/groundwork.md, section 2.

enum AgentMigrationMode: String, Codable, CaseIterable {
    /// Phase A switch-over: legacy bindings become `session.json`, and status
    /// files that no agent owns are deleted. `agents.json` stays schema 5.
    case cleanupV5
    /// Phase B: everything `cleanupV5` does, and tasks are flattened into
    /// schema 6.
    case flattenV6
    /// The dev identity's first start: a new root holding the Claude agents
    /// only, each with a fork marker in place of its binding.
    case seedDevCopy
}

/// The two workspace preferences that name tasks.
struct AgentWorkspaceDefaults: Codable, Equatable {
    var scope: String?
    var preferredAgents: [String: String]?
}

/// What the planner reads from a data root. Journals are never loaded whole.
struct AgentDataSnapshot {
    var agentsJSON: Data
    var stateJSON: Data?
    /// Every name in `status/`.
    var statusFileNames: [String]
    /// The configured agents' `.session`, `.session.json` and `.fork.json`
    /// files, by name.
    var bindingFiles: [String: Data]
    /// For each configured agent's journal, the bytes the app has not read
    /// yet: from its persisted offset to the end.
    var journalTails: [UUID: Data]
    /// Every name in `hooks/`.
    var hookFileNames: [String]
    var workspaceDefaults: AgentWorkspaceDefaults
}

struct AgentRename: Codable, Equatable {
    var agentID: UUID
    var from: String
    var to: String
}

enum AgentMigrationDeletionReason: String, Codable, CodingKeyRepresentable {
    /// A status file of an agent that is not in the configuration.
    case orphan
    /// A status file of schema 1, named after "<project>/<task>/<agent>".
    case v1
    /// A `.lastEvent` file. Nothing reads it.
    case lastEvent
    /// A legacy `.session` binding, replaced by `.session.json`.
    case legacySession
    /// A `.state` file. Nothing reads it.
    case legacyState
    /// A temporary file left by an interrupted write.
    case tempLeftover
    /// `hooks/clawddy-hook.sh`. No provider runs it.
    case legacyHook
}

/// Every count of one migration, written next to the data and into the backup.
struct AgentMigrationReport: Codable, Equatable {
    var mode: AgentMigrationMode
    /// Of the input `agents.json`.
    var schemaVersion: Int
    var projects: Int
    /// Tasks in the input; 0 for schema 6.
    var tasks: Int
    var sourceAgents: Int
    /// Agents in the resulting configuration, and their providers.
    var agents: Int
    var claudeAgents: Int
    var codexAgents: Int
    var sessionConversions: Int
    var forkMarkers: Int
    var renames: [AgentRename]
    var statusFiles: Int
    var deletions: [AgentMigrationDeletionReason: Int]
    /// Root-relative paths of files whose kind the migration does not know.
    /// They are kept.
    var unknownFiles: [String]
    var stateEntriesDropped: Int
}

struct AgentMigrationPlan: Equatable {
    /// The new `agents.json`, or nil when it stays. Written last of all
    /// writes: the commit point.
    var agentsJSON: Data?
    /// The new `state.json`, or nil when it stays.
    var stateJSON: Data?
    /// New files in `status/`, by name.
    var statusWrites: [String: Data]
    /// Root-relative paths, deleted after the commit point.
    var deletions: [String]
    /// New workspace preferences, or nil when they stay.
    var workspaceDefaults: AgentWorkspaceDefaults?
    var report: AgentMigrationReport

    var isEmpty: Bool {
        agentsJSON == nil && stateJSON == nil && statusWrites.isEmpty
            && deletions.isEmpty && workspaceDefaults == nil
    }
}

/// The data is not what the migration expects. It is thrown before anything
/// is written, and an operator must look: nothing is guessed.
struct AgentMigrationAbort: LocalizedError, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

// MARK: - Planning

/// Plans `mode` for the root `snapshot` was read from. Throws
/// `AgentMigrationAbort` on anything unexpected.
func planAgentMigration(
    _ snapshot: AgentDataSnapshot,
    mode: AgentMigrationMode
) throws -> AgentMigrationPlan {
    let config = try decodeConfig(snapshot.agentsJSON)
    let expected = mode == .flattenV6 ? [5, 6] : [5]
    guard expected.contains(config.schemaVersion) else {
        throw AgentMigrationAbort(
            "agents.json has schemaVersion \(config.schemaVersion); \(mode.rawValue) expects \(expected.map(String.init).joined(separator: " or ")).")
    }
    let agents = config.agents
    guard Set(agents.map(\.id)).count == agents.count else {
        throw AgentMigrationAbort("agents.json: an agent ID appears more than once.")
    }
    if case .v5(let v5) = config {
        try requireNoMovableV1Files(v5, statusFileNames: Set(snapshot.statusFileNames))
    }
    var bindings: [UUID: AgentBindings] = [:]
    for agent in agents {
        bindings[agent.id] = try readBindings(of: agent, snapshot: snapshot)
    }
    try requireTaggedJournalTails(snapshot, configured: Set(bindings.keys))
    let state = try decodeState(snapshot.stateJSON)

    if mode == .seedDevCopy, case .v5(let v5) = config {
        return try planSeed(snapshot, config: v5, bindings: bindings, state: state)
    }
    return try planInPlace(snapshot, mode: mode, config: config, bindings: bindings, state: state)
}

private func planInPlace(
    _ snapshot: AgentDataSnapshot,
    mode: AgentMigrationMode,
    config: ConfigFormat,
    bindings: [UUID: AgentBindings],
    state: StateFormat
) throws -> AgentMigrationPlan {
    var statusWrites: [String: Data] = [:]
    for agent in config.agents {
        guard let sessionID = bindings[agent.id]?.legacyOnlySessionID else { continue }
        statusWrites["\(agent.id.uuidString).session.json"] = try encodeFile(AgentSessionBinding(
            provider: .claudeCode,
            sessionID: sessionID,
            launchGeneration: nil))
    }

    var deletions: [String] = []
    var deletionCounts: [AgentMigrationDeletionReason: Int] = [:]
    var unknownFiles: [String] = []
    func delete(_ path: String, _ reason: AgentMigrationDeletionReason) {
        deletions.append(path)
        deletionCounts[reason, default: 0] += 1
    }
    for name in snapshot.statusFileNames.sorted() {
        let (agentID, kind) = classifyStatusFile(name)
        if kind == .unknown {
            unknownFiles.append("status/\(name)")
        } else if let reason = deletionReason(kind, isOrphan: agentID.map { bindings[$0] == nil } ?? false) {
            delete("status/\(name)", reason)
        }
    }
    for name in snapshot.hookFileNames.sorted() {
        switch name {
        case "clawddy-provider-hook.sh", "clawddy-statusline-proxy.sh": break
        case "clawddy-hook.sh": delete("hooks/\(name)", .legacyHook)
        default: unknownFiles.append("hooks/\(name)")
        }
    }

    let cleanedState = state.keeping(Set(bindings.keys))
    let stateEntriesDropped = state.entryCount - cleanedState.entryCount
    let stateJSON = try stateEntriesDropped == 0 ? nil : encodeFile(cleanedState)

    var agentsJSON: Data?
    var renames: [AgentRename] = []
    var workspaceDefaults: AgentWorkspaceDefaults?
    if mode == .flattenV6 {
        if case .v5(let v5) = config {
            let flattened = flatten(v5)
            agentsJSON = try encodeFile(flattened.config)
            renames = flattened.renames
        }
        workspaceDefaults = try flattenWorkspaceDefaults(snapshot.workspaceDefaults)
    }

    return AgentMigrationPlan(
        agentsJSON: agentsJSON,
        stateJSON: stateJSON,
        statusWrites: statusWrites,
        deletions: deletions,
        workspaceDefaults: workspaceDefaults,
        report: AgentMigrationReport(
            mode: mode,
            schemaVersion: config.schemaVersion,
            projects: config.projectCount,
            tasks: config.taskCount,
            sourceAgents: config.agents.count,
            agents: config.agents.count,
            claudeAgents: config.agents.filter { $0.provider == .claudeCode }.count,
            codexAgents: config.agents.filter { $0.provider == .codex }.count,
            sessionConversions: statusWrites.count,
            forkMarkers: 0,
            renames: renames,
            statusFiles: snapshot.statusFileNames.count,
            deletions: deletionCounts,
            unknownFiles: unknownFiles,
            stateEntriesDropped: stateEntriesDropped))
}

/// The Claude agents only, in their tasks; each bound agent gets a fork
/// marker of its session, so the dev copy never resumes a live session.
/// Unread completions are copied; nothing else of the state, no journal,
/// metadata, runtime file or hook.
private func planSeed(
    _ snapshot: AgentDataSnapshot,
    config: ConfigV5,
    bindings: [UUID: AgentBindings],
    state: StateFormat
) throws -> AgentMigrationPlan {
    var seeded = config
    for projectIndex in seeded.projects.indices {
        for taskIndex in seeded.projects[projectIndex].tasks.indices {
            seeded.projects[projectIndex].tasks[taskIndex].agents.removeAll {
                $0.provider != .claudeCode
            }
        }
    }
    let seededAgents = seeded.projects.flatMap { $0.tasks.flatMap(\.agents) }
    var statusWrites: [String: Data] = [:]
    for agent in seededAgents {
        guard let source = bindings[agent.id]?.forkSource else { continue }
        statusWrites["\(agent.id.uuidString).fork.json"] = try encodeFile(AgentPendingFork(
            provider: .claudeCode,
            sourceSessionID: source))
    }
    let seededState = StateFormat(
        unreadCompletions: (state.unreadCompletions ?? FlatPairs([]))
            .keeping(Set(seededAgents.map(\.id))))

    return AgentMigrationPlan(
        agentsJSON: try encodeFile(seeded),
        stateJSON: try encodeFile(seededState),
        statusWrites: statusWrites,
        deletions: [],
        workspaceDefaults: nil,
        report: AgentMigrationReport(
            mode: .seedDevCopy,
            schemaVersion: seeded.schemaVersion,
            projects: seeded.projects.count,
            tasks: seeded.projects.map(\.tasks.count).reduce(0, +),
            sourceAgents: ConfigFormat.v5(config).agents.count,
            agents: seededAgents.count,
            claudeAgents: seededAgents.count,
            codexAgents: 0,
            sessionConversions: 0,
            forkMarkers: statusWrites.count,
            renames: [],
            statusFiles: snapshot.statusFileNames.count,
            deletions: [:],
            unknownFiles: [],
            stateEntriesDropped: state.entryCount - seededState.entryCount))
}

/// Schema 6: each project's agents in task order, then insertion order;
/// empty tasks vanish, empty projects stay. A name equal ignoring case to
/// an earlier one becomes "<name> (<task>)", then "<name> (<task>) 2" and
/// so on while that is taken or is another agent's original name.
private func flatten(_ config: ConfigV5) -> (config: ConfigV6, renames: [AgentRename]) {
    func sameName(_ a: String, _ b: String) -> Bool {
        a.localizedCaseInsensitiveCompare(b) == .orderedSame
    }
    var renames: [AgentRename] = []
    let projects = config.projects.map { project -> ProjectV6 in
        let originalNames = project.tasks.flatMap { $0.agents.map(\.name) }
        var agents: [AgentFormat] = []
        for task in project.tasks {
            for var agent in task.agents {
                if agents.contains(where: { sameName($0.name, agent.name) }) {
                    let base = "\(agent.name) (\(task.name))"
                    var candidate = base
                    var number = 2
                    while (agents.map(\.name) + originalNames).contains(where: { sameName($0, candidate) }) {
                        candidate = "\(base) \(number)"
                        number += 1
                    }
                    renames.append(AgentRename(agentID: agent.id, from: agent.name, to: candidate))
                    agent.name = candidate
                }
                agents.append(agent)
            }
        }
        return ProjectV6(
            id: project.id,
            name: project.name,
            workingDirectory: project.workingDirectory,
            agents: agents)
    }
    return (ConfigV6(schemaVersion: 6, projects: projects), renames)
}

/// Schema 6 has no tasks: a task scope becomes its project's scope, and the
/// per-task preferred agents go.
private func flattenWorkspaceDefaults(
    _ defaults: AgentWorkspaceDefaults
) throws -> AgentWorkspaceDefaults? {
    var result = defaults
    if let scope = defaults.scope, scope.hasPrefix("task:") {
        let parts = scope.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw AgentMigrationAbort("The workspace scope \"\(scope)\" is not task:<project>:<task>.")
        }
        result.scope = "project:\(parts[1])"
    }
    result.preferredAgents = defaults.preferredAgents?.filter { !$0.key.hasPrefix("task:") }
    return result == defaults ? nil : result
}

// MARK: - Preflight

/// One configured agent's persisted identity, decoded and checked.
private struct AgentBindings {
    var tagged: AgentSessionBinding?
    var legacySessionID: String?
    var pendingFork: AgentPendingFork?

    /// The legacy binding of an agent that has no tagged one: it is
    /// converted. Where both exist, the tagged one wins.
    var legacyOnlySessionID: String? { tagged == nil ? legacySessionID : nil }

    var forkSource: String? {
        tagged?.sessionID ?? legacySessionID ?? pendingFork?.sourceSessionID
    }
}

private func readBindings(
    of agent: AgentFormat,
    snapshot: AgentDataSnapshot
) throws -> AgentBindings {
    let id = agent.id.uuidString
    if snapshot.statusFileNames.contains("\(id).forkFrom") {
        throw AgentMigrationAbort("status/\(id).forkFrom: a legacy fork marker, which the app no longer reads.")
    }
    func check(_ sessionID: String, _ provider: AgentProviderID, file: String) throws {
        guard AgentSessionStore.valid(sessionID) else {
            throw AgentMigrationAbort("\(file): \"\(sessionID)\" is not a valid session ID.")
        }
        guard provider == agent.provider else {
            throw AgentMigrationAbort("\(file): a \(provider.rawValue) binding of a \(agent.provider.rawValue) agent.")
        }
    }
    var bindings = AgentBindings()
    if let data = snapshot.bindingFiles["\(id).session.json"] {
        let file = "status/\(id).session.json"
        let binding = try decodeExactly(AgentSessionBinding.self, from: data, file: file)
        try check(binding.sessionID, binding.provider, file: file)
        bindings.tagged = binding
    }
    if let data = snapshot.bindingFiles["\(id).session"] {
        let file = "status/\(id).session"
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw AgentMigrationAbort("\(file) is not UTF-8 text.")
        }
        // Legacy bindings predate provider support: they are all Claude's.
        let sessionID = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try check(sessionID, .claudeCode, file: file)
        bindings.legacySessionID = sessionID
    }
    if let data = snapshot.bindingFiles["\(id).fork.json"] {
        let file = "status/\(id).fork.json"
        let fork = try decodeExactly(AgentPendingFork.self, from: data, file: file)
        try check(fork.sourceSessionID, fork.provider, file: file)
        bindings.pendingFork = fork
    }
    return bindings
}

/// The app reads each journal from its persisted offset and drops a record
/// without a provider, which only the pre-provider hook wrote.
private func requireTaggedJournalTails(
    _ snapshot: AgentDataSnapshot,
    configured: Set<UUID>
) throws {
    let blank = Set(" \t\r".utf8)
    for (agentID, tail) in snapshot.journalTails where configured.contains(agentID) {
        let file = "status/\(agentID.uuidString).events"
        // The last piece is an unfinished line, or empty: the app waits for
        // its newline.
        for line in tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).dropLast() {
            guard !line.allSatisfy(blank.contains) else { continue }
            let record: Any
            do {
                record = try JSONSerialization.jsonObject(with: Data(line))
            } catch {
                throw AgentMigrationAbort("\(file): an unreadable record after the persisted offset: \(error.localizedDescription)")
            }
            guard let provider = (record as? [String: Any])?["provider"] as? String, !provider.isEmpty else {
                throw AgentMigrationAbort("\(file): a record without a provider after the persisted offset.")
            }
        }
    }
}

/// A schema 1 file of a configured agent whose UUID-keyed name is free is
/// that agent's only copy. The app no longer moves it to that name, and the
/// sweep would delete it.
private func requireNoMovableV1Files(_ config: ConfigV5, statusFileNames: Set<String>) throws {
    for project in config.projects {
        for task in project.tasks {
            for agent in task.agents {
                let key = "\(project.name)/\(task.name)/\(agent.name)"
                    .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
                for ext in v1Extensions
                where statusFileNames.contains("\(key).\(ext)")
                    && !statusFileNames.contains("\(agent.id.uuidString).\(ext)") {
                    throw AgentMigrationAbort(
                        "status/\(key).\(ext) is a schema 1 file of agent \(agent.id.uuidString) with no UUID-keyed copy.")
                }
            }
        }
    }
}

// MARK: - Status files

private let v1Extensions = [
    "session", "session.json", "state", "heartbeat", "forkFrom",
    "fork.json", "lastEvent", "events", "events.lock", "json", "metadata.json",
]

private enum StatusKind {
    /// `events`, `events.lock`, `session.json`, `fork.json`, `metadata.json`.
    case current
    case legacySession
    case legacyFork
    case lastEvent
    case legacyState
    case tempLeftover
    case v1
    case unknown
}

/// The agent a status file belongs to, when its name starts with a UUID,
/// and its kind.
private func classifyStatusFile(_ name: String) -> (agentID: UUID?, kind: StatusKind) {
    let agentID = UUID(uuidString: String(name.prefix(36)))
    let suffix = agentID == nil ? "" : String(name.dropFirst(36))
    // The hook scripts write `<id>.session.<pid>.tmp` and
    // `<id>.metadata.<pid>.tmp`; an older one wrote `<id>.session.<pid>`.
    let pid = suffix.dropFirst(".session.".count)
    if name.hasSuffix(".tmp") || name.hasPrefix("clawddy-hook-")
        || (suffix.hasPrefix(".session.") && !pid.isEmpty && pid.allSatisfy(\.isNumber)) {
        return (agentID, .tempLeftover)
    }
    guard let agentID else {
        return (nil, v1Extensions.contains { name.hasSuffix(".\($0)") } ? .v1 : .unknown)
    }
    switch suffix {
    case ".events", ".events.lock", ".session.json", ".fork.json", ".metadata.json":
        return (agentID, .current)
    case ".session": return (agentID, .legacySession)
    case ".forkFrom": return (agentID, .legacyFork)
    case ".lastEvent": return (agentID, .lastEvent)
    case ".state": return (agentID, .legacyState)
    default: return (agentID, .unknown)
    }
}

/// Why a status file is deleted, or nil when it stays. Unknown kinds always
/// stay. A configured agent's legacy fork marker never gets here: the
/// preflight aborts on it.
private func deletionReason(_ kind: StatusKind, isOrphan: Bool) -> AgentMigrationDeletionReason? {
    if kind == .unknown { return nil }
    if isOrphan { return .orphan }
    switch kind {
    case .current, .legacyFork, .unknown: return nil
    case .legacySession: return .legacySession
    case .lastEvent: return .lastEvent
    case .legacyState: return .legacyState
    case .tempLeftover: return .tempLeftover
    case .v1: return .v1
    }
}

// MARK: - Formats

// The migration's own models of the files it rewrites, with every key that
// the live data always has required. They do not follow the app's decoders,
// so they keep reading schema 5 after the app moves on. A project's
// `workingDirectory` is optional: `addProject` writes a project without one
// when none is chosen, and the key is then absent, never null.

private struct LaunchProfileFormat: Codable {
    var modelID: String?
    var reasoningEffort: String?
    var startMode: AgentStartMode
}

private struct AgentFormat: Codable {
    var id: UUID
    var name: String
    var provider: AgentProviderID
    var launchProfile: LaunchProfileFormat
}

private struct TaskFormat: Codable {
    var id: UUID
    var name: String
    var agents: [AgentFormat]
}

private struct ProjectV5: Codable {
    var id: UUID
    var name: String
    var workingDirectory: String?
    var tasks: [TaskFormat]
}

private struct ProjectV6: Codable {
    var id: UUID
    var name: String
    var workingDirectory: String?
    var agents: [AgentFormat]
}

private struct ConfigV5: Codable {
    var schemaVersion: Int
    var projects: [ProjectV5]
}

private struct ConfigV6: Codable {
    var schemaVersion: Int
    var projects: [ProjectV6]
}

private enum ConfigFormat {
    case v5(ConfigV5)
    case v6(ConfigV6)

    var schemaVersion: Int {
        switch self {
        case .v5(let config): return config.schemaVersion
        case .v6(let config): return config.schemaVersion
        }
    }

    var projectCount: Int {
        switch self {
        case .v5(let config): return config.projects.count
        case .v6(let config): return config.projects.count
        }
    }

    var taskCount: Int {
        switch self {
        case .v5(let config): return config.projects.map(\.tasks.count).reduce(0, +)
        case .v6: return 0
        }
    }

    var agents: [AgentFormat] {
        switch self {
        case .v5(let config): return config.projects.flatMap { $0.tasks.flatMap(\.agents) }
        case .v6(let config): return config.projects.flatMap(\.agents)
        }
    }
}

private func decodeConfig(_ data: Data) throws -> ConfigFormat {
    struct SchemaVersion: Decodable { var schemaVersion: Int }
    let version = try decode(SchemaVersion.self, from: data, file: "agents.json").schemaVersion
    switch version {
    case 5: return .v5(try decodeExactly(ConfigV5.self, from: data, file: "agents.json"))
    case 6: return .v6(try decodeExactly(ConfigV6.self, from: data, file: "agents.json"))
    default: throw AgentMigrationAbort("agents.json has schemaVersion \(version); the migration knows 5 and 6.")
    }
}

/// A `[UUID: Value]` as JSONEncoder writes it, `[key, value, key, value, …]`,
/// kept in file order.
private struct FlatPairs<Value: Codable>: Codable {
    var pairs: [(key: UUID, value: Value)]

    init(_ pairs: [(key: UUID, value: Value)]) {
        self.pairs = pairs
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        pairs = []
        while !container.isAtEnd {
            let key = try container.decode(UUID.self)
            guard !pairs.contains(where: { $0.key == key }) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "\(key.uuidString) appears more than once")
            }
            let value = try container.decode(Value.self)
            pairs.append((key, value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for (key, value) in pairs {
            try container.encode(key)
            try container.encode(value)
        }
    }

    func keeping(_ ids: Set<UUID>) -> FlatPairs {
        FlatPairs(pairs.filter { ids.contains($0.key) })
    }
}

/// `state.json`. The engine steps that drop fields from it also drop them here.
private struct StateFormat: Codable {
    var unreadCompletions: FlatPairs<AgentCompletionID>?
    var lastAppliedCompletions: FlatPairs<AgentCompletionID>?
    var pendingRenames: FlatPairs<String>?
    var eventOffsets: FlatPairs<Int>?

    var entryCount: Int {
        (unreadCompletions?.pairs.count ?? 0) + (lastAppliedCompletions?.pairs.count ?? 0)
            + (pendingRenames?.pairs.count ?? 0) + (eventOffsets?.pairs.count ?? 0)
    }

    func keeping(_ ids: Set<UUID>) -> StateFormat {
        StateFormat(
            unreadCompletions: unreadCompletions?.keeping(ids),
            lastAppliedCompletions: lastAppliedCompletions?.keeping(ids),
            pendingRenames: pendingRenames?.keeping(ids),
            eventOffsets: eventOffsets?.keeping(ids))
    }
}

private func decodeState(_ data: Data?) throws -> StateFormat {
    guard let data else { return StateFormat() }
    return try decodeExactly(StateFormat.self, from: data, file: "state.json")
}

private func decode<T: Decodable>(_ type: T.Type, from data: Data, file: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw AgentMigrationAbort("\(file): \(AgentConfig.describeLoadFailure(error))")
    }
}

/// Decodes `data` and proves that `T` holds all of it: encoding the value
/// back must give the same JSON. A missing key, a null, an unknown key or a
/// value of another type aborts, naming its path.
private func decodeExactly<T: Codable>(_ type: T.Type, from data: Data, file: String) throws -> T {
    let value = try decode(type, from: data, file: file)
    let original = try JSONSerialization.jsonObject(with: data)
    let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    if let path = firstDifference(original, reencoded, path: "") {
        throw AgentMigrationAbort("\(file): \(path.isEmpty ? "the top level" : path) is not in the format the migration knows.")
    }
    return value
}

/// The path of the first place where two parsed JSON values differ, or nil
/// when they are equal.
private func firstDifference(_ a: Any, _ b: Any, path: String) -> String? {
    switch (a, b) {
    case let (a as [String: Any], b as [String: Any]):
        for key in Set(a.keys).union(b.keys).sorted() {
            let keyPath = path.isEmpty ? key : "\(path).\(key)"
            guard let x = a[key], let y = b[key] else { return keyPath }
            if let difference = firstDifference(x, y, path: keyPath) { return difference }
        }
        return nil
    case let (a as [Any], b as [Any]):
        guard a.count == b.count else { return path }
        for (index, (x, y)) in zip(a, b).enumerated() {
            if let difference = firstDifference(x, y, path: "\(path)[\(index)]") { return difference }
        }
        return nil
    default:
        return (a as AnyObject).isEqual(b) ? nil : path
    }
}

/// The style of the app's `agents.json` and bindings. Sorted keys also make
/// every plan byte-for-byte reproducible, which the backup check relies on.
private func encodeFile<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
}

// MARK: - IO

extension AgentDataSnapshot {
    /// Reads what the planner needs from `root`. Every open is read-only.
    static func read(from root: AgentDataRoot, defaults: UserDefaults?) throws -> AgentDataSnapshot {
        let fm = FileManager.default
        let agentsJSON = try Data(contentsOf: root.agentsFile)
        let stateJSON = try fm.fileExists(atPath: root.stateFile.path)
            ? Data(contentsOf: root.stateFile) : nil
        let statusFileNames = try fm.contentsOfDirectory(atPath: root.statusDir.path)
        let hookFileNames = try fm.fileExists(atPath: root.hooksDir.path)
            ? fm.contentsOfDirectory(atPath: root.hooksDir.path) : []
        let names = Set(statusFileNames)
        let offsets = Dictionary(
            uniqueKeysWithValues: (try decodeState(stateJSON).eventOffsets?.pairs ?? []).map { ($0.key, $0.value) })
        var bindingFiles: [String: Data] = [:]
        var journalTails: [UUID: Data] = [:]
        for agent in try decodeConfig(agentsJSON).agents {
            let id = agent.id.uuidString
            for name in ["\(id).session", "\(id).session.json", "\(id).fork.json"] where names.contains(name) {
                bindingFiles[name] = try Data(contentsOf: root.statusDir.appendingPathComponent(name))
            }
            if names.contains("\(id).events") {
                journalTails[agent.id] = try unreadBytes(
                    of: root.statusDir.appendingPathComponent("\(id).events"),
                    from: offsets[agent.id] ?? 0)
            }
        }
        return AgentDataSnapshot(
            agentsJSON: agentsJSON,
            stateJSON: stateJSON,
            statusFileNames: statusFileNames,
            bindingFiles: bindingFiles,
            journalTails: journalTails,
            hookFileNames: hookFileNames,
            workspaceDefaults: AgentWorkspaceDefaults(
                scope: defaults?.string(forKey: AgentWorkspaceModel.DefaultsKey.scope),
                preferredAgents: defaults?.dictionary(
                    forKey: AgentWorkspaceModel.DefaultsKey.preferredAgents) as? [String: String]))
    }
}

/// The journal bytes the app has not read: from `offset` to the end, or the
/// whole file when `offset` lies past the end, as the bridge does.
private func unreadBytes(of journal: URL, from offset: Int) throws -> Data {
    guard offset >= 0 else {
        throw AgentMigrationAbort("state.json: the offset of status/\(journal.lastPathComponent) is negative.")
    }
    let handle = try FileHandle(forReadingFrom: journal)
    let size = try handle.seekToEnd()
    try handle.seek(toOffset: UInt64(offset) <= size ? UInt64(offset) : 0)
    let data = try handle.readToEnd() ?? Data()
    try handle.close()
    return data
}

/// A point in the apply order after which a test can inject a failure.
enum AgentMigrationStep {
    case statusWrites, state, agents, deletions
}

/// Runs `cleanupV5` or `flattenV6` on `root`. It takes the root's lock, so
/// no Clawddy instance is using the root; plans, so unexpected data aborts
/// before any write; copies the root without `cron/` into `backupDir`, which
/// must not exist yet, and proves that the copy reproduces the plan; then
/// applies the plan in commit-point order and writes the report into the
/// root and the backup.
@discardableResult
func migrateAgentDataInPlace(
    root: AgentDataRoot,
    mode: AgentMigrationMode,
    backupDir: URL,
    defaults: UserDefaults?,
    afterStep: (AgentMigrationStep) throws -> Void = { _ in }
) throws -> AgentMigrationReport {
    precondition(mode != .seedDevCopy, "seedDevCopy writes a new root; use seedAgentDevCopy.")
    return try root.withLock {
        let snapshot = try AgentDataSnapshot.read(from: root, defaults: defaults)
        let plan = try planAgentMigration(snapshot, mode: mode)
        try backUp(root, defaults: snapshot.workspaceDefaults, to: backupDir)
        let backupPlan = try planAgentMigration(
            AgentDataSnapshot.read(from: AgentDataRoot(url: backupDir), defaults: defaults),
            mode: mode)
        guard backupPlan == plan else {
            throw AgentMigrationAbort("The backup in \(backupDir.path) does not reproduce the plan; nothing was changed.")
        }
        try apply(plan, to: root, defaults: defaults, afterStep: afterStep)
        let reportFile = root.migrationReportFile(mode: mode)
        try FileManager.default.copyItem(
            at: reportFile,
            to: backupDir.appendingPathComponent(reportFile.lastPathComponent))
        return plan.report
    }
}

/// The dev seed: writes a new root at `destination` holding `source`'s
/// Claude agents, each with a fork marker in place of its binding, and their
/// unread completions. `source` is only read. The new root is built beside
/// `destination` and renamed into place, so an interrupted seed leaves no
/// partial root. Throws when `destination` exists.
@discardableResult
func seedAgentDevCopy(
    from source: AgentDataRoot,
    to destination: AgentDataRoot
) throws -> AgentMigrationReport {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: destination.url.path) else {
        throw AgentMigrationAbort("\(destination.url.path) already exists; delete it to seed again.")
    }
    let plan = try planAgentMigration(
        AgentDataSnapshot.read(from: source, defaults: nil),
        mode: .seedDevCopy)
    let staging = AgentDataRoot(url: destination.url.deletingLastPathComponent().appendingPathComponent(
        ".\(destination.url.lastPathComponent)-seeding-\(UUID().uuidString)",
        isDirectory: true))
    try fm.createDirectory(
        at: staging.statusDir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    try apply(plan, to: staging, defaults: nil) { _ in }
    try fm.moveItem(at: staging.url, to: destination.url)
    return plan.report
}

/// Copies every top-level item of `root` except agent-cron's folder, and the
/// workspace preferences the plan may change.
private func backUp(_ root: AgentDataRoot, defaults: AgentWorkspaceDefaults, to backupDir: URL) throws {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: backupDir.path) else {
        throw AgentMigrationAbort("The backup folder \(backupDir.path) already exists.")
    }
    try fm.createDirectory(
        at: backupDir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    for name in try fm.contentsOfDirectory(atPath: root.url.path)
    where name != root.cronDir.lastPathComponent {
        try fm.copyItem(
            at: root.url.appendingPathComponent(name),
            to: backupDir.appendingPathComponent(name))
    }
    try encodeFile(defaults).write(to: backupDir.appendingPathComponent("workspace-defaults.json"))
}

/// Additive writes first, `agents.json` last of the writes (the commit
/// point), deletions after it. A rerun after a failure at any step plans
/// what is left and ends in the same tree.
private func apply(
    _ plan: AgentMigrationPlan,
    to root: AgentDataRoot,
    defaults: UserDefaults?,
    afterStep: (AgentMigrationStep) throws -> Void
) throws {
    for (name, data) in plan.statusWrites {
        try data.write(to: root.statusDir.appendingPathComponent(name), options: .atomic)
    }
    try afterStep(.statusWrites)
    if let state = plan.stateJSON {
        try state.write(to: root.stateFile, options: .atomic)
    }
    try afterStep(.state)
    if let agents = plan.agentsJSON {
        try agents.write(to: root.agentsFile, options: .atomic)
    }
    try afterStep(.agents)
    for path in plan.deletions {
        try FileManager.default.removeItem(at: root.url.appendingPathComponent(path))
    }
    try afterStep(.deletions)
    if let workspaceDefaults = plan.workspaceDefaults, let defaults {
        defaults.set(workspaceDefaults.scope, forKey: AgentWorkspaceModel.DefaultsKey.scope)
        defaults.set(
            workspaceDefaults.preferredAgents,
            forKey: AgentWorkspaceModel.DefaultsKey.preferredAgents)
    }
    try encodeFile(plan.report).write(to: root.migrationReportFile(mode: plan.report.mode), options: .atomic)
}
