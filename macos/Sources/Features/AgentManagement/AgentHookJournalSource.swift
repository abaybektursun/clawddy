import CoreServices
import Foundation

/// Reads the records hooks append to each agent's event file,
/// `<status folder>/<agent id>.events`, and gives every record to the bridge
/// as an observation. A file-level FSEvents watcher on the status folder sees
/// each append; the reads it asks for are throttled into one per window and
/// never overlap. Offsets live in memory and start at the end of each file
/// when the source starts, so a record written before then never applies: a
/// restarted app does not replay history. Once the part of a file already
/// read reaches 1 MiB, that part is cut off under the hooks' own lock and the
/// offset moves to the start of the rest, so compaction neither replays nor
/// loses a record.
///
/// The same reads pick up Claude's status-line snapshot,
/// `<agent id>.metadata.json`, which its proxy publishes into the folder.
@MainActor
final class AgentHookJournalSource {
    /// Reads asked for within this window share one read.
    private static let throttle: TimeInterval = 0.2
    /// How long FSEvents gathers the kernel's events into one callback.
    private static let latency: CFTimeInterval = 0.05
    private static let compactionThreshold = 1_048_576

    private struct StatusLineRead: Sendable {
        let data: Data
        let snapshot: Result<AgentSessionMetadata, any Error>
    }

    private let statusDir: URL
    private let scheduler: any AgentScheduler
    private let io: any AgentIOExecutor
    private let diagnose: AgentDiagnosticsSink

    private var agents: @MainActor () -> [UUID: AgentProviderID] = { [:] }
    private var observe: @MainActor (AgentStatusObservation) -> Void = { _ in }
    private var statusLine: @MainActor (UUID, AgentSessionMetadata) -> Void = { _, _ in }

    /// Running from `start` to `stop`.
    private var stream: FSEventStreamRef?
    /// The next byte to read in each agent's event file.
    private var offsets: [UUID: Int] = [:]
    /// Each status-line file as last read, so an unchanged one is skipped.
    private var statusLineData: [UUID: Data] = [:]
    private var compacting: Set<UUID> = []
    private var readPending = false
    private var readInFlight = false
    private var readAgain = false

    init(
        statusDir: URL,
        scheduler: any AgentScheduler,
        io: any AgentIOExecutor,
        diagnose: @escaping AgentDiagnosticsSink
    ) {
        self.statusDir = statusDir
        self.scheduler = scheduler
        self.io = io
        self.diagnose = diagnose
    }

    /// Starts reading at the end of each agent's event file and watching the
    /// folder. `agents` names the agents to read, with their providers, at
    /// each read; `observe` receives each record and `statusLine` each new
    /// status-line snapshot.
    func start(
        agents: @escaping @MainActor () -> [UUID: AgentProviderID],
        observe: @escaping @MainActor (AgentStatusObservation) -> Void,
        statusLine: @escaping @MainActor (UUID, AgentSessionMetadata) -> Void
    ) {
        precondition(stream == nil, "The hook journal source is already running.")
        self.agents = agents
        self.observe = observe
        self.statusLine = statusLine
        for id in agents().keys {
            do {
                offsets[id] = try Self.size(of: Self.journalURL(id, in: statusDir))
            } catch {
                diagnose(.error, "journal size unreadable for \(id): \(error.localizedDescription)")
            }
        }
        watch()
        // Shows the status lines the last run left.
        requestRead(after: 0)
    }

    /// Stops watching; a read still in flight delivers nothing.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Reads what each agent's event file gained since the last read, and
    /// each changed status-line file. The watcher asks for this through the
    /// throttle; a test calls it directly.
    func read() {
        guard stream != nil else { return }
        if readInFlight {
            readAgain = true
            return
        }
        readInFlight = true
        let agents = self.agents()
        offsets = offsets.filter { agents[$0.key] != nil }
        statusLineData = statusLineData.filter { agents[$0.key] != nil }
        let statusDir = statusDir
        let offsets = offsets
        let compacting = compacting
        let knownStatusLines = statusLineData
        let io = self.io
        let diagnose = self.diagnose
        io.async { [weak self] in
            var batches: [UUID: AgentEventJournalBatch] = [:]
            var statusLines: [UUID: StatusLineRead] = [:]
            for (id, provider) in agents {
                let offset = offsets[id] ?? 0
                do {
                    if !compacting.contains(id),
                       let batch = try Self.readJournal(Self.journalURL(id, in: statusDir), from: offset),
                       !batch.records.isEmpty || batch.endOffset != offset {
                        batches[id] = batch
                    }
                } catch {
                    diagnose(.error, "journal read failed for \(id): \(error.localizedDescription)")
                }

                guard provider == .claudeCode else { continue }
                let url = statusDir.appendingPathComponent("\(id.uuidString).metadata.json")
                do {
                    if let read = try Self.readStatusLine(url, unless: knownStatusLines[id]) {
                        if case .failure(let error) = read.snapshot {
                            diagnose(.error, "invalid metadata snapshot for \(id): \(error.localizedDescription)")
                        }
                        statusLines[id] = read
                    }
                } catch {
                    diagnose(.error, "status line read failed for \(id): \(error.localizedDescription)")
                }
            }
            io.onMainActor { [weak self] in
                self?.deliver(batches, statusLines)
            }
        }
    }

    private func deliver(
        _ batches: [UUID: AgentEventJournalBatch],
        _ statusLines: [UUID: StatusLineRead]
    ) {
        defer { finishRead() }
        guard stream != nil else { return }
        for (id, read) in statusLines {
            statusLineData[id] = read.data
            if case .success(let snapshot) = read.snapshot { statusLine(id, snapshot) }
        }
        for (id, batch) in batches {
            for (record, offset) in zip(batch.records, batch.recordOffsets) {
                let event: AgentRawProviderEvent
                do {
                    event = try JSONDecoder().decode(AgentRawProviderEvent.self, from: record)
                } catch {
                    let reason = "undecodable record in \(Self.journalURL(id, in: statusDir).path) at byte \(offset): \(AgentConfig.describeLoadFailure(error))"
                    diagnose(.error, reason)
                    observe(AgentStatusObservation(
                        agentID: id, generation: nil, source: .hookJournal, event: .unreadableRecord(reason)))
                    continue
                }
                observe(AgentStatusObservation(
                    agentID: id,
                    generation: event.launchGeneration,
                    source: .hookJournal,
                    event: .hook(event)))
            }
            offsets[id] = batch.endOffset
            if batch.endOffset >= Self.compactionThreshold {
                compact(id, acknowledgedOffset: batch.endOffset)
            }
        }
    }

    private func finishRead() {
        readInFlight = false
        guard readAgain else { return }
        readAgain = false
        requestRead(after: 0)
    }

    /// Asks for a read after `delay`. An ask while one waits joins it; one
    /// that comes while a read runs starts another after it, because that
    /// read may have looked before the change.
    private func requestRead(after delay: TimeInterval = AgentHookJournalSource.throttle) {
        guard stream != nil else { return }
        if readInFlight {
            readAgain = true
            return
        }
        guard !readPending else { return }
        readPending = true
        scheduler.after(delay) { [weak self] in
            guard let self else { return }
            self.readPending = false
            self.read()
        }
    }

    /// Cuts off the first `acknowledgedOffset` bytes, which have been read.
    /// The hooks append under the same lock, so a record written meanwhile
    /// stays in the rest, which the next read takes from its start.
    private func compact(_ id: UUID, acknowledgedOffset: Int) {
        guard compacting.insert(id).inserted else { return }
        let url = Self.journalURL(id, in: statusDir)
        let lockURL = statusDir.appendingPathComponent("\(id.uuidString).events.lock")
        let io = self.io
        let diagnose = self.diagnose
        io.async { [weak self] in
            var compacted = false
            do {
                compacted = try AgentEventJournal.compact(
                    url: url,
                    lockURL: lockURL,
                    acknowledgedOffset: acknowledgedOffset)
                if !compacted {
                    diagnose(.debug, "journal compaction deferred for \(id)")
                }
            } catch {
                diagnose(.error, "journal compaction failed for \(id): \(error.localizedDescription)")
            }
            io.onMainQueue { [weak self] in
                guard let self else { return }
                // Reads skip the file while it is compacted, so an offset
                // that moved belongs to an agent that is gone.
                if compacted, self.offsets[id] == acknowledgedOffset {
                    self.offsets[id] = 0
                }
                self.compacting.remove(id)
                self.requestRead(after: 0)
            }
        }
    }

    // MARK: - Watcher

    /// Watches every file in the status folder. File events report an append
    /// to a file that already exists, which a watcher on the folder itself
    /// never sees.
    private func watch() {
        // The stream holds the source until `stop` releases the stream.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<AgentHookJournalSource>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
            guard let info else { return }
            // Content changes only: reading a file can change its access
            // time, which must not ask for another read.
            let changes = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated
                    | kFSEventStreamEventFlagItemModified
                    | kFSEventStreamEventFlagItemRenamed
                    | kFSEventStreamEventFlagMustScanSubDirs)
            guard UnsafeBufferPointer(start: flags, count: count).contains(where: { $0 & changes != 0 })
            else { return }
            let source = Unmanaged<AgentHookJournalSource>.fromOpaque(info).takeUnretainedValue()
            // The stream delivers on the main queue.
            MainActor.assumeIsolated { source.requestRead() }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [statusDir.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        else { preconditionFailure("Could not create a watcher for \(statusDir.path).") }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            preconditionFailure("Could not watch \(statusDir.path).")
        }
        self.stream = stream
    }

    // MARK: - Files

    nonisolated private static func journalURL(_ id: UUID, in statusDir: URL) -> URL {
        statusDir.appendingPathComponent("\(id.uuidString).events")
    }

    /// When the agent's hooks last appended to its event file, which they do
    /// from the start of each launch to its end; nil when there is no file,
    /// because the agent has never run.
    nonisolated static func lastRecordDate(of id: UUID, in statusDir: URL) throws -> Date? {
        let url = journalURL(id, in: statusDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The file's size, and 0 when there is no file yet.
    nonisolated private static func size(of url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let handle = try FileHandle(forReadingFrom: url)
        let size = try handle.seekToEnd()
        try handle.close()
        return Int(size)
    }

    /// The complete records from `offset` to the end of the file, or from its
    /// start when the file is now shorter than `offset`; nil when there is no
    /// file.
    nonisolated private static func readJournal(
        _ url: URL,
        from offset: Int
    ) throws -> AgentEventJournalBatch? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        let size = try handle.seekToEnd()
        let start = UInt64(offset) <= size ? offset : 0
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        let batch = AgentEventJournal.read(data, from: 0)
        return AgentEventJournalBatch(
            records: batch.records,
            recordOffsets: batch.recordOffsets.map { start + $0 },
            endOffset: start + batch.endOffset)
    }

    /// The status-line file, stamped with its modification time; nil when
    /// there is none or it still holds `known`.
    nonisolated private static func readStatusLine(
        _ url: URL,
        unless known: Data?
    ) throws -> StatusLineRead? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data != known else { return nil }
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
            as? Date ?? Date()
        return StatusLineRead(data: data, snapshot: Result {
            try AgentSessionMetadata.decodeStatusLinePayload(data, observedAt: modified)
        })
    }
}
