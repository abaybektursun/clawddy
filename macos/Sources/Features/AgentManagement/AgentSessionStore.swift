import Foundation

enum AgentSessionStore {
    private static let safeIDCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_."))

    static func persistedProvider(
        for agentID: UUID,
        directory: URL
    ) -> AgentProviderID? {
        let sessionURL = directory
            .appendingPathComponent("\(agentID.uuidString).session.json")
        if let data = try? Data(contentsOf: sessionURL),
           let binding = try? JSONDecoder().decode(AgentSessionBinding.self, from: data),
           valid(binding.sessionID) {
            return binding.provider
        }

        let forkURL = directory
            .appendingPathComponent("\(agentID.uuidString).fork.json")
        if let data = try? Data(contentsOf: forkURL),
           let pending = try? JSONDecoder().decode(AgentPendingFork.self, from: data),
           valid(pending.sourceSessionID) {
            return pending.provider
        }

        // Untagged persistence predates provider support and is exclusively
        // Claude Code state. Ignore malformed or empty legacy identifiers.
        for suffix in ["session", "forkFrom"] {
            let url = directory
                .appendingPathComponent("\(agentID.uuidString).\(suffix)")
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if valid(identifier) { return .claudeCode }
        }
        return nil
    }

    static func session(
        for agentID: UUID,
        provider: AgentProviderID,
        directory: URL
    ) -> AgentSessionBinding? {
        let taggedURL = directory
            .appendingPathComponent("\(agentID.uuidString).session.json")
        if let data = try? Data(contentsOf: taggedURL),
           let binding = try? JSONDecoder().decode(AgentSessionBinding.self, from: data),
           binding.provider == provider,
           valid(binding.sessionID) {
            return binding
        }

        // Compatibility input only. Every pre-v4 session belongs to Claude Code.
        guard provider == .claudeCode else { return nil }
        let legacyURL = directory
            .appendingPathComponent("\(agentID.uuidString).session")
        guard let raw = try? String(contentsOf: legacyURL, encoding: .utf8) else { return nil }
        let sessionID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard valid(sessionID) else { return nil }
        let migrated = AgentSessionBinding(
            provider: .claudeCode,
            sessionID: sessionID,
            launchGeneration: nil)
        _ = write(migrated, for: agentID, directory: directory)
        return migrated
    }

    @discardableResult
    static func write(
        _ binding: AgentSessionBinding,
        for agentID: UUID,
        directory: URL
    ) -> Bool {
        guard valid(binding.sessionID) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(binding) else { return false }
        let url = directory
            .appendingPathComponent("\(agentID.uuidString).session.json")
        return AgentConfig.atomicWrite(data, to: url)
    }

    static func pendingFork(
        for agentID: UUID,
        provider: AgentProviderID,
        directory: URL
    ) -> AgentPendingFork? {
        let taggedURL = directory
            .appendingPathComponent("\(agentID.uuidString).fork.json")
        if let data = try? Data(contentsOf: taggedURL),
           let pending = try? JSONDecoder().decode(AgentPendingFork.self, from: data),
           pending.provider == provider,
           valid(pending.sourceSessionID) {
            return pending
        }

        guard provider == .claudeCode else { return nil }
        let legacyURL = directory
            .appendingPathComponent("\(agentID.uuidString).forkFrom")
        guard let raw = try? String(contentsOf: legacyURL, encoding: .utf8) else { return nil }
        let sessionID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard valid(sessionID) else { return nil }
        let migrated = AgentPendingFork(provider: .claudeCode, sourceSessionID: sessionID)
        _ = write(migrated, for: agentID, directory: directory)
        return migrated
    }

    @discardableResult
    static func write(
        _ pending: AgentPendingFork,
        for agentID: UUID,
        directory: URL
    ) -> Bool {
        guard valid(pending.sourceSessionID) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(pending) else { return false }
        let url = directory
            .appendingPathComponent("\(agentID.uuidString).fork.json")
        return AgentConfig.atomicWrite(data, to: url)
    }

    static func clearPendingFork(
        for agentID: UUID,
        directory: URL
    ) {
        for suffix in ["fork.json", "forkFrom"] {
            try? FileManager.default.removeItem(
                at: directory
                    .appendingPathComponent("\(agentID.uuidString).\(suffix)"))
        }
    }

    static func removeAll(
        for agentID: UUID,
        directory: URL
    ) {
        for suffix in [
            "session.json", "session", "fork.json", "forkFrom", "lastEvent",
            "events", "events.lock", "metadata.json",
        ] {
            try? FileManager.default.removeItem(
                at: directory
                    .appendingPathComponent("\(agentID.uuidString).\(suffix)"))
        }
    }

    static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy(safeIDCharacters.contains)
    }
}
