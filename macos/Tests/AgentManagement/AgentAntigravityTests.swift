import Foundation
import Testing
import UserNotifications
@testable import Ghostty

/// agy, the Antigravity CLI (`docs/clawddy-design/agy-plan.md`, stages 2 and
/// 3; facts in `docs/clawddy-refactor/cli-facts.md`, agy 1.5.17): its
/// launch, its hooks through the shared hook script, how its reports read,
/// and its input box. Launches run against the stand-in
/// (`StandIns/agy`); every folder is a fresh temporary one, and agy's data
/// folder is the sandbox's, never `~/.gemini`.
struct AgentAntigravityLaunchTests {
    /// A fresh launch adds the agent's hook folder, skips permissions in the
    /// unrestricted start mode, names a model and an effort only when the
    /// person chose them, passes no settings, and gives the first prompt as
    /// one argument, so a prompt starting with "-" is text.
    @Test func aFreshLaunch() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        var request = sandbox.request()
        request.firstPrompt = "-v, then fix it"
        let launch = try sandbox.provider.prepareLaunch(request).get()
        let folder = AntigravityProvider.hookFolder(root: sandbox.root, agentID: request.agentID)
        #expect(launch.executableURL == sandbox.bin.appendingPathComponent("agy"))
        #expect(launch.arguments == [
            "--add-dir", folder.path, "--dangerously-skip-permissions", "--prompt-interactive=-v, then fix it",
        ])
        #expect(launch.environment.isEmpty)

        request.launchProfile = AgentLaunchProfile(modelID: "example-model", reasoningEffort: "max", startMode: .standard)
        request.firstPrompt = nil
        #expect(try sandbox.provider.prepareLaunch(request).get().arguments == [
            "--add-dir", folder.path, "--model", "example-model", "--effort", "max",
        ])
        request.launchProfile = AgentLaunchProfile(modelID: " ", reasoningEffort: "", startMode: .standard)
        #expect(try sandbox.provider.prepareLaunch(request).get().arguments == ["--add-dir", folder.path])
        #expect(AgentProviderID.antigravity.executableName == "agy")
        #expect(AgentProviderID.antigravity.rawValue == "antigravity")
        #expect(AgentProviderID.antigravity.displayName == "Antigravity")
    }

    /// The hook folder holds `.agents/hooks.json`, whose commands run the
    /// shared hook script with this launch's identity, for exactly the
    /// events of agy's table: no PreToolUse, whose `{}` would deny a tool.
    /// Its path is the same at every launch of the agent; only the launch
    /// in the command changes.
    @Test func theHookFolderIsTheAgentsOwnAndStable() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        let first = sandbox.request()
        var second = first
        second.launchGeneration = UUID()
        let one = try sandbox.provider.prepareLaunch(first).get()
        let two = try sandbox.provider.prepareLaunch(second).get()
        #expect(one.arguments[0...1] == two.arguments[0...1])
        let folder = URL(fileURLWithPath: two.arguments[1])
        #expect(folder == sandbox.root.agyHookBase.appendingPathComponent("\(first.agentID.uuidString)/agy", isDirectory: true))

        let hooks = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent(".agents/hooks.json"))) as? [String: [String: Any]])
        let events = try #require(hooks["clawddy"])
        #expect(Set(events.keys) == ["SessionStart", "PreInvocation", "Stop"])
        let command = AgentHookRuntime.command(
            root: sandbox.root, provider: .antigravity, agentID: first.agentID, generation: second.launchGeneration)
        for (event, value) in events {
            #expect(NSArray(array: value as? [Any] ?? []).isEqual(to: [["type": "command", "command": command, "timeout": 10]]), "\(event)")
        }

        try sandbox.provider.cleanup(agentID: first.agentID)
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        // It goes with the agent's other files.
        _ = try sandbox.provider.prepareLaunch(first).get()
        try FileManager.default.createDirectory(at: sandbox.root.statusDir, withIntermediateDirectories: true)
        try sandbox.root.removeFiles(ofAgent: first.agentID)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// agy lists its workspace folders sorted by path and gives the model
    /// the first as the one it works in (cli-facts, "Workspace folders,
    /// sorted"): the app's hook folder sorts after any project under
    /// `/Users` or `/Volumes`, and each app identity has its own.
    @Test func theAppsHookFolderSortsAfterItsProjects() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let agent = UUID()
        let dev = AntigravityProvider.hookFolder(
            root: AgentDataRoot.resolve(directoryName: "clawddy-dev", isRunningTests: false, homeDirectory: home), agentID: agent)
        let production = AntigravityProvider.hookFolder(root: AgentDataRoot.production(homeDirectory: home), agentID: agent)
        #expect(dev.path.hasPrefix("/var/folders/") && dev.path.hasSuffix("/clawddy-dev/\(agent.uuidString)/agy"))
        #expect(production.path.hasSuffix("/ghostty-agents/\(agent.uuidString)/agy"))
        for project in ["/Users/someone/projects/lagoon", "/Users/someone/Desktop/reef", "/Volumes/Work/harbour", "/private/tmp/tide"] {
            #expect(project < dev.path && project < production.path, "\(project)")
        }
    }

    /// A launch removes the hook folder of the place it had before (inside
    /// the data folder): a conversation made with it still lists it, and
    /// agy skips a listed folder that is gone, so a resume runs one set of
    /// hooks, the new folder's.
    @Test func aLaunchRemovesTheFormerHookFolder() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        let request = sandbox.request()
        let former = AntigravityProvider.formerHookFolder(root: sandbox.root, agentID: request.agentID)
        try FileManager.default.createDirectory(at: former.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: former.appendingPathComponent(".agents/hooks.json"))
        let launch = try sandbox.provider.prepareLaunch(request).get()
        #expect(!FileManager.default.fileExists(atPath: former.path))
        let folder = AntigravityProvider.hookFolder(root: sandbox.root, agentID: request.agentID)
        #expect(Array(launch.arguments[0...1]) == ["--add-dir", folder.path])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".agents/hooks.json").path))
    }

    /// A launch whose hook folder cannot be written fails, saying where.
    @Test func anUnwritableHookFolderFailsTheLaunch() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        let request = sandbox.request()
        try FileManager.default.createDirectory(at: sandbox.root.agyHookBase, withIntermediateDirectories: true)
        try Data().write(to: sandbox.root.agyHookBase.appendingPathComponent(request.agentID.uuidString))
        guard case .failure(let issue) = sandbox.provider.prepareLaunch(request) else {
            Issue.record("A launch ran without its hooks.")
            return
        }
        guard case .launchPreparationFailed(.antigravity, let reason) = issue else {
            Issue.record("Unexpected issue \(issue)")
            return
        }
        #expect(reason.hasPrefix("Its hook folder \(AntigravityProvider.hookFolder(root: sandbox.root, agentID: request.agentID).path) could not be written"))
    }

    /// A resume names the conversation only once it exists and no process
    /// holds its presence lock; agy itself would answer in a conversation
    /// open elsewhere, and take an id it does not know as a new one.
    @Test func aResumeChecksTheConversationAndItsLock() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        var request = sandbox.request()
        request.session = AgentSessionBinding(provider: .antigravity, sessionID: "c-1")
        guard case .failure(let missing) = sandbox.provider.prepareLaunch(request) else {
            Issue.record("A conversation that does not exist was resumed.")
            return
        }
        #expect(missing == .sessionMissing(.antigravity, "c-1"))

        try sandbox.makeConversation("c-1")
        #expect(Array(try sandbox.provider.prepareLaunch(request).get().arguments.suffix(2)) == ["--conversation", "c-1"])

        let lock = sandbox.data.appendingPathComponent("presence/c-1.lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: lock)
        let holder = open(lock.path, O_RDWR)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)
        guard case .failure(let held) = sandbox.provider.prepareLaunch(request) else {
            Issue.record("A conversation open elsewhere was resumed.")
            return
        }
        #expect(held == .sessionOpenElsewhere(.antigravity, "c-1"))
        flock(holder, LOCK_UN)
        #expect(try sandbox.provider.prepareLaunch(request).get().arguments.contains("--conversation"))
    }

    /// Installed and its version, from the stand-in; agy has no sign-in
    /// status command, so none is asked.
    @Test func probeReadsTheVersionOnly() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        let health = sandbox.provider.probe(environmentPath: "\(sandbox.bin.path):/usr/bin:/bin")
        #expect(health.installation == .ready(executable: sandbox.bin.appendingPathComponent("agy").path, version: "1.5.17"))
        #expect(health.authentication == .unavailable("Antigravity reports its sign-in only in its terminal."))
        #expect(AntigravityProvider(root: sandbox.root, dataFolder: sandbox.data).probe(environmentPath: "/nowhere").installation == .missing)
    }

    /// The whole way through with the stand-in: the launch's arguments, its
    /// hook folder, the stand-in running its hooks with the shared script,
    /// and the records that come out of it. The first prompt starts with
    /// "-"; the reply comes in full from the transcript. While it runs, the
    /// conversation's lock refuses a resume; once it has ended, the resume
    /// names it, and the hook folder is where it was.
    @Test func theStandInRunsTheHooks() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        _ = try sandbox.provider.prepareIntegration().get()
        var request = sandbox.request()
        request.firstPrompt = "-v first"
        let launch = try sandbox.provider.prepareLaunch(request).get()
        let agy = try sandbox.run(launch)
        defer { agy.end() }

        let events = try sandbox.waitForEvents(request.agentID) { $0.contains { $0.hookEventName == "Stop" } }
        let conversation = try #require(events.first?.sessionID)
        #expect(events.allSatisfy { $0.sessionID == conversation && $0.launchGeneration == request.launchGeneration })
        // The stand-in's default turn: two tool calls, then the reply.
        #expect(events.map(\.hookEventName) == ["SessionStart", "PreInvocation", "PreInvocation", "PreInvocation", "Stop"])
        #expect(events.filter { $0.hookEventName == "PreInvocation" }.map(\.invocation) == ["0", "1", "2"])
        let bound = AgentDomainEvent.sessionBound(sessionID: conversation)
        #expect(events.flatMap { AntigravityProvider.hookEvents[$0.hookEventName]?($0) ?? [] } == [
            bound,
            bound, .promptSubmitted("-v first"),
            bound,
            bound,
            bound, .messageReported("Done: -v first.\nOne file changed and the 48 tests pass."),
        ])

        var resume = request
        resume.launchGeneration = UUID()
        resume.session = AgentSessionBinding(provider: .antigravity, sessionID: conversation)
        guard case .failure(let held) = sandbox.provider.prepareLaunch(resume) else {
            Issue.record("A conversation the stand-in holds was resumed.")
            return
        }
        #expect(held == .sessionOpenElsewhere(.antigravity, conversation))
        agy.end()
        try sandbox.wait("the lock is released") {
            AntigravityProvider.isHeld(sandbox.data.appendingPathComponent("presence/\(conversation).lock")) == .success(false)
        }
        let resumed = try sandbox.provider.prepareLaunch(resume).get()
        #expect(Array(resumed.arguments.suffix(3)) == ["--conversation", conversation, "--prompt-interactive=-v first"])
        #expect(resumed.arguments[0...1] == launch.arguments[0...1])
    }
}

/// agy's records through the shared hook script: its own field names, its
/// invocation, the prompt as text, the last reply read from the transcript
/// the record names, and `{}` printed whatever happens.
struct AgentAntigravityHookScriptTests {
    @Test func preInvocationRecordsThePromptAndTheInvocation() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        let marker = sandbox.folder.appendingPathComponent("injected")
        let prompt = "-n \"quoted\" $(touch \(marker.path)) `touch \(marker.path)`\n\ttwo 🧪\n\n"
        let (output, records) = try sandbox.hook(["hookEventName": "PreInvocation", "conversationId": "c-1",
                                                   "invocationNum": 0, "lastUserInput": prompt, "initialNumSteps": 1])
        #expect(output == "{}\n")
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.provider == .antigravity && record.hookEventName == "PreInvocation")
        #expect(record.sessionID == "c-1" && record.invocation == "0" && record.text == prompt)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let later = try sandbox.hook(["hookEventName": "PreInvocation", "conversationId": "c-1", "invocationNum": 2,
                                      "lastUserInput": prompt]).records
        #expect(later.first?.invocation == "2")
        #expect(AntigravityProvider.hookEvents["PreInvocation"]?(try #require(later.first)) == [.sessionBound(sessionID: "c-1")])
        #expect(AntigravityProvider.hookEvents["PreInvocation"]?(record) == [.sessionBound(sessionID: "c-1"), .promptSubmitted(prompt)])
    }

    /// Coordinator item 1: PreInvocation records the transcript's last step
    /// at that moment. The person's prompt has `USER_INPUT` last (stage 1
    /// captures: a launch's first prompt, typed prompts, a resumed
    /// conversation); agy's own wake-up after a background command has the
    /// previous reply last and is no prompt (probe `stage5/wake2`). A
    /// transcript that cannot be read records no step, notes it in
    /// `hook-errors.log`, records no failure, and the prompt counts.
    @Test func preInvocationRecordsTheTranscriptsLastStep() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        func preInvocation(_ transcript: String) throws -> AgentRawProviderEvent {
            try #require(try sandbox.hook(["hookEventName": "PreInvocation", "conversationId": "c-1", "invocationNum": 0,
                                           "lastUserInput": "go", "transcriptPath": transcript]).records.first)
        }
        let prompt = try preInvocation(try sandbox.transcript([
            ["type": "USER_INPUT", "content": "go"], ["type": "PLANNER_RESPONSE", "content": "Went."],
            ["type": "USER_INPUT", "content": "go"],
        ]))
        #expect(prompt.step == "USER_INPUT" && prompt.text == "go")
        #expect(AntigravityProvider.hookEvents["PreInvocation"]?(prompt) == [.sessionBound(sessionID: "c-1"), .promptSubmitted("go")])
        let wake = try preInvocation(try sandbox.transcript([
            ["type": "USER_INPUT", "content": "go"], ["type": "PLANNER_RESPONSE", "tool_calls": [["name": "run_command"]]],
            ["type": "GENERIC", "content": "started"], ["type": "PLANNER_RESPONSE", "content": "Waiting for it to finish."],
        ]))
        #expect(wake.step == "PLANNER_RESPONSE")
        #expect(AntigravityProvider.hookEvents["PreInvocation"]?(wake) == [.sessionBound(sessionID: "c-1"), .selfStarted])
        // Review of the fixes, defect 4: a blank line at the end is no step,
        // and only invocation 0 reads the transcript.
        let file = sandbox.home.appendingPathComponent(".gemini/antigravity-cli/brain/c-1/.system_generated/logs/transcript_full.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n\n".utf8))
        try handle.close()
        #expect(try preInvocation("~/.gemini/antigravity-cli/brain/c-1/.system_generated/logs/transcript_full.jsonl").step == "PLANNER_RESPONSE")
        let later = try #require(try sandbox.hook([
            "hookEventName": "PreInvocation", "conversationId": "c-1", "invocationNum": 1, "lastUserInput": "go",
            "transcriptPath": "~/.gemini/antigravity-cli/brain/c-1/.system_generated/logs/transcript_full.jsonl",
        ]).records.first)
        #expect(later.step == nil && later.invocation == "1")
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.statusDir.appendingPathComponent("hook-errors.log").path))

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let unread = try preInvocation("~/.gemini/antigravity-cli/brain/c-1/.system_generated/logs/transcript_full.jsonl")
        #expect(unread.hookEventName == "PreInvocation" && unread.step == nil && unread.text == "go")
        #expect(AntigravityProvider.hookEvents["PreInvocation"]?(unread) == [.sessionBound(sessionID: "c-1"), .promptSubmitted("go")])
        let log = try String(contentsOf: sandbox.root.statusDir.appendingPathComponent("hook-errors.log"), encoding: .utf8)
        #expect(log.contains("PreInvocation: could not read the transcript"))
    }

    /// The reply is the last `PLANNER_RESPONSE` with content since the
    /// turn's prompt, exactly, from a transcript named with `~/`; a turn
    /// with none records no text, never the turn before's. A last line
    /// that is not complete JSON gives no text, never an earlier step's. An
    /// event agy's table has not, and a record without a complete identity,
    /// still print `{}`.
    @Test func stopRecordsTheReplyFromTheTranscript() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        let reply = "First line.\n\n\"Second\" line with $(echo no) and \\ 🧪\n"
        let transcript = sandbox.home.appendingPathComponent(".gemini/antigravity-cli/brain/c-1/.system_generated/logs/transcript_full.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        func step(_ type: String, _ fields: [String: Any] = [:]) throws -> String {
            var object: [String: Any] = ["step_index": 0, "source": "MODEL", "type": type, "status": "DONE"]
            object.merge(fields) { $1 }
            return try #require(String(bytes: JSONSerialization.data(withJSONObject: object, options: .sortedKeys), encoding: .utf8))
        }
        let earlier = [try step("USER_INPUT", ["content": "<USER_REQUEST>\nfirst\n</USER_REQUEST>"]),
                       try step("PLANNER_RESPONSE", ["content": "The turn before."])]
        let turn = [try step("USER_INPUT", ["content": "<USER_REQUEST>\nsecond\n</USER_REQUEST>"]),
                    try step("PLANNER_RESPONSE", ["content": reply]),
                    try step("PLANNER_RESPONSE", ["tool_calls": [["name": "run_command"]], "content": ""]),
                    try step("GENERIC", ["content": "Created At: now\n48 passed"])]
        let stop: [String: Any] = ["hookEventName": "Stop", "conversationId": "c-1", "terminationReason": "NO_TOOL_CALL",
                                   "transcriptPath": "~/.gemini/antigravity-cli/brain/c-1/.system_generated/logs/transcript_full.jsonl"]

        // No newline after the last line, as a file cut short might end.
        try Data((earlier + turn).joined(separator: "\n").utf8).write(to: transcript)
        #expect(try sandbox.hook(stop).records.first?.text == reply)
        // Final review 8: a blank line at the end is no step.
        try Data(((earlier + turn).joined(separator: "\n") + "\n\n").utf8).write(to: transcript)
        #expect(try sandbox.hook(stop).records.first?.text == reply)
        try Data(((earlier + turn).joined(separator: "\n") + "\n").utf8).write(to: transcript)
        let record = try #require(try sandbox.hook(stop).records.first)
        #expect(record.text == reply)
        #expect(AntigravityProvider.hookEvents["Stop"]?(record) == [.sessionBound(sessionID: "c-1"), .messageReported(reply)])

        try Data((earlier + [try step("USER_INPUT", ["content": "third"])]).joined(separator: "\n").utf8).write(to: transcript)
        let none = try #require(try sandbox.hook(stop).records.first)
        #expect(none.text == nil && none.hookEventName == "Stop")

        // A turn that called a tool with a preamble, its last line cut short.
        let cut = String(try step("PLANNER_RESPONSE", ["content": "Final answer"]).dropLast(8))
        try Data(([turn[0], try step("PLANNER_RESPONSE", ["content": "Let me check.", "tool_calls": [["name": "x"]]]), cut])
            .joined(separator: "\n").utf8).write(to: transcript)
        let partial = try #require(try sandbox.hook(stop).records.first)
        #expect(partial.text == nil && partial.hookEventName == "Stop")

        let skipped = try sandbox.hook(["hookEventName": "PostInvocation", "conversationId": "c-1", "invocationNum": 0])
        #expect(skipped.output == "{}\n" && skipped.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.statusDir.appendingPathComponent("hook-errors.log").path))
        #expect(try sandbox.hook(stop, identity: false).output == "{}\n")
    }

    /// Review 3: a reply of 2 MB full of quotes, newlines and backslashes
    /// records its beginning, cut on a character boundary, and the hook
    /// succeeds; so does a prompt as long. Final review 3: so does one of
    /// four-byte characters fewer than `textBytes` in number (about 1 MB),
    /// in the UTF-8 locale an agent's terminal has.
    @Test func aHugeTextRecordsItsBeginning() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        let wide = String(repeating: "🧪", count: AgentHookRuntime.textBytes - 10)
        let wideTranscript = try sandbox.transcript([["type": "USER_INPUT", "content": "go"], ["type": "PLANNER_RESPONSE", "content": wide]])
        let wideStop = try #require(try sandbox.hook(["hookEventName": "Stop", "conversationId": "c-1", "transcriptPath": wideTranscript]).records.first)
        #expect(wideStop.hookEventName == "Stop")
        #expect(wideStop.text.map { wide.hasPrefix($0) && $0.utf8.count <= AgentHookRuntime.textBytes } == true)
        let unit = "a \"quoted\" \\ line é🧪\n"
        let huge = String(repeating: unit, count: 2_000_000 / unit.utf8.count)
        let transcript = try sandbox.transcript([
            ["type": "USER_INPUT", "content": "go"], ["type": "PLANNER_RESPONSE", "content": huge],
        ])
        let stop = try #require(try sandbox.hook(["hookEventName": "Stop", "conversationId": "c-1", "transcriptPath": transcript]).records.first)
        let text = try #require(stop.text)
        #expect(text.utf8.count <= AgentHookRuntime.textBytes && text.utf8.count > AgentHookRuntime.textBytes - 4)
        #expect(huge.hasPrefix(text))
        let prompt = try #require(try sandbox.hook(["hookEventName": "PreInvocation", "conversationId": "c-1", "invocationNum": 0,
                                                     "lastUserInput": huge]).records.first)
        #expect(prompt.text.map { huge.hasPrefix($0) && $0.utf8.count <= AgentHookRuntime.textBytes } == true)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.statusDir.appendingPathComponent("hook-errors.log").path))
    }

    /// Review 3: a transcript that cannot be read is a recorded hook
    /// failure, not a silent loss of the reply.
    @Test func anUnreadableTranscriptIsAFailure() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        let transcript = try sandbox.transcript([["type": "PLANNER_RESPONSE", "content": "Reply."]])
        let file = sandbox.home.appendingPathComponent(String(transcript.dropFirst(2)))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let records = try sandbox.hook(["hookEventName": "Stop", "conversationId": "c-1", "transcriptPath": transcript]).records
        #expect(records.map(\.hookEventName) == [AgentHookRuntime.failureRecordName])
        #expect(records.first?.text?.hasPrefix("Stop: could not read the transcript") == true)
    }

    /// Review 3: the script reads only the last `transcriptTailBytes` of
    /// the transcript: a reply further back than that is not found, and the
    /// report's message stands.
    @Test func onlyTheTranscriptsTailIsRead() throws {
        let sandbox = try AgySandbox()
        defer { sandbox.remove() }
        let output = String(repeating: "x", count: 1 << 20)
        let tools = (0...AgentHookRuntime.transcriptTailBytes >> 20).map { _ in ["type": "GENERIC", "content": output] }
        let transcript = try sandbox.transcript([["type": "USER_INPUT", "content": "go"], ["type": "PLANNER_RESPONSE", "content": "Far back."]] + tools)
        let stop = try #require(try sandbox.hook(["hookEventName": "Stop", "conversationId": "c-1", "transcriptPath": transcript]).records.first)
        #expect(stop.hookEventName == "Stop" && stop.text == nil)
    }

    /// Review 3, as the script's text shows it: two `mktemp` calls before
    /// `reply()`, which every hook runs, two inside it, which only a record
    /// carrying a reply runs, and none after.
    @Test func theScriptMakesTwoTemporaryFilesOutsideReply() throws {
        let script = AgentHookRuntime.script
        let reply = try #require(script.range(of: "\nreply() {"))
        let end = try #require(script.range(of: "\n}\n", range: reply.upperBound..<script.endIndex))
        #expect(script[..<reply.lowerBound].components(separatedBy: "/usr/bin/mktemp").count - 1 == 2)
        #expect(script[reply.lowerBound..<end.upperBound].components(separatedBy: "/usr/bin/mktemp").count - 1 == 2)
        #expect(script[end.upperBound...].components(separatedBy: "/usr/bin/mktemp").count - 1 == 0)
        #expect(!script.contains("export EVENTS EVENT_LINE"))
    }
}

/// How agy's reports read (plan traps 1 and 2, rulings 1, 6, 7 and 8), each
/// against the rule Claude Code and Codex keep (`AgentReportRules.standard`).
struct AgentAntigravityReducerTests {
    private static let rules = AntigravityProvider(
        root: AgentDataRoot(url: URL(fileURLWithPath: "/nonexistent")), dataFolder: URL(fileURLWithPath: "/nonexistent")).entry.reports

    @Test func theTableValues() {
        let nowhere = URL(fileURLWithPath: "/nonexistent")
        #expect(Self.rules == AgentReportRules(
            doneWithMessageCompletes: true, signInStandTime: 2, workingMessageIsActivity: false,
            turnStartDelay: 0, askingAtStartIsStarted: true, queuedMessagesRunNextTurn: true))
        #expect(Self.rules.workingStartsTurn)
        #expect(ClaudeCodeProvider(root: AgentDataRoot(url: nowhere)).entry.reports == .standard)
        var codex = AgentReportRules.standard
        codex.turnStartDelay = 3
        #expect(CodexProvider(root: AgentDataRoot(url: nowhere), configFile: nowhere).entry.reports == codex)
        #expect(AgentReportRules.standard == AgentReportRules(
            doneWithMessageCompletes: false, signInStandTime: 0, workingMessageIsActivity: true,
            turnStartDelay: 1, askingAtStartIsStarted: false, queuedMessagesRunNextTurn: false))
        #expect(!AgentReportRules.standard.workingStartsTurn && !codex.workingStartsTurn)
    }

    /// Review 2 (i): a sign-in failure starts no turn. A saved last reply
    /// stays, and a repeated sign-in report changes nothing and notifies
    /// nobody.
    @Test func aSignInFailureStartsNoTurn() throws {
        let auth = "state=blocked:kind=auth:app=antigravity:msg=\(b64("Sign in required"))"
        let done = try Turn.start(rules: Self.rules).working().prompt("go").report("state=done:app=antigravity:msg=\(b64("Reply."))")
        let failed = try done.report(auth).apply(.signInSettled(generation: done.generation))
        #expect(failed.state.record.problem?.kind == .loginExpired && failed.state.record.lastMessage == "Reply.")
        let again = try failed.report(auth).apply(.signInSettled(generation: done.generation))
        #expect(again.state.record == failed.state.record && !again.effects.contains(.failed))
        // Claude's sign-in report, counted at once, keeps the reply too.
        let claude = try Turn.start(rules: .standard).working().prompt("go").report("state=done:app=antigravity")
            .provider(.messageReported("Reply.")).report(auth)
        #expect(claude.state.record.problem?.kind == .loginExpired && claude.state.record.lastMessage == "Reply.")
    }

    /// Review 2 (ii): the next report past the sign-in clears the login
    /// problem a standing sign-in report raised, never one a failed turn
    /// raised (Claude's StopFailure, then its `idle`).
    @Test func aReportPastTheSignInClearsItsProblem() throws {
        let auth = "state=blocked:kind=auth:app=antigravity:msg=\(b64("Sign in required"))"
        let launched = try Turn.start(rules: Self.rules, ready: false).report(auth)
        let failed = launched.apply(.signInSettled(generation: launched.generation))
        #expect(failed.state.record.problem?.kind == .loginExpired && failed.effects.contains(.startedAsking))
        let signedIn = try failed.report("state=idle:app=antigravity")
        #expect(signedIn.state.record.problem == nil && signedIn.state.record.state == .finished && signedIn.state.inputReady)
        let claude = try Turn.start(rules: .standard).working().prompt("go")
            .provider(.turnFailed(AgentFailure(error: "authentication_failed", text: "OAuth token expired")))
            .report("state=idle:app=antigravity")
        #expect(claude.state.record.problem?.kind == .loginExpired)
    }

    /// Review 1: a turn's state does not depend on whether its `working` or
    /// its prompt's record comes first, nor on its length. Each order ends
    /// finished, unread, with the full reply, the prompt recorded once and
    /// never as queued.
    @Test func theTurnDoesNotDependOnWhichComesFirst() throws {
        let done = "state=done:app=antigravity:msg=\(b64("Reply."))"
        let full = AgentDomainEvent.messageReported("Reply.\nAll of it.")
        func finished(_ turn: Turn) -> Bool {
            turn.state.record.state == .finished && turn.state.record.unread
                && turn.state.record.lastMessage == "Reply.\nAll of it." && turn.state.record.queued == nil
                && turn.state.record.prompts.map(\.text) == ["go"] && turn.state.lastAppliedCompletion != nil
        }
        let start = try Turn.start(rules: Self.rules)
        // (a) The prompt's record, then `working`; a short turn.
        #expect(finished(try start.prompt("go").working().provider(full).report(done)))
        // (b) `working`, `done`, then the prompt's record and the Stop record.
        #expect(finished(try start.working().report(done).prompt("go").provider(full)))
        // (c) `working`, the prompt's record much later.
        let late = try start.working()
        #expect(late.state.record.state == .working && late.state.turnState != .starting)
        #expect(finished(try late.prompt("go").provider(full).report(done)))
        // (d) As (b), with a key typed (`idle`) before the records come.
        #expect(finished(try start.working().report(done).report("state=idle:app=antigravity").prompt("go").provider(full)))
        // Claude's `working` still waits for its delay.
        #expect(try Turn.start(rules: .standard).working().state.turnState == .starting)
    }

    /// Trap 1: every agy turn ends in a `done` with the reply's first line.
    /// It completes the turn, and that line is the reply until the full one
    /// comes; under Claude's rule it would complete nothing.
    @Test func aDoneWithAMessageCompletesTheTurn() throws {
        let agy = try Turn.start(rules: Self.rules).working().prompt("go").report("state=done:app=antigravity:msg=\(b64("Reply."))")
        #expect(agy.state.record.state == .finished && agy.state.record.unread)
        #expect(agy.effects.contains(.completed) && agy.state.lastAppliedCompletion != nil)
        #expect(agy.state.record.lastMessage == "Reply." && !agy.state.record.interrupted)
        let claude = try Turn.start(rules: .standard).working().prompt("go").report("state=done:app=antigravity:msg=\(b64("Reply."))")
        #expect(!claude.effects.contains(.completed) && claude.state.lastAppliedCompletion == nil)
    }

    /// Ruling 1: a sign-in report changes nothing until it has stood; under
    /// Claude's rule it fails the agent at once.
    @Test func aSignInReportWaitsToStand() throws {
        let auth = "state=blocked:kind=auth:app=antigravity:msg=\(b64("Sign in required"))"
        let agy = try Turn.start(rules: Self.rules, ready: false).report(auth)
        #expect(agy.state.pendingSignIn != nil && agy.effects.isEmpty)
        #expect(agy.state.record.problem == nil && agy.state.processState == .launching && !agy.state.inputReady)
        let settled = agy.apply(.signInSettled(generation: agy.generation))
        #expect(settled.state.record.problem?.kind == .loginExpired && settled.effects.contains(.failed))
        let claude = try Turn.start(rules: .standard, ready: false).report(auth)
        #expect(claude.state.record.problem?.kind == .loginExpired)
    }

    /// Ruling 6: a resumed conversation's `working` carries its title, which
    /// is no step under way; Claude's names the step.
    @Test func aWorkingMessageIsNoActivity() throws {
        let working = "state=working:app=antigravity:msg=\(b64("Harbour Palette"))"
        #expect(try Turn.start(rules: Self.rules).report(working).prompt("go").report(working).state.record.activity == nil)
        #expect(try Turn.start(rules: .standard).report(working).prompt("go").report(working).state.record.activity == "Harbour Palette")
    }

    /// Ruling 8: the first key typed after a finished turn makes agy report
    /// `idle`; the agent stays finished and unread, waiting on the person.
    @Test func typingAfterDoneLeavesItFinished() throws {
        let done = try Turn.start(rules: Self.rules).working().prompt("go").report("state=done:app=antigravity:msg=\(b64("Reply."))")
        let typed = try done.report("state=idle:app=antigravity")
        #expect(typed.state.record.state == .finished && typed.state.record.unread && typed.state.record.isWaitingOnYou)
        #expect(!typed.state.record.interrupted && typed.state.record.lastMessage == "Reply.")
    }

    /// One agent's reducer run, applied event by event.
    private struct Turn {
        let rules: AgentReportRules
        let generation: UUID
        let state: AgentRuntimeSnapshot
        let effects: [AgentRuntimeEffect]

        /// A launch, and its `idle` when `ready`.
        static func start(rules: AgentReportRules, ready: Bool = true) throws -> Turn {
            let generation = UUID()
            let launched = Turn(rules: rules, generation: generation, result: AgentStateReducer.reduce(
                AgentRuntimeSnapshot(), event: .launchRequested(generation: generation), rules: rules))
            return ready ? try launched.report("state=idle:app=antigravity") : launched
        }

        private init(rules: AgentReportRules, generation: UUID, result: (state: AgentRuntimeSnapshot, effects: [AgentRuntimeEffect])) {
            self.rules = rules
            self.generation = generation
            state = result.state
            effects = result.effects
        }

        func apply(_ event: AgentRuntimeEvent) -> Turn {
            Turn(rules: rules, generation: generation, result: AgentStateReducer.reduce(state, event: event, rules: rules))
        }

        func provider(_ event: AgentDomainEvent) -> Turn {
            apply(.provider(generation: generation, provider: .antigravity, eventID: UUID().uuidString, event: event, isViewed: false))
        }

        func report(_ body: String) throws -> Turn { provider(.programStatus(try programStatus(body))) }
        func working() throws -> Turn { try report("state=working:app=antigravity") }
        func prompt(_ text: String) -> Turn { provider(.promptSubmitted(text)) }
    }
}

/// agy agents through the bridge, as its terminal and hooks report them.
@MainActor
struct AgentAntigravityBridgeTests {
    /// Ruling 1: a sign-in report that stands half a second and gives way
    /// to `idle` fails nothing; one that stands 2 s stops the agent with
    /// the login problem, as the app shows one today.
    @Test func theSignInReportMustStandTwoSeconds() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let brief = try h.addAgent("Brief", provider: .antigravity)
        let stuck = try h.addAgent("Stuck", provider: .antigravity)
        h.start()
        for id in [brief, stuck] {
            try h.activate(id)
            try h.osc(id, "state=blocked:kind=auth:app=antigravity:msg=\(b64("Sign in required"))")
        }
        h.scheduler.advance(by: 0.5)
        try h.osc(brief, "state=idle:app=antigravity")
        #expect(try h.agent(brief).runtime.inputReady)
        h.scheduler.advance(by: 1.49)
        #expect(try h.agent(stuck).record.problem == nil)
        h.scheduler.advance(by: 0.02)
        let agent = try h.agent(stuck)
        #expect(agent.record.state == .problem && agent.record.problem?.kind == .loginExpired)
        // agy has no /login.
        #expect(agent.record.sentence(cli: .antigravity) == .app("Login expired. Open it and sign in again."))
        h.scheduler.advance(by: 5)
        #expect(try h.agent(brief).record.problem == nil && h.agent(brief).record.state == .finished)
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(stuck.uuidString).error"])
        // It has started: the start limit cannot replace the login problem.
        h.scheduler.advance(by: AgentBridge.startLimit)
        #expect(agent.record.problem?.kind == .loginExpired)
        // Signed in at last: its `idle` clears the problem.
        try h.osc(stuck, "state=idle:app=antigravity")
        #expect(agent.record.problem == nil && agent.record.state == .finished && agent.runtime.inputReady)
    }

    /// Review 2 (iv): keys typed while it starts are not delivered into its
    /// sign-in screen; they end as when an agent asks.
    @Test func heldKeysDoNotGoIntoTheSignIn() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        var delivered: [UUID] = []
        var dropped: [UUID] = []
        h.bridge.onKeysReady = { delivered.append($0) }
        h.bridge.onKeysNotHeld = { dropped.append($0) }
        try h.activate(id)
        try h.osc(id, "state=blocked:kind=auth:app=antigravity:msg=\(b64("Sign in required"))")
        #expect(h.bridge.holdsKeys(for: id))
        h.scheduler.advance(by: 2.01)
        #expect(delivered.isEmpty && dropped == [id] && !h.bridge.holdsKeys(for: id))
    }

    /// Review 4: agy's folder-trust dialog at start-up is no turn. Answered,
    /// a new agent is a new agent with no output, and a launch with a first
    /// prompt goes on to that prompt's turn; waiting past the start limit
    /// keeps the question.
    @Test func theTrustDialogAtStartIsNoTurn() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        let trust = "state=blocked:kind=permission:app=antigravity:msg=\(b64("Trust this folder?"))"
        try h.activate(id)
        try h.osc(id, trust)
        let agent = try h.agent(id)
        #expect(agent.record.state == .asks && agent.record.question == "Trust this folder?")
        h.scheduler.advance(by: AgentBridge.startLimit + 1)
        #expect(agent.record.state == .asks && agent.record.problem == nil)
        try h.osc(id, "state=idle:app=antigravity")
        #expect(agent.record.state == .finished && !agent.record.interrupted && agent.record.lastMessage == nil)
        #expect(agent.record.sentence(cli: .antigravity) == .app("No output yet"))

        let project = try #require(h.config.projects.first)
        let entry = try #require(h.bridge.startAgent(
            task: "fix the tide chart", provider: .antigravity, launchProfile: AgentLaunchProfile(),
            config: h.config, project: project, host: h.host))
        try h.osc(entry.id, trust)
        try h.osc(entry.id, "state=idle:app=antigravity")
        let started = try h.agent(entry.id)
        #expect(started.record.state == .working && !started.record.interrupted)
        try h.osc(entry.id, "state=working:app=antigravity")
        try agyHook(h, entry.id, "PreInvocation", session: "c-1", invocation: "0", text: "fix the tide chart")
        try h.osc(entry.id, "state=done:app=antigravity:msg=\(b64("Done."))")
        #expect(started.record.state == .finished && started.record.lastMessage == "Done.")
    }

    /// Final review 1, with the real order of records (probe
    /// `stage5/trustprompt`, agy 1.5.17): the trust report, then behind the
    /// dialog SessionStart, PreInvocation 0 and Stop with no report, then
    /// `idle` when the person accepts. The tile asks until then; then the
    /// agent is finished and unread with the reply, notified once, and the
    /// next prompt is that turn's own, not a queued one.
    @Test func aFirstPromptRunBehindTheTrustDialog() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        h.start()
        let project = try #require(h.config.projects.first)
        let id = try #require(h.bridge.startAgent(
            task: "fix the tide chart", provider: .antigravity, launchProfile: AgentLaunchProfile(),
            config: h.config, project: project, host: h.host)).id
        try h.osc(id, "state=blocked:kind=auth:app=antigravity:msg=\(b64("Sign in required"))")
        try h.osc(id, "state=blocked:kind=permission:app=antigravity:msg=\(b64("Trust this folder?"))")
        try agyHook(h, id, "SessionStart", session: "c-1", text: "fix the tide chart")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", step: "USER_INPUT", text: "fix the tide chart")
        try agyHook(h, id, "Stop", session: "c-1", text: "Done.\nAll of it.")
        let agent = try h.agent(id)
        #expect(agent.record.state == .asks && agent.record.question == "Trust this folder?")
        #expect(agent.record.sentence(cli: .antigravity) == .cli("Trust this folder?"))
        #expect(h.notifier.posted.isEmpty || h.notifier.posted.allSatisfy { !$0.identifier.hasSuffix(".completed") })
        try h.osc(id, "state=idle:app=antigravity")
        #expect(agent.record.state == .finished && agent.record.unread && !agent.record.interrupted)
        #expect(agent.record.lastMessage == "Done.\nAll of it.")
        #expect(h.notifier.posted.filter { $0.identifier.hasSuffix(".completed") }.count == 1)
        #expect(agent.record.prompts.map(\.text) == ["fix the tide chart"])
        // The next prompt, as agy reports it: its own turn's.
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", step: "USER_INPUT", text: "run the tests")
        #expect(agent.record.prompts.map(\.text) == ["fix the tide chart", "run the tests"])
        #expect(agent.record.queued == nil && agent.record.sentence(cli: .antigravity) == .cli("run the tests"))
        try agyHook(h, id, "Stop", session: "c-1", text: "Tests pass.")
        try h.osc(id, "state=done:app=antigravity:msg=\(b64("Tests pass."))")
        #expect(agent.record.state == .finished && agent.record.lastMessage == "Tests pass.")
    }

    /// Final review 1, the order the coordinator asked to cover: `working`
    /// and `done` arriving behind the dialog leave it asking until `idle`.
    @Test func aTurnReportedBehindTheTrustDialogKeepsItAsking() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        h.start()
        let project = try #require(h.config.projects.first)
        let id = try #require(h.bridge.startAgent(
            task: "fix the tide chart", provider: .antigravity, launchProfile: AgentLaunchProfile(),
            config: h.config, project: project, host: h.host)).id
        try h.osc(id, "state=blocked:kind=permission:app=antigravity:msg=\(b64("Trust this folder?"))")
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", step: "USER_INPUT", text: "fix the tide chart")
        let agent = try h.agent(id)
        #expect(agent.record.state == .asks && !agent.runtime.inputReady)
        try agyHook(h, id, "Stop", session: "c-1", text: "Done.")
        try h.osc(id, "state=done:app=antigravity:msg=\(b64("Done."))")
        #expect(agent.record.state == .asks && agent.record.question == "Trust this folder?")
        try h.osc(id, "state=idle:app=antigravity")
        #expect(agent.record.state == .finished && agent.record.unread && agent.record.lastMessage == "Done.")
        #expect(h.notifier.posted.filter { $0.identifier.hasSuffix(".completed") }.count == 1)
    }

    /// Final review 7 and coordinator item 2: declining the trust dialog
    /// ("No, exit": agy reports `idle`, then exits with status 0). A process
    /// that has gone never asks: the agent is as the app's rule for an exit
    /// with status 0 has it, finished, here with the reply of the first
    /// prompt that ran behind the dialog. With no `idle` (the process
    /// simply ends) it is the same; with no prompt behind the dialog it is
    /// as it was ("No output yet").
    @Test func declinedTrustLeavesNoQuestion() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let plain = try h.addAgent("Plain", provider: .antigravity)
        let silent = try h.addAgent("Silent", provider: .antigravity)
        h.start()
        let trust = "state=blocked:kind=permission:app=antigravity:msg=\(b64("Trust this folder?"))"
        let project = try #require(h.config.projects.first)
        let behind = try #require(h.bridge.startAgent(
            task: "fix the tide chart", provider: .antigravity, launchProfile: AgentLaunchProfile(),
            config: h.config, project: project, host: h.host)).id
        try h.osc(behind, trust)
        try agyHook(h, behind, "PreInvocation", session: "c-1", invocation: "0", step: "USER_INPUT", text: "fix the tide chart")
        try agyHook(h, behind, "Stop", session: "c-1", text: "Done.")
        try h.providerQuit(behind, status: 0)
        let first = try h.agent(behind)
        #expect(first.record.state == .finished && first.record.lastMessage == "Done." && first.record.question == nil)

        try h.activate(plain)
        try h.osc(plain, trust)
        try h.osc(plain, "state=idle:app=antigravity")
        try h.providerQuit(plain, status: 0)
        let second = try h.agent(plain)
        #expect(second.record.state == .finished && second.record.sentence(cli: .antigravity) == .app("No output yet"))

        try h.activate(silent)
        try h.osc(silent, trust)
        try h.providerQuit(silent, status: 0)
        #expect(try h.agent(silent).record.state == .finished && h.agent(silent).record.question == nil)
    }

    /// Final review 2: an agent asking at start (three agy agents on the
    /// trust dialog) holds no start slot: a fourth agent, of another CLI,
    /// starts.
    @Test func agentsAskingAtStartHoldNoStartSlot() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let asking = try (0..<AgentBridge.startConcurrency).map { try h.addAgent("agy \($0)", provider: .antigravity) }
        let other = try h.addAgent("Claude", provider: .claudeCode)
        h.start()
        for id in asking {
            try h.activate(id)
            try h.osc(id, "state=blocked:kind=permission:app=antigravity:msg=\(b64("Trust this folder?"))")
        }
        try h.activate(other)
        h.scheduler.advance(by: 0)
        #expect(try !h.agent(other).waitsToStart)
        #expect(h.providers.launchRequests.map(\.agentID).contains(other))
    }

    /// A turn from a first prompt: its prompt from the first PreInvocation
    /// only, the cut reply from `done`, then the full reply from Stop in its
    /// place; the conversation bound from every record, and bound again
    /// when `/clear` gives it a new id.
    @Test func aTurnItsReplyAndItsConversation() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        h.start()
        let project = try #require(h.config.projects.first)
        let entry = try #require(h.bridge.startAgent(
            task: "fix the tide chart", provider: .antigravity, launchProfile: AgentLaunchProfile(),
            config: h.config, project: project, host: h.host))
        let id = entry.id
        try h.osc(id, "state=idle:app=antigravity")
        #expect(try h.agent(id).record.state == .working)
        // The first prompt's records come up to 1.24 s after its `working`.
        try h.osc(id, "state=working:app=antigravity")
        h.scheduler.advance(by: 1.24)
        try agyHook(h, id, "SessionStart", session: "c-1", text: nil)
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", text: "fix the tide chart")
        #expect(try h.binding(id).sessionID == "c-1")
        #expect(try h.agent(id).record.queued == nil && h.agent(id).record.state == .working)
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "1", text: "fix the tide chart")
        // Cut as agy cuts it: 199 characters and "…".
        let cut = String(repeating: "word ", count: 39) + "word…"
        try h.osc(id, "state=done:app=antigravity:msg=\(b64(cut))")
        let agent = try h.agent(id)
        #expect(agent.record.state == .finished && agent.record.lastMessage == cut)
        #expect(agent.record.prompts.map(\.text) == ["fix the tide chart"])
        let full = String(repeating: "word ", count: 60) + "\n\nSecond paragraph."
        try agyHook(h, id, "Stop", session: "c-1", text: full)
        #expect(agent.record.lastMessage == full)

        // A new id with no SessionStart (an id agy did not know, or a
        // resumed conversation's): the PreInvocation binds it.
        h.view(id)
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-2", invocation: "0", text: "start over")
        #expect(try h.binding(id).sessionID == "c-2")
        // The full reply first, then the `done`: the full reply stays. The
        // Stop record alone binds too.
        try agyHook(h, id, "Stop", session: "c-3", text: "All done.\nTwo lines.")
        #expect(try h.binding(id).sessionID == "c-3")
        try h.osc(id, "state=done:app=antigravity:msg=\(b64("All done."))")
        #expect(agent.record.lastMessage == "All done.\nTwo lines.")
        #expect(agent.record.prompts.map(\.text) == ["fix the tide chart", "start over"])

        // After a restart its next launch resumes the last id.
        try h.providerQuit(id, status: 0)
        try h.restart()
        try h.activate(id)
        #expect(h.providers.launchRequests.last?.session?.sessionID == "c-3")
    }

    /// Review 7: the binding is written only when it changes, though agy
    /// names its conversation in every record.
    @Test func theBindingIsWrittenOnlyWhenItChanges() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        try agyLaunch(h, id)
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", text: "go")
        let file = h.statusFile(id, "session.json")
        #expect(h.exists(file))
        try FileManager.default.removeItem(at: file)
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "1", text: "go")
        try agyHook(h, id, "Stop", session: "c-1", text: "Done.")
        #expect(!h.exists(file))
        try agyHook(h, id, "PreInvocation", session: "c-2", invocation: "0", text: "go on")
        #expect(try h.binding(id).sessionID == "c-2")
    }

    /// A question and a permission: the agent asks, with the report's
    /// words, and works again once answered; the PreInvocation after the
    /// answer is no prompt.
    @Test func aQuestionAndAPermission() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        try agyLaunch(h, id)
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", text: "pick a palette")
        try h.osc(id, "state=blocked:kind=question:app=antigravity:msg=\(b64("Which palette, the harbour one or the dune one?"))")
        let agent = try h.agent(id)
        #expect(agent.record.state == .asks && agent.record.question == "Which palette, the harbour one or the dune one?")
        #expect(h.notifier.posted.map(\.identifier) == ["clawddy.\(id.uuidString).waiting"])
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "1", text: "pick a palette")
        #expect(agent.record.state == .working && agent.record.question == nil)
        try h.osc(id, "state=blocked:kind=permission:app=antigravity:msg=\(b64("Approve Bash: make test"))")
        #expect(agent.record.state == .asks && agent.record.question == "Approve Bash: make test")
        try h.osc(id, "state=working:app=antigravity")
        try h.osc(id, "state=done:app=antigravity:msg=\(b64("harbour"))")
        #expect(agent.record.state == .finished && agent.record.lastMessage == "harbour")
        #expect(agent.record.prompts.map(\.text) == ["pick a palette"])
    }

    /// A failure comes from the terminal's report alone (no hook runs).
    @Test func aFailureReportedByTheTerminal() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        try agyLaunch(h, id)
        try h.osc(id, "state=error:app=antigravity:msg=\(b64("failed to construct executor: plan model not specified"))")
        let agent = try h.agent(id)
        #expect(agent.record.state == .problem && agent.record.problem?.kind == .error)
        #expect(agent.record.problem?.text == "failed to construct executor: plan model not specified")
        // The first key after it reports `idle`, which leaves the problem.
        try h.osc(id, "state=idle:app=antigravity")
        #expect(agent.record.state == .problem)
    }

    /// Plan trap 6: an interrupt gives back the messages queued during the
    /// turn. They are the person's: never wiped, the send is refused. No
    /// path sends agy Control-C: here, after a plain send, and after an
    /// interrupt that gave back nothing.
    @Test func anInterruptWithAQueuedMessage() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        try agyLaunch(h, id)
        h.host.screens[id] = AgyScreens.workingQueued
        try h.osc(id, "state=working:app=antigravity")
        h.scheduler.advance(by: 3)
        var result: AgentSendResult?
        h.bridge.send("instead", to: id, by: .person, interrupting: true) { result = $0 }
        #expect(h.host.inputs[id] == [.escape])
        h.host.screens[id] = AgyScreens.interruptedGivenBack
        try h.osc(id, "state=idle:app=antigravity")
        h.scheduler.advance(by: 1)
        #expect(result == .holdsText)
        #expect(h.host.inputs[id] == [.escape])
        #expect(try h.agent(id).record.interrupted)

        // Nothing given back: the text goes in.
        h.host.screens[id] = AgyScreens.working
        try h.osc(id, "state=working:app=antigravity")
        h.scheduler.advance(by: 3)
        result = nil
        h.bridge.send("again", to: id, by: .person, interrupting: true) { result = $0 }
        h.host.screens[id] = AgyScreens.doneBareBox
        try h.osc(id, "state=idle:app=antigravity")
        h.scheduler.advance(by: 1)
        #expect(result == .sent)
        // A plain send while it works: agy queues it.
        h.host.screens[id] = AgyScreens.working
        try h.osc(id, "state=working:app=antigravity")
        #expect(try h.agent(id).record.state == .working)
        result = nil
        h.bridge.send("one more", to: id, by: .app) { result = $0 }
        #expect(result == .sent)
        #expect(h.host.inputs[id] == [.escape, .escape, .paste("again"), .enter, .paste("one more"), .enter])
        #expect(h.host.inputs[id]?.contains(.interrupt) == false)
    }

    /// Stage 5, real agy: a message sent while agy works waits in agy, which
    /// reports it only when its own turn starts. The send is the sign it
    /// waits: the sentence is the running turn's instruction, then "You
    /// sent: …", until that message's turn starts.
    @Test func aMessageSentWhileItWorksShowsAsQueued() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        try agyLaunch(h, id)
        h.host.screens[id] = AgyScreens.working
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", text: "count slowly")
        h.bridge.send("queued words", to: id, by: .person) { _ in }
        let agent = try h.agent(id)
        #expect(agent.record.queued == "queued words")
        #expect(agent.record.sentence(cli: .antigravity) == .cli("count slowly You sent: queued words"))
        try agyHook(h, id, "Stop", session: "c-1", text: "Counted.")
        try h.osc(id, "state=done:app=antigravity:msg=\(b64("Counted."))")
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", text: "queued words")
        #expect(agent.record.state == .working && agent.record.queued == nil)
        #expect(agent.record.sentence(cli: .antigravity) == .cli("queued words"))
        #expect(agent.record.prompts.map(\.text) == ["count slowly", "queued words"])
    }

    /// Coordinator item 1 (probe `stage5/wake2`, agy 1.5.17): a long command
    /// runs in the background, the turn's Stop comes, then agy starts
    /// invocation 0 itself with the previous prompt, and its Stop brings
    /// the new reply. That is no second prompt; the agent ends finished,
    /// unread, with the new reply.
    @Test func aWakeUpAfterABackgroundCommandIsNoPrompt() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        try agyLaunch(h, id)
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", step: "USER_INPUT", text: "sleep, then say slept")
        try agyHook(h, id, "Stop", session: "c-1", text: "Waiting for sleep 20 to finish.")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", step: "PLANNER_RESPONSE", text: "sleep, then say slept")
        try agyHook(h, id, "Stop", session: "c-1", text: "slept")
        try h.osc(id, "state=done:app=antigravity:msg=\(b64("slept"))")
        let agent = try h.agent(id)
        #expect(agent.record.prompts.map(\.text) == ["sleep, then say slept"])
        #expect(agent.record.state == .finished && agent.record.unread && agent.record.lastMessage == "slept")
    }

    /// The same words sent twice by the person are two prompts.
    @Test func aRepeatedPromptIsTwoPrompts() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        try agyLaunch(h, id)
        for reply in ["One.", "Two."] {
            try h.osc(id, "state=working:app=antigravity")
            try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", step: "USER_INPUT", text: "continue")
            try agyHook(h, id, "Stop", session: "c-1", text: reply)
            try h.osc(id, "state=done:app=antigravity:msg=\(b64(reply))")
        }
        let agent = try h.agent(id)
        #expect(agent.record.prompts.map(\.text) == ["continue", "continue"])
        #expect(agent.record.state == .finished && agent.record.lastMessage == "Two.")
    }

    /// Review of the fixes, defect 3: a wake-up turn (agy starting an
    /// invocation itself) records no prompt, and the next real prompt, its
    /// record before its `working`, is recorded once, not queued; its
    /// `working` reads the unread reply (agy's prompt records change only
    /// the prompts, `everyMergeOfReportsAndRecords`).
    @Test func aWakeUpTurnWaitsForNoPrompt() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        try agyLaunch(h, id)
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", step: "USER_INPUT", text: "sleep, then say slept")
        try agyHook(h, id, "Stop", session: "c-1", text: "Waiting.")
        try h.osc(id, "state=done:app=antigravity:msg=\(b64("Waiting."))")
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", step: "PLANNER_RESPONSE", text: "sleep, then say slept")
        try agyHook(h, id, "Stop", session: "c-1", text: "slept")
        try h.osc(id, "state=done:app=antigravity:msg=\(b64("slept"))")
        let agent = try h.agent(id)
        #expect(agent.record.state == .finished && agent.record.unread && agent.record.lastMessage == "slept")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", step: "USER_INPUT", text: "next")
        #expect(agent.record.prompts.map(\.text) == ["sleep, then say slept", "next"] && agent.record.queued == nil)
        try h.osc(id, "state=working:app=antigravity")
        #expect(!agent.record.unread)
        #expect(agent.record.sentence(cli: .antigravity) == .cli("next"))
        try agyHook(h, id, "Stop", session: "c-1", text: "Next.")
        try h.osc(id, "state=done:app=antigravity:msg=\(b64("Next."))")
        #expect(agent.record.prompts.map(\.text) == ["sleep, then say slept", "next"])
        #expect(agent.record.state == .finished && agent.record.lastMessage == "Next.")
    }

    /// Review of the fixes, defect 3: a turn a `blocked` report started,
    /// its prompt's record first, then approved, `done`, and a late Stop:
    /// one completion, one notification.
    @Test func aTurnABlockedReportStartedCompletesOnce() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        try agyLaunch(h, id)
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", step: "USER_INPUT", text: "run it")
        try h.osc(id, "state=blocked:kind=permission:app=antigravity:msg=\(b64("Approve Bash: make"))")
        let agent = try h.agent(id)
        #expect(agent.record.state == .asks)
        try h.osc(id, "state=working:app=antigravity")
        try h.osc(id, "state=done:app=antigravity:msg=\(b64("Ran."))")
        try agyHook(h, id, "Stop", session: "c-1", text: "Ran.\nIt all passed.")
        #expect(agent.record.state == .finished && agent.record.lastMessage == "Ran.\nIt all passed.")
        #expect(h.notifier.posted.filter { $0.identifier.hasSuffix(".completed") }.count == 1)
    }

    /// Review of the fixes, defect 5: the terminal closed by the person while
    /// they view an agent whose turn ended behind the dialog leaves it read;
    /// a terminal that closes under it leaves the reply and the problem,
    /// not also an unread mark.
    @Test func aCloseDuringTheDialogKeepsTheReplyWithoutAnUnreadMark() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        h.start()
        let project = try #require(h.config.projects.first)
        var ids: [UUID] = []
        for task in ["fix the chart", "tidy the legend"] {
            let id = try #require(h.bridge.startAgent(
                task: task, provider: .antigravity, launchProfile: AgentLaunchProfile(),
                config: h.config, project: project, host: h.host)).id
            try h.osc(id, "state=blocked:kind=permission:app=antigravity:msg=\(b64("Trust this folder?"))")
            try agyHook(h, id, "PreInvocation", session: "c-\(ids.count)", invocation: "0", step: "USER_INPUT", text: task)
            try agyHook(h, id, "Stop", session: "c-\(ids.count)", text: "Done.")
            ids.append(id)
        }
        h.bridge.isViewed = { $0 == ids[0] }
        h.bridge.surfaceClosed(id: ids[0], generation: try h.generation(ids[0]), processAlive: true)
        h.scheduler.advance(by: 0)
        h.host.answerClose(confirmed: true)
        h.scheduler.advance(by: 0)
        let viewed = try h.agent(ids[0])
        #expect(viewed.record.state == .finished && !viewed.record.unread && viewed.record.lastMessage == "Done.")
        try h.terminalClosed(ids[1])
        let killed = try h.agent(ids[1])
        #expect(killed.record.state == .problem && !killed.record.unread && killed.record.lastMessage == "Done.")
    }

    /// Review 8: a message Clawddy sent while agy worked, given back by an
    /// interrupt, was never submitted: it is no prompt, and the same words
    /// typed and submitted later are the person's own prompt.
    @Test func aSendGivenBackByAnInterruptIsNoPrompt() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        try agyLaunch(h, id)
        h.host.screens[id] = AgyScreens.working
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", text: "count slowly")
        var result: AgentSendResult?
        h.bridge.send("queued words", to: id, by: .app) { result = $0 }
        #expect(result == .sent)
        let agent = try h.agent(id)
        #expect(agent.record.prompts.map(\.text) == ["count slowly", "queued words"])
        #expect(agent.record.queued == "queued words")
        try h.osc(id, "state=idle:app=antigravity")
        #expect(agent.record.prompts.map(\.text) == ["count slowly"] && agent.record.interrupted)
        #expect(agent.record.queued == nil)
        // The person submits those words themselves.
        try h.osc(id, "state=working:app=antigravity")
        try agyHook(h, id, "PreInvocation", session: "c-1", invocation: "0", text: "queued words")
        #expect(agent.record.prompts.map(\.text) == ["count slowly", "queued words"])
        #expect(agent.record.prompts.map(\.by) == [.person, .person])
    }

    /// A saved conversation that is gone follows the flow of Claude's
    /// missing session: the agent offers only Start Fresh, after a restart
    /// too. One open in another terminal is refused and says so.
    @Test func aConversationGoneOrOpenElsewhere() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let data = h.folder.appendingPathComponent("agy-data", isDirectory: true)
        let agy = AntigravityProvider(root: h.root, dataFolder: data)
        try FileManager.default.createDirectory(at: h.binFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: h.binFolder.appendingPathComponent("agy"), withDestinationURL: AgySandbox.standIn)
        h.providers.prepareLaunch = { agy.prepareLaunch($0) }
        let gone = try h.addAgent("Gone", provider: .antigravity)
        let elsewhere = try h.addAgent("Elsewhere", provider: .antigravity)
        for (id, session) in [(gone, "c-gone"), (elsewhere, "c-open")] {
            try AgentSessionStore.write(
                AgentSessionBinding(provider: .antigravity, sessionID: session, launchGeneration: UUID()),
                for: id, directory: h.root.statusDir)
        }
        try FileManager.default.createDirectory(at: data.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        try Data().write(to: data.appendingPathComponent("conversations/c-open.db"))
        try FileManager.default.createDirectory(at: data.appendingPathComponent("presence"), withIntermediateDirectories: true)
        try Data().write(to: data.appendingPathComponent("presence/c-open.lock"))
        let holder = open(data.appendingPathComponent("presence/c-open.lock").path, O_RDWR)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)
        h.start()

        func hooks(_ id: UUID) -> URL {
            AntigravityProvider.hookFolder(root: h.root, agentID: id).appendingPathComponent(".agents/hooks.json")
        }
        try h.activate(gone)
        #expect(try h.agent(gone).record.problem?.kind == .conversationMissing)
        #expect(try h.agent(gone).canOnlyStartFresh)
        #expect(try h.binding(gone).missing == true)
        try h.activate(elsewhere)
        #expect(try h.agent(elsewhere).record.problem?.kind == .openElsewhere)
        #expect(try !h.agent(elsewhere).canOnlyStartFresh)
        // Neither refused launch wrote hooks for its conversation.
        #expect(!h.exists(hooks(gone)) && !h.exists(hooks(elsewhere)))

        try h.restart()
        #expect(try h.agent(gone).canOnlyStartFresh)
        let project = try #require(h.config.project(forAgent: gone))
        h.bridge.startFresh(id: gone, host: h.host, project: project)
        #expect(h.providers.launchRequests.last?.session == nil)
        #expect(try h.agent(gone).record.problem == nil && !h.agent(gone).canOnlyStartFresh)
        #expect(h.exists(hooks(gone)))
    }

    /// One agy hook record, as the hook script writes it.
    private func agyHook(
        _ h: AgentBridgeHarness, _ id: UUID, _ event: String, session: String, invocation: String = "", step: String = "",
        text: String?
    ) throws {
        var object: [String: Any] = [
            "schemaVersion": 1, "eventID": UUID().uuidString, "provider": "antigravity",
            "launchGeneration": try h.generation(id).uuidString, "hookEventName": event, "sessionID": session,
            "turnID": "", "invocation": invocation, "step": step, "model": "", "permissionMode": "",
        ]
        object["text"] = text
        try h.append(id, try #require(String(bytes: JSONSerialization.data(withJSONObject: object), encoding: .utf8)))
        h.poll()
    }

    /// The agent's agy starts and reads its input.
    private func agyLaunch(_ h: AgentBridgeHarness, _ id: UUID) throws {
        try h.activate(id)
        try h.osc(id, "state=blocked:kind=auth:app=antigravity:msg=\(b64("Sign in required"))")
        try h.osc(id, "state=idle:app=antigravity")
    }
}

/// agy's input box, read from screens the stand-in draws as the captures
/// show them (80 columns; `cli-facts.md`, agy, "Screens").
struct AgentAntigravityScreenTests {
    /// Plan trap 4: each prompt's echo under its shorter rule is no input
    /// box, so a menu, which takes the box's place, reads as a menu and
    /// never as the echo's text. Ruling 2: the box is empty when it holds
    /// nothing or the mode's hint. Queued text an interrupt gave back is
    /// text the person holds.
    @Test func theInputBox() {
        func read(_ screen: String) -> AgentInputLine { AgentInputLine.read(screen, provider: .antigravity, prompted: true) }
        #expect(read(AgyScreens.startHint) == .empty)
        #expect(read(AgyScreens.typed) == .holdsText("which palette"))
        #expect(read(AgyScreens.doneBareBox) == .empty)
        #expect(read(AgyScreens.question) == .none)
        #expect(read(AgyScreens.permission) == .none)
        #expect(read(AgyScreens.trust) == .none)
        #expect(read(AgyScreens.working) == .empty)
        #expect(read(AgyScreens.workingQueued) == .empty)
        #expect(read(AgyScreens.workingTyped) == .holdsText("half typed"))
        #expect(read(AgyScreens.interruptedGivenBack) == .holdsText("queued words"))
        #expect(read(AgyScreens.givenBackPlusPaste) == .holdsText("queued wordsfirst line\n  second line"))
        for hint in ["Plan mode: research & plan only (shift+tab to cycle)",
                     "Accept-edits mode: file edits auto-approved (shift+tab to cycle)"] {
            #expect(read(AgyScreens.box("> " + hint)) == .empty)
        }
        // A hint too long for the terminal is cut and ends "..." (probed at
        // 44 columns); a wrapped one reads the same.
        #expect(read(AgyScreens.box("> Auto mode: edits & safe commands auto-...")) == .empty)
        #expect(read(AgyScreens.box("> Auto mode: edits & safe commands auto-approved (shift+tab to\n  cycle)")) == .empty)
        #expect(read(AgyScreens.box("> fix the chart...")) == .holdsText("fix the chart..."))
        // A 60-column terminal: the echoes' rules span it, and the screen
        // between a prompt's submission and the box's return is no box.
        let rule60 = String(repeating: "─", count: 60)
        #expect(read([rule60, "> first prompt", "  ok", rule60, "> second prompt"].joined(separator: "\n")) == .none)
        #expect(read([rule60, "> first prompt", "  ok", rule60, ">", rule60, "? for shortcuts      example-model · high"]
            .joined(separator: "\n")) == .empty)
        // A terminal no wider than the echo's rule: the echo's rule spans
        // it too, and the menu still reads as one.
        let narrow = AgyScreens.question.components(separatedBy: "\n").map { row in
            row.allSatisfy { $0 == "─" } && !row.isEmpty ? String(repeating: "─", count: 60) : row
        }.joined(separator: "\n")
        #expect(read(narrow) == .none)
    }

    /// The tile shows the rows above the box, or above a menu's title.
    @Test func theTileStopsAboveTheBoxOrTheMenu() {
        let typed = AgentTail.lines(AgyScreens.typed, provider: .antigravity)
        #expect(typed.last == "  Second line.")
        let question = AgentTail.lines(AgyScreens.question, provider: .antigravity)
        #expect(question.last == "? Which palette, the harbour one or the dune one?")
        let queued = AgentTail.lines(AgyScreens.workingQueued, provider: .antigravity)
        #expect(queued.last == "▸ queued words (alt+m to send immediately)")
        // A stopped agy: its last turn, then how to resume it.
        let stopped = AgentTail.lines(AgyScreens.exited, provider: .antigravity)
        #expect(Array(stopped.suffix(5)) == [
            "> fix the tide chart", "  First line.", "  Second line.", "Resume with -c (or command below):",
            "agy --conversation=0b9e2c1a-7d4f-4e3b-9a52-1c0ffee00000",
        ])
        // Final review 8: a rule inside the reply (a Markdown rule, a table's
        // divider) is no menu's: the stopped tile still shows the reply.
        let ruled = AgentTail.lines(AgyScreens.exitedWithARule, provider: .antigravity)
        #expect(Array(ruled.suffix(4)) == [
            AgyScreens.rule, "  Totals are below.", "Resume with -c (or command below):",
            "agy --conversation=0b9e2c1a-7d4f-4e3b-9a52-1c0ffee00000",
        ])
    }
}

/// Screens the stand-in `agy` draws at 80 columns (cli-facts.md, agy,
/// "Screens"), with an invented folder.
enum AgyScreens {
    static let rule = String(repeating: "─", count: 80)
    static let echo = String(repeating: "─", count: 60)
    static let footer = "? for shortcuts                                      auto · example-model · high"
    static let typingFooter = "                                                     auto · example-model · high"
    static let menuFooter = "esc to cancel                                        auto · example-model · high"
    static let banner = [
        "     ▄▀▀▄     Antigravity CLI 1.5.17", "    ▀▀▀▀▀▀    Example account (Example plan)",
        "   ▀▀▀▀▀▀▀▀   example-model (High)", "  ▄▀▀    ▀▀▄  /work/harbour", " ▄▀▀ ▀▀▄ ▀▀▄", "", "",
    ]
    static let firstTurn = [echo, "> fix the tide chart", "", "  First line.", "  Second line.", ""]
    static let answered = [
        " ▄▀▀ ▀▀▄ ▀▀▄", "", "", echo, "> fix the tide chart", "", "  First line.", "  Second line.", "",
        echo, "> which palette", "? Which palette, the harbour one or the dune one?",
    ]
    static let testsRun = [
        "? Which palette, the harbour one or the dune one?", "> harbour", "", "  harbour", "", echo, "> run the tests", "",
        "● Ran (make test) (ctrl+o to expand)", "", "  Tests pass.", "", echo, "> count slowly", "",
        "● Ran (make long) (ctrl+o to expand)",
    ]

    static func box(_ input: String) -> String {
        (banner + firstTurn + [rule, input, rule, footer]).joined(separator: "\n")
    }

    static let startHint = (banner + [rule, "> Auto mode: edits & safe commands auto-approved (shift+tab to cycle)", rule, footer])
        .joined(separator: "\n")
    static let typed = (banner + firstTurn + [rule, "> which palette", rule, typingFooter]).joined(separator: "\n")
    static let question = (answered + [
        "", "Question", rule, "", "Question 1/1: Which palette, the harbour one or the dune one?", "",
        "> 1. harbour", "  2. dune", "  3. Write-in...", "", "  ↑/↓ Navigate · enter Select · esc Skip", menuFooter,
    ]).joined(separator: "\n")
    static let doneBareBox = (answered + ["> harbour", "", "  harbour", "", rule, ">", rule, footer]).joined(separator: "\n")
    static let permission = ([
        "? Which palette, the harbour one or the dune one?", "> harbour", "", "  harbour", "", echo, "> run the tests", "",
        "● Ran (make test) (ctrl+o to expand)", "", "Command", rule, "", "Requesting permission for:", "   make test", "",
        "Run this command?", "> 1. Yes, run command",
        "  2. Yes, and always allow in this conversation for commands that start with 'ma",
        "  3. Yes, and always allow for commands that start with 'make' (Persist to setti", "  4. No, cancel", "",
        "  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command", menuFooter,
    ]).joined(separator: "\n")
    static let working = (testsRun + ["", "⣻  Generating...", rule, ">", rule, menuFooter]).joined(separator: "\n")
    static let workingQueued = (testsRun + [
        "", "⣾  Generating...", "▸ queued words (alt+m to send immediately)", rule, ">", rule,
        "  Press up to edit queued messages                   auto · example-model · high",
    ]).joined(separator: "\n")
    static let workingTyped = (testsRun + [
        "", "⣯  Generating...", "▸ queued words (alt+m to send immediately)", rule, "> half typed", rule, menuFooter,
    ]).joined(separator: "\n")
    static let interruptedGivenBack = (testsRun + [
        "  ⎿  Interrupted · What should Antigravity CLI do instead?", "", rule, "> queued words", rule, typingFooter,
    ]).joined(separator: "\n")
    static let givenBackPlusPaste = (testsRun + [
        "  ⎿  Interrupted · What should Antigravity CLI do instead?", "", rule, "> queued wordsfirst line", "  second line",
        rule, typingFooter,
    ]).joined(separator: "\n")
    /// After Control-D twice: the box gone, then how to resume
    /// (cli-facts.md, agy, "At exit").
    static let exited = (banner + firstTurn + [
        "", "Resume with -c (or command below):", "agy --conversation=0b9e2c1a-7d4f-4e3b-9a52-1c0ffee00000",
    ]).joined(separator: "\n")
    static let exitedWithARule = (banner + firstTurn + [
        "  Above the line.", rule, "  Totals are below.",
        "Resume with -c (or command below):", "agy --conversation=0b9e2c1a-7d4f-4e3b-9a52-1c0ffee00000",
    ]).joined(separator: "\n")
    static let trust = (banner + [
        "Accessing workspace:", "/work/harbour", "Do you trust the contents of this project?",
        "Antigravity CLI requires permission to read, edit, and execute files here.", "> Yes, I trust this folder",
        "  No, exit", "  ↑/↓ Navigate · enter Confirm", typingFooter,
    ]).joined(separator: "\n")
}

func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

/// A temporary folder with a data root, a home, agy's data folder inside
/// that home, and `bin/agy`, a link to the stand-in.
final class AgySandbox {
    static let standIn = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("StandIns/agy")

    let folder: URL
    let root: AgentDataRoot
    let home: URL
    let bin: URL
    let data: URL
    let provider: AntigravityProvider

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("clawddy-agy-\(UUID().uuidString)", isDirectory: true)
        root = AgentDataRoot(
            url: folder.appendingPathComponent("root", isDirectory: true),
            agyHookBase: folder.appendingPathComponent("hook-cache", isDirectory: true))
        home = folder.appendingPathComponent("home", isDirectory: true)
        bin = folder.appendingPathComponent("bin", isDirectory: true)
        data = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        for directory in [root.url, home, bin, data, folder.appendingPathComponent("work")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("agy"), withDestinationURL: Self.standIn)
        provider = AntigravityProvider(root: root, dataFolder: data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    func request() -> AgentLaunchRequest {
        AgentLaunchRequest(
            agentID: UUID(), name: "Agent", provider: .antigravity, launchProfile: AgentLaunchProfile(),
            workingDirectory: folder.appendingPathComponent("work").path, environmentPath: bin.path,
            launchGeneration: UUID(), session: nil)
    }

    func makeConversation(_ id: String) throws {
        let conversations = data.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        try Data().write(to: conversations.appendingPathComponent("\(id).db"))
    }

    /// Runs the installed hook script as agy runs a hook, with `payload` on
    /// its input: what it printed, and the records it appended. Without
    /// `identity` it is given only the status folder and the provider.
    func hook(_ payload: [String: Any], identity: Bool = true) throws -> (output: String, records: [AgentRawProviderEvent]) {
        try AgentHookRuntime.install(root: root)
        let agentID = UUID()
        let arguments = AgentHookRuntime.arguments(root: root, provider: .antigravity, agentID: agentID, generation: UUID())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", (identity ? arguments : Array(arguments.prefix(3))).map(AgentHookRuntime.shellQuote).joined(separator: " ")]
        process.environment = [
            "HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": folder.path, "LANG": "en_US.UTF-8",
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload, options: .sortedKeys))
        try input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return (try #require(String(bytes: printed, encoding: .utf8)), try events(agentID))
    }

    /// A transcript of `steps`, one JSON object per line, under the
    /// sandbox's home; its path as agy names it, starting "~/".
    func transcript(_ steps: [[String: Any]]) throws -> String {
        let relative = ".gemini/antigravity-cli/brain/c-1/.system_generated/logs/transcript_full.jsonl"
        let file = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for step in steps {
            data += try JSONSerialization.data(withJSONObject: step, options: .sortedKeys)
            data += Data("\n".utf8)
        }
        try data.write(to: file)
        return "~/" + relative
    }

    func events(_ agentID: UUID) throws -> [AgentRawProviderEvent] {
        let file = root.statusDir.appendingPathComponent("\(agentID.uuidString).events")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try AgentEventJournal.read(Data(contentsOf: file), from: 0).records.map {
            try JSONDecoder().decode(AgentRawProviderEvent.self, from: $0)
        }
    }

    /// The stand-in in a terminal of its own (`script`), as the agent's
    /// terminal runs the launch, in the work folder.
    func run(_ launch: AgentPreparedLaunch) throws -> RunningAgy {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", launch.executableURL.path] + launch.arguments
        process.currentDirectoryURL = folder.appendingPathComponent("work")
        process.environment = [
            "HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": folder.path,
            "AGY_STANDIN_DATA_DIR": data.path, "TERM": "xterm-256color",
        ]
        // An input that never ends: `script` passes an end of input on as
        // Control-D.
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return RunningAgy(process: process, input: input)
    }

    func waitForEvents(_ agentID: UUID, until done: ([AgentRawProviderEvent]) -> Bool) throws -> [AgentRawProviderEvent] {
        var events: [AgentRawProviderEvent] = []
        try wait("the stand-in's hooks") {
            events = (try? self.events(agentID)) ?? []
            return done(events)
        }
        return events
    }

    func wait(_ what: String, _ condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < end else { throw AgyTimeout(what: what) }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

struct AgyTimeout: Error, CustomStringConvertible {
    var what: String
    var description: String { "\(what): not within 20 s" }
}

final class RunningAgy {
    let process: Process
    let input: Pipe

    init(process: Process, input: Pipe) {
        self.process = process
        self.input = input
    }

    func end() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}
