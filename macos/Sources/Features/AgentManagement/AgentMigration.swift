import Foundation
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentStateFold")

/// The one change older data still needs: the marks earlier builds kept in
/// `state.json` become the agents' records (`AgentRecord`), once.
enum AgentStateFold {
    /// `state.json` as earlier builds wrote it. Only the agents it names
    /// matter; what each unread completion was is not kept.
    private struct LegacyState: Decodable {
        var unreadCompletions: [UUID: AgentCompletionID]?
        var interrupted: Set<UUID>?
        var running: Set<UUID>?
        var autoNamed: Set<UUID>?
    }

    /// When the root holds `state.json`: writes a record for each agent of
    /// `agents` that has none, backs the file up beside the root, and removes
    /// it. Decisions of 2026-11-23: an agent that was neither running nor
    /// unread starts settled, findable but off home; one a quit interrupted
    /// is unread; the sentence and the instructions start empty, as no
    /// transcript is read. `lastActive` dates each record. Call holding the
    /// root's lock, before anything reads a record.
    ///
    /// Last review ruling 2: a `state.json` that cannot be read never stops
    /// the app from launching: it is moved to a backups folder under its own
    /// name, and the folder is returned for the person to be told. A record
    /// that cannot be read is left as it is, and only its agent goes without
    /// a folded record (the bridge shows that agent's problem). The fork
    /// markers older builds left (`<agent id>.fork.json`) are deleted: no
    /// build reads them.
    @discardableResult
    static func fold(
        root: AgentDataRoot,
        agents: [UUID],
        lastActive: (UUID) -> Date?,
        now: Date
    ) throws -> URL? {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.statusDir.path) {
            for name in try manager.contentsOfDirectory(atPath: root.statusDir.path) where name.hasSuffix(".fork.json") {
                try manager.removeItem(at: root.statusDir.appendingPathComponent(name))
            }
        }
        let data: Data
        do {
            data = try Data(contentsOf: root.stateFile)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        let state: LegacyState
        do {
            state = try JSONDecoder().decode(LegacyState.self, from: data)
        } catch {
            let backup = try moveToBackups(root: root, now: now)
            logger.error("state.json could not be read (\(AgentConfig.describeLoadFailure(error))); moved to \(backup.path)")
            return backup
        }
        let unread = Set((state.unreadCompletions ?? [:]).keys).union(state.interrupted ?? [])
        let running = state.running ?? []
        try manager.createDirectory(at: root.statusDir, withIntermediateDirectories: true)
        for id in agents {
            let existing: AgentRecord?
            do {
                existing = try AgentRecord.load(id, from: root.statusDir)
            } catch {
                // Left as it is: its agent alone shows that it cannot be read.
                continue
            }
            guard existing == nil else { continue }
            var record = AgentRecord()
            record.changedAt = lastActive(id) ?? now
            record.unread = unread.contains(id)
            record.nameSource = state.autoNamed?.contains(id) == true ? .app : .person
            // What was running or unread stays on the agents' tiles.
            if !record.unread && !running.contains(id) { record.settledAt = now }
            try AgentRecord.save(record, for: id, in: root.statusDir)
        }
        _ = try moveToBackups(root: root, now: now)
        return nil
    }

    /// Moves `state.json` to its backups folder, which it returns.
    private static func moveToBackups(root: AgentDataRoot, now: Date) throws -> URL {
        let backup = root.backupDir(named: "state-json", date: now)
        try FileManager.default.createDirectory(
            at: backup,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: root.stateFile, to: backup.appendingPathComponent("state.json"))
        return backup
    }
}
