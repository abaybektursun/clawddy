import Foundation
import Testing
@testable import Ghostty

/// Claude hooks travel in each agent's settings overlay, and Codex's notify
/// program on each launch's command line, both with the agent's identity as
/// arguments; nothing is exported. Only the production identity removes the
/// entries older builds left in the providers' global files. Every provider
/// file here is a stand-in inside a fresh temporary folder; no test passes a
/// real home's provider file to an installer.
struct AgentHookIntegrationTests {
    @Test func claudeLaunchCarriesHooksInSettingsOverlay() throws {
        let sandbox = try HookSandbox()
        defer { sandbox.remove() }
        let provider = ClaudeCodeProvider(root: sandbox.root)
        let request = sandbox.request(.claudeCode)
        let subscribed = ClaudeCodeProvider.hookEvents.keys.sorted()

        let launch = try provider.prepareLaunch(request).get()
        let settingsIndex = try #require(launch.arguments.firstIndex(of: "--settings"))
        let settingsURL = URL(fileURLWithPath: launch.arguments[settingsIndex + 1])
        let overlay = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let hooks = try #require(overlay["hooks"] as? [String: Any])
        let command = AgentHookRuntime.command(
            root: sandbox.root,
            provider: .claudeCode,
            agentID: request.agentID,
            generation: request.launchGeneration)
        let expectedGroup: [String: Any] = [
            "hooks": [["type": "command", "command": command, "timeout": 5]],
        ]
        #expect(Set(hooks.keys) == Set(subscribed))
        for event in subscribed {
            #expect(NSArray(array: hooks[event] as? [Any] ?? []).isEqual(to: [expectedGroup]))
        }

        // The command line in the overlay records each event for this agent,
        // with no identity anywhere in its environment.
        _ = try provider.prepareIntegration().get()
        for event in subscribed {
            let status = try sandbox.runShell(
                command,
                environment: sandbox.plainEnvironment,
                payload: #"{"session_id":"session-1","hook_event_name":"\#(event)"}"#)
            #expect(status == 0)
        }
        let events = try sandbox.events(request.agentID)
        #expect(events.map(\.hookEventName) == subscribed)
        #expect(events.allSatisfy {
            $0.provider == .claudeCode && $0.launchGeneration == request.launchGeneration
        })
    }

    /// Each provider's event table is the one list of its hooks: every event
    /// it subscribes to has a meaning, and the hooks written for it (Claude's
    /// settings overlay) and the events the installed hook script records
    /// are exactly its events.
    @Test func providerTableMapsEveryHookEvent() throws {
        let sandbox = try HookSandbox()
        defer { sandbox.remove() }
        let table = AgentProviderTable(
            root: sandbox.root, codexConfigFile: sandbox.home.appendingPathComponent(".codex/config.toml"))
        let record = try JSONDecoder().decode(
            AgentRawProviderEvent.self,
            from: Data(#"{"provider":"claudeCode","launchGeneration":"\#(UUID().uuidString)","hookEventName":"Any","text":"x"}"#.utf8))
        for provider in AgentProviderID.allCases {
            for (event, meaning) in table[provider].hookEvents {
                #expect(!meaning(record).isEmpty, "\(provider) \(event)")
            }
        }

        let launch = try table.claudeCode.prepareLaunch(sandbox.request(.claudeCode)).get()
        let settingsIndex = try #require(launch.arguments.firstIndex(of: "--settings"))
        let overlay = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: launch.arguments[settingsIndex + 1]))) as? [String: Any])
        let overlayHooks = try #require(overlay["hooks"] as? [String: Any])
        #expect(Set(overlayHooks.keys) == Set(table.claudeCode.hookEvents.keys))
        #expect(table.codex.hookEvents.keys.sorted() == ["agent-turn-complete"])
        // The terminal reports turn activity; the hooks report the session,
        // the text, failures and compaction only (P3.5).
        #expect(table.claudeCode.hookEvents.keys.sorted() == [
            "PermissionRequest", "PostCompact", "PreCompact", "SessionEnd", "SessionStart", "Stop",
            "StopFailure", "UserPromptSubmit",
        ])

        // Every event either provider subscribes to, and one neither does.
        try AgentHookRuntime.install(root: sandbox.root)
        let candidates = Set(AgentProviderID.allCases.flatMap { table[$0].hookEvents.keys })
            .union(["Notification"])
            .sorted()
        for provider in AgentProviderID.allCases {
            let agentID = UUID()
            let command = AgentHookRuntime.command(
                root: sandbox.root,
                provider: provider,
                agentID: agentID,
                generation: UUID())
            // Claude's field names and agy's (`hookEventName`,
            // `conversationId`), the provider's own with the event and the
            // other's with an event and a session no one records: a
            // provider that reads the other's names records nothing right.
            let agy = provider == .antigravity
            for event in candidates {
                let payload: [String: String] = [
                    "hook_event_name": agy ? "Notification" : event, "session_id": agy ? "wrong" : "session-1",
                    "hookEventName": agy ? event : "Notification", "conversationId": agy ? "session-1" : "wrong",
                ]
                let text = try #require(String(bytes: JSONSerialization.data(withJSONObject: payload), encoding: .utf8))
                #expect(try sandbox.runShell(command, environment: sandbox.plainEnvironment, payload: text) == 0)
            }
            let events = try sandbox.events(agentID)
            #expect(events.map(\.hookEventName) == table[provider].hookEvents.keys.sorted())
            #expect(events.allSatisfy { $0.sessionID == "session-1" })
        }
    }

    @Test func claudeLaunchExportsNoAgentIdentity() throws {
        let sandbox = try HookSandbox()
        defer { sandbox.remove() }

        let claude = try sandbox.prepareSurfaceLaunch(sandbox.request(.claudeCode))
        let claudeScript = try String(contentsOf: claude.scriptURL, encoding: .utf8)
        #expect(!claudeScript.contains("GHOSTTY_AGENT_"))
        #expect(!claudeScript.contains("CLAWDDY_"))
        #expect(!claude.environment.keys.contains { isAgentIdentity($0) })

        // Codex's identity travels as its notify program's arguments.
        let codexRequest = sandbox.request(.codex)
        let codex = try sandbox.prepareSurfaceLaunch(codexRequest)
        let codexScript = try String(contentsOf: codex.scriptURL, encoding: .utf8)
        #expect(!codexScript.contains("GHOSTTY_AGENT_"))
        #expect(!codexScript.contains("CLAWDDY_"))
        #expect(!codex.environment.keys.contains { isAgentIdentity($0) })
        #expect(codexScript.contains(codexRequest.agentID.uuidString))
    }

    @Test func devIdentityNeverTouchesGlobalHooks() throws {
        let sandbox = try HookSandbox()
        defer { sandbox.remove() }
        let oldEntry: [String: Any] = [
            "hooks": [
                "SessionStart": [[
                    "hooks": [["type": "command", "command": sandbox.quotedScript]],
                ]],
            ],
        ]
        let claudeSettings = sandbox.home.appendingPathComponent(".claude/settings.json")
        let codexHooks = sandbox.home.appendingPathComponent(".codex/hooks.json")
        try sandbox.writeJSON(oldEntry, to: claudeSettings)
        try sandbox.writeJSON(oldEntry, to: codexHooks)
        let before = try filesUnder(sandbox.home)
        let beforeDates = try [claudeSettings, codexHooks].map(modificationDate)

        #expect(try ClaudeCodeProvider.removeGlobalHooks(
            settingsFile: claudeSettings,
            root: sandbox.root,
            isProduction: false) == false)
        #expect(try CodexProvider.removeGlobalHooks(
            hooksFile: codexHooks,
            root: sandbox.root,
            isProduction: false) == false)
        _ = try sandbox.prepareSurfaceLaunch(sandbox.request(.claudeCode))
        _ = try sandbox.prepareSurfaceLaunch(sandbox.request(.codex))

        #expect(try filesUnder(sandbox.home) == before)
        #expect(try [claudeSettings, codexHooks].map(modificationDate) == beforeDates)
    }

    @Test func hookInstallerRemovesOnlyItsOwnScriptPath() throws {
        let sandbox = try HookSandbox()
        defer { sandbox.remove() }
        let script = sandbox.quotedScript
        func handler(_ command: String) -> [String: Any] { ["type": "command", "command": command] }
        let user = handler("python3 /Users/example/.claude/hooks/now.py")
        let otherRoot = handler(
            "'/Users/example/.config/clawddy-dev/hooks/clawddy-provider-hook.sh' '/Users/example/.config/clawddy-dev/status'")
        let sameFolderOtherFile = handler(
            AgentHookRuntime.shellQuote(AgentHookRuntime.scriptURL(root: sandbox.root).path + ".orig"))
        let mentionsPath = handler("/bin/echo \(script)")
        let ownOld = handler(script)
        let ownStatusOnly = handler("\(script) \(AgentHookRuntime.shellQuote(sandbox.root.statusDir.path))")
        let ownWithIdentity = handler(AgentHookRuntime.command(
            root: sandbox.root, provider: .claudeCode, agentID: UUID(), generation: UUID()))
        let source: [String: Any] = [
            "model": "example",
            "hooks": [
                "SessionStart": [["hooks": [user]], ["hooks": [ownOld]]],
                "Stop": [["matcher": "*", "hooks": [user, ownStatusOnly, otherRoot]]],
                "PreToolUse": [["hooks": [ownWithIdentity]]],
                "Notification": [["hooks": [sameFolderOtherFile, mentionsPath]]],
            ],
        ]
        let kept: [String: Any] = [
            "SessionStart": [["hooks": [user]]],
            "Stop": [["matcher": "*", "hooks": [user, otherRoot]]],
            "Notification": [["hooks": [sameFolderOtherFile, mentionsPath]]],
        ]

        // The production app removes its own old entries and nothing else,
        // from Claude's settings and Codex's hooks alike, and writes again
        // only if there is something left to remove.
        let claudeSettings = sandbox.home.appendingPathComponent(".claude/settings.json")
        let codexHooks = sandbox.home.appendingPathComponent(".codex/hooks.json")
        let removals: [(URL, () throws -> Bool)] = [
            (claudeSettings, {
                try ClaudeCodeProvider.removeGlobalHooks(
                    settingsFile: claudeSettings, root: sandbox.root, isProduction: true)
            }),
            (codexHooks, {
                try CodexProvider.removeGlobalHooks(hooksFile: codexHooks, root: sandbox.root, isProduction: true)
            }),
        ]
        for (file, remove) in removals {
            try sandbox.writeJSON(source, to: file)
            let sourceBytes = try Data(contentsOf: file)
            #expect(try remove())
            let cleaned = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect(NSDictionary(dictionary: cleaned).isEqual(to: ["model": "example", "hooks": kept]))
            #expect(try Data(contentsOf: file.appendingPathExtension("clawddy-backup")) == sourceBytes)
            let cleanedBytes = try Data(contentsOf: file)
            let cleanedDate = try modificationDate(file)
            #expect(try remove() == false)
            #expect(try Data(contentsOf: file) == cleanedBytes)
            #expect(try modificationDate(file) == cleanedDate)
        }
    }

    /// A `claude` started by an agent's tools gets the agent's terminal
    /// environment but not its `--settings`. If any hook entry outside the
    /// overlay runs the script (an older build's global entry has no
    /// arguments, or only the status folder), the script finds no identity
    /// and records nothing.
    @Test func nestedClaudeCannotReportAsParent() throws {
        let sandbox = try HookSandbox()
        defer { sandbox.remove() }
        let parent = try sandbox.prepareSurfaceLaunch(sandbox.request(.claudeCode))
        var environment = parent.environment
        // The parent's own HOME and TMPDIR are the real account's; the test
        // must never write there.
        environment["HOME"] = sandbox.home.path
        environment["TMPDIR"] = sandbox.home.path
        let script = AgentHookRuntime.scriptURL(root: sandbox.root).path
        let payload = #"{"session_id":"nested-session","hook_event_name":"SessionStart"}"#

        let before = try filesUnder(sandbox.url)
        for command in [
            AgentHookRuntime.shellQuote(script),
            "\(AgentHookRuntime.shellQuote(script)) \(AgentHookRuntime.shellQuote(sandbox.root.statusDir.path))",
        ] {
            #expect(try sandbox.runShell(command, environment: environment, payload: payload) == 0)
        }
        #expect(try filesUnder(sandbox.url) == before)
    }

    /// A new Claude session launches as `--session-id <new> --name <label>`.
    /// Preparing the launch saves nothing: Claude writes the session only
    /// with its first entry (review S1 capture), so until the bridge saves
    /// the binding at the first turn, the next launch chooses a new ID. Once
    /// it is saved, the next launch resumes that session, still named.
    @Test func claudeNewLaunchChoosesSessionID() throws {
        let sandbox = try HookSandbox()
        defer { sandbox.remove() }
        let request = sandbox.request(.claudeCode)
        let claude = sandbox.bin.appendingPathComponent("claude").path
        let bindingFile = AgentSessionStore.sessionURL(request.agentID, sandbox.root.statusDir)

        let first = try sandbox.prepareSurfaceLaunch(request)
        let sessionID = try #require(first.newSessionID)
        #expect(UUID(uuidString: sessionID) != nil && sessionID == sessionID.lowercased())
        #expect(first.resumedSessionID == nil)
        #expect(!FileManager.default.fileExists(atPath: bindingFile.path))
        let firstScript = try String(contentsOf: first.scriptURL, encoding: .utf8)
        #expect(firstScript.contains(shellCommand([claude, "--session-id", sessionID, "--name", "Agent"])))
        #expect(!firstScript.contains("--resume"))

        var unsaved = request
        unsaved.launchGeneration = UUID()
        let again = try sandbox.prepareSurfaceLaunch(unsaved)
        #expect(try #require(again.newSessionID) != sessionID)

        let saved = AgentSessionBinding(
            provider: .claudeCode,
            sessionID: sessionID,
            launchGeneration: request.launchGeneration)
        try AgentSessionStore.write(saved, for: request.agentID, directory: sandbox.root.statusDir)
        var next = request
        next.launchGeneration = UUID()
        let second = try sandbox.prepareSurfaceLaunch(next)
        let secondScript = try String(contentsOf: second.scriptURL, encoding: .utf8)
        #expect(secondScript.contains(shellCommand([claude, "--resume", sessionID, "--name", "Agent"])))
        #expect(!secondScript.contains("--session-id"))
        #expect(second.newSessionID == nil && second.resumedSessionID == sessionID)
        #expect(try AgentSessionStore.session(
            for: request.agentID,
            provider: .claudeCode,
            directory: sandbox.root.statusDir) == saved)
    }

}

private func isAgentIdentity(_ name: String) -> Bool {
    name.hasPrefix("GHOSTTY_AGENT_") || name.hasPrefix("CLAWDDY_")
}

private func modificationDate(_ url: URL) throws -> Date {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
}

/// A temporary folder holding a data root, a stand-in home for provider files,
/// and fake `claude` and `codex` executables.
private struct HookSandbox {
    let url: URL
    let root: AgentDataRoot
    let home: URL
    let bin: URL

    init() throws {
        let fm = FileManager.default
        url = fm.temporaryDirectory
            .appendingPathComponent("clawddy-hook-integration-\(UUID().uuidString)", isDirectory: true)
        root = AgentDataRoot(url: url.appendingPathComponent("root", isDirectory: true))
        home = url.appendingPathComponent("home", isDirectory: true)
        bin = url.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        // The bridge does this at start; launch scripts are written there.
        try root.resetLaunchDir()
        // `AgentConfig` creates the status folder before any launch.
        try fm.createDirectory(at: root.statusDir, withIntermediateDirectories: true)
        for name in ["claude", "codex"] {
            let executable = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\n[ \"$1\" = agents ] && echo '[]'\nexit 0\n".utf8).write(to: executable)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    var quotedScript: String {
        AgentHookRuntime.shellQuote(AgentHookRuntime.scriptURL(root: root).path)
    }

    var plainEnvironment: [String: String] {
        ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": home.path]
    }

    func request(_ provider: AgentProviderID) -> AgentLaunchRequest {
        AgentLaunchRequest(
            agentID: UUID(),
            name: "Agent",
            provider: provider,
            launchProfile: AgentLaunchProfile(),
            workingDirectory: nil,
            environmentPath: "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            launchGeneration: UUID(),
            session: nil)
    }

    /// What the bridge prepares for a launch, with a provider table whose
    /// Codex configuration is a stand-in.
    func prepareSurfaceLaunch(_ request: AgentLaunchRequest) throws -> AgentPreparedSurfaceLaunch {
        let coordinator = AgentLaunchCoordinator(
            providers: AgentProviderTable(
                root: root,
                codexConfigFile: home.appendingPathComponent(".codex/config.toml")),
            root: root)
        switch coordinator.prepare(request) {
        case .success(let launch): return launch
        case .failure(let issue, _, _, _): throw issue
        }
    }

    func writeJSON(_ object: [String: Any], to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: file)
    }

    /// Runs `command` as a provider runs a hook: `/bin/sh -c`, the payload on
    /// standard input.
    func runShell(_ command: String, environment: [String: String], payload: String) throws -> Int32 {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func events(_ agentID: UUID) throws -> [AgentRawProviderEvent] {
        let data = try Data(contentsOf: root.statusDir
            .appendingPathComponent("\(agentID.uuidString).events"))
        return try AgentEventJournal.read(data, from: 0).records.map {
            try JSONDecoder().decode(AgentRawProviderEvent.self, from: $0)
        }
    }
}
