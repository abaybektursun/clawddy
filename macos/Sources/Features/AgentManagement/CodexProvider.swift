import Foundation

struct CodexProvider: AgentProviderAdapter {
    let id: AgentProviderID = .codex
    let capabilities: AgentProviderCapabilities = .codex

    private static let hookedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "PreCompact", "PostCompact",
        "SubagentStart", "SubagentStop",
    ]
    private static let hookReviewNotice =
        "Review and trust Clawddy’s activity hook in Codex with /hooks. The terminal remains fully usable while status tracking is paused."
    private static var hookReviewMarkerURL: URL {
        AgentConfig.baseDir.appendingPathComponent("codex-hook-review-required")
    }

    func prepareIntegration() -> Result<AgentIntegrationPreparation, AgentProviderIssue> {
        do {
            try AgentHookRuntime.install()
            let changed = try installHooks()
            if changed {
                guard AgentConfig.atomicWrite(
                    Data(Self.hookReviewNotice.utf8),
                    to: Self.hookReviewMarkerURL)
                else { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: Self.hookReviewMarkerURL.path)
            }
            return .success(AgentIntegrationPreparation(
                notice: Self.isHookReviewRequired ? Self.hookReviewNotice : nil))
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
        case "PreCompact":
            return [.activityChanged(.compacting)]
        case "PostCompact":
            return [.activityChanged(.idle)]
        case "ProviderExited":
            return [.providerExited(status: event.exitStatus ?? -1)]
        default:
            return []
        }
    }

    func probe(environmentPath: String) -> AgentProviderHealth {
        guard let executable = AgentExecutableLocator.locate(id.executableName, path: environmentPath)
        else {
            return AgentProviderHealth(installation: .missing, authentication: .signedOut)
        }
        let version = AgentProcessProbe.run(
            executable: executable,
            arguments: ["--version"],
            environmentPath: environmentPath)?.output
        let auth = AgentProcessProbe.run(
            executable: executable,
            arguments: ["login", "status"],
            environmentPath: environmentPath,
            additionalEnvironment: AgentConfig.codexConfigEnvironmentOverride.map {
                ["CODEX_HOME": $0.path]
            } ?? [:])
        return AgentProviderHealth(
            installation: .ready(executable: executable.path, version: version),
            authentication: auth?.status == 0 ? .signedIn : .signedOut,
            integrationIssue: Self.isHookReviewRequired ? Self.hookReviewNotice : nil)
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

    static func clearHookReviewRequired() {
        try? FileManager.default.removeItem(at: hookReviewMarkerURL)
    }

    private static var isHookReviewRequired: Bool {
        FileManager.default.fileExists(atPath: hookReviewMarkerURL.path)
    }

    private func installHooks() throws -> Bool {
        let url = AgentConfig.codexConfigDir.appendingPathComponent("hooks.json")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("hooks.json.clawddy-backup")
        return try AgentHookRuntime.updateJSONFile(at: url, backupURL: backup) { root in
            var hooks = AgentHookRuntime.removingIntegrationHandlers(
                from: root["hooks"] as? [String: Any] ?? [:])
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
            root["hooks"] = hooks
        }
    }
}
