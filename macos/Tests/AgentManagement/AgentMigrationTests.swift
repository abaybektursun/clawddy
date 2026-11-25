import Foundation
import Testing
@testable import Ghostty

/// The marks earlier builds kept in `state.json` become records once
/// (`AgentStateFold`), and the bridge starts from them.
@MainActor
struct AgentMigrationTests {
    /// A `state.json` as the last build wrote it: JSONEncoder's flat
    /// `[key, value, …]` arrays for the UUID-keyed dictionary.
    private func legacyState(unread: UUID, interrupted: UUID, running: [UUID], autoNamed: UUID) -> Data {
        let completion = #"{"provider":"claudeCode","sessionID":"s","launchGeneration":"\#(UUID().uuidString)","eventID":"e"}"#
        let ids = { (set: [UUID]) in set.map { "\"\($0.uuidString)\"" }.joined(separator: ",") }
        return Data("""
            {"unreadCompletions":["\(unread.uuidString)",\(completion)],
             "interrupted":[\(ids([interrupted]))],
             "running":[\(ids(running))],
             "autoNamed":[\(ids([autoNamed]))]}
            """.utf8)
    }

    /// Decisions 3 and 4 of 2026-11-23: unread and interrupted agents are
    /// unread, running ones stay on their tiles, the rest start settled; whose name it
    /// is carries over; the file is backed up beside the root and removed;
    /// a record that exists is kept; nothing happens without the file.
    @Test func stateFileFoldsIntoRecordsOnce() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-fold-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = AgentDataRoot(url: folder.appendingPathComponent("root", isDirectory: true))
        try FileManager.default.createDirectory(at: root.statusDir, withIntermediateDirectories: true)
        let (unread, interrupted, running, idle, kept) = (UUID(), UUID(), UUID(), UUID(), UUID())
        try legacyState(unread: unread, interrupted: interrupted, running: [running, unread], autoNamed: running)
            .write(to: root.stateFile)
        var existing = AgentRecord()
        existing.lastMessage = "kept"
        try AgentRecord.save(existing, for: kept, in: root.statusDir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let active = Date(timeIntervalSince1970: 1_799_000_000)

        try AgentStateFold.fold(
            root: root, agents: [unread, interrupted, running, idle, kept],
            lastActive: { $0 == idle ? active : nil }, now: now)

        func record(_ id: UUID) throws -> AgentRecord { try #require(try AgentRecord.load(id, from: root.statusDir)) }
        #expect(try record(unread).unread && record(unread).settledAt == nil)
        #expect(try record(interrupted).unread && record(interrupted).settledAt == nil)
        #expect(try !record(running).unread && record(running).settledAt == nil)
        #expect(try record(running).nameSource == .app && record(unread).nameSource == .person)
        #expect(try record(idle).settledAt == now && record(idle).changedAt == active && record(idle).state == .finished)
        #expect(try record(idle).lastMessage == nil && record(idle).firstInstruction == nil)
        #expect(try record(kept) == existing)
        #expect(!FileManager.default.fileExists(atPath: root.stateFile.path))
        let backup = root.backupDir(named: "state-json", date: now).appendingPathComponent("state.json")
        #expect(FileManager.default.fileExists(atPath: backup.path))

        // A second start finds no file and changes nothing.
        let before = try filesUnder(folder)
        try AgentStateFold.fold(root: root, agents: [idle], lastActive: { _ in nil }, now: now + 60)
        #expect(try filesUnder(folder) == before)
    }

    /// The bridge folds at start, then starts from the records: the unread
    /// agent is unread and the settled one is off the waiting count.
    @Test func theBridgeStartsFromTheFoldedRecords() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let unread = try h.addAgent("Unread")
        let idle = try h.addAgent("Idle")
        try FileManager.default.createDirectory(at: h.root.statusDir, withIntermediateDirectories: true)
        try legacyState(unread: unread, interrupted: unread, running: [], autoNamed: idle).write(to: h.root.stateFile)
        h.start()
        #expect(try h.agent(unread).record.unread)
        #expect(try h.agent(idle).record.settledAt != nil)
        #expect(try h.agent(idle).autoNamed)
        #expect(!h.exists(h.root.stateFile))
    }

    /// An unread mark survives a restart, and a turn under way when the app
    /// quits or crashes is cut off at the next start: the record alone says
    /// so.
    @Test func unreadAndCutOffSurviveARestart() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let finished = try h.addAgent("Finished")
        let working = try h.addAgent("Working")
        h.start()
        try h.launch(finished)
        try h.completeTurn(finished)
        try h.launch(working)
        try h.startTurn(working)
        #expect(try AgentRecord.load(working, from: h.root.statusDir)?.state == .working)

        try h.restart()
        #expect(try h.agent(finished).record.unread)
        #expect(try h.agent(working).record.cutOff && h.agent(working).record.state == .working)
        #expect(try AgentRecord.load(working, from: h.root.statusDir)?.cutOff == true)
    }
}
