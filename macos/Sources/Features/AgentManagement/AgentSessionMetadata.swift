import Foundation

/// A provider-neutral last-known metadata snapshot. Claude Code's official
/// status-line payload fills the richer usage fields; provider hook fields fill
/// the shared identity and permission fields. The UI uses the presentation
/// helpers below without inferring unsupported telemetry.
struct AgentSessionMetadata: Codable, Equatable, Sendable {
    var provider: AgentProviderID?
    var modelID: String?
    var modelDisplayName: String?
    var effortLevel: String?
    var contextWindowSize: Int?
    var contextUsedPercentage: Double?
    var currentInputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?
    var totalInputTokens: Int?
    var totalOutputTokens: Int?
    var totalCostUSD: Double?
    var durationMilliseconds: Int?
    var sessionID: String?
    var runtimeVersion: String?
    var permissionMode: String?
    var thinkingEnabled: Bool?
    var observedAt: Date

    init(
        provider: AgentProviderID,
        modelID: String? = nil,
        effortLevel: String? = nil,
        sessionID: String? = nil,
        runtimeVersion: String? = nil,
        permissionMode: String? = nil,
        observedAt: Date = Date()
    ) {
        self.provider = provider
        self.modelID = modelID
        self.effortLevel = effortLevel
        self.sessionID = sessionID
        self.runtimeVersion = runtimeVersion
        self.permissionMode = permissionMode
        self.observedAt = observedAt
    }

    var displayModel: String? {
        nonempty(modelDisplayName) ?? nonempty(modelID)
    }

    var displayEffort: String? {
        guard let effort = nonempty(effortLevel) else { return nil }
        switch effort.lowercased() {
        case "xhigh": return "Extra high"
        case "max": return "Maximum"
        default: return effort.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Claude defines context use as current input plus cache creation/read input.
    var contextUsedTokens: Int? {
        let values = [currentInputTokens, cacheCreationInputTokens, cacheReadInputTokens]
        guard values.contains(where: { $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }

    var contextFraction: Double? {
        if let percentage = contextUsedPercentage {
            return min(max(percentage / 100, 0), 1)
        }
        guard let used = contextUsedTokens, let size = contextWindowSize, size > 0 else { return nil }
        return min(max(Double(used) / Double(size), 0), 1)
    }

    var contextPercentText: String? {
        guard let fraction = contextFraction else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    var searchTerms: [String] {
        [displayModel, displayEffort, contextPercentText].compactMap { $0 }
    }

    static func decodeStatusLinePayload(_ data: Data, observedAt: Date = Date()) throws -> Self {
        let payload = try JSONDecoder().decode(StatusLinePayload.self, from: data)
        var snapshot = Self(
            provider: .claudeCode,
            modelID: payload.model?.id,
            effortLevel: payload.effort?.level,
            sessionID: payload.sessionID,
            runtimeVersion: payload.version,
            permissionMode: nil,
            observedAt: observedAt)
        snapshot.modelDisplayName = payload.model?.displayName
        snapshot.contextWindowSize = payload.contextWindow?.contextWindowSize
        snapshot.contextUsedPercentage = payload.contextWindow?.usedPercentage
        snapshot.currentInputTokens = payload.contextWindow?.currentUsage?.inputTokens
        snapshot.cacheCreationInputTokens = payload.contextWindow?.currentUsage?.cacheCreationInputTokens
        snapshot.cacheReadInputTokens = payload.contextWindow?.currentUsage?.cacheReadInputTokens
        snapshot.totalInputTokens = payload.contextWindow?.totalInputTokens
        snapshot.totalOutputTokens = payload.contextWindow?.totalOutputTokens
        snapshot.totalCostUSD = payload.cost?.totalCostUSD
        snapshot.durationMilliseconds = payload.cost?.totalDurationMS
        snapshot.thinkingEnabled = payload.thinking?.enabled
        return snapshot
    }

    static func formatTokens(_ value: Int) -> String {
        let magnitude = abs(value)
        if magnitude < 1_000 { return value.formatted() }
        if magnitude < 100_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        if magnitude < 1_000_000 {
            return "\(Int((Double(value) / 1_000).rounded()))K"
        }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }
}

enum AgentMetadataAvailability: Equatable, Sendable {
    case notStarted
    case waiting
    case available
    case unavailable(String)
}

private struct StatusLinePayload: Decodable {
    struct Model: Decodable {
        var id: String?
        var displayName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    struct Effort: Decodable { var level: String? }

    struct Usage: Decodable {
        var inputTokens: Int?
        var cacheCreationInputTokens: Int?
        var cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    struct ContextWindow: Decodable {
        var contextWindowSize: Int?
        var usedPercentage: Double?
        var currentUsage: Usage?
        var totalInputTokens: Int?
        var totalOutputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case contextWindowSize = "context_window_size"
            case usedPercentage = "used_percentage"
            case currentUsage = "current_usage"
            case totalInputTokens = "total_input_tokens"
            case totalOutputTokens = "total_output_tokens"
        }
    }

    struct Cost: Decodable {
        var totalCostUSD: Double?
        var totalDurationMS: Int?

        enum CodingKeys: String, CodingKey {
            case totalCostUSD = "total_cost_usd"
            case totalDurationMS = "total_duration_ms"
        }
    }

    struct Thinking: Decodable { var enabled: Bool? }

    var model: Model?
    var effort: Effort?
    var contextWindow: ContextWindow?
    var cost: Cost?
    var sessionID: String?
    var version: String?
    var thinking: Thinking?

    enum CodingKeys: String, CodingKey {
        case model, effort, cost, version, thinking
        case contextWindow = "context_window"
        case sessionID = "session_id"
    }
}
