import Foundation
import Testing
@testable import Ghostty

/// Claude hooks travel in each agent's settings overlay, with the agent's
/// identity as arguments, and nothing is exported for Claude. Codex keeps one
/// global entry that only the production identity writes. Every provider file
/// here is a stand-in inside a fresh temporary folder; no test passes a real
/// home's provider file to an installer.
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
    /// settings overlay, Codex's global file) and the events the installed
    /// hook script records are exactly its events. Codex's list is pinned:
    /// a change rewrites `hooks.json`, and Codex then asks for a hook review
    /// in every session on the machine.
    @Test func providerTableMapsEveryHookEvent() throws {
        let sandbox = try HookSandbox()
        defer { sandbox.remove() }
        let hooksFile = sandbox.home.appendingPathComponent(".codex/hooks.json")
        let table = AgentProviderTable(root: sandbox.root, codexHooksFile: hooksFile, isProduction: true)
        let record = try JSONDecoder().decode(
            AgentRawProviderEvent.self,
            from: Data(#"{"provider":"claudeCode","launchGeneration":"\#(UUID().uuidString)","hookEventName":"Any"}"#.utf8))
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

        _ = try table.codex.prepareIntegration().get()
        let codexHooks = try #require(
            (JSONSerialization.jsonObject(with: Data(contentsOf: hooksFile)) as? [String: Any])?["hooks"]
                as? [String: Any])
        #expect(Set(codexHooks.keys) == Set(table.codex.hookEvents.keys))
        #expect(table.codex.hookEvents.keys.sorted() == [
            "PermissionRequest", "PostCompact", "PostToolUse", "PreCompact", "PreToolUse",
            "SessionStart", "Stop", "SubagentStart", "SubagentStop", "UserPromptSubmit",
        ])
        // Claude's terminal reports its turn activity; its hooks report the
        // session, failures and compaction only (P3.5).
        #expect(table.claudeCode.turnActivity == .surface)
        #expect(table.codex.turnActivity == .hookJournal)
        #expect(table.claudeCode.hookEvents.keys.sorted() == [
            "PostCompact", "PreCompact", "SessionEnd", "SessionStart", "StopFailure",
        ])

        // Every event either provider subscribes to, and one neither does.
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
            for event in candidates {
                #expect(try sandbox.runShell(
                    command,
                    environment: sandbox.plainEnvironment,
                    payload: #"{"session_id":"session-1","hook_event_name":"\#(event)"}"#) == 0)
            }
            #expect(try sandbox.events(agentID).map(\.hookEventName) == table[provider].hookEvents.keys.sorted())
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

        // Codex, by contrast, gets exactly the four CLAWDDY_* names.
        let codexRequest = sandbox.request(.codex)
        let codex = try sandbox.prepareSurfaceLaunch(codexRequest)
        let codexScript = try String(contentsOf: codex.scriptURL, encoding: .utf8)
        #expect(!codexScript.contains("GHOSTTY_AGENT_"))
        #expect(codex.environment.filter { isAgentIdentity($0.key) } == [
            "CLAWDDY_AGENT_ID": codexRequest.agentID.uuidString,
            "CLAWDDY_AGENT_PROVIDER": AgentProviderID.codex.rawValue,
            "CLAWDDY_AGENT_GENERATION": codexRequest.launchGeneration.uuidString,
            "CLAWDDY_STATUS_DIR": sandbox.root.statusDir.path,
        ])
        #expect(codexScript.contains("export CLAWDDY_AGENT_ID="))
    }

    @Test func devIdentityNeverInstallsGlobalHooks() throws {
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
        let missingCodexHooks = sandbox.home.appendingPathComponent("no-codex/hooks.json")
        try sandbox.writeJSON(oldEntry, to: claudeSettings)
        try sandbox.writeJSON(oldEntry, to: codexHooks)
        let before = try filesUnder(sandbox.home)
        let beforeDates = try [claudeSettings, codexHooks].map(modificationDate)

        #expect(try ClaudeCodeProvider.removeGlobalHooks(
            settingsFile: claudeSettings,
            root: sandbox.root,
            isProduction: false) == false)
        for hooksFile in [codexHooks, missingCodexHooks] {
            let codex = CodexProvider(root: sandbox.root, hooksFile: hooksFile, isProduction: false)
            let preparation = try codex.prepareIntegration().get()
            #expect(preparation.notice != nil)
        }
        _ = try sandbox.prepareSurfaceLaunch(sandbox.request(.claudeCode))
        _ = try sandbox.prepareSurfaceLaunch(sandbox.request(.codex))

        #expect(try filesUnder(sandbox.home) == before)
        #expect(try [claudeSettings, codexHooks].map(modificationDate) == beforeDates)
        #expect(!FileManager.default.fileExists(atPath: missingCodexHooks.path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.codexHookReviewMarker.path))
    }

    @Test func codexInstallerIsNoOpWhenUnchanged() throws {
        let sandbox = try HookSandbox()
        defer { sandbox.remove() }
        let hooksFile = sandbox.home.appendingPathComponent(".codex/hooks.json")
        let seed: [String: Any] = [
            "hooks": [
                "SessionStart": [[
                    "hooks": [["type": "command", "command": sandbox.quotedScript]],
                ]],
            ],
        ]
        try sandbox.writeJSON(seed, to: hooksFile)
        let seedBytes = try Data(contentsOf: hooksFile)
        let codex = CodexProvider(root: sandbox.root, hooksFile: hooksFile, isProduction: true)

        let first = try codex.prepareIntegration().get()
        #expect(first.notice != nil)
        let installed = try Data(contentsOf: hooksFile)
        let installedDate = try modificationDate(hooksFile)
        #expect(installed != seedBytes)
        #expect(try Data(contentsOf: hooksFile.appendingPathExtension("clawddy-backup")) == seedBytes)
        let hooks = try #require(
            (JSONSerialization.jsonObject(with: installed) as? [String: Any])?["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(CodexProvider.hookEvents.keys))

        // The user reviewed the hooks in Codex. A later launch must neither
        // rewrite the file nor ask again.
        try CodexProvider.clearHookReviewRequired(root: sandbox.root)
        let second = try codex.prepareIntegration().get()
        #expect(second.notice == nil)
        #expect(try Data(contentsOf: hooksFile) == installed)
        #expect(try modificationDate(hooksFile) == installedDate)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.codexHookReviewMarker.path))
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
        let ownStatusOnly = handler(AgentHookRuntime.command(root: sandbox.root))
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

        // Claude: the production app removes its own old entries and nothing
        // else, and writes again only if there is something left to remove.
        let claudeSettings = sandbox.home.appendingPathComponent(".claude/settings.json")
        try sandbox.writeJSON(source, to: claudeSettings)
        let sourceBytes = try Data(contentsOf: claudeSettings)
        #expect(try ClaudeCodeProvider.removeGlobalHooks(
            settingsFile: claudeSettings, root: sandbox.root, isProduction: true))
        let cleaned = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])
        #expect(NSDictionary(dictionary: cleaned).isEqual(to: ["model": "example", "hooks": kept]))
        #expect(try Data(contentsOf: claudeSettings.appendingPathExtension("clawddy-backup")) == sourceBytes)
        let cleanedBytes = try Data(contentsOf: claudeSettings)
        let cleanedDate = try modificationDate(claudeSettings)
        #expect(try ClaudeCodeProvider.removeGlobalHooks(
            settingsFile: claudeSettings, root: sandbox.root, isProduction: true) == false)
        #expect(try Data(contentsOf: claudeSettings) == cleanedBytes)
        #expect(try modificationDate(claudeSettings) == cleanedDate)

        // Codex: the same entries stay, and each hooked event runs this root's
        // script exactly once, with the status folder only.
        let codexHooks = sandbox.home.appendingPathComponent(".codex/hooks.json")
        try sandbox.writeJSON(source, to: codexHooks)
        let codex = CodexProvider(root: sandbox.root, hooksFile: codexHooks, isProduction: true)
        _ = try codex.prepareIntegration().get()
        let installed = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: codexHooks)) as? [String: Any])
        var expected = kept
        for event in CodexProvider.hookEvents.keys {
            var groups = expected[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [[
                "type": "command",
                "command": AgentHookRuntime.command(root: sandbox.root),
                "timeout": 5,
            ]]])
            expected[event] = groups
        }
        #expect(NSDictionary(dictionary: installed).isEqual(to: ["model": "example", "hooks": expected]))
    }

    /// A `claude` started by an agent's tools gets the agent's terminal
    /// environment but not its `--settings`. If any hook entry outside the
    /// overlay runs the script (an older build's global entry has no
    /// arguments; this build's Codex form has only the status folder), the
    /// script finds no identity and records nothing.
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
            AgentHookRuntime.command(root: sandbox.root),
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

    /// A fork launches as `--resume <source> --fork-session --session-id
    /// <new>`, and preparing it saves nothing. Until the fork's first turn
    /// the bridge keeps its marker, and a relaunch forks again under another
    /// new ID; once the bridge has saved the fork's session and cleared the
    /// marker, the next launch resumes the fork's own session.
    @Test func forkLaunchAnnouncesItsNewSessionID() throws {
        let sandbox = try HookSandbox()
        defer { sandbox.remove() }
        let request = sandbox.request(.claudeCode)
        let statusDir = sandbox.root.statusDir
        try FileManager.default.createDirectory(at: statusDir, withIntermediateDirectories: true)
        try AgentSessionStore.write(
            AgentPendingFork(provider: .claudeCode, sourceSessionID: "live-session"),
            for: request.agentID,
            directory: statusDir)
        func launch() throws -> (sessionID: String?, script: String) {
            let launch = try sandbox.prepareSurfaceLaunch(request)
            return (launch.newSessionID, try String(contentsOf: launch.scriptURL, encoding: .utf8))
        }
        func command(_ arguments: [String]) -> String {
            arguments.map(AgentHookRuntime.shellQuote).joined(separator: " ")
        }

        let first = try launch()
        let forkID = try #require(first.sessionID)
        #expect(UUID(uuidString: forkID) != nil && forkID == forkID.lowercased())
        #expect(!FileManager.default.fileExists(atPath: AgentSessionStore.sessionURL(request.agentID, statusDir).path))
        #expect(first.script.contains(command([
            sandbox.bin.appendingPathComponent("claude").path,
            "--resume", "live-session", "--fork-session", "--session-id", forkID, "--name", "Agent",
        ])))

        let again = try launch()
        let againID = try #require(again.sessionID)
        #expect(againID != forkID)
        #expect(again.script.contains(command([
            "--resume", "live-session", "--fork-session", "--session-id", againID,
        ])))

        try AgentSessionStore.write(
            AgentSessionBinding(provider: .claudeCode, sessionID: againID, launchGeneration: request.launchGeneration),
            for: request.agentID,
            directory: statusDir)
        try AgentSessionStore.clearPendingFork(for: request.agentID, directory: statusDir)
        let resumed = try launch()
        #expect(resumed.sessionID == nil)
        #expect(resumed.script.contains(command([
            sandbox.bin.appendingPathComponent("claude").path, "--resume", againID,
        ])))
        #expect(!resumed.script.contains("--fork-session"))
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
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
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
            session: nil,
            pendingFork: nil)
    }

    /// What the bridge prepares for a launch, with a non-production provider
    /// table whose Codex file is a stand-in.
    func prepareSurfaceLaunch(_ request: AgentLaunchRequest) throws -> AgentPreparedSurfaceLaunch {
        let coordinator = AgentLaunchCoordinator(
            providers: AgentProviderTable(
                root: root,
                codexHooksFile: home.appendingPathComponent(".codex/hooks.json"),
                isProduction: false),
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
