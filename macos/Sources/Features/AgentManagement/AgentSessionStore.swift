import Foundation

enum AgentSessionStore {
    private static let safeIDCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_."))

    /// A binding or fork marker that exists but cannot be used: it cannot be
    /// read, does not decode, or names a session ID Clawddy would not write.
    struct UnreadableFile: LocalizedError {
        let url: URL
        let reason: String

        var errorDescription: String? { "\(url.path) could not be read: \(reason)" }
    }

    /// A session ID Clawddy does not store: empty, or with a character other
    /// than a letter, a digit, `-`, `_` or `.`.
    struct InvalidSessionID: LocalizedError {
        let sessionID: String

        var errorDescription: String? { "“\(sessionID)” is not a session ID Clawddy can store." }
    }

    /// The provider the agent's saved session or pending fork belongs to;
    /// nil when it has neither. Throws when one of them is unreadable.
    static func persistedProvider(
        for agentID: UUID,
        directory: URL
    ) throws -> AgentProviderID? {
        if let binding = try savedBinding(agentID, directory) {
            return binding.provider
        }
        if let pending = try savedFork(agentID, directory) {
            return pending.provider
        }

        // An untagged binding predates provider support and is exclusively
        // Claude Code state. Ignore a malformed or empty legacy identifier.
        guard let raw = try legacySession(agentID, directory),
              valid(raw)
        else { return nil }
        return .claudeCode
    }

    /// The agent's saved session for `provider`, or nil when it has none.
    /// Throws when the saved session is unreadable.
    static func session(
        for agentID: UUID,
        provider: AgentProviderID,
        directory: URL
    ) throws -> AgentSessionBinding? {
        if let binding = try savedBinding(agentID, directory),
           binding.provider == provider {
            return binding
        }

        // Compatibility input only. Every pre-v4 session belongs to Claude Code.
        guard provider == .claudeCode,
              let sessionID = try legacySession(agentID, directory),
              valid(sessionID)
        else { return nil }
        let migrated = AgentSessionBinding(
            provider: .claudeCode,
            sessionID: sessionID,
            launchGeneration: nil)
        try write(migrated, for: agentID, directory: directory)
        return migrated
    }

    static func write(
        _ binding: AgentSessionBinding,
        for agentID: UUID,
        directory: URL
    ) throws {
        guard valid(binding.sessionID) else { throw InvalidSessionID(sessionID: binding.sessionID) }
        try write(binding, to: sessionURL(agentID, directory))
    }

    /// The saved session its provider found missing (`markMissing`), or nil
    /// when the agent's binding names a session not known to be missing or
    /// there is none. Reads only the binding; throws when it is unreadable.
    static func missingSession(for agentID: UUID, directory: URL) throws -> String? {
        guard let binding = try savedBinding(agentID, directory), binding.missing == true else { return nil }
        return binding.sessionID
    }

    /// Records that the provider found no conversation with `sessionID`,
    /// the session the agent's binding names. A binding that names another
    /// session, or none, is left as it is: the next launch does not resume
    /// the missing one.
    static func markMissing(_ sessionID: String, for agentID: UUID, directory: URL) throws {
        guard var binding = try savedBinding(agentID, directory), binding.sessionID == sessionID else { return }
        binding.missing = true
        try write(binding, for: agentID, directory: directory)
    }

    /// Forgets the agent's saved session, so its next launch starts a new
    /// one: the binding, the untagged file older builds wrote, which
    /// `session` would otherwise read and resume, and a pending fork.
    static func discardSession(for agentID: UUID, directory: URL) throws {
        for suffix in ["session.json", "session", "fork.json"] {
            try FileManager.default.removeItemIfPresent(
                at: directory.appendingPathComponent("\(agentID.uuidString).\(suffix)"))
        }
    }

    /// The agent's pending fork for `provider`, or nil when it has none.
    /// Throws when the marker is unreadable.
    static func pendingFork(
        for agentID: UUID,
        provider: AgentProviderID,
        directory: URL
    ) throws -> AgentPendingFork? {
        guard let pending = try savedFork(agentID, directory),
              pending.provider == provider
        else { return nil }
        return pending
    }

    static func write(
        _ pending: AgentPendingFork,
        for agentID: UUID,
        directory: URL
    ) throws {
        guard valid(pending.sourceSessionID) else {
            throw InvalidSessionID(sessionID: pending.sourceSessionID)
        }
        try write(pending, to: forkURL(agentID, directory))
    }

    static func clearPendingFork(
        for agentID: UUID,
        directory: URL
    ) throws {
        try FileManager.default.removeItemIfPresent(at: forkURL(agentID, directory))
    }

    static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy(safeIDCharacters.contains)
    }

    // MARK: - Files

    static func sessionURL(_ agentID: UUID, _ directory: URL) -> URL {
        directory.appendingPathComponent("\(agentID.uuidString).session.json")
    }

    static func forkURL(_ agentID: UUID, _ directory: URL) -> URL {
        directory.appendingPathComponent("\(agentID.uuidString).fork.json")
    }

    private static func savedBinding(_ agentID: UUID, _ directory: URL) throws -> AgentSessionBinding? {
        try decoded(AgentSessionBinding.self, at: sessionURL(agentID, directory), sessionID: \.sessionID)
    }

    private static func savedFork(_ agentID: UUID, _ directory: URL) throws -> AgentPendingFork? {
        try decoded(AgentPendingFork.self, at: forkURL(agentID, directory), sessionID: \.sourceSessionID)
    }

    /// The file decoded, or nil when there is no file. The session ID it
    /// names must be one `write` accepts.
    private static func decoded<T: Decodable>(
        _ type: T.Type,
        at url: URL,
        sessionID: (T) -> String
    ) throws -> T? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw UnreadableFile(url: url, reason: error.localizedDescription)
        }
        let value: T
        do {
            value = try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw UnreadableFile(url: url, reason: AgentConfig.describeLoadFailure(error))
        }
        guard valid(sessionID(value)) else {
            throw UnreadableFile(
                url: url,
                reason: InvalidSessionID(sessionID: sessionID(value)).localizedDescription)
        }
        return value
    }

    /// The untagged binding's text, trimmed, or nil when there is none.
    ///
    /// Every use is logged as an error. The production app runs `cleanupV5`
    /// at its first start, before it reads anything, and that converts every
    /// untagged binding; the dev seed writes none. So in either app a use
    /// comes after the cleanup report exists, and the fallback can be deleted
    /// only while the log shows none.
    private static func legacySession(_ agentID: UUID, _ directory: URL) throws -> String? {
        let url = directory.appendingPathComponent("\(agentID.uuidString).session")
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw UnreadableFile(url: url, reason: error.localizedDescription)
        }
        AgentDiagnostics.unifiedLog(
            .error,
            "used the legacy binding \(url.path), which cleanupV5 converts: the .session fallback is still needed")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AgentConfig.atomicWrite(try encoder.encode(value), to: url)
    }
}
