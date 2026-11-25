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
                {"session_id":"session-123","hook_event_name":"agent-turn-complete","turn-id":"turn-1","model":"gpt-5.4","permission_mode":"default"}
                """.utf8))

        #expect(result == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.status
            .appendingPathComponent("\(agentID.uuidString).session.json").path))

        let events = try fixture.events(agentID)
        #expect(events.count == 1)
        #expect(events[0].provider == .codex)
        #expect(events[0].eventID?.isEmpty == false)
        #expect(events[0].launchGeneration == generation)
        #expect(events[0].hookEventName == "agent-turn-complete")
        #expect(events[0].sessionID == "session-123")
        #expect(events[0].turnID == "turn-1")
        #expect(events[0].model == "gpt-5.4")
        #expect(events[0].permissionMode == "default")
    }

    /// Claude names the turn `prompt_id` and never sends `turn_id`, so a
    /// Claude record's turn is the prompt; Codex's notify names it `turn-id`. A field
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
            #"{"session_id":"s","hook_event_name":"agent-turn-complete","prompt_id":"prompt-1","turn-id":"turn-1"}"#).turnID
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
            provider: .claudeCode,
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

    /// The real installed script, run without its identity, writes nothing,
    /// even with `CLAWDDY_*` names in its environment, which older builds
    /// gave Codex's terminal. It exits 0, not 1: older builds left
    /// argument-less global entries, and entries with only the status
    /// folder, in the providers' settings, and those must not report a hook
    /// error in every session on the machine.
    @Test func hookScriptRequiresItsIdentityAsArguments() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .appendingPathComponent("clawddy-hook-argument-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: sandbox) }
        let root = AgentDataRoot(url: sandbox.appendingPathComponent("root", isDirectory: true))
        let home = sandbox.appendingPathComponent("home", isDirectory: true)
        let payload = sandbox.appendingPathComponent("payload.json")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try AgentHookRuntime.install(root: root)
        try Data(#"{"session_id":"session-1","hook_event_name":"SessionStart"}"#.utf8).write(to: payload)

        let before = try filesUnder(sandbox)
        for arguments in [[], [root.statusDir.path]] {
            let process = Process()
            process.executableURL = AgentHookRuntime.scriptURL(root: root)
            process.arguments = arguments
            process.environment = [
                "CLAWDDY_AGENT_ID": UUID().uuidString,
                "CLAWDDY_AGENT_PROVIDER": AgentProviderID.codex.rawValue,
                "CLAWDDY_AGENT_GENERATION": UUID().uuidString,
                "CLAWDDY_STATUS_DIR": root.statusDir.path,
                "HOME": home.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": home.path,
            ]
            process.standardInput = try FileHandle(forReadingFrom: payload)
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        #expect(try filesUnder(sandbox) == before)
    }

    /// Text reaches the record exactly as the payload gave it, whatever it
    /// holds: quotes, backslashes, newlines (trailing ones too), tabs, emoji
    /// and joined emoji, a line separator, shell syntax that must not run,
    /// a leading dash, and 70 KB. Nothing is lost, added or run.
    @Test func textSurvivesExactly() throws {
        let fixture = try HookFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("injected")
        let texts = [
            #"He said "hi" and left \ a backslash\n (not a newline)"#,
            "line 1\n\n\tline 3\n\n",
            "🧪 👩‍💻 é ü 中文 \u{2028} end",
            "$(touch \(marker.path)) `touch \(marker.path)` ; touch \(marker.path) && echo $HOME '\"",
            "-n",
            "--string",
            String(repeating: "0123456789", count: 7_000) + "🧪\n",
            "\n",
        ]
        for (index, text) in texts.enumerated() {
            for (event, field) in [("UserPromptSubmit", "prompt"), ("Stop", "last_assistant_message")] {
                let agentID = UUID()
                let payload = try JSONSerialization.data(withJSONObject: [
                    "session_id": "s", "hook_event_name": event, "prompt_id": "p", field: text,
                ])
                #expect(try fixture.run(agentID: agentID, provider: .claudeCode, generation: UUID(), payload: payload) == 0)
                let events = try fixture.events(agentID)
                try #require(events.count == 1, "text \(index) \(event)")
                #expect(events[0].text == text, "text \(index) \(event)")
                #expect(events[0].hookEventName == event)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.status.appendingPathComponent("hook-errors.log").path))
    }

    /// Final review 3: the bound is in bytes. A text of four-byte characters
    /// just under the old limit counted in characters (about 1 MB) records
    /// its beginning, at most `textBytes` bytes, and the hook succeeds.
    @Test func aTextOfWideCharactersIsBoundInBytes() throws {
        let fixture = try HookFixture()
        defer { fixture.remove() }
        let wide = String(repeating: "🧪", count: AgentHookRuntime.textBytes - 10)
        let agentID = UUID()
        let payload = try JSONSerialization.data(withJSONObject: [
            "session_id": "s", "hook_event_name": "Stop", "prompt_id": "p", "last_assistant_message": wide,
        ])
        #expect(try fixture.run(agentID: agentID, provider: .claudeCode, generation: UUID(), payload: payload) == 0)
        let text = try #require(try fixture.events(agentID).first?.text)
        #expect(text.utf8.count <= AgentHookRuntime.textBytes && text.utf8.count > AgentHookRuntime.textBytes - 4)
        #expect(wide.hasPrefix(text))
        #expect(!FileManager.default.fileExists(atPath: fixture.status.appendingPathComponent("hook-errors.log").path))
    }

    /// A payload without the field records no text, never an empty one; a
    /// failure records Claude's kind and its text; a question comes from deep
    /// in the payload; a session's end and start record why and how.
    @Test func eachEventRecordsItsOwnFields() throws {
        let fixture = try HookFixture()
        defer { fixture.remove() }
        func record(_ payload: String) throws -> AgentRawProviderEvent {
            let agentID = UUID()
            #expect(try fixture.run(
                agentID: agentID, provider: .claudeCode, generation: UUID(), payload: Data(payload.utf8)) == 0)
            let events = try fixture.events(agentID)
            try #require(events.count == 1)
            return events[0]
        }
        let stop = try record(#"{"session_id":"s","hook_event_name":"Stop","prompt_id":"p"}"#)
        #expect(stop.text == nil && stop.error == nil)
        // JSON null is no text either.
        let nullText = try record(#"{"session_id":"s","hook_event_name":"Stop","last_assistant_message":null,"error":null}"#)
        #expect(nullText.text == nil && nullText.error == nil && nullText.hookEventName == "Stop")
        let failure = try record(
            #"{"session_id":"s","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"Claude usage limit reached."}"#)
        #expect(failure.error == "rate_limit")
        #expect(failure.text == "Claude usage limit reached.")
        let question = try record(
            #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which layout: A or B?","header":"Layout"}]}}"#)
        #expect(question.text == "Which layout: A or B?")
        let permission = try record(
            #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        #expect(permission.text == nil)
        #expect(try record(#"{"session_id":"s","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#).reason
            == "prompt_input_exit")
        #expect(try record(#"{"session_id":"s","hook_event_name":"SessionStart","source":"resume"}"#).source
            == "resume")
        // An event that carries no text writes no text field at all.
        let agentID = UUID()
        #expect(try fixture.run(
            agentID: agentID, provider: .claudeCode, generation: UUID(),
            payload: Data(#"{"session_id":"s","hook_event_name":"SessionStart","prompt":"not this"}"#.utf8)) == 0)
        let line = try String(contentsOf: fixture.status.appendingPathComponent("\(agentID.uuidString).events"), encoding: .utf8)
        #expect(!line.contains("\"text\""))
    }

    /// As Codex's notify program the script takes the payload from its last
    /// argument, records the turn's session, prompts and last message, and
    /// runs the owner's own notify command with the same payload, as Codex
    /// would have. Without an owner command it runs nothing else.
    @Test func notifyRecordsTheTurnAndChainsToTheOwnersNotify() throws {
        let fixture = try HookFixture()
        defer { fixture.remove() }
        let owner = fixture.root.appendingPathComponent("owner notify")
        let ownerLog = fixture.root.appendingPathComponent("owner.log")
        try Data("#!/bin/sh\nprintf '%s|%s' \"$1\" \"$2\" > \"$(dirname \"$0\")/owner.log\"\n".utf8).write(to: owner)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: owner.path)
        let payload = try String(data: JSONSerialization.data(withJSONObject: [
            "type": "agent-turn-complete", "thread-id": "thread-1", "turn-id": "turn-1",
            "cwd": "/tmp", "client": "codex-tui",
            "input-messages": ["first \"one\"\n", "second 🧪"],
            "last-assistant-message": "Done.\n\nTwo files changed.",
        ]), encoding: .utf8)!
        let agentID = UUID()
        let generation = UUID()

        for ownerCommand in [[owner.path, "turn-ended"], []] {
            let process = Process()
            process.executableURL = fixture.script
            process.arguments = [fixture.status.path, "codex", agentID.uuidString, generation.uuidString,
                                 AgentHookRuntime.notifyMode] + ownerCommand + [payload]
            process.environment = ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin", "TMPDIR": fixture.root.path]
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        let events = try fixture.events(agentID)
        try #require(events.count == 2)
        for event in events {
            #expect(event.hookEventName == "agent-turn-complete")
            #expect(event.sessionID == "thread-1")
            #expect(event.turnID == "turn-1")
            #expect(event.prompts == ["first \"one\"\n", "second 🧪"])
            #expect(event.text == "Done.\n\nTwo files changed.")
            #expect(event.launchGeneration == generation)
        }
        // The owner's command runs in the background; give it a moment.
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ownerLog.path) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(try String(contentsOf: ownerLog, encoding: .utf8) == "turn-ended|\(payload)")
    }

    /// A hook that cannot record its event says why in the status folder's
    /// `hook-errors.log`, still exiting 0, and appends a `HookFailed` record
    /// to the agent's event file when that file takes a line, so the agent
    /// shows the loss; past 64 KiB the log moves to `hook-errors.log.1`.
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
        let failure = try fixture.events(agentID)
        #expect(failure.map(\.hookEventName) == [AgentHookRuntime.failureRecordName])
        #expect(failure.first?.text == ": the hook input names no hook_event_name")
        try FileManager.default.removeItem(at: events)

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

    /// A line a full disk cut short never takes the next record with it:
    /// each record starts on a line of its own.
    @Test func aPartialLineDoesNotConsumeTheNextRecord() throws {
        let fixture = try HookFixture()
        defer { fixture.remove() }
        let agentID = UUID()
        let events = fixture.status.appendingPathComponent("\(agentID.uuidString).events")
        try Data(#"{"schemaVersion":1,"provider":"claudeCo"#.utf8).write(to: events)
        #expect(try fixture.run(
            agentID: agentID, provider: .claudeCode, generation: UUID(),
            payload: Data(#"{"session_id":"s","hook_event_name":"SessionStart"}"#.utf8)) == 0)
        let lines = AgentEventJournal.read(try Data(contentsOf: events), from: 0).records
        #expect(lines.count == 2)
        #expect(try JSONDecoder().decode(AgentRawProviderEvent.self, from: lines[1]).hookEventName == "SessionStart")
    }

    /// The script's temporary files are made by `mktemp`, under names no one
    /// can guess, and go when it ends.
    @Test func temporaryFilesAreUnguessableAndRemoved() throws {
        let fixture = try HookFixture()
        defer { fixture.remove() }
        #expect(AgentHookRuntime.script.contains("/usr/bin/mktemp"))
        #expect(!AgentHookRuntime.script.contains("clawddy-hook-$ID-$$"))
        #expect(try fixture.run(
            agentID: UUID(), provider: .claudeCode, generation: UUID(),
            payload: Data(#"{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"x"}"#.utf8)) == 0)
        let left = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter { $0.hasPrefix("clawddy-hook.") }
        #expect(left.isEmpty)
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
            // As in an agent's terminal.
            "LANG": "en_US.UTF-8",
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
