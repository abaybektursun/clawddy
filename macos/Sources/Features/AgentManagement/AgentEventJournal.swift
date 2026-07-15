import Foundation

struct AgentEventJournalBatch: Equatable {
    let records: [Data]
    let endOffset: Int
}

enum AgentEventJournal {
    /// Returns only newline-terminated records. If the journal was replaced or
    /// truncated, reading restarts at zero instead of permanently skipping data.
    static func read(_ data: Data, from requestedOffset: Int) -> AgentEventJournalBatch {
        let startOffset = requestedOffset <= data.count ? requestedOffset : 0
        var records: [Data] = []
        var lineStart = startOffset
        var endOffset = startOffset

        if lineStart < data.count {
            for index in lineStart..<data.count where data[index] == 0x0A {
                if index > lineStart {
                    records.append(data.subdata(in: lineStart..<index))
                }
                lineStart = index + 1
                endOffset = lineStart
            }
        }

        return AgentEventJournalBatch(records: records, endOffset: endOffset)
    }

    static func compact(
        url: URL,
        lockURL: URL,
        acknowledgedOffset: Int,
        timeout: TimeInterval = 1
    ) -> Bool {
        guard acknowledgedOffset >= 0 else { return false }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).compact.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let script = """
            size=$(/usr/bin/stat -f %z "$1") || exit 66
            [ "$2" -le "$size" ] || exit 66
            start=$(($2 + 1))
            /usr/bin/tail -c +"$start" "$1" > "$3" || exit 66
            /bin/mv -f "$3" "$1"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = [
            "-s", "-t", String(Int(timeout)), "-k", lockURL.path,
            "/bin/sh", "-c", script, "clawddy-compact",
            url.path, String(acknowledgedOffset), temporary.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
