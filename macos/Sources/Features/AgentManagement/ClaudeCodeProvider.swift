import Foundation

struct ClaudeCodeProvider: Sendable {
    let id: AgentProviderID = .claudeCode
    let root: AgentDataRoot

    /// Claude's event table: each hook event it subscribes to, and what it
    /// means. Claude reports its turn activity and liveness in its terminal
    /// (OSC 7501), so no hook here starts, continues or completes a turn.
    static let hookEvents: [String: AgentProviderEntry.Meaning] = [
        // Every source (startup, resume, clear, compact) names the
        // session the next launch resumes.
        "SessionStart": { [.sessionBound(sessionID: $0.sessionID)] },
        // A prompt starts the turn its `working` announced, and reads the
        // turn before. A command that submits none, such as `/resume`, is no
        // turn.
        "UserPromptSubmit": { [.promptSubmitted($0.text)] },
        // The turn's `done` comes in the terminal; this brings its message.
        "Stop": { record in record.text.map { [.messageReported($0)] } ?? [] },
        // Claude's own `error` report usually comes first; the turn fails once.
        "StopFailure": { [.turnFailed(AgentFailure(error: $0.error, text: $0.text))] },
        // The question of an `AskUserQuestion`, in full; the terminal's
        // `blocked` report has already said that it asks.
        "PermissionRequest": { record in record.text.map { [.questionReported($0)] } ?? [] },
        // A manual compaction is reported as a long `working` ending in a
        // `done` that must complete nothing. An automatic one runs inside a
        // real turn, whose completion stands.
        "PreCompact": {
            $0.trigger == "manual" ? [.manualCompactionStarted] : [.turnActivityChanged(.compacting)]
        },
        // Can arrive after the compaction's `done`; then it changes nothing.
        "PostCompact": { _ in [.turnActivityChanged(.executing)] },
        // Not an exit: `/clear` ends a session in a running process. A
        // resume that ends its session before starting it found no such
        // session, which nothing else tells apart.
        "SessionEnd": { _ in [.sessionEnded] },
    ]

    /// The payload field that names Claude's turn. Claude never sends
    /// `turn_id`.
    static let turnIDField = "prompt_id"

    /// The payload field whose text each event carries
    /// (`docs/clawddy-refactor/cli-facts.md`, probes of 2026-11-23).
    static let textFields = [
        "UserPromptSubmit": "prompt",
        "Stop": "last_assistant_message",
        "StopFailure": "last_assistant_message",
        "PermissionRequest": "tool_input.questions.0.question",
    ]

    /// Claude's entry in the provider table.
    var entry: AgentProviderEntry {
        AgentProviderEntry(
            turnStartDelay: 1,
            hookEvents: Self.hookEvents,
            prepareIntegration: { prepareIntegration() },
            prepareLaunch: { prepareLaunch($0) },
            probe: { probe(environmentPath: $0) },
            cleanup: { try cleanup(agentID: $0) })
    }

    /// Claude's hooks travel only in each agent's settings overlay, so the
    /// only file this writes is the hook script in the data root.
    func prepareIntegration() -> Result<AgentIntegrationPreparation, AgentProviderIssue> {
        do {
            try AgentHookRuntime.install(root: root)
            return .success(.ready)
        } catch {
            return .failure(.integrationFailed(id, error.localizedDescription))
        }
    }

    /// The `hooks` object of one launch's settings overlay: every event of
    /// Claude's event table runs the hook script with this agent's identity
    /// as arguments.
    func overlayHooks(agentID: UUID, generation: UUID) -> [String: Any] {
        let group: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": AgentHookRuntime.command(
                    root: root,
                    provider: id,
                    agentID: agentID,
                    generation: generation),
                "timeout": 5,
            ]],
        ]
        return Self.hookEvents.mapValues { _ in [group] }
    }

    /// Older Clawddy builds registered the hook script globally in Claude's
    /// `settings.json`. Removes the entries that run `root`'s script and
    /// nothing else, writing only when one was found. Only the production
    /// identity, which owns that script path, ever writes the file. Returns
    /// whether it was written.
    static func removeGlobalHooks(
        settingsFile: URL,
        root: AgentDataRoot,
        isProduction: Bool
    ) throws -> Bool {
        guard isProduction else { return false }
        return try AgentHookRuntime.updateJSONFile(
            at: settingsFile,
            backupURL: settingsFile.appendingPathExtension("clawddy-backup")
        ) { settings in
            guard let hooks = settings["hooks"] as? [String: Any] else { return }
            settings["hooks"] = AgentHookRuntime.removingHandlers(runningScriptOf: root, from: hooks)
        }
    }

    func prepareLaunch(_ request: AgentLaunchRequest) -> Result<AgentPreparedLaunch, AgentProviderIssue> {
        guard let executable = AgentExecutableLocator.locate(id.executableName, path: request.environmentPath)
        else { return .failure(.executableMissing(id)) }

        let metadata = AgentMetadataRuntime.prepare(
            agentID: request.agentID,
            workingDirectory: request.workingDirectory,
            root: root,
            hooks: overlayHooks(agentID: request.agentID, generation: request.launchGeneration))
        var arguments: [String] = []
        var newSessionID: String?
        var resumedSessionID: String?
        // The ID of a session this launch creates, in Claude's lowercase form.
        let chosenSessionID = UUID().uuidString.lowercased()

        if let session = request.session, session.provider == id {
            // The same conversation must never run twice (flows.md 4.5).
            let listing = request.liveSessions.listing(id) {
                Self.runningSessions(executable: executable, environmentPath: request.environmentPath)
            }
            switch listing.flatMap({ Self.isLive(session.sessionID, in: $0) }) {
            case .success(true): return .failure(.sessionOpenElsewhere(id, session.sessionID))
            case .success(false): break
            case .failure(let issue): return .failure(issue)
            }
            resumedSessionID = session.sessionID
            arguments += ["--resume", session.sessionID]
        } else {
            newSessionID = chosenSessionID
            arguments += ["--session-id", chosenSessionID]
        }
        // Claude takes a name the user gave at every launch, resumes
        // included, so a rename reaches the conversation at its next launch
        // and names it for good. Without one, Claude titles the conversation
        // after its first prompt, and that title becomes the agent's name.
        if request.namedByUser {
            arguments += ["--name", request.name]
        }
        arguments += id.startModeArguments(request.launchProfile.startMode)
        if let model = request.launchProfile.modelID, !model.isEmpty {
            arguments += ["--model", model]
        }
        if let effort = request.launchProfile.reasoningEffort, !effort.isEmpty {
            arguments += ["--effort", effort]
        }
        if let settingsURL = metadata.settingsURL {
            arguments += ["--settings", settingsURL.path]
        }
        // After `--`, a task that starts with "-" is never read as an option
        // (Claude Code 2.1.331 takes it so, probed 2026-11-24).
        if let prompt = request.firstPrompt {
            arguments += ["--", prompt]
        }

        var environment: [String: String] = [:]
        if let configURL = AgentConfig.claudeConfigEnvironmentOverride {
            environment["CLAUDE_CONFIG_DIR"] = configURL.path
        }
        let availability: AgentMetadataAvailability = metadata.unavailableReason
            .map { .unavailable($0) } ?? .waiting
        return .success(AgentPreparedLaunch(
            executableURL: executable,
            arguments: arguments,
            environment: environment,
            metadataAvailability: availability,
            newSessionID: newSessionID,
            resumedSessionID: resumedSessionID))
    }

    /// Claude's own list of its running sessions (`claude agents --json`,
    /// 0.1 s, probes.md P5), as it printed it.
    static func runningSessions(executable: URL, environmentPath: String) -> Result<String, AgentProviderIssue> {
        let outcome = AgentProcessProbe.run(
            executable: executable,
            // `--all` lists idle sessions too; without it, only busy ones.
            arguments: ["agents", "--json", "--all"],
            environmentPath: environmentPath,
            additionalEnvironment: AgentConfig.claudeConfigEnvironmentOverride.map {
                ["CLAUDE_CONFIG_DIR": $0.path]
            } ?? [:])
        guard let output = outcome.successfulOutput else {
            return .failure(.launchPreparationFailed(
                .claudeCode, "Claude Code's list of running conversations could not be read (\(outcome))."))
        }
        return .success(output)
    }

    /// Whether a Claude process runs `sessionID` now, by `listing`
    /// (`runningSessions`): an interactive one whose process is alive, or a
    /// background one.
    static func isLive(_ sessionID: String, in listing: String) -> Result<Bool, AgentProviderIssue> {
        guard let data = listing.data(using: .utf8),
              let sessions = try? JSONDecoder().decode([RunningSession].self, from: data)
        else {
            return .failure(.launchPreparationFailed(
                .claudeCode, "Claude Code's list of running conversations could not be read (\(listing.prefix(200)))."))
        }
        return .success(sessions.contains { session in
            guard session.sessionId == sessionID else { return false }
            guard let pid = session.pid else { return true }
            return kill(pid_t(pid), 0) == 0
        })
    }

    private struct RunningSession: Decodable {
        var sessionId: String
        var pid: Int?
    }

    func probe(environmentPath: String) -> AgentProviderHealth {
        guard let executable = AgentExecutableLocator.locate(id.executableName, path: environmentPath)
        else {
            return AgentProviderHealth(
                installation: .missing,
                authentication: .unavailable("Claude Code is not installed."))
        }
        let version = AgentProcessProbe.run(
            executable: executable,
            arguments: ["--version"],
            environmentPath: environmentPath).successfulOutput
        let auth = AgentProcessProbe.run(
            executable: executable,
            arguments: ["auth", "status"],
            environmentPath: environmentPath,
            additionalEnvironment: AgentConfig.claudeConfigEnvironmentOverride.map {
                ["CLAUDE_CONFIG_DIR": $0.path]
            } ?? [:])
        return AgentProviderHealth(
            installation: .ready(executable: executable.path, version: version),
            authentication: Self.authenticationState(from: auth))
    }

    static func authenticationState(
        from outcome: AgentProcessProbe.Outcome
    ) -> AgentProviderAuthState {
        let result: AgentProcessProbe.Result
        switch outcome {
        case .completed(let completed): result = completed
        case .launchFailed:
            return .unavailable("Claude Code sign-in status could not be started.")
        case .timedOut:
            return .unavailable("Claude Code sign-in status timed out.")
        }
        if let data = result.output.data(using: .utf8),
           let status = try? JSONDecoder().decode(AuthenticationStatus.self, from: data) {
            return status.loggedIn ? .signedIn : .signedOut
        }
        if result.status == 0 { return .signedIn }
        return .unavailable("Claude Code returned an unreadable sign-in status.")
    }

    func cleanup(agentID: UUID) throws {
        try AgentMetadataRuntime.remove(agentID: agentID, root: root)
    }

    private struct AuthenticationStatus: Decodable {
        var loggedIn: Bool
    }
}
