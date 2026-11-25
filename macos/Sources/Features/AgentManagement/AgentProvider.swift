import Foundation

enum AgentProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex
    /// agy, the Antigravity CLI.
    case antigravity

    var id: Self { self }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .antigravity: return "agy"
        }
    }

    var symbolName: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "arrow.up.circle"
        }
    }

    func startModeTitle(_ mode: AgentStartMode) -> String {
        switch (self, mode) {
        case (.claudeCode, .unrestricted), (.antigravity, .unrestricted): return "Dangerously skip permissions"
        case (.codex, .unrestricted): return "YOLO"
        case (_, .standard): return "Standard permissions"
        }
    }

    func startModeDescription(_ mode: AgentStartMode) -> String {
        switch (self, mode) {
        case (.claudeCode, .unrestricted):
            return "Bypasses all Claude Code permission checks."
        case (.codex, .unrestricted):
            return "Runs without approval prompts or the Codex sandbox."
        case (.antigravity, .unrestricted):
            return "Runs commands and edits files without asking."
        case (_, .standard):
            return "Uses the provider’s normal approval and sandbox behavior."
        }
    }

    func startModeArguments(_ mode: AgentStartMode) -> [String] {
        guard mode == .unrestricted else { return [] }
        switch self {
        case .claudeCode, .antigravity: return ["--dangerously-skip-permissions"]
        case .codex: return ["--dangerously-bypass-approvals-and-sandbox"]
        }
    }
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
}

enum AgentProviderIssue: Error, Equatable, LocalizedError, Sendable {
    case executableMissing(AgentProviderID)
    case integrationFailed(AgentProviderID, String)
    /// The saved session could not be read; the agent can only start fresh.
    case unreadableSession(AgentProviderID, String)
    case launchPreparationFailed(AgentProviderID, String)
    /// The conversation it would resume runs in another terminal.
    case sessionOpenElsewhere(AgentProviderID, String)
    /// The conversation it would resume no longer exists.
    case sessionMissing(AgentProviderID, String)

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
        case .sessionOpenElsewhere(let provider, let session):
            return "The \(provider.displayName) conversation \(session) is open in another terminal."
        case .sessionMissing(let provider, let session):
            return "\(provider.displayName) has no conversation \(session) any more."
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

struct AgentLaunchRequest: Sendable {
    var agentID: UUID
    var name: String
    var provider: AgentProviderID
    var launchProfile: AgentLaunchProfile
    var workingDirectory: String?
    var environmentPath: String
    var launchGeneration: UUID
    var session: AgentSessionBinding?
    /// The user named the agent; a name that is Clawddy's is not given to
    /// the provider, so the conversation's own title can replace it.
    var namedByUser = true
    /// The launch's first prompt, given on the command line, which both CLIs
    /// submit as the first turn of a new or resumed session (probes.md, P5).
    var firstPrompt: String?
    /// A line the terminal shows, dim, before the CLI starts.
    var notice: String?
    /// The running conversations, listed once for every launch that shares
    /// it: the launches of one burst ask one question, not one each.
    var liveSessions = AgentLiveSessions()
}

/// The answer to "which conversations run now?", taken once per provider
/// and kept for every launch that shares this object (`AgentBridge`: the
/// launches of one burst of starts). A conversation a launch of this
/// burst resumes was found not live by that one listing; the CLIs this
/// burst starts are Clawddy's own.
final class AgentLiveSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var listings: [AgentProviderID: String] = [:]
    /// How many listings were taken, for the tests.
    private(set) var taken = 0

    /// The provider's listing: the one already taken, or `take`'s now. A
    /// listing that failed is not kept: the next launch asks again.
    func listing(
        _ provider: AgentProviderID,
        take: () -> Result<String, AgentProviderIssue>
    ) -> Result<String, AgentProviderIssue> {
        lock.lock()
        defer { lock.unlock() }
        if let listing = listings[provider] { return .success(listing) }
        let listing = take()
        taken += 1
        if case .success(let text) = listing { listings[provider] = text }
        return listing
    }
}

struct AgentPreparedLaunch: Sendable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    var metadataAvailability: AgentMetadataAvailability
    /// The ID of the session this launch creates: every new Claude session. Claude writes such a session to disk only with its first
    /// entry (`cli-facts.md`, review S1 capture), so it becomes the agent's
    /// binding only once its first turn starts; until then the next launch
    /// creates it again. Nil when the launch resumes a session, and
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
    /// provider: `prompt_id` for Claude, the notify's `turn-id` for Codex.
    var turnID: String?
    /// agy's `invocationNum`: 0 at a turn's start, then one more after each
    /// tool result or answer within the turn.
    var invocation: String?
    var model: String?
    var permissionMode: String?
    /// What started a compaction: `manual` (`/compact`) or `auto`.
    var trigger: String?
    /// Claude's kind of failure (`StopFailure.error`), as `rate_limit`.
    var error: String?
    /// Why a session ended (`SessionEnd.reason`).
    var reason: String?
    /// How a session started (`SessionStart.source`).
    var source: String?
    /// The event's text, exactly as the payload gave it: a prompt, the
    /// agent's last message, a failure's text, or a question.
    var text: String?
    /// A completed Codex turn's prompts, in order.
    var prompts: [String]?

    var hasSupportedSchema: Bool { schemaVersion == 1 }
}

extension AgentRawProviderEvent {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, eventID, provider, launchGeneration, hookEventName
        case sessionID, turnID, invocation, model, permissionMode, trigger, error, reason, source, text, prompts
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
        invocation = try text(.invocation)
        model = try text(.model)
        permissionMode = try text(.permissionMode)
        trigger = try text(.trigger)
        error = try text(.error)
        reason = try text(.reason)
        source = try text(.source)
        self.text = try text(.text)
        prompts = try container.decodeIfPresent([String].self, forKey: .prompts)
    }
}

/// A failed turn as the provider reported it: Claude's kind of failure
/// (`StopFailure.error`) and the text it showed.
struct AgentFailure: Equatable, Sendable {
    var error: String?
    var text: String?
    /// When a usage limit resets, from the status line's `rate_limits`;
    /// the bridge adds it, since the hook does not say.
    var resetsAt: Date?

    /// The turn stopped at a usage limit. Claude's kinds, read in its binary
    /// (2.1.331): `rate_limit` and `billing_error` ("usage limit reached").
    var isUsageLimit: Bool { error == "rate_limit" || error == "billing_error" }
    /// The session's sign-in no longer works.
    var isLogin: Bool { error == "authentication_failed" || error == "oauth_org_not_allowed" }
}

enum AgentDomainEvent: Equatable, Sendable {
    /// The provider runs this session. It says nothing about liveness or the
    /// turn, which its terminal reports.
    case sessionBound(sessionID: String?)
    /// One report the program made about itself in its terminal.
    case programStatus(Ghostty.Action.ProgramStatus)
    /// The user started a compaction (`/compact`): the program's `working`
    /// is that compaction, which completes nothing.
    case manualCompactionStarted
    /// A prompt was submitted, with its text when the provider gave it:
    /// what the agent did before has been read. It starts a turn only while
    /// a `working` waits to settle, since the prompt's record can arrive
    /// after a short turn has ended.
    case promptSubmitted(String?)
    /// The agent's last message of the turn.
    case messageReported(String)
    /// The question the agent asks, in full.
    case questionReported(String)
    case turnActivityChanged(AgentActivityState)
    case turnCompleted(turnID: String?)
    case turnFailed(AgentFailure)
    /// A session ended. The process need not have: `/clear` ends one session
    /// and starts the next in the same process, and an exit is reported by
    /// the launch script.
    case sessionEnded
    case providerExited(status: Int)
}

/// How the reducer reads one CLI's terminal reports where the CLIs differ
/// (`AgentStateReducer`): the values of its entry in the provider table.
struct AgentReportRules: Equatable, Sendable {
    /// A `done` with a message completes the turn. Claude's turns end in a
    /// bare `done`, and one with a message ends something else, such as a
    /// compaction; every agy turn ends in a `done` with the reply's first
    /// line (`cli-facts.md`, agy).
    var doneWithMessageCompletes: Bool
    /// How long a sign-in report (`blocked`, kind `auth`) must stand, with
    /// no other report replacing it, before it stops the agent with a login
    /// problem; 0 counts it at once (`AgentBridge.updateSignInTimer`).
    var signInStandTime: TimeInterval
    /// A `working` report's message names the step under way, which the
    /// agent shows as its activity.
    var workingMessageIsActivity: Bool
    /// Every `working` is a turn, so it starts one at once, and the first
    /// prompt record of a turn that started without one is that turn's
    /// prompt, whichever comes first. agy reports no `working` for a command
    /// that submits nothing; Claude and Codex do, so theirs must stand for
    /// `turnStartDelay` first.
    var workingStartsTurn: Bool
    /// A dialog or a standing sign-in report at start-up shows that the CLI
    /// has started: the start limit (`AgentBridge.startLimit`) stops, and
    /// cannot replace what it asks with "did not start". Claude Code still
    /// on its trust dialog after 30 s says it did not start.
    var askingAtStartIsStarted: Bool
    /// An interrupt gives back, unsent, the messages queued while the turn
    /// worked (agy); Claude folds a queued message into the running turn.
    /// The ones Clawddy sent are then no prompts.
    var interruptReturnsQueuedMessages: Bool

    /// Claude Code's and Codex's.
    static let standard = Self(
        doneWithMessageCompletes: false, signInStandTime: 0, workingMessageIsActivity: true,
        workingStartsTurn: false, askingAtStartIsStarted: false, interruptReturnsQueuedMessages: false)
}

/// One provider's entry in the provider table: how long its `working` must
/// stand to start a turn, how its reports read, which hook events it
/// subscribes to and what each means, and the functions that integrate,
/// launch, probe and clean up after it. A test replaces any of them. Every
/// provider reports its turns in its terminal (OSC 7501); the hooks add
/// identity and text.
struct AgentProviderEntry: Sendable {
    /// What one record in the event file means for the agent.
    typealias Meaning = @Sendable (AgentRawProviderEvent) -> [AgentDomainEvent]

    /// How long a `working` report with no turn under way and no prompt
    /// must stand before the turn starts (`AgentBridge.updateTurnStartTimer`).
    var turnStartDelay: TimeInterval
    var reports: AgentReportRules
    /// The hook events the provider subscribes to, each with what it means.
    /// The provider's hooks and the hook script's list of the events it
    /// records are made from the same table, and `ingest` drops a hook
    /// record of any other event.
    var hookEvents: [String: Meaning]
    var prepareIntegration: @Sendable () -> Result<AgentIntegrationPreparation, AgentProviderIssue>
    var prepareLaunch: @Sendable (AgentLaunchRequest) -> Result<AgentPreparedLaunch, AgentProviderIssue>
    /// Probes installation and sign-in with the given PATH.
    var probe: @Sendable (String) -> AgentProviderHealth
    /// Removes the provider's files for the agent with this ID.
    var cleanup: @Sendable (UUID) throws -> Void

    /// What a record in the provider's event file means, or nil when the
    /// entry does not allow it there.
    func meaning(ofRecord name: String) -> Meaning? { hookEvents[name] }
}

/// Every provider's entry.
struct AgentProviderTable: Sendable {
    var claudeCode: AgentProviderEntry
    var codex: AgentProviderEntry
    var antigravity: AgentProviderEntry

    subscript(provider: AgentProviderID) -> AgentProviderEntry {
        get {
            switch provider {
            case .claudeCode: return claudeCode
            case .codex: return codex
            case .antigravity: return antigravity
            }
        }
        set {
            switch provider {
            case .claudeCode: claudeCode = newValue
            case .codex: codex = newValue
            case .antigravity: antigravity = newValue
            }
        }
    }
}

extension AgentProviderTable {
    /// The real providers on `root`. `codexConfigFile` holds the owner's own
    /// Codex `notify`, which each Codex launch's notify program runs;
    /// `agyDataFolder` is agy's own data folder, read for its conversations
    /// and their locks.
    init(root: AgentDataRoot, codexConfigFile: URL, agyDataFolder: URL = AntigravityProvider.defaultDataFolder) {
        self.init(
            claudeCode: ClaudeCodeProvider(root: root).entry,
            codex: CodexProvider(root: root, configFile: codexConfigFile).entry,
            antigravity: AntigravityProvider(root: root, dataFolder: agyDataFolder).entry)
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
        // After the provider returns: the exit report, an OSC 7501 report on
        // the record `exitReportID` whose `msg` is the exit status in
        // decimal, base64 as the protocol requires. Then the script ends and
        // the terminal closes: an agent's terminal is its provider's only.
        let notice = request.notice.map {
            "printf '\\033[2m%s\\033[0m\\n' \(AgentHookRuntime.shellQuote($0))"
        } ?? ""
        let script = """
            #!/bin/zsh -l
            \(exports)
            printf '\\033]2;%s\\007' \(AgentHookRuntime.shellQuote(name))
            clear
            \(notice)
            \(command)
            command_status=$?
            printf '\\033]7501;state=clear:id=\(Self.exitReportID):msg=%s\\007' "$(printf %s "$command_status" | /usr/bin/base64)"
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

/// What one reader of a probe's pipe read, handed to the waiting thread
/// after `DispatchGroup.wait`.
private final class PipeData: @unchecked Sendable {
    var value = Data()
}

enum AgentProcessProbe {
    struct Result: Equatable, Sendable {
        var status: Int32
        /// Standard output.
        var output: String
        /// Standard error, kept apart so a warning never spoils the output.
        var errors: String = ""
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
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(
            environmentPath: environmentPath,
            additionalEnvironment: additionalEnvironment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors

        // Close-on-exec: a terminal another thread starts meanwhile must not
        // inherit the write ends, or the reads below never see their end.
        // (The child still gets them: spawning dups them onto its 1 and 2.)
        for pipe in [output, errors] {
            for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
                _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .launchFailed(error.localizedDescription)
        }
        // Both pipes are read while the process runs: one that fills a pipe
        // (64 KB) would otherwise wait for a reader forever. Each on a thread
        // of its own, which a busy dispatch pool cannot hold back.
        let read = DispatchGroup()
        let outputData = PipeData()
        let errorData = PipeData()
        for (pipe, data) in [(output, outputData), (errors, errorData)] {
            read.enter()
            Thread {
                data.value = pipe.fileHandleForReading.readDataToEndOfFile()
                read.leave()
            }.start()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return .timedOut
        }
        // Its output ends with it; if a write end lives on elsewhere, this
        // fails as a timeout instead of holding the queue for ever.
        guard read.wait(timeout: .now() + 1) == .success else { return .timedOut }
        func text(_ data: Data) -> String {
            (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return .completed(Result(
            status: process.terminationStatus,
            output: text(outputData.value),
            errors: text(errorData.value)))
    }
}
