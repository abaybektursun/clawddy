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
    case delayed
    case unavailable(String)
}

enum AgentTurnState: Equatable, Sendable {
    case inactive
    case active(turnID: String?)
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
    var turnState: AgentTurnState = .inactive
    /// The saved session this launch resumes, until the provider starts it.
    var resumingSessionID: String?
    /// The saved session this launch found missing. The agent can only
    /// start fresh; `failureMessage` says why.
    var missingSessionID: String?
    /// The saved session could not be read, so this launch did not start.
    /// The agent can only start fresh; `failureMessage` says why.
    var sessionUnreadable = false
}

enum AgentRuntimeEvent: Equatable, Sendable {
    case launchRequested(generation: UUID)
    case surfaceOpened(generation: UUID, resumedSessionID: String? = nil)
    case launchTimedOut(generation: UUID)
    case launchFailed(generation: UUID, message: String, sessionUnreadable: Bool = false)
    case interactionRequired(generation: UUID, interaction: AgentInteractionState)
    case provider(
        generation: UUID,
        provider: AgentProviderID,
        eventID: String,
        event: AgentDomainEvent,
        isViewed: Bool)
    case compactionExpired(generation: UUID)
    case telemetryDelayed(generation: UUID)
    case surfaceDied(generation: UUID?)
    case completionViewed
    /// The provider's sign-in state, from a health probe.
    case providerAuthentication(AgentProviderAuthState)
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
                sessionID: current.sessionID,
                turnState: .inactive)

        case .surfaceOpened(let generation, let resumedSessionID):
            guard state.launchGeneration == generation else { break }
            state.surfaceState = .open
            state.resumingSessionID = resumedSessionID

        case .launchTimedOut(let generation):
            guard state.launchGeneration == generation,
                  state.processState == .launching
            else { break }
            state.telemetryHealth = .unavailable(
                "The terminal is running, but agent activity status is unavailable.")

        case .launchFailed(let generation, let message, let sessionUnreadable):
            guard state.launchGeneration == generation else { break }
            state.sessionUnreadable = sessionUnreadable
            state.surfaceState = .failed
            state.processState = .exited
            state.activityState = .unknown
            state.interactionState = .none
            state.turnState = .inactive
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
                // "Pre-start" is the launch phase, not "not currently
                // running": a session that started has moved the process to
                // .running, and its exit, with any status, is no launch
                // failure. A launch that already failed because its session
                // is missing keeps saying so.
                let stillLaunching = state.processState == .notStarted
                    || state.processState == .launching
                state.processState = .exited
                state.activityState = .unknown
                state.interactionState = .none
                state.turnState = .inactive
                if stillLaunching && status != 0 && state.missingSessionID == nil {
                    state.failureMessage = "The provider exited before the agent session started (status \(status))."
                    effects.append(.failed)
                }
                effects.append(.providerExited(status))
                break
            }

            switch domainEvent {
            case .sessionStarted, .turnStarted:
                confirmProviderAlive(&state, effects: &effects)
            case .turnCompleted, .turnFailed:
                if state.processState != .exited {
                    confirmProviderAlive(&state, effects: &effects)
                }
            case .turnActivityChanged, .turnInteractionChanged,
                    .sessionEnded, .providerExited:
                break
            }
            state.telemetryHealth = .live

            switch domainEvent {
            case .sessionStarted(let sessionID, _, _):
                state.sessionID = sessionID ?? state.sessionID
                state.activityState = .idle
                state.interactionState = .none
                state.turnState = .inactive
                state.runtimeErrorMessage = nil

            case .turnStarted(let turnID):
                state.turnState = .active(turnID: turnID)
                state.activityState = .reasoning
                state.interactionState = .none
                state.runtimeErrorMessage = nil
                clearUnread(&state, effects: &effects)

            case .turnActivityChanged(let activity):
                guard case .active = state.turnState else { break }
                state.activityState = activity

            case .turnInteractionChanged(let interaction):
                guard case .active = state.turnState else { break }
                if interaction != .none && state.interactionState != interaction {
                    effects.append(.waitingForUser)
                }
                state.interactionState = interaction

            case .turnCompleted(let turnID):
                state.turnState = .inactive
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
                state.turnState = .inactive
                state.activityState = .idle
                state.interactionState = .none
                state.runtimeErrorMessage = message?.trimmingCharacters(
                    in: .whitespacesAndNewlines).nilIfEmpty
                    ?? "The agent reported a runtime error."
                effects.append(.failed)

            case .sessionEnded:
                // The process goes on after `/clear`, whose next
                // `SessionStart` rebinds the agent, and reports its own exit.
                // What a session end does tell: Claude ends a resume of a
                // session it cannot find before starting it, with
                // `SessionEnd`, no `SessionStart`, and exit status 1. The
                // exit record may come first and has then already marked the
                // launch failed, without saying why.
                if let missing = state.resumingSessionID {
                    state.resumingSessionID = nil
                    state.missingSessionID = missing
                    if state.failureMessage == nil { effects.append(.failed) }
                    state.failureMessage = "\(provider.displayName) found no conversation with session ID \(missing), so the agent could not be resumed."
                }

            case .providerExited:
                // Handled before provider confirmation above so an executable
                // that fails immediately never masquerades as a live agent.
                break
            }

        case .compactionExpired(let generation):
            guard state.launchGeneration == generation else { break }
            if state.activityState == .compacting {
                if case .active = state.turnState {
                    state.activityState = .reasoning
                } else {
                    state.activityState = .idle
                }
            }

        case .telemetryDelayed(let generation):
            guard state.launchGeneration == generation,
                  state.processState == .running,
                  case .active = state.turnState,
                  state.telemetryHealth == .live
            else { break }
            // Confidence changed; the last confirmed activity fact did not.
            state.telemetryHealth = .delayed

        case .surfaceDied(let generation):
            if let generation, state.launchGeneration != generation { break }
            state.surfaceState = .closed
            state.processState = .exited
            state.activityState = .unknown
            state.interactionState = .none
            state.turnState = .inactive
            state.failureMessage = nil
            state.resumingSessionID = nil
            state.missingSessionID = nil
            state.sessionUnreadable = false

        case .completionViewed:
            clearUnread(&state, effects: &effects)

        case .providerAuthentication(let authentication):
            // Only an agent that has never started and has nothing unread
            // shows its provider's sign-in state.
            guard state.surfaceState == .inactive,
                  state.processState == .notStarted,
                  state.unreadCompletion == nil
            else { break }
            state.interactionState = AgentAuthenticationPresentation.reconciledInteraction(
                current: state.interactionState,
                authentication: authentication)
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

    private static func confirmProviderAlive(
        _ state: inout AgentRuntimeSnapshot,
        effects: inout [AgentRuntimeEffect]
    ) {
        guard state.processState != .running else { return }
        state.processState = .running
        state.failureMessage = nil
        state.resumingSessionID = nil
        effects.append(.becameAlive)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
