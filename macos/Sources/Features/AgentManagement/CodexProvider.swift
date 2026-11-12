import Foundation

struct CodexProvider: Sendable {
    let id: AgentProviderID = .codex
    let root: AgentDataRoot
    /// Codex's global `hooks.json`, the only place Codex hooks can live
    /// without a trust review on every launch.
    let hooksFile: URL
    /// Only the production identity writes `hooksFile`. Any change to that
    /// file makes Codex ask for a hook review in every session on the machine.
    let isProduction: Bool

    /// Codex's event table: each hook event it subscribes to, and what it
    /// means. Changing the set of events changes `hooksFile`.
    static let hookEvents: [String: AgentProviderEntry.Meaning] = [
        "SessionStart": { [.sessionStarted(sessionID: $0.sessionID, model: $0.model, permissionMode: $0.permissionMode)] },
        "UserPromptSubmit": { [.turnStarted(turnID: $0.turnID)] },
        "PreToolUse": { _ in [.turnInteractionChanged(.none), .turnActivityChanged(.executing)] },
        "SubagentStart": { _ in [.turnInteractionChanged(.none), .turnActivityChanged(.executing)] },
        "PostToolUse": { _ in [.turnInteractionChanged(.none), .turnActivityChanged(.reasoning)] },
        "SubagentStop": { _ in [.turnInteractionChanged(.none), .turnActivityChanged(.reasoning)] },
        "PermissionRequest": { _ in [.turnInteractionChanged(.permission)] },
        "Stop": { [.turnCompleted(turnID: $0.turnID)] },
        "PreCompact": { _ in [.turnActivityChanged(.compacting)] },
        "PostCompact": { _ in [.turnActivityChanged(.reasoning)] },
    ]

    /// The payload field that names Codex's turn. No Codex hook payload has
    /// been captured yet, so this is the field Clawddy has always read.
    static let turnIDField = "turn_id"

    /// Codex's entry in the provider table.
    var entry: AgentProviderEntry {
        AgentProviderEntry(
            turnActivity: .hookJournal,
            hookEvents: Self.hookEvents,
            recordsExit: true,
            prepareIntegration: { prepareIntegration() },
            prepareLaunch: { prepareLaunch($0) },
            probe: { probe(environmentPath: $0) },
            cleanup: { _ in })
    }
    private static let hookReviewNotice =
        "Review and trust Clawddy’s activity hook in Codex with /hooks. The terminal remains fully usable while status tracking is paused."
    private static let nonProductionNotice =
        "Only the production Clawddy installs Codex’s activity hook, so this build does not track Codex status."

    func prepareIntegration() -> Result<AgentIntegrationPreparation, AgentProviderIssue> {
        guard isProduction else {
            return .success(AgentIntegrationPreparation(notice: Self.nonProductionNotice))
        }
        do {
            try AgentHookRuntime.install(root: root)
            let changed = try installHooks()
            if changed {
                try AgentConfig.atomicWrite(
                    Data(Self.hookReviewNotice.utf8),
                    to: root.codexHookReviewMarker)
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

        // The global hook entry carries only the status folder, so Codex's
        // agent identity travels in the terminal's environment.
        var environment: [String: String] = [
            "CLAWDDY_AGENT_ID": request.agentID.uuidString,
            "CLAWDDY_AGENT_PROVIDER": id.rawValue,
            "CLAWDDY_AGENT_GENERATION": request.launchGeneration.uuidString,
            "CLAWDDY_STATUS_DIR": root.statusDir.path,
        ]
        if let configURL = AgentConfig.codexConfigEnvironmentOverride {
            environment["CODEX_HOME"] = configURL.path
        }
        return .success(AgentPreparedLaunch(
            executableURL: executable,
            arguments: arguments,
            environment: environment,
            metadataAvailability: .waiting))
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

    static func clearHookReviewRequired(root: AgentDataRoot) throws {
        try FileManager.default.removeItemIfPresent(at: root.codexHookReviewMarker)
    }

    private var isHookReviewRequired: Bool {
        FileManager.default.fileExists(atPath: root.codexHookReviewMarker.path)
    }

    /// Replaces the entries that run this root's hook script with one per
    /// event of Codex's event table, leaving every other entry alone. Writes
    /// only when that changes the file's content.
    private func installHooks() throws -> Bool {
        try AgentHookRuntime.updateJSONFile(
            at: hooksFile,
            backupURL: hooksFile.appendingPathExtension("clawddy-backup")
        ) { file in
            var hooks = AgentHookRuntime.removingHandlers(
                runningScriptOf: root,
                from: file["hooks"] as? [String: Any] ?? [:])
            for event in Self.hookEvents.keys {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": AgentHookRuntime.command(root: root),
                        "timeout": 5,
                    ]],
                ])
                hooks[event] = groups
            }
            file["hooks"] = hooks
        }
    }
}
