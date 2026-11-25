import Foundation
import Testing
@testable import Ghostty

struct AgentEventJournalTests {
    @Test func preservesOrderedBurstAndAdvancesToCompleteBoundary() {
        let source = Data("one\ntwo\nthree\n".utf8)
        let batch = AgentEventJournal.read(source, from: 0)

        #expect(batch.records.compactMap { String(data: $0, encoding: .utf8) }
            == ["one", "two", "three"])
        #expect(batch.endOffset == source.count)
    }

    @Test func leavesPartialRecordForNextPoll() {
        let complete = Data("one\n".utf8)
        let first = AgentEventJournal.read(complete + Data("part".utf8), from: 0)
        #expect(first.records == [Data("one".utf8)])
        #expect(first.endOffset == complete.count)

        let finished = complete + Data("partial\n".utf8)
        let second = AgentEventJournal.read(finished, from: first.endOffset)
        #expect(second.records == [Data("partial".utf8)])
        #expect(second.endOffset == finished.count)
    }

    @Test func restartsAfterJournalTruncation() {
        let replacement = Data("new\n".utf8)
        let batch = AgentEventJournal.read(replacement, from: 100)

        #expect(batch.records == [Data("new".utf8)])
        #expect(batch.endOffset == replacement.count)
    }

    @Test func compactionKeepsOnlyUnacknowledgedSuffix() throws {
        let acknowledged = Data("one\ntwo\n".utf8)
        let suffix = Data("partial".utf8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-journal-tests-\(UUID().uuidString)")
        let journal = directory.appendingPathComponent("agent.events")
        let lock = directory.appendingPathComponent("agent.events.lock")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (acknowledged + suffix).write(to: journal)

        #expect(try AgentEventJournal.compact(
            url: journal,
            lockURL: lock,
            acknowledgedOffset: acknowledged.count))
        #expect(try Data(contentsOf: journal) == suffix)
        #expect(try !AgentEventJournal.compact(
            url: journal,
            lockURL: lock,
            acknowledgedOffset: suffix.count + 1))
    }

    /// A record carrying 200 KB of text decodes whole; while only part of it
    /// is written, nothing of it is read, and the read resumes at its start.
    @Test func longTextRecordDecodesWholeAndAPartialWriteWaits() throws {
        let text = String(repeating: "line with \"quotes\" 🧪\n", count: 9_000)
        let line = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "provider": "claudeCode", "launchGeneration": UUID().uuidString,
            "hookEventName": "Stop", "text": text,
        ])
        #expect(line.count > 200_000)
        let before = Data("{}\n".utf8)

        let partial = AgentEventJournal.read(before + line.prefix(150_000), from: 0)
        #expect(partial.records == [Data("{}".utf8)])
        #expect(partial.endOffset == before.count)

        let whole = AgentEventJournal.read(before + line + Data("\n".utf8), from: partial.endOffset)
        let record = try JSONDecoder().decode(AgentRawProviderEvent.self, from: #require(whole.records.first))
        #expect(record.text == text)
    }
}
