import SwiftUI

// MARK: - Display State (derived, never stored)

enum DisplayState: Equatable, Sendable {
    case inactive
    case launching
    case idle
    case finished       // alive + idle + unread
    case thinking
    case working
    case permission
    case input
    case authentication
    case error
    case compacting
    case statusDelayed
    case statusUnavailable
    case failed
    case dead

    var color: Color {
        switch self {
        case .inactive:     return .secondary.opacity(0.3)
        case .launching:    return .secondary
        case .idle:         return .secondary
        case .finished:     return .yellow
        case .thinking:     return .blue
        case .working:      return .green
        case .permission, .input, .authentication, .statusDelayed,
                .statusUnavailable: return .orange
        case .error, .failed: return .red
        case .compacting:   return .purple
        case .dead:         return .secondary.opacity(0.3)
        }
    }

    var selectionTint: Color {
        switch self {
        case .finished:     return .yellow
        case .thinking:     return .blue
        case .working:      return .green
        case .permission, .input, .authentication: return .orange
        case .statusDelayed, .statusUnavailable: return .orange
        case .error, .failed: return .red
        case .compacting:   return .purple
        default:            return .accentColor
        }
    }

    var label: String {
        switch self {
        case .inactive:     return "Not Started"
        case .launching:    return "Starting"
        case .idle:         return "Ready"
        case .finished:     return "Completed"
        case .thinking:     return "Thinking"
        case .working:      return "Working"
        case .permission:   return "Waiting for You"
        case .input:        return "Input Required"
        case .authentication: return "Sign In Required"
        case .error:        return "Needs Attention"
        case .compacting:   return "Optimizing Context"
        case .statusDelayed: return "Status Delayed"
        case .statusUnavailable: return "Status Unavailable"
        case .failed:       return "Couldn't Start"
        case .dead:         return "Exited"
        }
    }

    /// Untouched agents are already communicated by the quiet empty-circle
    /// glyph. Repeating "Not Started" for every row overwhelms useful state
    /// changes in dense workspaces, while the detail header and accessibility
    /// value continue to expose the full lifecycle state.
    var showsListLabel: Bool {
        self != .inactive
    }

    var iconName: String? {
        switch self {
        case .inactive:     return nil
        case .launching:    return "circle.dotted"
        case .idle:         return "moon.fill"
        case .finished:     return "bell.badge.fill"
        case .thinking:     return "brain"
        case .working:      return "bolt.fill"
        case .permission:   return "exclamationmark.circle.fill"
        case .input:        return "keyboard.fill"
        case .authentication: return "person.crop.circle.badge.exclamationmark"
        case .error:        return "xmark.circle.fill"
        case .compacting:   return "arrow.triangle.2.circlepath"
        case .statusDelayed: return "clock.badge.exclamationmark"
        case .statusUnavailable: return "exclamationmark.circle"
        case .failed:       return "exclamationmark.triangle.fill"
        case .dead:         return "xmark"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .finished, .permission, .input, .authentication, .error, .failed: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .launching, .thinking, .working, .compacting: return true
        default: return false
        }
    }
}

extension AgentInstance {
    var displayState: DisplayState {
        if failureMessage != nil { return .failed }
        if runtimeErrorMessage != nil { return .error }
        switch interactionState {
        case .permission: return .permission
        case .input: return .input
        case .authentication: return .authentication
        case .none: break
        }
        // Completion is durable user-attention state. A provider or surface
        // exit must not hide work that the user has not reviewed yet.
        if unreadCompletion != nil { return .finished }
        switch surfaceState {
        case .inactive: return .inactive
        case .opening: return .launching
        case .failed: return .failed
        case .closed: return .dead
        case .open: break
        }
        if processState == .exited { return .dead }
        if telemetryHealth == .delayed { return .statusDelayed }
        switch activityState {
        case .unknown:
            if case .unavailable = telemetryHealth { return .statusUnavailable }
            return .launching
        case .idle: return .idle
        case .reasoning: return .thinking
        case .executing: return .working
        case .compacting: return .compacting
        }
    }
}

/// Derives one representative state for a task or project from its descendant
/// agents. Parent state is never stored; every render derives it from the same
/// live AgentInstance values used by agent rows.
enum AgentStateAggregation {
    static func representative<States: Sequence>(
        of states: States
    ) -> DisplayState? where States.Element == DisplayState {
        states.max {
            AgentStatePriority.value(of: $0) < AgentStatePriority.value(of: $1)
        }
    }
}
