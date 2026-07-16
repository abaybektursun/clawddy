import Foundation

struct ClaudeCodeProvider: AgentProviderAdapter {
    let id: AgentProviderID = .claudeCode
    let capabilities: AgentProviderCapabilities = .claudeCode

    private static let hookedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "Stop", "StopFailure",
        "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "SessionEnd",
    ]

    func prepareIntegration() -> Result<AgentIntegrationPreparation, AgentProviderIssue> {
        do {
            try AgentHookRuntime.install()
            try installHooks()
            return .success(.ready)
        } catch {
            return .failure(.integrationFailed(id, error.localizedDescription))
        }
    }

    func prepareLaunch(_ request: AgentLaunchRequest) -> Result<AgentPreparedLaunch, AgentProviderIssue> {
        guard let executable = AgentExecutableLocator.locate(id.executableName, path: request.environmentPath)
        else { return .failure(.executableMissing(id)) }

        let metadata = AgentMetadataRuntime.prepare(
            agentID: request.agentID,
            workingDirectory: request.workingDirectory)
        var arguments: [String] = []

        if let session = request.session, session.provider == id {
            arguments += ["--resume", session.sessionID]
        } else if let pending = request.pendingFork, pending.provider == id {
            arguments += [
                "--resume", pending.sourceSessionID,
                "--fork-session", "--name", request.name,
            ]
        } else {
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

        var environment: [String: String] = [:]
        if let configURL = AgentConfig.claudeConfigEnvironmentOverride {
            environment["CLAUDE_CONFIG_DIR"] = configURL.path
        }
        let availability: AgentMetadataAvailability = metadata.settingsURL == nil
            ? .unavailable(metadata.unavailableReason ?? "Session metadata is unavailable.")
            : .waiting
        return .success(AgentPreparedLaunch(
            executableURL: executable,
            arguments: arguments,
            environment: environment,
            metadataAvailability: availability))
    }

    func normalize(_ event: AgentRawProviderEvent) -> [AgentDomainEvent] {
        switch event.hookEventName {
        case "SessionStart":
            return [
                .sessionStarted(
                    sessionID: event.sessionID,
                    model: event.model,
                    permissionMode: event.permissionMode),
                .activityChanged(.idle),
            ]
        case "UserPromptSubmit":
            return [.interactionChanged(.none), .turnStarted(turnID: event.turnID)]
        case "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop":
            return [.interactionChanged(.none), .activityChanged(.executing)]
        case "PermissionRequest":
            return [.interactionChanged(.permission)]
        case "Stop":
            return [.interactionChanged(.none), .turnCompleted(turnID: event.turnID)]
        case "StopFailure", "PostToolUseFailure":
            return [.turnFailed(nil)]
        case "PreCompact":
            return [.activityChanged(.compacting)]
        case "PostCompact":
            return [.activityChanged(.idle)]
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

    func cleanup(agentID: UUID) {
        AgentMetadataRuntime.remove(agentID: agentID)
    }

    private func installHooks() throws {
        let url = AgentConfig.claudeConfigDir.appendingPathComponent("settings.json")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("settings.json.clawddy-backup")
        _ = try AgentHookRuntime.updateJSONFile(at: url, backupURL: backup) { settings in
            var hooks = AgentHookRuntime.removingIntegrationHandlers(
                from: settings["hooks"] as? [String: Any] ?? [:])
            for event in Self.hookedEvents {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": AgentHookRuntime.shellQuote(AgentHookRuntime.scriptURL.path),
                        "timeout": 5,
                    ]],
                ])
                hooks[event] = groups
            }
            settings["hooks"] = hooks
        }
    }

    private struct AuthenticationStatus: Decodable {
        var loggedIn: Bool
    }
}
