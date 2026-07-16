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
        let binding = try JSONDecoder().decode(
            AgentSessionBinding.self,
            from: Data(contentsOf: fixture.status
                .appendingPathComponent("\(agentID.uuidString).session.json")))
        #expect(binding == AgentSessionBinding(
            provider: .codex,
            sessionID: "session-123",
            launchGeneration: generation))

        let events = try fixture.events(agentID)
        #expect(events.count == 1)
        #expect(events[0].provider == .codex)
        #expect(events[0].eventID?.isEmpty == false)
        #expect(events[0].launchGeneration == generation)
        #expect(events[0].hookEventName == "SessionStart")
        #expect(events[0].turnID == "turn-1")
        #expect(events[0].model == "gpt-5.4")
        #expect(events[0].permissionMode == "default")
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
                "{\"session_id\":\"session-\(index)\",\"hook_event_name\":\"UserPromptSubmit\",\"turn_id\":\"turn-\(index)\"}\n".utf8))
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
            .appendingPathComponent("\(agentID.uuidString).session.json").path))
        #expect(!FileManager.default.fileExists(atPath: accountHome
            .appendingPathComponent(".config/ghostty-agents/status").path))
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

    @Test func reinstallRemovesOnlyClawddyHandlersAndPreservesUserHooks() throws {
        let userHandler: [String: Any] = [
            "type": "command",
            "command": "/Users/example/bin/my-hook",
        ]
        let integrationHandler: [String: Any] = [
            "type": "command",
            "command": "/Users/example/.config/ghostty-agents/hooks/old-hook.sh",
        ]
        let source: [String: Any] = [
            "Stop": [
                ["matcher": "*", "hooks": [userHandler, integrationHandler]],
                ["hooks": [integrationHandler]],
            ],
        ]

        let filtered = AgentHookRuntime.removingIntegrationHandlers(from: source)
        let groups = try #require(filtered["Stop"] as? [[String: Any]])
        #expect(groups.count == 1)
        #expect(groups[0]["matcher"] as? String == "*")
        let handlers = try #require(groups[0]["hooks"] as? [[String: Any]])
        #expect(handlers.count == 1)
        #expect(handlers[0]["command"] as? String == "/Users/example/bin/my-hook")
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
        var replaced = false

        let changed = try AgentHookRuntime.updateJSONFile(
            at: url,
            backupURL: backup
        ) { root in
            if !replaced {
                replaced = true
                try Data("{\"external\":true}".utf8).write(to: url)
            }
            root["clawddy"] = true
        }

        #expect(changed)
        let result = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Bool])
        #expect(result == ["external": true, "clawddy": true])
        let original = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Bool])
        #expect(original == ["original": true])
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
        process.environment = [
            "GHOSTTY_AGENT_ID": agentID.uuidString,
            "GHOSTTY_AGENT_PROVIDER": provider.rawValue,
            "GHOSTTY_AGENT_LAUNCH_GENERATION": generation.uuidString,
            "GHOSTTY_AGENT_STATUS_DIR": status.path,
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
