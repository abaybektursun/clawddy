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
        #expect(Set(hooks.keys) == Set(ClaudeCodeProvider.hookedEvents))
        for event in ClaudeCodeProvider.hookedEvents {
            #expect(NSArray(array: hooks[event] as? [Any] ?? []).isEqual(to: [expectedGroup]))
        }

        // The command line in the overlay records each event for this agent,
        // with no identity anywhere in its environment.
        _ = try provider.prepareIntegration().get()
        for event in ClaudeCodeProvider.hookedEvents {
            let status = try sandbox.runShell(
                command,
                environment: sandbox.plainEnvironment,
                payload: #"{"session_id":"session-1","hook_event_name":"\#(event)"}"#)
            #expect(status == 0)
        }
        let events = try sandbox.events(request.agentID)
        #expect(events.map(\.hookEventName) == ClaudeCodeProvider.hookedEvents)
        #expect(events.allSatisfy {
            $0.provider == .claudeCode && $0.launchGeneration == request.launchGeneration
        })
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
        #expect(Set(hooks.keys) == Set(CodexProvider.hookedEvents))

        // The user reviewed the hooks in Codex. A later launch must neither
        // rewrite the file nor ask again.
        CodexProvider.clearHookReviewRequired(root: sandbox.root)
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
        for event in CodexProvider.hookedEvents {
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

    /// A fork launches as `--resume <source> --fork-session --session-id
    /// <new>`, and the new ID is the agent's binding before the process
    /// starts. Until the fork is seen alive its marker stays, and a relaunch
    /// forks again under another new ID; once the bridge has cleared the
    /// marker, the next launch resumes the fork's own session.
    @Test func forkLaunchAnnouncesItsNewSessionID() throws {
        let sandbox = try HookSandbox()
        defer { sandbox.remove() }
        let request = sandbox.request(.claudeCode)
        let statusDir = sandbox.root.statusDir
        try FileManager.default.createDirectory(at: statusDir, withIntermediateDirectories: true)
        #expect(AgentSessionStore.write(
            AgentPendingFork(provider: .claudeCode, sourceSessionID: "live-session"),
            for: request.agentID,
            directory: statusDir))
        func launch() throws -> (binding: AgentSessionBinding, script: String) {
            let launch = try sandbox.prepareSurfaceLaunch(request)
            let binding = try #require(AgentSessionStore.session(
                for: request.agentID,
                provider: .claudeCode,
                directory: statusDir))
            return (binding, try String(contentsOf: launch.scriptURL, encoding: .utf8))
        }
        func command(_ arguments: [String]) -> String {
            arguments.map(AgentHookRuntime.shellQuote).joined(separator: " ")
        }

        let first = try launch()
        let forkID = first.binding.sessionID
        #expect(UUID(uuidString: forkID) != nil && forkID == forkID.lowercased())
        #expect(first.binding == AgentSessionBinding(
            provider: .claudeCode,
            sessionID: forkID,
            launchGeneration: request.launchGeneration))
        #expect(first.script.contains(command([
            sandbox.bin.appendingPathComponent("claude").path,
            "--resume", "live-session", "--fork-session", "--session-id", forkID, "--name", "Agent",
        ])))

        let again = try launch()
        #expect(again.binding.sessionID != forkID)
        #expect(again.script.contains(command([
            "--resume", "live-session", "--fork-session", "--session-id", again.binding.sessionID,
        ])))

        AgentSessionStore.clearPendingFork(for: request.agentID, directory: statusDir)
        let resumed = try launch()
        #expect(resumed.binding == again.binding)
        #expect(resumed.script.contains(command([
            sandbox.bin.appendingPathComponent("claude").path, "--resume", again.binding.sessionID,
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

    /// What the bridge prepares for a launch, with a non-production registry
    /// whose Codex file is a stand-in.
    func prepareSurfaceLaunch(_ request: AgentLaunchRequest) throws -> AgentPreparedSurfaceLaunch {
        let coordinator = AgentLaunchCoordinator(
            providerRegistry: AgentProviderRegistry(
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
