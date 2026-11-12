import Foundation
import Testing
@testable import Ghostty

struct AgentHookScriptTests {
    @Test func hookHasValidPOSIXShellSyntax() throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        process.standardInput = input

        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(AgentHookRuntime.script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    /// The script records the event and nothing else: the bridge writes the
    /// session binding from the record.
    @Test func hookPublishesProviderTaggedSessionAndEvent() throws {
        let fixture = try HookFixture()
        defer { fixture.remove() }
        let agentID = UUID()
        let generation = UUID()

        let result = try fixture.run(
            agentID: agentID,
            provider: .codex,
            generation: generation,
            payload: Data("""
                {"session_id":"session-123","hook_event_name":"SessionStart","turn_id":"turn-1","model":"gpt-5.4","permission_mode":"default"}
                """.utf8))

        #expect(result == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.status
            .appendingPathComponent("\(agentID.uuidString).session.json").path))

        let events = try fixture.events(agentID)
        #expect(events.count == 1)
        #expect(events[0].provider == .codex)
        #expect(events[0].eventID?.isEmpty == false)
        #expect(events[0].launchGeneration == generation)
        #expect(events[0].hookEventName == "SessionStart")
        #expect(events[0].sessionID == "session-123")
        #expect(events[0].turnID == "turn-1")
        #expect(events[0].model == "gpt-5.4")
        #expect(events[0].permissionMode == "default")
    }

    /// Claude names the turn `prompt_id` and never sends `turn_id`, so a
    /// Claude record's turn is the prompt; Codex's stays `turn_id`. A field
    /// the payload lacks is recorded as "", which decodes as absent. A
    /// compaction's record carries its trigger.
    @Test func claudeRecordsCarryPromptIDAsTurnIdentity() throws {
        let fixture = try HookFixture()
        defer { fixture.remove() }
        func record(_ provider: AgentProviderID, _ payload: String) throws -> AgentRawProviderEvent {
            let agentID = UUID()
            #expect(try fixture.run(
                agentID: agentID,
                provider: provider,
                generation: UUID(),
                payload: Data(payload.utf8)) == 0)
            let events = try fixture.events(agentID)
            try #require(events.count == 1)
            return events[0]
        }

        #expect(try record(
            .claudeCode,
            #"{"session_id":"s","hook_event_name":"StopFailure","prompt_id":"prompt-1","turn_id":"turn-1"}"#).turnID
            == "prompt-1")
        let compaction = try record(
            .claudeCode,
            #"{"session_id":"s","hook_event_name":"PreCompact","trigger":"manual","turn_id":"turn-1"}"#)
        #expect(compaction.turnID == nil)
        #expect(compaction.trigger == "manual")
        #expect(try record(
            .codex,
            #"{"session_id":"s","hook_event_name":"Stop","prompt_id":"prompt-1","turn_id":"turn-1"}"#).turnID
            == "turn-1")
    }

    @Test func concurrentHooksAppendOneValidRecordEach() throws {
        let fixture = try HookFixture()
        defer { fixture.remove() }
        let agentID = UUID()
        let generation = UUID()
        let eventCount = 24
        var processes: [(Process, Pipe)] = []

        for index in 0..<eventCount {
            let process = fixture.process(
                agentID: agentID,
                provider: .claudeCode,
                generation: generation)
            let input = Pipe()
            process.standardInput = input
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data(
                "{\"session_id\":\"session-\(index)\",\"hook_event_name\":\"StopFailure\",\"prompt_id\":\"turn-\(index)\"}\n".utf8))
            try input.fileHandleForWriting.close()
            processes.append((process, input))
        }

        for (process, _) in processes {
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        let events = try fixture.events(agentID)
        #expect(events.count == eventCount)
        #expect(Set(events.compactMap(\.turnID)).count == eventCount)
        #expect(events.allSatisfy { $0.provider == .claudeCode })
        #expect(Set(events.compactMap(\.eventID)).count == eventCount)
        #expect(events.allSatisfy { $0.launchGeneration == generation })
    }

    @Test func explicitStatusDirectoryIsIndependentFromHome() throws {
        let fixture = try HookFixture()
        defer { fixture.remove() }
        let accountHome = fixture.root.appendingPathComponent("account-home")
        try FileManager.default.createDirectory(
            at: accountHome,
            withIntermediateDirectories: true)
        let agentID = UUID()

        let result = try fixture.run(
            agentID: agentID,
            provider: .codex,
            generation: UUID(),
            home: accountHome,
            payload: Data(
                "{\"session_id\":\"isolated-session\",\"hook_event_name\":\"SessionStart\"}\n".utf8))

        #expect(result == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.status
            .appendingPathComponent("\(agentID.uuidString).events").path))
        #expect(!FileManager.default.fileExists(atPath: accountHome
            .appendingPathComponent(".config/ghostty-agents/status").path))
    }

    /// The real installed script, run without its status folder argument,
    /// writes nothing, although a Codex agent's identity is in its
    /// environment. It exits 0, not 1: older builds left argument-less global
    /// entries in Claude's settings, and those must not report a hook error in
    /// every Claude session on the machine. Codex's global command line, the
    /// script and the status folder, records only when the identity's
    /// `CLAWDDY_STATUS_DIR` names that same folder.
    @Test func hookScriptRequiresStatusDirArgument() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .appendingPathComponent("clawddy-hook-argument-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: sandbox) }
        let root = AgentDataRoot(url: sandbox.appendingPathComponent("root", isDirectory: true))
        let home = sandbox.appendingPathComponent("home", isDirectory: true)
        let environmentStatus = sandbox.appendingPathComponent("environment-status", isDirectory: true)
        let payload = sandbox.appendingPathComponent("payload.json")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try AgentHookRuntime.install(root: root)
        try Data(#"{"session_id":"session-1","hook_event_name":"SessionStart"}"#.utf8).write(to: payload)
        let agentID = UUID()

        func run(_ executable: String, _ arguments: [String], statusVariable: URL) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = [
                "CLAWDDY_AGENT_ID": agentID.uuidString,
                "CLAWDDY_AGENT_PROVIDER": AgentProviderID.codex.rawValue,
                "CLAWDDY_AGENT_GENERATION": UUID().uuidString,
                "CLAWDDY_STATUS_DIR": statusVariable.path,
                "HOME": home.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": home.path,
            ]
            process.standardInput = try FileHandle(forReadingFrom: payload)
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        let before = try filesUnder(sandbox)
        #expect(try run(
            AgentHookRuntime.scriptURL(root: root).path, [],
            statusVariable: environmentStatus) == 0)
        #expect(try run(
            AgentHookRuntime.scriptURL(root: root).path, [],
            statusVariable: root.statusDir) == 0)
        // Another instance's agent: its variable names another folder.
        #expect(try run(
            "/bin/sh", ["-c", AgentHookRuntime.command(root: root)],
            statusVariable: environmentStatus) == 0)
        #expect(try filesUnder(sandbox) == before)

        #expect(try run(
            "/bin/sh", ["-c", AgentHookRuntime.command(root: root)],
            statusVariable: root.statusDir) == 0)
        #expect(fm.fileExists(atPath: root.statusDir
            .appendingPathComponent("\(agentID.uuidString).events").path))
        #expect(!fm.fileExists(atPath: environmentStatus.path))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".config").path))
    }

    /// A hook that cannot record its event says why in the status folder's
    /// `hook-errors.log`, still exiting 0; past 64 KiB the log moves to
    /// `hook-errors.log.1` and starts again.
    @Test func hookFailuresGoToABoundedErrorLog() throws {
        let fixture = try HookFixture()
        defer { fixture.remove() }
        let agentID = UUID()
        let log = fixture.status.appendingPathComponent("hook-errors.log")
        let events = fixture.status.appendingPathComponent("\(agentID.uuidString).events")
        func run(_ payload: String) throws -> [Substring] {
            #expect(try fixture.run(
                agentID: agentID,
                provider: .claudeCode,
                generation: UUID(),
                payload: Data(payload.utf8)) == 0)
            return try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        }

        var lines = try run(#"{"session_id":"session-1"}"#)
        #expect(lines.count == 1)
        #expect(lines.last?.hasSuffix(
            " claudeCode \(agentID.uuidString) ?: the hook input names no hook_event_name") == true)
        #expect(!FileManager.default.fileExists(atPath: events.path))

        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        lines = try run(#"{"session_id":"session-1","hook_event_name":"SessionStart"}"#)
        #expect(lines.count == 2)
        #expect(lines.last?.hasSuffix(
            " claudeCode \(agentID.uuidString) SessionStart: could not append to \(events.path) (status 1)") == true)

        let full = Data(repeating: UInt8(ascii: "x"), count: 70_000)
        try full.write(to: log)
        lines = try run(#"{"session_id":"session-1"}"#)
        #expect(lines.count == 1)
        #expect(try Data(contentsOf: log.appendingPathExtension("1")) == full)
    }

    @Test func providerExitIsJournaledBeforeFallbackShell() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-exit-hook-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let agentID = UUID()
        let generation = UUID()
        let command = AgentHookRuntime.exitEventCommand(
            provider: .codex,
            agentID: agentID,
            generation: generation,
            statusDirectory: root)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "command_status=7; \(command)"]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let data = try Data(contentsOf: root
            .appendingPathComponent("\(agentID.uuidString).events"))
        let batch = AgentEventJournal.read(data, from: 0)
        let event = try JSONDecoder().decode(
            AgentRawProviderEvent.self,
            from: #require(batch.records.first))
        #expect(event.provider == .codex)
        #expect(event.eventID?.isEmpty == false)
        #expect(event.launchGeneration == generation)
        #expect(event.hookEventName == "ProviderExited")
        #expect(event.exitStatus == 7)
    }

    @Test func shellQuoteHandlesSpacesAndSingleQuotes() {
        #expect(AgentHookRuntime.shellQuote("/Users/A B/it's/hook")
            == "'/Users/A B/it'\\''s/hook'")
    }

    @Test func jsonIntegrationRetriesAgainstAConcurrentExternalReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-json-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        let backup = directory.appendingPathComponent("settings.json.backup")
        try Data("{\"original\":true}".utf8).write(to: url)
        var calls = 0

        // The first call is the unlocked check for a change; the external
        // editor replaces the file during the second, under the lock.
        let changed = try AgentHookRuntime.updateJSONFile(
            at: url,
            backupURL: backup
        ) { root in
            calls += 1
            if calls == 2 {
                try Data("{\"external\":true}".utf8).write(to: url)
            }
            root["clawddy"] = true
        }

        #expect(changed)
        #expect(calls == 3)
        let result = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Bool])
        #expect(result == ["external": true, "clawddy": true])
        // The backup holds the bytes the write replaced.
        let replaced = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Bool])
        #expect(replaced == ["external": true])
    }
}

private final class HookFixture {
    let root: URL
    let status: URL
    let script: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-hook-tests-\(UUID().uuidString)")
        status = root.appendingPathComponent("isolated/status")
        script = root.appendingPathComponent("clawddy-provider-hook.sh")
        try FileManager.default.createDirectory(at: status, withIntermediateDirectories: true)
        try AgentHookRuntime.script.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func process(
        agentID: UUID,
        provider: AgentProviderID,
        generation: UUID,
        home: URL? = nil
    ) -> Process {
        let process = Process()
        process.executableURL = script
        process.arguments = [status.path, provider.rawValue, agentID.uuidString, generation.uuidString]
        process.environment = [
            "HOME": (home ?? root).path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": root.path,
        ]
        return process
    }

    func run(
        agentID: UUID,
        provider: AgentProviderID,
        generation: UUID,
        home: URL? = nil,
        payload: Data
    ) throws -> Int32 {
        let process = process(
            agentID: agentID,
            provider: provider,
            generation: generation,
            home: home)
        let input = Pipe()
        process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: payload)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func events(_ agentID: UUID) throws -> [AgentRawProviderEvent] {
        let data = try Data(contentsOf: status
            .appendingPathComponent("\(agentID.uuidString).events"))
        return try AgentEventJournal.read(data, from: 0).records.map {
            try JSONDecoder().decode(AgentRawProviderEvent.self, from: $0)
        }
    }
}

/// Every path under `folder` with its size, to show that a run wrote nothing.
func filesUnder(_ folder: URL) throws -> [String: Int] {
    let enumerator = try #require(FileManager.default.enumerator(atPath: folder.path))
    var result: [String: Int] = [:]
    while let path = enumerator.nextObject() as? String {
        result[path] = (enumerator.fileAttributes?[.size] as? NSNumber)?.intValue ?? -1
    }
    return result
}
