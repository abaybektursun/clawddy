import Foundation

struct ClaudeCodeProvider: Sendable {
    let id: AgentProviderID = .claudeCode
    let root: AgentDataRoot

    /// Claude's event table: each hook event it subscribes to, and what it
    /// means. Claude reports its turn activity and liveness in its terminal
    /// (OSC 7501), so no hook here starts, continues or completes a turn.
    static let hookEvents: [String: AgentProviderEntry.Meaning] = [
        // Every source (startup, resume, clear, compact, fork) names the
        // session the next launch resumes.
        "SessionStart": { [.sessionBound(sessionID: $0.sessionID)] },
        // Claude's own `error` report usually comes first; the turn fails once.
        "StopFailure": { _ in [.turnFailed(nil)] },
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

    /// Claude's entry in the provider table.
    var entry: AgentProviderEntry {
        AgentProviderEntry(
            turnActivity: .surface,
            hookEvents: Self.hookEvents,
            recordsExit: false,
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

        // A fork marker stays until the fork's session is saved, at its first
        // turn, so while it exists the fork has no session on disk, and this
        // launch forks again rather than resuming a session that does not
        // exist. Claude accepts `--session-id` together with `--resume` only
        // with `--fork-session`.
        if let pending = request.pendingFork, pending.provider == id {
            newSessionID = chosenSessionID
            arguments += [
                "--resume", pending.sourceSessionID,
                "--fork-session", "--session-id", chosenSessionID,
            ]
        } else if let session = request.session, session.provider == id {
            resumedSessionID = session.sessionID
            arguments += ["--resume", session.sessionID]
        } else {
            newSessionID = chosenSessionID
            arguments += ["--session-id", chosenSessionID]
        }
        // Claude takes the agent's label at every launch, resumes included,
        // so a rename reaches the session at its next launch.
        arguments += ["--name", request.name]
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
