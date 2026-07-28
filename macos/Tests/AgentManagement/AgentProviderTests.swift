import Foundation
import Testing
@testable import Ghostty

struct AgentProviderTests {
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

    @Test func providerAuthenticationPresentationRetractsStaleSignInRequirement() {
        #expect(AgentAuthenticationPresentation.reconciledInteraction(
            current: .none,
            authentication: .signedOut) == .authentication)
        #expect(AgentAuthenticationPresentation.reconciledInteraction(
            current: .authentication,
            authentication: .signedIn) == .none)
        #expect(AgentAuthenticationPresentation.reconciledInteraction(
            current: .authentication,
            authentication: .unavailable("Probe failed")) == .none)
        #expect(AgentAuthenticationPresentation.reconciledInteraction(
            current: .permission,
            authentication: .unavailable("Probe failed")) == .permission)
    }

    @Test func explicitAgentDataDirectorySupportsIsolatedAppInstances() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let isolated = URL(
            fileURLWithPath: "/private/tmp/clawddy-isolated",
            isDirectory: true)

        #expect(AgentConfig.resolveBaseDirectory(
            environment: ["GHOSTTY_AGENT_DATA_DIR": isolated.path],
            defaultHomeDirectory: home) == isolated.standardizedFileURL)
        #expect(AgentConfig.resolveBaseDirectory(
            environment: ["GHOSTTY_AGENT_DATA_DIR": "relative/path"],
            defaultHomeDirectory: home) == home
                .appendingPathComponent(".config/ghostty-agents", isDirectory: true))
        #expect(AgentConfig.resolveBaseDirectory(
            environment: [:],
            defaultHomeDirectory: home) == home
                .appendingPathComponent(".config/ghostty-agents", isDirectory: true))
    }

    @Test func legacyAgentConfigMigratesToClaudeCode() throws {
        let id = UUID()
        let data = Data("""
            {
              "schemaVersion": 3,
              "projects": [{
                "id": "\(UUID().uuidString)",
                "name": "Project",
                "tasks": [{
                  "id": "\(UUID().uuidString)",
                  "name": "Task",
                  "agents": [{"id": "\(id.uuidString)", "name": "Existing"}]
                }]
              }]
            }
            """.utf8)

        let config = try JSONDecoder().decode(AgentConfigFile.self, from: data)
        let agent = try #require(config.projects.first?.tasks.first?.agents.first)
        #expect(agent.id == id)
        #expect(agent.provider == .claudeCode)
        #expect(agent.launchProfile == AgentLaunchProfile())
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
            AgentProject(
                name: "Project",
                tasks: [AgentTask(name: "Task", agents: agents)]),
        ])

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(AgentConfigFile.self, from: data)
        let decodedAgents = try #require(decoded.projects.first?.tasks.first?.agents)
        #expect(decoded.schemaVersion == 5)
        #expect(decodedAgents == agents)
    }

    @Test func preStartModeLaunchProfileMigratesToUnrestricted() throws {
        let profile = try JSONDecoder().decode(
            AgentLaunchProfile.self,
            from: Data("{\"modelID\":\"existing-model\",\"reasoningEffort\":\"high\"}".utf8))
        #expect(profile.modelID == "existing-model")
        #expect(profile.reasoningEffort == "high")
        #expect(profile.startMode == .unrestricted)
    }

    @Test func defaultStartModesAreUnrestrictedAndPersistIndependently() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preferences.json")

        var preferences = AgentPreferencesStore.load(from: url)
        #expect(preferences.defaultStartMode(for: .claudeCode) == .unrestricted)
        #expect(preferences.defaultStartMode(for: .codex) == .unrestricted)

        preferences.setDefaultStartMode(.standard, for: .codex)
        try AgentPreferencesStore.save(preferences, to: url)
        #expect(AgentPreferencesStore.load(from: url) == preferences)
        #expect(AgentPreferencesStore.load(from: url)
            .defaultStartMode(for: .claudeCode) == .unrestricted)
        #expect(AgentPreferencesStore.load(from: url)
            .defaultStartMode(for: .codex) == .standard)
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

        #expect(AgentSessionStore.session(
            for: agentID,
            provider: .codex,
            directory: directory) == nil)
        let migrated = AgentSessionStore.session(
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
        #expect(AgentSessionStore.write(binding, for: agentID, directory: directory))
        #expect(AgentSessionStore.session(
            for: agentID,
            provider: .codex,
            directory: directory) == binding)
        #expect(AgentSessionStore.session(
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
        #expect(AgentSessionStore.write(binding, for: agentID, directory: directory))

        var projects = [AgentProject(
            name: "Project",
            tasks: [AgentTask(
                name: "Task",
                agents: [AgentEntry(
                    id: agentID,
                    name: "Agent",
                    provider: .claudeCode)])])]

        #expect(AgentConfig.enforcePersistedProviderBindings(
            in: &projects,
            statusDirectory: directory))
        let restored = try #require(projects.first?.tasks.first?.agents.first)
        #expect(restored.provider == .codex)
        #expect(!AgentConfig.enforcePersistedProviderBindings(
            in: &projects,
            statusDirectory: directory))
    }

    @Test func pendingForkIsProviderTaggedAndValidated() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agentID = UUID()
        let pending = AgentPendingFork(provider: .codex, sourceSessionID: "source.session-1")

        #expect(AgentSessionStore.write(pending, for: agentID, directory: directory))
        #expect(AgentSessionStore.pendingFork(
            for: agentID,
            provider: .codex,
            directory: directory) == pending)
        #expect(AgentSessionStore.pendingFork(
            for: agentID,
            provider: .claudeCode,
            directory: directory) == nil)
    }

    @Test func rawEventsDecodeTaggedAndLegacyPayloads() throws {
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

        let legacy = try JSONDecoder().decode(
            AgentRawProviderEvent.self,
            from: Data("{\"hook_event_name\":\"SessionStart\",\"session_id\":\"legacy\"}".utf8))
        #expect(legacy.provider == nil)
        #expect(legacy.hookEventName == "SessionStart")
        #expect(legacy.sessionID == "legacy")
        #expect(tagged.hasSupportedSchema(for: .codex))
        #expect(legacy.hasSupportedSchema(for: .claudeCode))
        #expect(!legacy.hasSupportedSchema(for: .codex))
    }

    @Test func unknownProviderEventSchemaIsRejected() throws {
        let event = try JSONDecoder().decode(
            AgentRawProviderEvent.self,
            from: Data("{\"schemaVersion\":2,\"provider\":\"codex\",\"hookEventName\":\"Stop\"}".utf8))
        #expect(!event.hasSupportedSchema(for: .codex))
    }

    @Test func codexLaunchUsesStableInteractiveResumeAndForkCommands() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
        let provider = CodexProvider()
        let generation = UUID()
        let base = AgentLaunchRequest(
            agentID: UUID(),
            name: "Agent",
            provider: .codex,
            launchProfile: AgentLaunchProfile(
                modelID: "gpt-5.4",
                reasoningEffort: "xhigh"),
            workingDirectory: nil,
            environmentPath: directory.path,
            launchGeneration: generation,
            session: nil,
            pendingFork: nil)

        let fresh = try launch(provider.prepareLaunch(base))
        #expect(fresh.arguments == [
            "--dangerously-bypass-approvals-and-sandbox",
            "--model", "gpt-5.4", "--config", "model_reasoning_effort=\"xhigh\"",
        ])

        var resumedRequest = base
        resumedRequest.session = AgentSessionBinding(
            provider: .codex,
            sessionID: "session-1",
            launchGeneration: generation)
        let resumed = try launch(provider.prepareLaunch(resumedRequest))
        #expect(resumed.arguments.suffix(2) == ["resume", "session-1"])

        var forkRequest = base
        forkRequest.pendingFork = AgentPendingFork(
            provider: .codex,
            sourceSessionID: "source-1")
        let forked = try launch(provider.prepareLaunch(forkRequest))
        #expect(forked.arguments.suffix(2) == ["fork", "source-1"])

        var standardRequest = base
        standardRequest.launchProfile.startMode = .standard
        let standard = try launch(provider.prepareLaunch(standardRequest))
        #expect(!standard.arguments.contains(where: { $0.contains("dangerously") }))
    }

    @Test func adaptersNormalizeProviderSpecificHooksToSharedEvents() throws {
        let event = try rawEvent(name: "PermissionRequest")
        #expect(CodexProvider().normalize(event) == [.turnInteractionChanged(.permission)])
        #expect(ClaudeCodeProvider().normalize(event) == [.turnInteractionChanged(.permission)])

        let codexFailure = try rawEvent(name: "PostToolUseFailure")
        #expect(CodexProvider().normalize(codexFailure).isEmpty)
        #expect(ClaudeCodeProvider().normalize(codexFailure) == [.turnFailed(nil)])

        let childCompleted = try rawEvent(name: "SubagentStop")
        #expect(CodexProvider().normalize(childCompleted) == [
            .turnInteractionChanged(.none),
            .turnActivityChanged(.reasoning),
        ])
        #expect(ClaudeCodeProvider().normalize(childCompleted) == [
            .turnInteractionChanged(.none),
            .turnActivityChanged(.reasoning),
        ])
    }

    @Test func capabilityMatrixDoesNotPretendUnavailableCodexTelemetryExists() {
        #expect(AgentProviderID.codex.capabilities.resume.isSupported)
        #expect(AgentProviderID.codex.capabilities.fork.isSupported)
        #expect(AgentProviderID.codex.capabilities.sessionRename.isSupported)
        #expect(!AgentProviderID.codex.capabilities.contextTelemetry.isSupported)
        #expect(AgentProviderID.codex.capabilities.contextTelemetry.explanation != nil)
        #expect(AgentProviderID.claudeCode.capabilities.contextTelemetry.isSupported)
    }

    @Test func requestedLaunchMetadataHasHonestPresentationAndSearchTerms() {
        let profile = AgentLaunchProfile(
            modelID: "gpt-5.4",
            reasoningEffort: "xhigh")
        #expect(profile.displayReasoningEffort == "Extra high")
        #expect(profile.searchTerms.contains("gpt-5.4"))
        #expect(profile.searchTerms.contains("Extra high"))
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
        let entry = AgentEntry(name: "Codex", provider: .codex)
        let agent = AgentInstance(entry: entry)
        agent.surfaceState = .open
        agent.processState = .exited
        agent.activityState = .unknown
        agent.unreadCompletion = AgentCompletionID(
            provider: .codex,
            sessionID: "session",
            turnID: "turn",
            launchGeneration: UUID(),
            eventID: "complete")

        #expect(agent.displayState == .finished)
    }

    @MainActor
    @Test func persistedUnreadCompletionIsVisibleWithoutARestoredSurface() {
        let agent = AgentInstance(entry: AgentEntry(name: "Codex", provider: .codex))
        agent.unreadCompletion = AgentCompletionID(
            provider: .codex,
            sessionID: "session",
            turnID: "turn",
            launchGeneration: UUID(),
            eventID: "complete")
        #expect(agent.displayState == .finished)
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

    private func rawEvent(name: String) throws -> AgentRawProviderEvent {
        try JSONDecoder().decode(
            AgentRawProviderEvent.self,
            from: Data("{\"hookEventName\":\"\(name)\"}".utf8))
    }
}
