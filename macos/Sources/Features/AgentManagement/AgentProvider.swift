import Foundation

enum AgentProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex

    var id: Self { self }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    var symbolName: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Why the provider never reports its reasoning effort, or nil when it
    /// does: Claude's status line carries it.
    var effortUnavailableReason: String? {
        switch self {
        case .claudeCode: return nil
        case .codex: return "Reasoning effort is not exposed by the interactive hook interface."
        }
    }

    /// Why the provider never reports its context usage, or nil when it
    /// does: Claude's status line carries it.
    var contextUnavailableReason: String? {
        switch self {
        case .claudeCode: return nil
        case .codex:
            return "Context usage is not exposed by Codex lifecycle hooks in the interactive terminal integration."
        }
    }

    func startModeTitle(_ mode: AgentStartMode) -> String {
        switch (self, mode) {
        case (.claudeCode, .unrestricted): return "Dangerously Skip Permissions"
        case (.codex, .unrestricted): return "YOLO"
        case (_, .standard): return "Standard Permissions"
        }
    }

    func startModeDescription(_ mode: AgentStartMode) -> String {
        switch (self, mode) {
        case (.claudeCode, .unrestricted):
            return "Bypasses all Claude Code permission checks."
        case (.codex, .unrestricted):
            return "Runs without approval prompts or the Codex sandbox."
        case (_, .standard):
            return "Uses the provider’s normal approval and sandbox behavior."
        }
    }

    func startModeArguments(_ mode: AgentStartMode) -> [String] {
        guard mode == .unrestricted else { return [] }
        switch self {
        case .claudeCode: return ["--dangerously-skip-permissions"]
        case .codex: return ["--dangerously-bypass-approvals-and-sandbox"]
        }
    }

    /// Reasoning-effort choices offered at agent creation, in menu order.
    /// `value` is passed to the CLI verbatim; nil requests the provider default.
    var reasoningEffortOptions: [AgentReasoningEffortOption] {
        switch self {
        case .claudeCode: return [
            .init(id: "default", title: "Provider Default", value: nil),
            .init(id: "low", title: "Low", value: "low"),
            .init(id: "medium", title: "Medium", value: "medium"),
            .init(id: "high", title: "High", value: "high"),
            .init(id: "xhigh", title: "Extra High", value: "xhigh"),
            .init(id: "max", title: "Maximum", value: "max"),
        ]
        case .codex: return [
            .init(id: "default", title: "Provider Default", value: nil),
            .init(id: "minimal", title: "Minimal", value: "minimal"),
            .init(id: "low", title: "Low", value: "low"),
            .init(id: "medium", title: "Medium", value: "medium"),
            .init(id: "high", title: "High", value: "high"),
            .init(id: "xhigh", title: "Extra High", value: "xhigh"),
        ]
        }
    }
}

struct AgentReasoningEffortOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// Value passed to the CLI; nil requests the provider default.
    let value: String?
}

enum AgentStartMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case unrestricted
    case standard

    var id: Self { self }
}

struct AgentLaunchProfile: Codable, Equatable, Sendable {
    var modelID: String?
    var reasoningEffort: String?
    var startMode: AgentStartMode

    init(
        modelID: String? = nil,
        reasoningEffort: String? = nil,
        startMode: AgentStartMode = .unrestricted
    ) {
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.startMode = startMode
    }

    var displayReasoningEffort: String? {
        guard let effort = reasoningEffort?.trimmingCharacters(
            in: .whitespacesAndNewlines),
              !effort.isEmpty
        else { return nil }
        switch effort.lowercased() {
        case "xhigh": return "Extra high"
        case "max": return "Maximum"
        default: return effort.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var searchTerms: [String] {
        [modelID, displayReasoningEffort, reasoningEffort].compactMap { $0 }
    }
}

enum AgentProviderAuthState: Equatable, Sendable {
    case checking
    case signedIn
    case signedOut
    case unavailable(String)
}

struct AgentProviderHealth: Equatable, Sendable {
    enum Installation: Equatable, Sendable {
        case checking
        case ready(executable: String, version: String?)
        case missing
        case unavailable(String)
    }

    var installation: Installation = .checking
    var authentication: AgentProviderAuthState = .checking
    var integrationIssue: String?

    var isReadyToLaunch: Bool {
        if case .ready = installation { return true }
        return false
    }

    var conciseStatus: String {
        switch installation {
        case .checking: return "Checking…"
        case .missing: return "Not Installed"
        case .unavailable: return "Unavailable"
        case .ready:
            switch authentication {
            case .checking: return "Checking Sign-In…"
            case .signedIn: return integrationIssue == nil ? "Ready" : "Ready · Status Limited"
            case .signedOut: return "Sign In Required"
            case .unavailable: return "Ready · Sign-In Unknown"
            }
        }
    }
}

enum AgentAuthenticationPresentation {
    static func reconciledInteraction(
        current: AgentInteractionState,
        authentication: AgentProviderAuthState
    ) -> AgentInteractionState {
        if authentication == .signedOut { return .authentication }
        guard current == .authentication else { return current }
        switch authentication {
        case .signedIn, .unavailable: return .none
        case .checking, .signedOut: return current
        }
    }
}

enum AgentProviderIssue: Error, Equatable, LocalizedError, Sendable {
    case executableMissing(AgentProviderID)
    case integrationFailed(AgentProviderID, String)
    /// The saved session could not be read; the agent can only start fresh.
    case unreadableSession(AgentProviderID, String)
    case launchPreparationFailed(AgentProviderID, String)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let provider):
            return "\(provider.displayName) is not installed or is not available on the login-shell PATH."
        case .integrationFailed(let provider, let reason):
            return "\(provider.displayName) activity tracking could not be configured: \(reason)"
        case .unreadableSession(let provider, let reason):
            return "The saved \(provider.displayName) session could not be read, so the agent was not started. \(reason)"
        case .launchPreparationFailed(let provider, let reason):
            return "\(provider.displayName) could not be prepared: \(reason)"
        }
    }
}

struct AgentSessionBinding: Codable, Equatable, Sendable {
    var provider: AgentProviderID
    var sessionID: String
    var launchGeneration: UUID?
    /// True once a resume found no conversation with `sessionID`. The agent
    /// then offers only Start Fresh, which discards the binding, across
    /// closes of its terminal and restarts. Absent otherwise; older apps
    /// ignore it.
    var missing: Bool?
}

struct AgentPendingFork: Codable, Equatable, Sendable {
    var provider: AgentProviderID
    var sourceSessionID: String
}

struct AgentLaunchRequest: Sendable {
    var agentID: UUID
    var name: String
    var provider: AgentProviderID
    var launchProfile: AgentLaunchProfile
    var workingDirectory: String?
    var environmentPath: String
    var launchGeneration: UUID
    var session: AgentSessionBinding?
    var pendingFork: AgentPendingFork?
}

struct AgentPreparedLaunch: Sendable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    var metadataAvailability: AgentMetadataAvailability
    /// The ID of the session this launch creates: every new or forked Claude
    /// session. Claude writes such a session to disk only with its first
    /// entry (`cli-facts.md`, review S1 capture), so it becomes the agent's
    /// binding only once its first turn starts; until then the next launch
    /// creates or forks it again. Nil when the launch resumes a session, and
    /// for Codex, which cannot be given an ID.
    var newSessionID: String?
    /// The saved session a Claude launch resumes. Claude ends a resume of a
    /// session it cannot find with `SessionEnd` and no `SessionStart`, which
    /// is how the agent learns that the session is missing.
    var resumedSessionID: String?
}

struct AgentIntegrationPreparation: Equatable, Sendable {
    var notice: String?

    static let ready = Self(notice: nil)
}

/// One journal record, as every hook script and launch script since
/// provider support writes it. A record without a provider or a launch
/// generation does not decode.
struct AgentRawProviderEvent: Decodable, Equatable, Sendable {
    var schemaVersion: Int?
    var eventID: String?
    var provider: AgentProviderID
    var launchGeneration: UUID
    var hookEventName: String
    var sessionID: String?
    /// The turn, from the payload field the hook script reads for the
    /// provider: `prompt_id` for Claude, `turn_id` for Codex.
    var turnID: String?
    var model: String?
    var permissionMode: String?
    /// What started a compaction: `manual` (`/compact`) or `auto`.
    var trigger: String?
    var exitStatus: Int?

    var hasSupportedSchema: Bool { schemaVersion == 1 }
}

extension AgentRawProviderEvent {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, eventID, provider, launchGeneration, hookEventName
        case sessionID, turnID, model, permissionMode, trigger, exitStatus
    }

    /// The hook script writes "" for each field its payload did not carry;
    /// such a field is absent, never an empty value.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String? {
            guard let value = try container.decodeIfPresent(String.self, forKey: key),
                  !value.isEmpty
            else { return nil }
            return value
        }
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        eventID = try text(.eventID)
        provider = try container.decode(AgentProviderID.self, forKey: .provider)
        launchGeneration = try container.decode(UUID.self, forKey: .launchGeneration)
        hookEventName = try container.decode(String.self, forKey: .hookEventName)
        sessionID = try text(.sessionID)
        turnID = try text(.turnID)
        model = try text(.model)
        permissionMode = try text(.permissionMode)
        trigger = try text(.trigger)
        exitStatus = try container.decodeIfPresent(Int.self, forKey: .exitStatus)
    }
}

enum AgentDomainEvent: Equatable, Sendable {
    /// A session started: the provider is alive, and no turn is under way.
    case sessionStarted(sessionID: String?, model: String?, permissionMode: String?)
    /// The provider runs this session. Unlike `sessionStarted` it says
    /// nothing about liveness or the turn, for a provider whose terminal
    /// reports those.
    case sessionBound(sessionID: String?)
    /// One report the program made about itself in its terminal, for a
    /// provider whose turn activity comes from there.
    case programStatus(Ghostty.Action.ProgramStatus)
    /// The user started a compaction (`/compact`): the program's `working`
    /// is that compaction, which completes nothing.
    case manualCompactionStarted
    case turnStarted(turnID: String?)
    case turnActivityChanged(AgentActivityState)
    case turnInteractionChanged(AgentInteractionState)
    case turnCompleted(turnID: String?)
    case turnFailed(String?)
    /// A session ended. The process need not have: `/clear` ends one session
    /// and starts the next in the same process, and an exit is reported by
    /// the launch script.
    case sessionEnded
    case providerExited(status: Int)
}

/// One provider's entry in the provider table: which source reports its turn
/// activity, which hook events it subscribes to and what each means, and the
/// functions that integrate, launch, probe and clean up after it. A test
/// replaces any of them.
struct AgentProviderEntry: Sendable {
    /// What one record in the event file means for the agent.
    typealias Meaning = @Sendable (AgentRawProviderEvent) -> [AgentDomainEvent]

    /// The source that reports the agent's turn activity. The launch timeout
    /// waits for its first report, and `ingest` drops program-status reports,
    /// except the launch script's exit report, for a provider whose turn
    /// activity comes from its hooks. Only the
    /// event file's silence makes an active turn show as delayed: a program
    /// reports nothing during a long tool call (131 s captured).
    var turnActivity: AgentStatusObservation.Source
    /// The hook events the provider subscribes to, each with what it means.
    /// The provider's hooks and the hook script's list of the events it
    /// records are made from the same table, and `ingest` drops a hook
    /// record of any other event.
    var hookEvents: [String: Meaning]
    /// Whether the launch script also records the provider's exit in the
    /// event file, as a `ProviderExited` record. Every launch script reports
    /// the exit in the terminal, which is what ends the launch; Codex keeps
    /// the record until gate G4.
    var recordsExit: Bool
    var prepareIntegration: @Sendable () -> Result<AgentIntegrationPreparation, AgentProviderIssue>
    var prepareLaunch: @Sendable (AgentLaunchRequest) -> Result<AgentPreparedLaunch, AgentProviderIssue>
    /// Probes installation and sign-in with the given PATH.
    var probe: @Sendable (String) -> AgentProviderHealth
    /// Removes the provider's files for the agent with this ID.
    var cleanup: @Sendable (UUID) throws -> Void

    /// What a record in the provider's event file means, or nil when the
    /// entry does not allow it there.
    func meaning(ofRecord name: String) -> Meaning? {
        guard name == AgentHookRuntime.exitRecordName else { return hookEvents[name] }
        guard recordsExit else { return nil }
        return { [.providerExited(status: $0.exitStatus ?? -1)] }
    }
}

/// Every provider's entry.
struct AgentProviderTable: Sendable {
    var claudeCode: AgentProviderEntry
    var codex: AgentProviderEntry

    subscript(provider: AgentProviderID) -> AgentProviderEntry {
        get {
            switch provider {
            case .claudeCode: return claudeCode
            case .codex: return codex
            }
        }
        set {
            switch provider {
            case .claudeCode: claudeCode = newValue
            case .codex: codex = newValue
            }
        }
    }
}

extension AgentProviderTable {
    /// The real providers on `root`. Only `isProduction` writes
    /// `codexHooksFile`, Codex's global hook file.
    init(root: AgentDataRoot, codexHooksFile: URL, isProduction: Bool) {
        self.init(
            claudeCode: ClaudeCodeProvider(root: root).entry,
            codex: CodexProvider(root: root, hooksFile: codexHooksFile, isProduction: isProduction).entry)
    }
}

// MARK: - Launch preparation

struct AgentPreparedSurfaceLaunch: Sendable {
    var provider: AgentProviderID
    var generation: UUID
    var scriptURL: URL
    var environment: [String: String]
    var metadataAvailability: AgentMetadataAvailability
    var integrationIssue: String?
    /// See `AgentPreparedLaunch.resumedSessionID`.
    var resumedSessionID: String?
    /// See `AgentPreparedLaunch.newSessionID`.
    var newSessionID: String?
}

enum AgentSurfaceLaunchOutcome: Sendable {
    case success(AgentPreparedSurfaceLaunch)
    case failure(
        AgentProviderIssue,
        provider: AgentProviderID,
        generation: UUID,
        integrationIssue: String?)
}

struct AgentLaunchCoordinator: Sendable {
    /// The id of the program-status record on which the launch script
    /// reports the provider's exit.
    static let exitReportID = "clawddy"

    let providers: AgentProviderTable
    let root: AgentDataRoot

    /// `discardingSession` first forgets the agent's saved session, so the
    /// launch starts a new one.
    func prepare(
        _ initialRequest: AgentLaunchRequest,
        discardingSession: Bool = false
    ) -> AgentSurfaceLaunchOutcome {
        var request = initialRequest
        let agentID = request.agentID
        let name = request.name
        let provider = request.provider
        let generation = request.launchGeneration
        if discardingSession {
            do {
                try AgentSessionStore.discardSession(for: agentID, directory: root.statusDir)
            } catch {
                return .failure(
                    .launchPreparationFailed(
                        provider,
                        "The saved session could not be forgotten: \(error.localizedDescription)"),
                    provider: provider,
                    generation: generation,
                    integrationIssue: nil)
            }
        }
        do {
            request.session = try AgentSessionStore.session(
                for: agentID,
                provider: provider,
                directory: root.statusDir)
            request.pendingFork = try AgentSessionStore.pendingFork(
                for: agentID,
                provider: provider,
                directory: root.statusDir)
        } catch {
            // Starting a new session instead would leave the saved
            // conversation behind without a word.
            return .failure(
                .unreadableSession(provider, error.localizedDescription),
                provider: provider,
                generation: generation,
                integrationIssue: nil)
        }
        let entry = providers[provider]
        let prepared: AgentPreparedLaunch
        switch entry.prepareLaunch(request) {
        case .success(let launch): prepared = launch
        case .failure(let issue):
            return .failure(
                issue,
                provider: provider,
                generation: generation,
                integrationIssue: nil)
        }
        let integrationIssue: String?
        switch entry.prepareIntegration() {
        case .success(let preparation): integrationIssue = preparation.notice
        case .failure(let issue): integrationIssue = issue.localizedDescription
        }

        // Agent identity is whatever the provider asked for: none for Claude,
        // whose hooks carry it as arguments; the CLAWDDY_* names for Codex.
        var environment = AgentTerminalEnvironmentPolicy.explicitEnvironment(
            from: prepared.environment)
        environment["HOME"] = AgentConfig.accountHomeDirectory.path
        environment["PATH"] = request.environmentPath
        let command = AgentTerminalEnvironmentPolicy.interactiveCommand(
            executableURL: prepared.executableURL,
            arguments: prepared.arguments)
        let exports = environment.sorted(by: { $0.key < $1.key }).map {
            "export \($0.key)=\(AgentHookRuntime.shellQuote($0.value))"
        }.joined(separator: "\n")
        let recordExit = entry.recordsExit
            ? AgentHookRuntime.exitEventCommand(
                provider: provider,
                agentID: agentID,
                generation: generation,
                statusDirectory: root.statusDir)
            : ""
        // The login shell that keeps the terminal is no agent: it gets none
        // of the identity the launch gave the terminal, so neither it nor a
        // provider started in it by hand can report as the agent.
        let identity = environment.keys
            .filter(AgentTerminalEnvironmentPolicy.inheritedAgentIdentityVariables.contains)
            .sorted()
        let unsetIdentity = identity.isEmpty ? "" : "unset \(identity.joined(separator: " "))"
        // After the provider returns: the exit report, an OSC 7501 report on
        // the record `exitReportID` whose `msg` is the exit status in
        // decimal, base64 as the protocol requires.
        let script = """
            #!/bin/zsh -l
            \(AgentTerminalEnvironmentPolicy.shellPrelude)
            \(exports)
            printf '\\033]2;%s\\007' \(AgentHookRuntime.shellQuote(name))
            clear
            \(command)
            command_status=$?
            \(recordExit)
            printf '\\033]7501;state=clear:id=\(Self.exitReportID):msg=%s\\007' "$(printf %s "$command_status" | /usr/bin/base64)"
            \(unsetIdentity)
            printf '\\n\\033[33mAgent exited (status %s). Continuing in your login shell.\\033[0m\\n' "$command_status"
            exec "${SHELL:-/bin/zsh}" -l
            """
        let scriptURL = root.newLaunchScriptURL(agentID: agentID)
        do {
            try AgentConfig.atomicWrite(Data(script.utf8), to: scriptURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path)
        } catch {
            // A script left behind goes with the launch folder at the next
            // start.
            return .failure(
                .launchPreparationFailed(
                    provider,
                    "The launch script could not be created: \(error.localizedDescription)"),
                provider: provider,
                generation: generation,
                integrationIssue: integrationIssue)
        }
        return .success(AgentPreparedSurfaceLaunch(
            provider: provider,
            generation: generation,
            scriptURL: scriptURL,
            environment: environment,
            metadataAvailability: prepared.metadataAvailability,
            integrationIssue: integrationIssue,
            resumedSessionID: prepared.resumedSessionID,
            newSessionID: prepared.newSessionID))
    }
}

enum AgentRuntimeProviderPolicy {
    enum Decision: Equatable {
        case unchanged
        case replaceInactiveRuntime
        case preserveRuntimeAndRestoreConfig
    }

    static func decision(
        current: AgentProviderID,
        requested: AgentProviderID,
        persistedProvider: AgentProviderID?,
        surfaceState: AgentSurfaceState,
        processState: AgentProcessState
    ) -> Decision {
        guard current != requested else { return .unchanged }
        if persistedProvider != nil {
            return .preserveRuntimeAndRestoreConfig
        }
        if surfaceState == .inactive, processState == .notStarted {
            return .replaceInactiveRuntime
        }
        return .preserveRuntimeAndRestoreConfig
    }
}

enum AgentExecutableLocator {
    static func locate(_ executable: String, path: String) -> URL? {
        for component in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component), isDirectory: true)
                .appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

enum AgentProcessProbe {
    struct Result: Equatable, Sendable {
        var status: Int32
        var output: String
    }

    enum Outcome: Equatable, Sendable {
        case completed(Result)
        case launchFailed(String)
        case timedOut

        var successfulOutput: String? {
            guard case .completed(let result) = self, result.status == 0 else { return nil }
            return result.output
        }
    }

    /// Preserve the user's complete launch environment because provider
    /// authentication can depend on Keychain identity, API-key variables,
    /// proxies, certificate paths, and provider-specific configuration. Force
    /// account identity and PATH last so an isolated app instance or caller
    /// cannot accidentally probe a different macOS account.
    static func environment(
        environmentPath: String,
        additionalEnvironment: [String: String] = [:],
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        accountHomeDirectory: URL = AgentConfig.accountHomeDirectory,
        accountUserName: String = AgentConfig.accountUserName
    ) -> [String: String] {
        var environment = AgentTerminalEnvironmentPolicy.removingInheritedAutomationVariables(
            from: inheritedEnvironment)
        environment.merge(additionalEnvironment, uniquingKeysWith: { _, additional in additional })
        environment["HOME"] = accountHomeDirectory.path
        environment["PATH"] = environmentPath
        environment["USER"] = accountUserName
        environment["LOGNAME"] = accountUserName
        return environment
    }

    static func run(
        executable: URL,
        arguments: [String],
        environmentPath: String,
        additionalEnvironment: [String: String] = [:],
        timeout: TimeInterval = 3
    ) -> Outcome {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(
            environmentPath: environmentPath,
            additionalEnvironment: additionalEnvironment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .launchFailed(error.localizedDescription)
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return .timedOut
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return .completed(Result(
            status: process.terminationStatus,
            output: (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
