import Foundation

struct AgentRuntimeSnapshot: Equatable {
    var processState: ProcessState = .inactive
    var claudeState: ClaudeState = .unknown
    var isUnread = false
    var failureMessage: String?
}

enum AgentRuntimeEvent: Equatable {
    case launchRequested
    case launchTimedOut
    case launchFailed(String)
    case hook(ClaudeState, isViewed: Bool)
    case compactionExpired
    case surfaceDied
    case completionViewed
}

enum AgentRuntimeEffect: Hashable {
    case becameAlive
    case completed
    case waitingForUser
    case failed
    case unreadChanged
}

enum AgentStateReducer {
    static func reduce(
        _ current: AgentRuntimeSnapshot,
        event: AgentRuntimeEvent
    ) -> (state: AgentRuntimeSnapshot, effects: Set<AgentRuntimeEffect>) {
        var state = current
        var effects = Set<AgentRuntimeEffect>()

        switch event {
        case .launchRequested:
            state.processState = .launching
            state.claudeState = .unknown
            state.failureMessage = nil

        case .launchTimedOut:
            guard state.processState == .launching else { break }
            state.processState = .unconfirmed
            state.failureMessage = "The terminal is running, but agent activity status is unavailable."

        case .launchFailed(let message):
            state.processState = .failed
            state.failureMessage = message
            effects.insert(.failed)

        case .hook(let newClaudeState, let isViewed):
            let oldClaudeState = state.claudeState
            if state.processState == .launching || state.processState == .unconfirmed
                || state.processState == .failed {
                state.processState = .alive
                state.failureMessage = nil
                effects.insert(.becameAlive)
            }
            state.claudeState = newClaudeState

            if oldClaudeState.isActiveState && newClaudeState == .idle {
                effects.insert(.completed)
                if !isViewed && !state.isUnread {
                    state.isUnread = true
                    effects.insert(.unreadChanged)
                }
            }
            if newClaudeState.isActiveState && state.isUnread {
                state.isUnread = false
                effects.insert(.unreadChanged)
            }
            if newClaudeState == .permission && oldClaudeState != .permission {
                effects.insert(.waitingForUser)
            }
            if newClaudeState == .error && oldClaudeState != .error {
                effects.insert(.failed)
            }

        case .surfaceDied:
            state.processState = .dead
            state.claudeState = .unknown
            state.failureMessage = nil

        case .compactionExpired:
            if state.claudeState == .compacting {
                state.claudeState = .idle
            }

        case .completionViewed:
            if state.isUnread {
                state.isUnread = false
                effects.insert(.unreadChanged)
            }
        }

        return (state, effects)
    }
}
