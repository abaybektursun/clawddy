import Foundation

/// A last-known snapshot reported by Claude Code's official status-line input.
/// The raw identifiers are retained for diagnostics while the UI uses the
/// presentation helpers below.
struct AgentSessionMetadata: Codable, Equatable, Sendable {
    var modelID: String?
    var modelDisplayName: String?
    var effortLevel: String?
    var contextWindowSize: Int?
    var contextUsedPercentage: Double?
    var contextRemainingPercentage: Double?
    var currentInputTokens: Int?
    var currentOutputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?
    var totalInputTokens: Int?
    var totalOutputTokens: Int?
    var totalCostUSD: Double?
    var durationMilliseconds: Int?
    var apiDurationMilliseconds: Int?
    var linesAdded: Int?
    var linesRemoved: Int?
    var sessionID: String?
    var sessionName: String?
    var transcriptPath: String?
    var claudeVersion: String?
    var thinkingEnabled: Bool?
    var observedAt: Date

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
        return Self(
            modelID: payload.model?.id,
            modelDisplayName: payload.model?.displayName,
            effortLevel: payload.effort?.level,
            contextWindowSize: payload.contextWindow?.contextWindowSize,
            contextUsedPercentage: payload.contextWindow?.usedPercentage,
            contextRemainingPercentage: payload.contextWindow?.remainingPercentage,
            currentInputTokens: payload.contextWindow?.currentUsage?.inputTokens,
            currentOutputTokens: payload.contextWindow?.currentUsage?.outputTokens,
            cacheCreationInputTokens: payload.contextWindow?.currentUsage?.cacheCreationInputTokens,
            cacheReadInputTokens: payload.contextWindow?.currentUsage?.cacheReadInputTokens,
            totalInputTokens: payload.contextWindow?.totalInputTokens,
            totalOutputTokens: payload.contextWindow?.totalOutputTokens,
            totalCostUSD: payload.cost?.totalCostUSD,
            durationMilliseconds: payload.cost?.totalDurationMS,
            apiDurationMilliseconds: payload.cost?.totalAPIDurationMS,
            linesAdded: payload.cost?.totalLinesAdded,
            linesRemoved: payload.cost?.totalLinesRemoved,
            sessionID: payload.sessionID,
            sessionName: payload.sessionName,
            transcriptPath: payload.transcriptPath,
            claudeVersion: payload.version,
            thinkingEnabled: payload.thinking?.enabled,
            observedAt: observedAt)
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

enum AgentMetadataAvailability: Equatable {
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
        var outputTokens: Int?
        var cacheCreationInputTokens: Int?
        var cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    struct ContextWindow: Decodable {
        var contextWindowSize: Int?
        var usedPercentage: Double?
        var remainingPercentage: Double?
        var currentUsage: Usage?
        var totalInputTokens: Int?
        var totalOutputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case contextWindowSize = "context_window_size"
            case usedPercentage = "used_percentage"
            case remainingPercentage = "remaining_percentage"
            case currentUsage = "current_usage"
            case totalInputTokens = "total_input_tokens"
            case totalOutputTokens = "total_output_tokens"
        }
    }

    struct Cost: Decodable {
        var totalCostUSD: Double?
        var totalDurationMS: Int?
        var totalAPIDurationMS: Int?
        var totalLinesAdded: Int?
        var totalLinesRemoved: Int?

        enum CodingKeys: String, CodingKey {
            case totalCostUSD = "total_cost_usd"
            case totalDurationMS = "total_duration_ms"
            case totalAPIDurationMS = "total_api_duration_ms"
            case totalLinesAdded = "total_lines_added"
            case totalLinesRemoved = "total_lines_removed"
        }
    }

    struct Thinking: Decodable { var enabled: Bool? }

    var model: Model?
    var effort: Effort?
    var contextWindow: ContextWindow?
    var cost: Cost?
    var sessionID: String?
    var sessionName: String?
    var transcriptPath: String?
    var version: String?
    var thinking: Thinking?

    enum CodingKeys: String, CodingKey {
        case model, effort, cost, version, thinking
        case contextWindow = "context_window"
        case sessionID = "session_id"
        case sessionName = "session_name"
        case transcriptPath = "transcript_path"
    }
}
