import Foundation

struct CodexProvider: AgentProviderAdapter {
    let id: AgentProviderID = .codex
    let capabilities: AgentProviderCapabilities = .codex
    let root: AgentDataRoot

    private static let hookedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "PreCompact", "PostCompact",
        "SubagentStart", "SubagentStop",
    ]
    private static let hookReviewNotice =
        "Review and trust Clawddy’s activity hook in Codex with /hooks. The terminal remains fully usable while status tracking is paused."

    func prepareIntegration() -> Result<AgentIntegrationPreparation, AgentProviderIssue> {
        do {
            try AgentHookRuntime.install(root: root)
            let changed = try installHooks()
            if changed {
                guard AgentConfig.atomicWrite(
                    Data(Self.hookReviewNotice.utf8),
                    to: root.codexHookReviewMarker)
                else { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: root.codexHookReviewMarker.path)
            }
            return .success(AgentIntegrationPreparation(
                notice: isHookReviewRequired ? Self.hookReviewNotice : nil))
        } catch {
            return .failure(.integrationFailed(id, error.localizedDescription))
        }
    }

    func prepareLaunch(_ request: AgentLaunchRequest) -> Result<AgentPreparedLaunch, AgentProviderIssue> {
        guard let executable = AgentExecutableLocator.locate(
            id.executableName,
            path: request.environmentPath)
        else { return .failure(.executableMissing(id)) }

        var globalArguments: [String] = []
        globalArguments += id.startModeArguments(request.launchProfile.startMode)
        if let model = normalized(request.launchProfile.modelID) {
            globalArguments += ["--model", model]
        }
        if let effort = normalizedEffort(request.launchProfile.reasoningEffort) {
            globalArguments += ["--config", "model_reasoning_effort=\"\(effort)\""]
        }

        let arguments: [String]
        if let session = request.session, session.provider == id {
            arguments = globalArguments + ["resume", session.sessionID]
        } else if let pending = request.pendingFork, pending.provider == id {
            arguments = globalArguments + ["fork", pending.sourceSessionID]
        } else {
            arguments = globalArguments
        }

        var environment: [String: String] = [:]
        if let configURL = AgentConfig.codexConfigEnvironmentOverride {
            environment["CODEX_HOME"] = configURL.path
        }
        return .success(AgentPreparedLaunch(
            executableURL: executable,
            arguments: arguments,
            environment: environment,
            metadataAvailability: .waiting))
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
        case "PostToolUse", "SubagentStop":
            return [.turnInteractionChanged(.none), .turnActivityChanged(.reasoning)]
        case "PermissionRequest":
            return [.turnInteractionChanged(.permission)]
        case "Stop":
            return [.turnCompleted(turnID: event.turnID)]
        case "PreCompact":
            return [.turnActivityChanged(.compacting)]
        case "PostCompact":
            return [.turnActivityChanged(.reasoning)]
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
                authentication: .unavailable("Codex is not installed."))
        }
        let version = AgentProcessProbe.run(
            executable: executable,
            arguments: ["--version"],
            environmentPath: environmentPath).successfulOutput
        let auth = AgentProcessProbe.run(
            executable: executable,
            arguments: ["login", "status"],
            environmentPath: environmentPath,
            additionalEnvironment: AgentConfig.codexConfigEnvironmentOverride.map {
                ["CODEX_HOME": $0.path]
            } ?? [:])
        return AgentProviderHealth(
            installation: .ready(executable: executable.path, version: version),
            authentication: Self.authenticationState(from: auth),
            integrationIssue: isHookReviewRequired ? Self.hookReviewNotice : nil)
    }

    static func authenticationState(
        from outcome: AgentProcessProbe.Outcome
    ) -> AgentProviderAuthState {
        let result: AgentProcessProbe.Result
        switch outcome {
        case .completed(let completed): result = completed
        case .launchFailed:
            return .unavailable("Codex sign-in status could not be started.")
        case .timedOut:
            return .unavailable("Codex sign-in status timed out.")
        }
        if result.status == 0 { return .signedIn }
        let output = result.output.lowercased()
        if output.contains("not logged in") || output.contains("not signed in") {
            return .signedOut
        }
        return .unavailable("Codex returned an unreadable sign-in status.")
    }

    func cleanup(agentID _: UUID) {}

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private func normalizedEffort(_ value: String?) -> String? {
        guard let value = normalized(value)?.lowercased(),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(
                      CharacterSet(charactersIn: "_-")).contains($0)
              })
        else { return nil }
        return value
    }

    static func clearHookReviewRequired(root: AgentDataRoot) {
        try? FileManager.default.removeItem(at: root.codexHookReviewMarker)
    }

    private var isHookReviewRequired: Bool {
        FileManager.default.fileExists(atPath: root.codexHookReviewMarker.path)
    }

    private func installHooks() throws -> Bool {
        let url = AgentConfig.codexConfigDir.appendingPathComponent("hooks.json")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("hooks.json.clawddy-backup")
        return try AgentHookRuntime.updateJSONFile(at: url, backupURL: backup) { file in
            var hooks = AgentHookRuntime.removingIntegrationHandlers(
                from: file["hooks"] as? [String: Any] ?? [:])
            for event in Self.hookedEvents {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": AgentHookRuntime.shellQuote(
                            AgentHookRuntime.scriptURL(root: root).path),
                        "timeout": 5,
                    ]],
                ])
                hooks[event] = groups
            }
            file["hooks"] = hooks
        }
    }
}
