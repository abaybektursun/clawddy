import Foundation
import Testing
@testable import Ghostty

struct AgentProviderTests {
    /// A probe whose output outlives it (a child left holding the pipe)
    /// ends as a timeout about a second after it exits, instead of holding
    /// the IO queue, and with it every record save, until the child ends.
    @Test func aProbeWhoseOutputOutlivesItTimesOut() {
        let start = Date()
        let outcome = AgentProcessProbe.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 8 & echo started"],
            environmentPath: "/usr/bin:/bin")
        #expect(outcome == .timedOut)
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func providerProbeEnvironmentPreservesMacOSAccountIdentity() {
        let environment = AgentProcessProbe.environment(
            environmentPath: "/custom/bin:/usr/bin",
            additionalEnvironment: [
                "CODEX_HOME": "/tmp/codex",
                "HOME": "/hostile/home",
                "USER": "wrong-user",
            ],
            inheritedEnvironment: [
                "LANG": "en_US.UTF-8",
                "HTTPS_PROXY": "https://proxy.example",
                "LOGNAME": "wrong-logname",
                "CLAUDE_CODE_CHILD_SESSION": "1",
                "CLAUDECODE": "1",
                "CLAUDE_PID": "59562",
            ],
            accountHomeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            accountUserName: "example")

        #expect(environment == [
            "HOME": "/Users/example",
            "PATH": "/custom/bin:/usr/bin",
            "USER": "example",
            "LOGNAME": "example",
            "CODEX_HOME": "/tmp/codex",
            "LANG": "en_US.UTF-8",
            "HTTPS_PROXY": "https://proxy.example",
        ])
    }

    @Test func claudeAuthenticationDistinguishesSignedOutFromProbeFailure() {
        #expect(ClaudeCodeProvider.authenticationState(from: .completed(.init(
            status: 0,
            output: #"{"loggedIn":true}"#))) == .signedIn)
        #expect(ClaudeCodeProvider.authenticationState(from: .completed(.init(
            status: 1,
            output: #"{"loggedIn":false}"#))) == .signedOut)
        #expect(ClaudeCodeProvider.authenticationState(from: .timedOut) == .unavailable(
            "Claude Code sign-in status timed out."))
        #expect(ClaudeCodeProvider.authenticationState(from: .launchFailed("missing")) == .unavailable(
            "Claude Code sign-in status could not be started."))
        #expect(ClaudeCodeProvider.authenticationState(from: .completed(.init(
            status: 1,
            output: "Keychain lookup failed"))) == .unavailable(
                "Claude Code returned an unreadable sign-in status."))
    }

    @Test func codexAuthenticationDistinguishesSignedOutFromProbeFailure() {
        #expect(CodexProvider.authenticationState(from: .completed(.init(
            status: 0,
            output: "Logged in using ChatGPT"))) == .signedIn)
        #expect(CodexProvider.authenticationState(from: .completed(.init(
            status: 1,
            output: "Not logged in"))) == .signedOut)
        #expect(CodexProvider.authenticationState(from: .timedOut) == .unavailable(
            "Codex sign-in status timed out."))
        #expect(CodexProvider.authenticationState(from: .launchFailed("missing")) == .unavailable(
            "Codex sign-in status could not be started."))
        #expect(CodexProvider.authenticationState(from: .completed(.init(
            status: 1,
            output: "Credential store unavailable"))) == .unavailable(
                "Codex returned an unreadable sign-in status."))
    }

    @Test func mixedProviderConfigRoundTripsAtSchemaFive() throws {
        let agents = [
            AgentEntry(name: "Claude", provider: .claudeCode),
            AgentEntry(
                name: "Codex",
                provider: .codex,
                launchProfile: AgentLaunchProfile(
                    modelID: "gpt-5.4",
                    reasoningEffort: "high")),
        ]
        let source = AgentConfigFile(projects: [
            AgentProject(name: "Project", agents: agents),
        ])

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(AgentConfigFile.self, from: data)
        let decodedAgents = try #require(decoded.projects.first?.agents)
        #expect(decoded.schemaVersion == 6)
        #expect(decodedAgents == agents)
    }

    @Test func defaultStartModesAreUnrestrictedAndPersistIndependently() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preferences.json")

        for changed in AgentProviderID.allCases {
            try? FileManager.default.removeItem(at: url)
            var preferences = AgentPreferencesStore.load(from: url).preferences
            #expect(AgentProviderID.allCases.allSatisfy { preferences.defaultStartMode(for: $0) == .unrestricted })

            preferences.setDefaultStartMode(.standard, for: changed)
            try AgentPreferencesStore.save(preferences, to: url)
            let loaded = AgentPreferencesStore.load(from: url)
            #expect(loaded == AgentPreferencesStore.Loaded(preferences: preferences))
            for provider in AgentProviderID.allCases {
                #expect(loaded.preferences.defaultStartMode(for: provider) == (provider == changed ? .standard : .unrestricted))
            }
        }
    }

    /// A preferences file of the shape written before the agy work (one
    /// named field per CLI) loads with its values; saving writes the keyed
    /// shape only. A CLI the file does not name starts unrestricted.
    @Test func theOldPreferencesShapeStillLoads() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preferences.json")
        try Data("""
        {
          "claudeCodeDefaultStartMode" : "standard",
          "codexDefaultStartMode" : "unrestricted",
          "schemaVersion" : 1
        }
        """.utf8).write(to: url)

        let loaded = AgentPreferencesStore.load(from: url)
        #expect(loaded.error == nil)
        #expect(loaded.preferences.defaultStartMode(for: .claudeCode) == .standard)
        #expect(loaded.preferences.defaultStartMode(for: .codex) == .unrestricted)
        #expect(loaded.preferences.defaultStartMode(for: .antigravity) == .unrestricted)

        try AgentPreferencesStore.save(loaded.preferences, to: url)
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(written.keys) == ["schemaVersion", "defaultStartModes"])
        #expect(written["schemaVersion"] as? Int == 2)
        #expect(written["defaultStartModes"] as? [String: String]
            == ["claudeCode": "standard", "codex": "unrestricted", "antigravity": "unrestricted"])
        #expect(AgentPreferencesStore.load(from: url) == loaded)
    }

    /// A name no CLI has (a file from a later build) is dropped, and the
    /// rest load.
    @Test func anUnknownCLIInPreferencesIsDropped() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preferences.json")
        try Data(#"{"schemaVersion": 3, "defaultStartModes": {"codex": "standard", "later": "standard"}}"#.utf8).write(to: url)

        let loaded = AgentPreferencesStore.load(from: url)
        #expect(loaded.error == nil)
        #expect(loaded.preferences.defaultStartMode(for: .codex) == .standard)
        #expect(loaded.preferences.defaultStartMode(for: .claudeCode) == .unrestricted)
    }

    @Test func startModesMapToProviderCanonicalArguments() {
        #expect(AgentProviderID.claudeCode.startModeArguments(.unrestricted)
            == ["--dangerously-skip-permissions"])
        #expect(AgentProviderID.codex.startModeArguments(.unrestricted)
            == ["--dangerously-bypass-approvals-and-sandbox"])
        #expect(AgentProviderID.claudeCode.startModeArguments(.standard).isEmpty)
        #expect(AgentProviderID.codex.startModeArguments(.standard).isEmpty)
    }

    @Test func providerTaggedSessionStoreMigratesOnlyClaudeLegacyFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agentID = UUID()
        try Data("legacy-session\n".utf8).write(to: directory
            .appendingPathComponent("\(agentID.uuidString).session"))

        #expect(try AgentSessionStore.session(
            for: agentID,
            provider: .codex,
            directory: directory) == nil)
        let migrated = try AgentSessionStore.session(
            for: agentID,
            provider: .claudeCode,
            directory: directory)
        #expect(migrated?.provider == .claudeCode)
        #expect(migrated?.sessionID == "legacy-session")
        #expect(FileManager.default.fileExists(atPath: directory
            .appendingPathComponent("\(agentID.uuidString).session.json").path))
    }

    @Test func taggedSessionNeverCrossesProviderBoundary() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agentID = UUID()
        let binding = AgentSessionBinding(
            provider: .codex,
            sessionID: "codex-session",
            launchGeneration: UUID())
        try AgentSessionStore.write(binding, for: agentID, directory: directory)
        #expect(try AgentSessionStore.session(
            for: agentID,
            provider: .codex,
            directory: directory) == binding)
        #expect(try AgentSessionStore.session(
            for: agentID,
            provider: .claudeCode,
            directory: directory) == nil)
    }

    @Test func persistedSessionProviderOverridesExternallyEditedConfig() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agentID = UUID()
        let binding = AgentSessionBinding(
            provider: .codex,
            sessionID: "codex-session",
            launchGeneration: UUID())
        try AgentSessionStore.write(binding, for: agentID, directory: directory)

        var projects = [AgentProject(
            name: "Project",
            agents: [AgentEntry(id: agentID, name: "Agent", provider: .claudeCode)])]

        #expect(AgentConfig.enforcePersistedProviderBindings(
            in: &projects,
            statusDirectory: directory))
        let restored = try #require(projects.first?.agents.first)
        #expect(restored.provider == .codex)
        #expect(!AgentConfig.enforcePersistedProviderBindings(
            in: &projects,
            statusDirectory: directory))
    }

    @Test func rawEventsDecodeOnlyTaggedRecords() throws {
        let generation = UUID()
        let tagged = try JSONDecoder().decode(
            AgentRawProviderEvent.self,
            from: Data("""
                {"schemaVersion":1,"eventID":"event-1","provider":"codex","launchGeneration":"\(generation.uuidString)","hookEventName":"Stop","sessionID":"s","turnID":"t","model":"gpt-5.4","permissionMode":"default"}
                """.utf8))
        #expect(tagged.provider == .codex)
        #expect(tagged.eventID == "event-1")
        #expect(tagged.launchGeneration == generation)
        #expect(tagged.hookEventName == "Stop")
        #expect(tagged.turnID == "t")
        #expect(tagged.hasSupportedSchema)

        // The pre-provider hook's untagged record.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                AgentRawProviderEvent.self,
                from: Data("{\"hook_event_name\":\"SessionStart\",\"session_id\":\"legacy\"}".utf8))
        }
    }

    @Test func unknownProviderEventSchemaIsRejected() throws {
        let event = try JSONDecoder().decode(
            AgentRawProviderEvent.self,
            from: Data("{\"schemaVersion\":2,\"provider\":\"codex\",\"launchGeneration\":\"\(UUID().uuidString)\",\"hookEventName\":\"Stop\"}".utf8))
        #expect(!event.hasSupportedSchema)
    }

    @Test func codexLaunchUsesStableInteractiveResumeAndForkCommands() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\n[ \"$1\" = agents ] && echo '[]'\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
        let root = AgentDataRoot(url: directory)
        let provider = CodexProvider(root: root, configFile: directory.appendingPathComponent("config.toml"))
        let agentID = UUID()
        let generation = UUID()
        let base = AgentLaunchRequest(
            agentID: agentID,
            name: "Agent",
            provider: .codex,
            launchProfile: AgentLaunchProfile(
                modelID: "gpt-5.4",
                reasoningEffort: "xhigh"),
            workingDirectory: nil,
            environmentPath: directory.path,
            launchGeneration: generation,
            session: nil)

        let fresh = try launch(provider.prepareLaunch(base))
        let notify = CodexProvider.tomlArray(AgentHookRuntime.arguments(
            root: root, provider: .codex, agentID: agentID, generation: generation) + ["notify"])
        #expect(fresh.arguments == [
            "-c", "notify=\(notify)",
            "--dangerously-bypass-approvals-and-sandbox",
            "--model", "gpt-5.4", "--config", "model_reasoning_effort=\"xhigh\"",
        ])
        #expect(fresh.environment.filter { $0.key.hasPrefix("CLAWDDY_") }.isEmpty)

        var resumedRequest = base
        resumedRequest.session = AgentSessionBinding(
            provider: .codex,
            sessionID: "session-1",
            launchGeneration: generation)
        let resumed = try launch(provider.prepareLaunch(resumedRequest))
        #expect(resumed.arguments.suffix(2) == ["resume", "session-1"])

        var standardRequest = base
        standardRequest.launchProfile.startMode = .standard
        let standard = try launch(provider.prepareLaunch(standardRequest))
        #expect(!standard.arguments.contains(where: { $0.contains("dangerously") }))
    }

    /// Each Codex launch names the hook script its notify program, with the
    /// owner's own `notify` from Codex's configuration after `notify`, so the
    /// script runs it. Only the top-level key counts.
    @Test func codexNotifyChainsToTheOwnersNotify() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.toml")
        #expect(try CodexProvider.notifyCommand(inConfig: config) == [])
        for (text, expected) in [
            (#"notify = ["/Apps/A B.app/client", "turn-ended"]"#, ["/Apps/A B.app/client", "turn-ended"]),
            ("model = \"x\"\nnotify = [\n  'C:\\raw', # a comment\n  \"q\\\"\\u00e9\",\n]\n", ["C:\\raw", "q\"é"]),
            ("model = \"x\"\n[profiles.a]\nnotify = [\"not top level\"]\n", []),
        ] {
            try Data(text.utf8).write(to: config)
            #expect(try CodexProvider.notifyCommand(inConfig: config) == expected, "\(text)")
        }
        try Data(#"notify = ["unterminated"#.utf8).write(to: config)
        #expect(throws: (any Error).self) { try CodexProvider.notifyCommand(inConfig: config) }
        #expect(CodexProvider.tomlArray(["a\"b\\c", "é\n"]) == #"["a\"b\\c","é\n"]"#)
    }

    /// Codex's one event is its notify program's record of a completed turn:
    /// its session, its prompts as submitted, the completion, and the last
    /// message. Codex's own title turn notifies too and means nothing.
    @Test func codexNotifyMeansACompletedTurn() throws {
        func record(_ prompts: [String]) throws -> AgentRawProviderEvent {
            let object: [String: Any] = [
                "provider": "codex", "launchGeneration": UUID().uuidString,
                "hookEventName": "agent-turn-complete", "sessionID": "thread-1", "turnID": "turn-1",
                "text": "Done.", "prompts": prompts,
            ]
            return try JSONDecoder().decode(
                AgentRawProviderEvent.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let meaning = try #require(CodexProvider.hookEvents["agent-turn-complete"])
        #expect(try meaning(record(["fix it", "also this"])) == [
            .sessionBound(sessionID: "thread-1"),
            .promptSubmitted("fix it"),
            .promptSubmitted("also this"),
            .turnCompleted(turnID: "turn-1"),
            .messageReported("Done."),
        ])
        #expect(try meaning(record([CodexProvider.titleInstruction + " ... User prompt:\nfix it"])) == [])
        #expect(CodexProvider.hookEvents.count == 1)
    }

    /// Claude's terminal reports its turns (P3.5): no hook of Claude's
    /// continues or completes one. `SessionStart` only binds the session,
    /// `UserPromptSubmit` is the prompt that starts the turn its terminal
    /// announced, `Stop` brings the turn's last message, `StopFailure` fails
    /// the turn with Claude's kind and text, `PermissionRequest` brings an
    /// asked question in full, and `PreCompact` tells a manual compaction
    /// from an automatic one by its trigger.
    @Test func claudeHooksCarryNoTurnActivity() throws {
        for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop"] {
            #expect(try meaning(ClaudeCodeProvider.hookEvents, event) == nil, "\(event)")
        }
        #expect(try meaning(ClaudeCodeProvider.hookEvents, "UserPromptSubmit", text: "hi") == [.promptSubmitted("hi")])
        #expect(try meaning(ClaudeCodeProvider.hookEvents, "Stop", text: "ok") == [.messageReported("ok")])
        #expect(try meaning(ClaudeCodeProvider.hookEvents, "Stop") == [])
        #expect(try meaning(ClaudeCodeProvider.hookEvents, "PermissionRequest", text: "A or B?")
            == [.questionReported("A or B?")])
        #expect(try meaning(ClaudeCodeProvider.hookEvents, "PermissionRequest") == [])
        #expect(try meaning(ClaudeCodeProvider.hookEvents, "SessionStart") == [.sessionBound(sessionID: nil)])
        #expect(try meaning(ClaudeCodeProvider.hookEvents, "StopFailure", text: "limit", error: "rate_limit")
            == [.turnFailed(AgentFailure(error: "rate_limit", text: "limit"))])
        #expect(try meaning(ClaudeCodeProvider.hookEvents, "PreCompact", trigger: "manual")
            == [.manualCompactionStarted])
        #expect(try meaning(ClaudeCodeProvider.hookEvents, "PreCompact", trigger: "auto")
            == [.turnActivityChanged(.compacting)])
        #expect(try meaning(ClaudeCodeProvider.hookEvents, "PostCompact") == [.turnActivityChanged(.executing)])
        // Every event with text is one Claude subscribes to.
        #expect(Set(ClaudeCodeProvider.textFields.keys).isSubset(of: ClaudeCodeProvider.hookEvents.keys))
    }

    @Test func providerReconciliationOnlyReplacesAnUnboundInactiveRuntime() {
        #expect(AgentRuntimeProviderPolicy.decision(
            current: .claudeCode,
            requested: .codex,
            persistedProvider: nil,
            surfaceState: .inactive,
            processState: .notStarted) == .replaceInactiveRuntime)
        #expect(AgentRuntimeProviderPolicy.decision(
            current: .claudeCode,
            requested: .codex,
            persistedProvider: .claudeCode,
            surfaceState: .inactive,
            processState: .notStarted) == .preserveRuntimeAndRestoreConfig)
        #expect(AgentRuntimeProviderPolicy.decision(
            current: .claudeCode,
            requested: .codex,
            persistedProvider: nil,
            surfaceState: .open,
            processState: .running) == .preserveRuntimeAndRestoreConfig)
    }

    @MainActor
    @Test func unreadCompletionSurvivesProviderExitInPresentationState() {
        var runtime = AgentRuntimeSnapshot(surfaceState: .open, processState: .exited, activityState: .unknown)
        runtime.record.unread = true
        let agent = AgentInstance(entry: AgentEntry(name: "Codex", provider: .codex), runtime: runtime)
        #expect(agent.shownState == .finishedUnread)
    }

    @MainActor
    @Test func persistedUnreadCompletionIsVisibleWithoutARestoredSurface() {
        var runtime = AgentRuntimeSnapshot()
        runtime.record.unread = true
        let agent = AgentInstance(entry: AgentEntry(name: "Codex", provider: .codex), runtime: runtime)
        #expect(agent.shownState == .finishedUnread)
    }

    /// Claude's own list of its running sessions (`claude agents --json`)
    /// says whether a conversation is live in another terminal: an
    /// interactive one whose process is alive, or a background one. Such a
    /// conversation is not resumed; a list that cannot be read stops the
    /// launch rather than risk it (flows.md 4.5).
    @Test func aLiveClaudeConversationIsNotResumed() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let claude = folder.appendingPathComponent("claude")
        func answer(_ list: String) throws {
            try Data("#!/bin/sh\n[ \"$1 $2\" = 'agents --json' ] && /bin/cat <<'LIST'\n\(list)\nLIST\nexit 0\n".utf8).write(to: claude)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        }
        func isLive(_ session: String) -> Result<Bool, AgentProviderIssue> {
            ClaudeCodeProvider.runningSessions(executable: claude, environmentPath: folder.path)
                .flatMap { ClaudeCodeProvider.isLive(session, in: $0) }
        }
        let me = ProcessInfo.processInfo.processIdentifier
        try answer(#"[{"pid":\#(me),"sessionId":"s-1","kind":"interactive","status":"idle"}]"#)
        #expect(isLive("s-1") == .success(true))
        #expect(isLive("s-2") == .success(false))
        try answer(#"[{"pid":99999,"sessionId":"s-1","kind":"interactive"}]"#)
        #expect(isLive("s-1") == .success(false))
        try answer(#"[{"id":"b-1","sessionId":"s-1","state":"running","kind":"background"}]"#)
        #expect(isLive("s-1") == .success(true))
        try answer("[]")
        #expect(isLive("s-1") == .success(false))
        try answer("not a list")
        guard case .failure = isLive("s-1") else { Issue.record("An unreadable list was taken as an answer."); return }

        try answer(#"[{"pid":\#(me),"sessionId":"s-1","kind":"interactive"}]"#)
        let request = AgentLaunchRequest(
            agentID: UUID(), name: "Agent", provider: .claudeCode, launchProfile: AgentLaunchProfile(),
            workingDirectory: nil, environmentPath: folder.path, launchGeneration: UUID(),
            session: AgentSessionBinding(provider: .claudeCode, sessionID: "s-1"))
        let launch = ClaudeCodeProvider(root: AgentDataRoot(url: folder.appendingPathComponent("root"))).prepareLaunch(request)
        guard case .failure(let issue) = launch else { Issue.record("A live conversation was resumed."); return }
        #expect(issue == .sessionOpenElsewhere(.claudeCode, "s-1"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func launch(
        _ result: Result<AgentPreparedLaunch, AgentProviderIssue>
    ) throws -> AgentPreparedLaunch {
        switch result {
        case .success(let launch): return launch
        case .failure(let issue): throw issue
        }
    }

    /// What the event table says a record of the hook event `name` means, or
    /// nil when the table has no such event. The record carries only the
    /// hook name, the trigger, the text, the error, and the keys every
    /// record has.
    private func meaning(
        _ table: [String: AgentProviderEntry.Meaning],
        _ name: String,
        trigger: String = "",
        text: String? = nil,
        error: String = ""
    ) throws -> [AgentDomainEvent]? {
        var object: [String: Any] = [
            "provider": "claudeCode", "launchGeneration": UUID().uuidString,
            "hookEventName": name, "trigger": trigger, "error": error,
        ]
        object["text"] = text
        let record = try JSONDecoder().decode(
            AgentRawProviderEvent.self, from: JSONSerialization.data(withJSONObject: object))
        return table[name]?(record)
    }
}
