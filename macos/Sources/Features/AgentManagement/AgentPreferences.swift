import Foundation

struct AgentPreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var claudeCodeDefaultStartMode: AgentStartMode
    var codexDefaultStartMode: AgentStartMode
    var antigravityDefaultStartMode: AgentStartMode

    init(
        claudeCodeDefaultStartMode: AgentStartMode = .unrestricted,
        codexDefaultStartMode: AgentStartMode = .unrestricted,
        antigravityDefaultStartMode: AgentStartMode = .unrestricted
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.claudeCodeDefaultStartMode = claudeCodeDefaultStartMode
        self.codexDefaultStartMode = codexDefaultStartMode
        self.antigravityDefaultStartMode = antigravityDefaultStartMode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case claudeCodeDefaultStartMode
        case codexDefaultStartMode
        case antigravityDefaultStartMode
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
        antigravityDefaultStartMode = try container.decodeIfPresent(
            AgentStartMode.self,
            forKey: .antigravityDefaultStartMode) ?? .unrestricted
    }

    func defaultStartMode(for provider: AgentProviderID) -> AgentStartMode {
        switch provider {
        case .claudeCode: return claudeCodeDefaultStartMode
        case .codex: return codexDefaultStartMode
        case .antigravity: return antigravityDefaultStartMode
        }
    }

    mutating func setDefaultStartMode(_ mode: AgentStartMode, for provider: AgentProviderID) {
        switch provider {
        case .claudeCode: claudeCodeDefaultStartMode = mode
        case .codex: codexDefaultStartMode = mode
        case .antigravity: antigravityDefaultStartMode = mode
        }
    }
}

enum AgentPreferencesStore {
    /// What `load` read.
    struct Loaded: Equatable {
        var preferences: AgentPreferences
        /// Why the file could not be read, or nil.
        var error: String?
    }

    /// The saved preferences, and the defaults while there is no file. A
    /// file that cannot be read or decoded gives standard mode for every
    /// provider, the least permissive, and says why.
    static func load(from url: URL) -> Loaded {
        do {
            let data = try Data(contentsOf: url)
            return Loaded(preferences: try JSONDecoder().decode(AgentPreferences.self, from: data))
        } catch CocoaError.fileReadNoSuchFile {
            return Loaded(preferences: AgentPreferences())
        } catch {
            return Loaded(
                preferences: AgentPreferences(
                    claudeCodeDefaultStartMode: .standard,
                    codexDefaultStartMode: .standard,
                    antigravityDefaultStartMode: .standard),
                error: "Agent defaults could not be read from \(url.path) (\(AgentConfig.describeLoadFailure(error))), so new agents start with standard permissions.")
        }
    }

    static func save(_ preferences: AgentPreferences, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AgentConfig.atomicWrite(try encoder.encode(preferences), to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path)
    }
}
