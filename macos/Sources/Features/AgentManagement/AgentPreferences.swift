import Foundation

/// What new agents start with, saved in `preferences.json`: one start mode
/// per CLI, keyed by the CLI's stored name, so a CLI added later needs no
/// field of its own.
struct AgentPreferences: Codable, Equatable, Sendable {
    /// 2: `defaultStartModes`. 1 (until the agy work): one named field per
    /// CLI, `<CLI>DefaultStartMode`, still read.
    static let currentSchemaVersion = 2

    private var defaultStartModes: [AgentProviderID: AgentStartMode]

    /// Every CLI starting `mode`.
    init(defaultStartMode mode: AgentStartMode = .unrestricted) {
        defaultStartModes = Dictionary(uniqueKeysWithValues: AgentProviderID.allCases.map { ($0, mode) })
    }

    func defaultStartMode(for provider: AgentProviderID) -> AgentStartMode {
        defaultStartModes[provider] ?? .unrestricted
    }

    mutating func setDefaultStartMode(_ mode: AgentStartMode, for provider: AgentProviderID) {
        defaultStartModes[provider] = mode
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { nil }

        static let schemaVersion = Key("schemaVersion")
        static let defaultStartModes = Key("defaultStartModes")
        /// Schema 1's field for `provider`, e.g. `codexDefaultStartMode`.
        static func named(_ provider: AgentProviderID) -> Key { Key("\(provider.rawValue)DefaultStartMode") }
    }

    /// A CLI the file does not name (one added since it was written) starts
    /// with permission checks when any CLI it names is set to them, else
    /// unrestricted, the default: a person who chose permission checks never
    /// gets a new CLI without them. A name the file has that no CLI has is
    /// dropped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var stored: [AgentProviderID: AgentStartMode] = [:]
        if let modes = try container.decodeIfPresent([String: AgentStartMode].self, forKey: .defaultStartModes) {
            for (name, mode) in modes {
                if let provider = AgentProviderID(rawValue: name) { stored[provider] = mode }
            }
        } else {
            for provider in AgentProviderID.allCases {
                if let mode = try container.decodeIfPresent(AgentStartMode.self, forKey: .named(provider)) {
                    stored[provider] = mode
                }
            }
        }
        self.init(defaultStartMode: stored.values.contains(.standard) ? .standard : .unrestricted)
        defaultStartModes.merge(stored) { $1 }
    }

    /// Always the current shape.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(
            Dictionary(uniqueKeysWithValues: defaultStartModes.map { ($0.key.rawValue, $0.value) }),
            forKey: .defaultStartModes)
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
                preferences: AgentPreferences(defaultStartMode: .standard),
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
