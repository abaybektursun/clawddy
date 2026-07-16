import Foundation

enum AgentProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex

    var id: Self { self }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    var symbolName: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var capabilities: AgentProviderCapabilities {
        switch self {
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        }
    }

    func startModeTitle(_ mode: AgentStartMode) -> String {
        switch (self, mode) {
        case (.claudeCode, .unrestricted): return "Dangerously Skip Permissions"
        case (.codex, .unrestricted): return "YOLO"
        case (_, .standard): return "Standard Permissions"
        }
    }

    func startModeDescription(_ mode: AgentStartMode) -> String {
        switch (self, mode) {
        case (.claudeCode, .unrestricted):
            return "Bypasses all Claude Code permission checks."
        case (.codex, .unrestricted):
            return "Runs without approval prompts or the Codex sandbox."
        case (_, .standard):
            return "Uses the provider’s normal approval and sandbox behavior."
        }
    }

    func startModeArguments(_ mode: AgentStartMode) -> [String] {
        guard mode == .unrestricted else { return [] }
        switch self {
        case .claudeCode: return ["--dangerously-skip-permissions"]
        case .codex: return ["--dangerously-bypass-approvals-and-sandbox"]
        }
    }
}

enum AgentStartMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case unrestricted
    case standard

    var id: Self { self }
}

struct AgentLaunchProfile: Codable, Equatable, Sendable {
    var modelID: String?
    var reasoningEffort: String?
    var startMode: AgentStartMode

    init(
        modelID: String? = nil,
        reasoningEffort: String? = nil,
        startMode: AgentStartMode = .unrestricted
    ) {
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.startMode = startMode
    }

    private enum CodingKeys: String, CodingKey {
        case modelID, reasoningEffort, startMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        startMode = try container.decodeIfPresent(AgentStartMode.self, forKey: .startMode)
            ?? .unrestricted
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(modelID, forKey: .modelID)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(startMode, forKey: .startMode)
    }

    var displayReasoningEffort: String? {
        guard let effort = reasoningEffort?.trimmingCharacters(
            in: .whitespacesAndNewlines),
              !effort.isEmpty
        else { return nil }
        switch effort.lowercased() {
        case "xhigh": return "Extra high"
        case "max": return "Maximum"
        default: return effort.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var searchTerms: [String] {
        [modelID, displayReasoningEffort, reasoningEffort].compactMap { $0 }
    }
}

enum AgentCapabilitySupport: Equatable, Sendable {
    case supported
    case unavailable(String)
    case unsupported(String)

    var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    var explanation: String? {
        switch self {
        case .supported: return nil
        case .unavailable(let reason), .unsupported(let reason): return reason
        }
    }
}

struct AgentProviderCapabilities: Equatable, Sendable {
    var resume: AgentCapabilitySupport
    var fork: AgentCapabilitySupport
    var sessionRename: AgentCapabilitySupport
    var modelTelemetry: AgentCapabilitySupport
    var effortTelemetry: AgentCapabilitySupport
    var contextTelemetry: AgentCapabilitySupport
    var costTelemetry: AgentCapabilitySupport
    var approvalTelemetry: AgentCapabilitySupport

    static let claudeCode = Self(
        resume: .supported,
        fork: .supported,
        sessionRename: .supported,
        modelTelemetry: .supported,
        effortTelemetry: .supported,
        contextTelemetry: .supported,
        costTelemetry: .supported,
        approvalTelemetry: .supported)

    static let codex = Self(
        resume: .supported,
        fork: .supported,
        sessionRename: .supported,
        modelTelemetry: .supported,
        effortTelemetry: .unavailable("Reasoning effort is not exposed by the interactive hook interface."),
        contextTelemetry: .unavailable(
            "Context usage is not exposed by Codex lifecycle hooks in the interactive terminal integration."),
        costTelemetry: .unsupported("Session cost is not reported by the interactive Codex interface."),
        approvalTelemetry: .supported)
}

enum AgentProviderAuthState: Equatable, Sendable {
    case checking
    case signedIn
    case signedOut
    case unavailable(String)
}

struct AgentProviderHealth: Equatable, Sendable {
    enum Installation: Equatable, Sendable {
        case checking
        case ready(executable: String, version: String?)
        case missing
        case unavailable(String)
    }

    var installation: Installation = .checking
    var authentication: AgentProviderAuthState = .checking
    var integrationIssue: String?

    var isReadyToLaunch: Bool {
        if case .ready = installation { return true }
        return false
    }

    var conciseStatus: String {
        switch installation {
        case .checking: return "Checking…"
        case .missing: return "Not Installed"
        case .unavailable: return "Unavailable"
        case .ready:
            switch authentication {
            case .checking: return "Checking Sign-In…"
            case .signedIn: return integrationIssue == nil ? "Ready" : "Ready · Status Limited"
            case .signedOut: return "Sign In Required"
            case .unavailable: return "Ready · Sign-In Unknown"
            }
        }
    }
}

enum AgentProviderIssue: Error, Equatable, LocalizedError, Sendable {
    case executableMissing(AgentProviderID)
    case integrationFailed(AgentProviderID, String)
    case invalidSession(AgentProviderID)
    case launchPreparationFailed(AgentProviderID, String)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let provider):
            return "\(provider.displayName) is not installed or is not available on the login-shell PATH."
        case .integrationFailed(let provider, let reason):
            return "\(provider.displayName) activity tracking could not be configured: \(reason)"
        case .invalidSession(let provider):
            return "The saved \(provider.displayName) session is invalid."
        case .launchPreparationFailed(let provider, let reason):
            return "\(provider.displayName) could not be prepared: \(reason)"
        }
    }
}

struct AgentSessionBinding: Codable, Equatable, Sendable {
    var provider: AgentProviderID
    var sessionID: String
    var launchGeneration: UUID?
}

struct AgentPendingFork: Codable, Equatable, Sendable {
    var provider: AgentProviderID
    var sourceSessionID: String
}

struct AgentLaunchRequest: Sendable {
    var agentID: UUID
    var name: String
    var provider: AgentProviderID
    var launchProfile: AgentLaunchProfile
    var workingDirectory: String?
    var environmentPath: String
    var launchGeneration: UUID
    var session: AgentSessionBinding?
    var pendingFork: AgentPendingFork?
}

struct AgentPreparedLaunch: Sendable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    var metadataAvailability: AgentMetadataAvailability
}

struct AgentIntegrationPreparation: Equatable, Sendable {
    var notice: String?

    static let ready = Self(notice: nil)
}

struct AgentRawProviderEvent: Decodable, Equatable, Sendable {
    var schemaVersion: Int?
    var eventID: String?
    var provider: AgentProviderID?
    var launchGeneration: UUID?
    var hookEventName: String
    var sessionID: String?
    var turnID: String?
    var model: String?
    var permissionMode: String?
    var exitStatus: Int?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case eventID
        case provider
        case launchGeneration
        case hookEventName
        case sessionID
        case turnID
        case model
        case permissionMode
        case exitStatus
        case legacyHookEventName = "hook_event_name"
        case legacySessionID = "session_id"
        case legacyTurnID = "turn_id"
        case legacyPermissionMode = "permission_mode"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        eventID = try container.decodeIfPresent(String.self, forKey: .eventID)
        provider = try container.decodeIfPresent(AgentProviderID.self, forKey: .provider)
        launchGeneration = try container.decodeIfPresent(UUID.self, forKey: .launchGeneration)
        hookEventName = try container.decodeIfPresent(String.self, forKey: .hookEventName)
            ?? container.decode(String.self, forKey: .legacyHookEventName)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? container.decodeIfPresent(String.self, forKey: .legacySessionID)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
            ?? container.decodeIfPresent(String.self, forKey: .legacyTurnID)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
            ?? container.decodeIfPresent(String.self, forKey: .legacyPermissionMode)
        exitStatus = try container.decodeIfPresent(Int.self, forKey: .exitStatus)
    }

    func hasSupportedSchema(for provider: AgentProviderID) -> Bool {
        switch schemaVersion {
        case 1: return true
        case nil: return self.provider == nil && provider == .claudeCode
        default: return false
        }
    }
}

enum AgentDomainEvent: Equatable, Sendable {
    case sessionStarted(sessionID: String?, model: String?, permissionMode: String?)
    case turnStarted(turnID: String?)
    case activityChanged(AgentActivityState)
    case interactionChanged(AgentInteractionState)
    case turnCompleted(turnID: String?)
    case turnFailed(String?)
    case sessionEnded
    case providerExited(status: Int)
}

protocol AgentProviderAdapter: Sendable {
    var id: AgentProviderID { get }
    var capabilities: AgentProviderCapabilities { get }

    func prepareIntegration() -> Result<AgentIntegrationPreparation, AgentProviderIssue>
    func prepareLaunch(_ request: AgentLaunchRequest) -> Result<AgentPreparedLaunch, AgentProviderIssue>
    func normalize(_ event: AgentRawProviderEvent) -> [AgentDomainEvent]
    func probe(environmentPath: String) -> AgentProviderHealth
    func cleanup(agentID: UUID)
}

struct AgentProviderRegistry: Sendable {
    private let claude = ClaudeCodeProvider()
    private let codex = CodexProvider()

    func adapter(for provider: AgentProviderID) -> any AgentProviderAdapter {
        switch provider {
        case .claudeCode: return claude
        case .codex: return codex
        }
    }

    func capabilities(for provider: AgentProviderID) -> AgentProviderCapabilities {
        adapter(for: provider).capabilities
    }
}

enum AgentRuntimeProviderPolicy {
    enum Decision: Equatable {
        case unchanged
        case replaceInactiveRuntime
        case preserveRuntimeAndRestoreConfig
    }

    static func decision(
        current: AgentProviderID,
        requested: AgentProviderID,
        persistedProvider: AgentProviderID?,
        surfaceState: AgentSurfaceState,
        processState: AgentProcessState
    ) -> Decision {
        guard current != requested else { return .unchanged }
        if persistedProvider != nil {
            return .preserveRuntimeAndRestoreConfig
        }
        if surfaceState == .inactive, processState == .notStarted {
            return .replaceInactiveRuntime
        }
        return .preserveRuntimeAndRestoreConfig
    }
}

enum AgentExecutableLocator {
    static func locate(_ executable: String, path: String) -> URL? {
        for component in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component), isDirectory: true)
                .appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

enum AgentProcessProbe {
    struct Result: Sendable {
        var status: Int32
        var output: String
    }

    static func run(
        executable: URL,
        arguments: [String],
        environmentPath: String,
        additionalEnvironment: [String: String] = [:],
        timeout: TimeInterval = 3
    ) -> Result? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = additionalEnvironment.merging([
            "HOME": AgentConfig.accountHomeDirectory.path,
            "PATH": environmentPath,
        ], uniquingKeysWith: { current, _ in current })
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return Result(
            status: process.terminationStatus,
            output: (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
