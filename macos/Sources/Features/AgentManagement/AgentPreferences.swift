import Foundation

struct AgentPreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var claudeCodeDefaultStartMode: AgentStartMode
    var codexDefaultStartMode: AgentStartMode

    init(
        claudeCodeDefaultStartMode: AgentStartMode = .unrestricted,
        codexDefaultStartMode: AgentStartMode = .unrestricted
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.claudeCodeDefaultStartMode = claudeCodeDefaultStartMode
        self.codexDefaultStartMode = codexDefaultStartMode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case claudeCodeDefaultStartMode
        case codexDefaultStartMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        claudeCodeDefaultStartMode = try container.decodeIfPresent(
            AgentStartMode.self,
            forKey: .claudeCodeDefaultStartMode) ?? .unrestricted
        codexDefaultStartMode = try container.decodeIfPresent(
            AgentStartMode.self,
            forKey: .codexDefaultStartMode) ?? .unrestricted
    }

    func defaultStartMode(for provider: AgentProviderID) -> AgentStartMode {
        switch provider {
        case .claudeCode: return claudeCodeDefaultStartMode
        case .codex: return codexDefaultStartMode
        }
    }

    mutating func setDefaultStartMode(_ mode: AgentStartMode, for provider: AgentProviderID) {
        switch provider {
        case .claudeCode: claudeCodeDefaultStartMode = mode
        case .codex: codexDefaultStartMode = mode
        }
    }
}

enum AgentPreferencesStore {
    static func load(from url: URL) -> AgentPreferences {
        guard let data = try? Data(contentsOf: url),
              let preferences = try? JSONDecoder().decode(AgentPreferences.self, from: data)
        else { return AgentPreferences() }
        return preferences
    }

    static func save(_ preferences: AgentPreferences, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard AgentConfig.atomicWrite(try encoder.encode(preferences), to: url) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path)
    }
}
