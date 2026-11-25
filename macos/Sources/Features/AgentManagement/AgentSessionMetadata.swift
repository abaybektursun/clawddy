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
    /// Lines the session added and removed, as Claude's status line reports
    /// them: the header's "+38 −9".
    var linesAdded: Int?
    var linesRemoved: Int?
    var sessionID: String?
    var runtimeVersion: String?
    var permissionMode: String?
    var thinkingEnabled: Bool?
    /// When the plan's most used usage window resets, from the status
    /// line's `rate_limits` (Claude Code 2.1.331: `five_hour` and `seven_day`,
    /// each with `used_percentage` and `resets_at` in seconds since 1970).
    var limitResetsAt: Date?
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
        snapshot.linesAdded = payload.cost?.totalLinesAdded
        snapshot.linesRemoved = payload.cost?.totalLinesRemoved
        snapshot.durationMilliseconds = payload.cost?.totalDurationMS
        snapshot.thinkingEnabled = payload.thinking?.enabled
        let windows = [payload.rateLimits?.fiveHour, payload.rateLimits?.sevenDay].compactMap { $0 }
        snapshot.limitResetsAt = windows.max { ($0.usedPercentage ?? 0) < ($1.usedPercentage ?? 0) }?
            .resetsAt.map { Date(timeIntervalSince1970: $0) }
        return snapshot
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
        var totalLinesAdded: Int?
        var totalLinesRemoved: Int?

        enum CodingKeys: String, CodingKey {
            case totalCostUSD = "total_cost_usd"
            case totalDurationMS = "total_duration_ms"
            case totalLinesAdded = "total_lines_added"
            case totalLinesRemoved = "total_lines_removed"
        }
    }

    struct Thinking: Decodable { var enabled: Bool? }

    struct RateLimitWindow: Decodable {
        var usedPercentage: Double?
        var resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    struct RateLimits: Decodable {
        var fiveHour: RateLimitWindow?
        var sevenDay: RateLimitWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    var model: Model?
    var effort: Effort?
    var contextWindow: ContextWindow?
    var cost: Cost?
    var sessionID: String?
    var version: String?
    var thinking: Thinking?
    var rateLimits: RateLimits?

    enum CodingKeys: String, CodingKey {
        case model, effort, cost, version, thinking
        case contextWindow = "context_window"
        case sessionID = "session_id"
        case rateLimits = "rate_limits"
    }
}
