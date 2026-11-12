import Foundation
import Testing
import UserNotifications
@testable import Ghostty

/// Every observation about an agent enters through `AgentBridge.ingest(_:)`;
/// the event file is read by `AgentHookJournalSource`, whose file-level
/// watcher sees appends.
@MainActor
struct AgentBridgeStatusSeamTests {
    /// The event file is one way into `ingest`, not a second path into the
    /// state: records read from it drive exactly the transitions and
    /// notifications that the same observations given to `ingest` directly
    /// drive, as the terminal's will. A close does the same from the host's
    /// notification or given directly.
    @Test func ingestDrivesSameTransitionsFromEitherSource() async throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let fromFile = try h.addAgent("From File")
        let direct = try h.addAgent("Direct")
        h.start()
        try h.activate(fromFile)
        try h.activate(direct)
        func summary(_ id: UUID) throws -> String {
            let agent = try h.agent(id)
            let notifications = h.notifier.posted
                .filter { $0.content.threadIdentifier == id.uuidString }
                .map { $0.identifier.replacingOccurrences(of: id.uuidString, with: "agent") }
            return "\(agent.displayState) \(agent.surfaceState) \(agent.processState) "
                + "\(agent.activityState) \(agent.interactionState) \(agent.turnState) "
                + "\(agent.telemetryHealth) \(agent.sessionID ?? "-") \(agent.isUnread) \(notifications)"
        }

        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop"] {
            try h.append(fromFile, h.record(event, generation: try h.generation(fromFile), eventID: event))
            h.poll()
            let line = h.record(event, generation: try h.generation(direct), eventID: event)
            h.bridge.ingest(AgentStatusObservation(
                agentID: direct,
                generation: try h.generation(direct),
                source: .hookJournal,
                event: .hook(try JSONDecoder().decode(AgentRawProviderEvent.self, from: Data(line.utf8)))))
            #expect(try summary(direct) == summary(fromFile), "\(event)")
        }
        #expect(try h.agent(direct).displayState == .finished)
        #expect(h.notifier.posted.count == 4)

        let surface = try #require(h.host.surfaces[fromFile])
        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: surface,
            userInfo: ["process_alive": false])
        h.bridge.ingest(AgentStatusObservation(
            agentID: direct,
            generation: try h.generation(direct),
            source: .surface,
            event: .surfaceClosed(processAlive: false)))
        await yieldToMainActor(until: { h.surfaceDeaths.count == 2 })

        #expect(try summary(direct) == summary(fromFile))
        #expect(try h.agent(direct).surfaceState == .closed)
        #expect(Set(h.surfaceDeaths) == [fromFile, direct])
    }

    /// A real watcher on a temporary folder: an append to an event file that
    /// already exists, which a watcher on the folder alone never sees, is
    /// delivered with no poll and no timer but the source's own throttle.
    /// The record already in the file at start is not delivered.
    @Test func appendIsSeenWithoutPolling() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-journal-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                Issue.record(error)
            }
        }
        let id = UUID()
        let generation = UUID()
        func line(_ event: String) -> Data {
            Data((#"{"schemaVersion":1,"eventID":"\#(event)","provider":"codex","launchGeneration":"\#(generation.uuidString)","hookEventName":"\#(event)","sessionID":"","turnID":"","model":"","permissionMode":""}"# + "\n").utf8)
        }
        let events = folder.appendingPathComponent("\(id.uuidString).events")
        try line("Before").write(to: events)

        let (delivered, continuation) = AsyncStream.makeStream(of: String.self)
        let diagnostics = DiagnosticsRecord()
        let source = AgentHookJournalSource(
            statusDir: folder,
            scheduler: AgentRunLoopScheduler(),
            io: AgentDispatchIO(),
            diagnose: diagnostics.sink)
        source.start(
            agents: { [id: .codex] },
            observe: { observation in
                if case .hook(let record) = observation.event {
                    continuation.yield(record.hookEventName)
                }
            },
            statusLine: { _, _ in })
        defer { source.stop() }

        let handle = try FileHandle(forWritingTo: events)
        try handle.seekToEnd()
        try handle.write(contentsOf: line("After"))
        try handle.close()

        #expect(try await first(of: delivered, within: .seconds(10)) == "After")
        #expect(diagnostics.messages.isEmpty)
    }
}

/// The stream's first element, or nil when none arrives within `timeout`.
private func first(of stream: AsyncStream<String>, within timeout: Duration) async throws -> String? {
    try await withThrowingTaskGroup(of: String?.self) { group in
        group.addTask { await stream.first { _ in true } }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
