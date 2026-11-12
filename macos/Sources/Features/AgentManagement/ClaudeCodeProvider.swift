import Foundation

struct ClaudeCodeProvider: AgentProviderAdapter {
    let id: AgentProviderID = .claudeCode
    let capabilities: AgentProviderCapabilities = .claudeCode
    let root: AgentDataRoot

    static let hookedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "Stop", "StopFailure",
        "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "SessionEnd",
    ]

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

    /// The `hooks` object of one launch's settings overlay: every hooked
    /// event runs the hook script with this agent's identity as arguments.
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
        return Dictionary(uniqueKeysWithValues: Self.hookedEvents.map { ($0, [group]) })
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
        var newSession: AgentSessionBinding?
        var resumedSessionID: String?
        // The ID of a session this launch creates, in Claude's lowercase form.
        let chosenSession = AgentSessionBinding(
            provider: id,
            sessionID: UUID().uuidString.lowercased(),
            launchGeneration: request.launchGeneration)

        // A fork marker stays until the forked process is seen alive, so
        // while it exists the fork has not started, and this launch forks
        // again rather than resuming a session that may not exist. Claude
        // accepts `--session-id` together with `--resume` only with
        // `--fork-session`.
        if let pending = request.pendingFork, pending.provider == id {
            newSession = chosenSession
            arguments += [
                "--resume", pending.sourceSessionID,
                "--fork-session", "--session-id", chosenSession.sessionID,
            ]
        } else if let session = request.session, session.provider == id {
            resumedSessionID = session.sessionID
            arguments += ["--resume", session.sessionID]
        } else {
            newSession = chosenSession
            arguments += ["--session-id", chosenSession.sessionID]
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
            newSession: newSession,
            resumedSessionID: resumedSessionID))
    }

    func normalize(_ event: AgentRawProviderEvent) -> [AgentDomainEvent] {
        switch event.hookEventName {
        case "SessionStart":
            return [.sessionStarted(
                sessionID: event.sessionID,
                model: event.model,
                permissionMode: event.permissionMode)]
        case "UserPromptSubmit":
            return [.turnStarted(turnID: event.turnID)]
        case "PreToolUse", "SubagentStart":
            return [.turnInteractionChanged(.none), .turnActivityChanged(.executing)]
        case "PostToolUse", "PostToolUseFailure", "SubagentStop":
            // PostToolUseFailure reports one tool call that failed inside the
            // nested agentic loop. Claude continues the same turn, so this is
            // activity evidence, not a terminal turn failure (StopFailure).
            // Ending the turn here would emit a false error and drop every
            // later permission/activity/stop event in that turn.
            return [.turnInteractionChanged(.none), .turnActivityChanged(.reasoning)]
        case "PermissionRequest":
            return [.turnInteractionChanged(.permission)]
        case "Stop":
            return [.turnCompleted(turnID: event.turnID)]
        case "StopFailure":
            return [.turnFailed(nil)]
        case "PreCompact":
            return [.turnActivityChanged(.compacting)]
        case "PostCompact":
            return [.turnActivityChanged(.reasoning)]
        case "SessionEnd":
            return [.sessionEnded]
        case "ProviderExited":
            return [.providerExited(status: event.exitStatus ?? -1)]
        default:
            return []
        }
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
