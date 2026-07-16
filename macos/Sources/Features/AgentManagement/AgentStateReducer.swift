import Foundation

enum AgentSurfaceState: Codable, Equatable, Sendable {
    case inactive
    case opening
    case open
    case failed
    case closed
}

enum AgentProcessState: Codable, Equatable, Sendable {
    case notStarted
    case launching
    case running
    case exited
}

enum AgentActivityState: Codable, Equatable, Sendable {
    case unknown
    case idle
    case reasoning
    case executing
    case compacting

    var isActive: Bool {
        self == .reasoning || self == .executing
    }
}

enum AgentInteractionState: Codable, Equatable, Sendable {
    case none
    case permission
    case input
    case authentication
}

enum AgentTelemetryHealth: Equatable, Sendable {
    case notStarted
    case awaiting
    case live
    case unavailable(String)
}

struct AgentCompletionID: Codable, Equatable, Hashable, Sendable {
    var provider: AgentProviderID
    var sessionID: String?
    var turnID: String?
    var launchGeneration: UUID
    var eventID: String
}

struct AgentRuntimeSnapshot: Equatable, Sendable {
    var surfaceState: AgentSurfaceState = .inactive
    var processState: AgentProcessState = .notStarted
    var activityState: AgentActivityState = .unknown
    var interactionState: AgentInteractionState = .none
    var telemetryHealth: AgentTelemetryHealth = .notStarted
    var unreadCompletion: AgentCompletionID?
    var lastAppliedCompletion: AgentCompletionID?
    var failureMessage: String?
    var runtimeErrorMessage: String?
    var launchGeneration: UUID?
    var sessionID: String?
}

enum AgentRuntimeEvent: Equatable, Sendable {
    case launchRequested(generation: UUID)
    case surfaceOpened(generation: UUID)
    case launchTimedOut(generation: UUID)
    case launchFailed(generation: UUID, message: String)
    case interactionRequired(generation: UUID, interaction: AgentInteractionState)
    case provider(
        generation: UUID,
        provider: AgentProviderID,
        eventID: String,
        event: AgentDomainEvent,
        isViewed: Bool)
    case compactionExpired(generation: UUID)
    case surfaceDied(generation: UUID?)
    case completionViewed
}

enum AgentRuntimeEffect: Equatable, Sendable {
    case becameAlive
    case completed
    case waitingForUser
    case failed
    case unreadChanged
    case providerExited(Int)
}

enum AgentStateReducer {
    static func reduce(
        _ current: AgentRuntimeSnapshot,
        event: AgentRuntimeEvent
    ) -> (state: AgentRuntimeSnapshot, effects: [AgentRuntimeEffect]) {
        var state = current
        var effects: [AgentRuntimeEffect] = []

        switch event {
        case .launchRequested(let generation):
            state = AgentRuntimeSnapshot(
                surfaceState: .opening,
                processState: .launching,
                activityState: .unknown,
                interactionState: .none,
                telemetryHealth: .awaiting,
                unreadCompletion: current.unreadCompletion,
                lastAppliedCompletion: current.lastAppliedCompletion,
                failureMessage: nil,
                runtimeErrorMessage: nil,
                launchGeneration: generation,
                sessionID: current.sessionID)

        case .surfaceOpened(let generation):
            guard state.launchGeneration == generation else { break }
            state.surfaceState = .open

        case .launchTimedOut(let generation):
            guard state.launchGeneration == generation,
                  state.processState == .launching
            else { break }
            state.telemetryHealth = .unavailable(
                "The terminal is running, but agent activity status is unavailable.")

        case .launchFailed(let generation, let message):
            guard state.launchGeneration == generation else { break }
            state.surfaceState = .failed
            state.processState = .exited
            state.activityState = .unknown
            state.interactionState = .none
            state.failureMessage = message
            state.runtimeErrorMessage = nil
            effects.append(.failed)

        case .interactionRequired(let generation, let interaction):
            guard state.launchGeneration == generation,
                  interaction != .none
            else { break }
            if state.interactionState != interaction {
                state.interactionState = interaction
                effects.append(.waitingForUser)
            }

        case .provider(let generation, let provider, let eventID, let domainEvent, let isViewed):
            guard state.launchGeneration == generation else { break }
            if case .providerExited(let status) = domainEvent {
                let wasRunning = state.processState == .running
                state.processState = .exited
                state.activityState = .unknown
                state.interactionState = .none
                if !wasRunning && status != 0 {
                    state.failureMessage = "The provider exited before the agent session started (status \(status))."
                    effects.append(.failed)
                }
                effects.append(.providerExited(status))
                break
            }
            let wasConfirmed = state.processState == .running
            if !wasConfirmed {
                state.processState = .running
                state.failureMessage = nil
                effects.append(.becameAlive)
            }
            state.telemetryHealth = .live

            switch domainEvent {
            case .sessionStarted(let sessionID, _, _):
                state.sessionID = sessionID ?? state.sessionID
                state.activityState = .idle
                state.interactionState = .none
                state.runtimeErrorMessage = nil

            case .turnStarted:
                state.activityState = .reasoning
                state.interactionState = .none
                state.runtimeErrorMessage = nil
                clearUnread(&state, effects: &effects)

            case .activityChanged(let activity):
                state.activityState = activity

            case .interactionChanged(let interaction):
                if interaction != .none && state.interactionState != interaction {
                    effects.append(.waitingForUser)
                }
                state.interactionState = interaction

            case .turnCompleted(let turnID):
                state.activityState = .idle
                state.interactionState = .none
                let completion = AgentCompletionID(
                    provider: provider,
                    sessionID: state.sessionID,
                    turnID: turnID,
                    launchGeneration: generation,
                    eventID: eventID)
                state.runtimeErrorMessage = nil
                if state.lastAppliedCompletion != completion {
                    state.lastAppliedCompletion = completion
                    effects.append(.completed)
                    if !isViewed, state.unreadCompletion != completion {
                        state.unreadCompletion = completion
                        effects.append(.unreadChanged)
                    }
                }

            case .turnFailed(let message):
                state.activityState = .idle
                state.interactionState = .none
                state.runtimeErrorMessage = message?.trimmingCharacters(
                    in: .whitespacesAndNewlines).nilIfEmpty
                    ?? "The agent reported a runtime error."
                effects.append(.failed)

            case .sessionEnded:
                state.processState = .exited
                state.activityState = .idle
                state.interactionState = .none

            case .providerExited:
                // Handled before provider confirmation above so an executable
                // that fails immediately never masquerades as a live agent.
                break
            }

        case .compactionExpired(let generation):
            guard state.launchGeneration == generation else { break }
            if state.activityState == .compacting {
                state.activityState = .idle
            }

        case .surfaceDied(let generation):
            if let generation, state.launchGeneration != generation { break }
            state.surfaceState = .closed
            state.processState = .exited
            state.activityState = .unknown
            state.interactionState = .none
            state.failureMessage = nil

        case .completionViewed:
            clearUnread(&state, effects: &effects)
        }

        return (state, effects)
    }

    private static func clearUnread(
        _ state: inout AgentRuntimeSnapshot,
        effects: inout [AgentRuntimeEffect]
    ) {
        guard state.unreadCompletion != nil else { return }
        state.unreadCompletion = nil
        effects.append(.unreadChanged)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
