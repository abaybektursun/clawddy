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
    /// The program reported `working` with no turn active. The turn starts
    /// when that report has stood for `AgentBridge.turnStartDelay`, so the
    /// `working` of `/clear`, `/exit` or the `/exit` confirmation, which
    /// lasts 14 to 63 ms, starts nothing and changes nothing on screen.
    case starting
    case active(turnID: String?)
    /// A manual compaction (`/compact`): it ends as a turn does, but
    /// completes nothing.
    case compaction
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
    /// This launch created its session, `sessionID`, and the session is not
    /// on disk yet: Claude writes a new or forked session only with its
    /// first entry. It is saved, and becomes the agent's binding, when the
    /// first turn starts (`sessionSaved`); until then a relaunch creates or
    /// forks it again instead of resuming a session that does not exist.
    var sessionUnsaved = false
}

enum AgentRuntimeEvent: Equatable, Sendable {
    case launchRequested(generation: UUID)
    /// `newSessionID` is the session the launch creates under an ID it
    /// chose, which is not on disk until the first turn.
    case surfaceOpened(generation: UUID, resumedSessionID: String? = nil, newSessionID: String? = nil)
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
    /// The `working` report that put the turn in `.starting` has stood for
    /// `AgentBridge.turnStartDelay`.
    case turnStartSettled(generation: UUID)
    case telemetryDelayed(generation: UUID)
    case surfaceDied(generation: UUID?)
    case completionViewed
    /// The provider's sign-in state, from a health probe.
    case providerAuthentication(AgentProviderAuthState)
}

enum AgentRuntimeEffect: Equatable, Sendable {
    case becameAlive
    /// The session the launch created is on disk now: it is the agent's
    /// binding, and a fork it came from is done.
    case sessionSaved
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

        case .surfaceOpened(let generation, let resumedSessionID, let newSessionID):
            guard state.launchGeneration == generation else { break }
            state.surfaceState = .open
            state.resumingSessionID = resumedSessionID
            if let newSessionID {
                state.sessionID = newSessionID
                state.sessionUnsaved = true
            }

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
                // A launch's provider exits once. Codex's exit record, which
                // its launch script still writes, follows the exit report and
                // changes nothing, as does a report printed again later.
                guard state.processState != .exited else { return (current, []) }
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
            case .sessionStarted, .turnCompleted, .turnFailed:
                confirmProviderAlive(&state, effects: &effects)
            case .turnStarted:
                // A prompt the event file delivers after the exit report
                // starts no turn: the provider has gone.
                guard state.processState != .exited else { return (current, []) }
                confirmProviderAlive(&state, effects: &effects)
            case .programStatus(let report):
                // The provider has exited or its terminal has closed: what
                // the terminal reports now is not this launch's provider.
                guard state.processState != .exited else { return (current, []) }
                // `clear` is no sign of life: Claude sends it when the folder
                // trust dialog is declined and when it exits.
                if report.state != .clear {
                    confirmProviderAlive(&state, effects: &effects)
                }
            case .sessionBound, .manualCompactionStarted, .turnActivityChanged,
                    .turnInteractionChanged, .sessionEnded, .providerExited:
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

            case .sessionBound(let sessionID):
                state.sessionID = sessionID ?? state.sessionID
                // The session exists, so a resume found it.
                state.resumingSessionID = nil

            case .turnStarted(let turnID):
                startTurn(&state, effects: &effects, turnID: turnID, activity: .reasoning)

            case .programStatus(let report):
                applyProgramStatus(
                    report,
                    to: &state,
                    effects: &effects,
                    completion: AgentCompletionID(
                        provider: provider,
                        sessionID: state.sessionID,
                        turnID: nil,
                        launchGeneration: generation,
                        eventID: eventID),
                    isViewed: isViewed)

            case .manualCompactionStarted:
                switch state.turnState {
                case .starting:
                    // The `working` it follows is the compaction, no blip.
                    startTurn(&state, effects: &effects, activity: .compacting)
                    state.turnState = .compaction
                case .active:
                    state.turnState = .compaction
                    state.activityState = .compacting
                case .inactive, .compaction:
                    // With no turn under way the hook came before its
                    // `working`, or after its `done` ended a short
                    // compaction; nothing tells the two apart. Marking the
                    // next turn would suppress a real completion, so the
                    // hook changes nothing. A compaction it fails to mark
                    // still completes nothing when its `done` carries the
                    // previous summary, as the captured one does.
                    break
                }

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
                endTurn(&state)
                state.runtimeErrorMessage = nil
                complete(
                    AgentCompletionID(
                        provider: provider,
                        sessionID: state.sessionID,
                        turnID: turnID,
                        launchGeneration: generation,
                        eventID: eventID),
                    isViewed: isViewed,
                    state: &state,
                    effects: &effects)

            case .turnFailed(let message):
                // A failed turn fails once: Claude's own `error` report
                // comes 15 to 27 ms before its `StopFailure` hook.
                guard state.runtimeErrorMessage == nil else { break }
                failTurn(message, state: &state, effects: &effects)

            case .sessionEnded:
                // The process goes on after `/clear`, whose next
                // `SessionStart` rebinds the agent, and reports its own exit.
                // What a session end does tell: Claude ends a resume of a
                // session it cannot find before starting it, with
                // `SessionEnd`, no `SessionStart`, and exit status 1. The
                // exit report, which skips the event file's delay, usually
                // comes first and has then already marked the launch failed
                // and notified it; this only says why.
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

        case .turnStartSettled(let generation):
            guard state.launchGeneration == generation,
                  state.turnState == .starting
            else { break }
            startTurn(&state, effects: &effects, activity: .executing)

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

    /// What one report the program made about itself (the root record) means,
    /// given the turn it finds. The reports are Claude's, as captured in
    /// `docs/clawddy-refactor/cli-facts.md`; `completion` is the one a `done`
    /// that completes the turn records.
    private static func applyProgramStatus(
        _ report: Ghostty.Action.ProgramStatus,
        to state: inout AgentRuntimeSnapshot,
        effects: inout [AgentRuntimeEffect],
        completion: AgentCompletionID,
        isViewed: Bool
    ) {
        switch report.state {
        case .working:
            switch state.turnState {
            case .inactive: state.turnState = .starting
            case .starting: break
            case .active, .compaction: state.interactionState = .none
            }

        case .blocked:
            if state.turnState == .inactive || state.turnState == .starting {
                startTurn(&state, effects: &effects, activity: .executing)
            }
            let interaction: AgentInteractionState
            switch report.kind {
            case .question: interaction = .input
            case .auth: interaction = .authentication
            case .permission, nil: interaction = .permission
            }
            if state.interactionState != interaction {
                state.interactionState = interaction
                effects.append(.waitingForUser)
            }

        case .done:
            switch state.turnState {
            case .inactive:
                // The summary that follows a completed turn, 1.5 to 2.5 s
                // later, or a repeat: never a second completion.
                break
            case .starting:
                // A blip, such as the `/exit` confirmation's `done` 14 ms
                // after its `working`.
                state.turnState = .inactive
            case .active:
                endTurn(&state)
                // Every captured `done` that completed a turn was bare; one
                // with a summary ended something else, such as a compaction.
                if report.message == nil {
                    complete(completion, isViewed: isViewed, state: &state, effects: &effects)
                }
            case .compaction:
                endTurn(&state)
            }

        case .idle:
            // An interrupt, Esc on a prompt and `/clear` all end here; no
            // turn is completed and nothing is notified.
            endTurn(&state)
            state.runtimeErrorMessage = nil

        case .clear:
            // Resets the activity; the launch goes on until the provider's
            // exit is reported.
            let known = state.activityState != .unknown
            endTurn(&state)
            if !known { state.activityState = .unknown }
            state.runtimeErrorMessage = nil

        case .error:
            // Never a blip: a failure can come 106 ms after its `working`.
            if state.turnState == .starting {
                startTurn(&state, effects: &effects, activity: .executing)
            }
            failTurn(report.message, state: &state, effects: &effects)
        }
    }

    private static func startTurn(
        _ state: inout AgentRuntimeSnapshot,
        effects: inout [AgentRuntimeEffect],
        turnID: String? = nil,
        activity: AgentActivityState
    ) {
        state.turnState = .active(turnID: turnID)
        state.activityState = activity
        state.interactionState = .none
        state.runtimeErrorMessage = nil
        clearUnread(&state, effects: &effects)
        // The turn's prompt is the session's first entry, which writes it.
        if state.sessionUnsaved {
            state.sessionUnsaved = false
            effects.append(.sessionSaved)
        }
    }

    private static func endTurn(_ state: inout AgentRuntimeSnapshot) {
        state.turnState = .inactive
        state.activityState = .idle
        state.interactionState = .none
    }

    /// Records `completion` once, unread unless the agent is viewed.
    private static func complete(
        _ completion: AgentCompletionID,
        isViewed: Bool,
        state: inout AgentRuntimeSnapshot,
        effects: inout [AgentRuntimeEffect]
    ) {
        guard state.lastAppliedCompletion != completion else { return }
        state.lastAppliedCompletion = completion
        effects.append(.completed)
        if !isViewed, state.unreadCompletion != completion {
            state.unreadCompletion = completion
            effects.append(.unreadChanged)
        }
    }

    /// Ends the turn as failed. A turn that has already failed only takes
    /// the new message, if there is one, and is not reported again.
    private static func failTurn(
        _ message: String?,
        state: inout AgentRuntimeSnapshot,
        effects: inout [AgentRuntimeEffect]
    ) {
        if state.runtimeErrorMessage == nil { effects.append(.failed) }
        endTurn(&state)
        state.runtimeErrorMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? state.runtimeErrorMessage
            ?? "The agent reported a runtime error."
    }

    private static func clearUnread(
        _ state: inout AgentRuntimeSnapshot,
        effects: inout [AgentRuntimeEffect]
    ) {
        guard state.unreadCompletion != nil else { return }
        state.unreadCompletion = nil
        effects.append(.unreadChanged)
    }

    /// The provider is seen alive. A launch whose provider has exited, or
    /// whose terminal has closed, is never alive again: a hook record that
    /// arrives after the exit report was written before the exit, and the
    /// event file delivered it late.
    private static func confirmProviderAlive(
        _ state: inout AgentRuntimeSnapshot,
        effects: inout [AgentRuntimeEffect]
    ) {
        guard state.processState == .notStarted || state.processState == .launching else { return }
        state.processState = .running
        state.failureMessage = nil
        state.resumingSessionID = nil
        effects.append(.becameAlive)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
