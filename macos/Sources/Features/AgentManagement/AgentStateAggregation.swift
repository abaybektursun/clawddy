/// Derives one representative state for a task or project from its descendant
/// agents. Parent state is never stored; every render derives it from the same
/// live AgentInstance values used by agent rows.
enum AgentStateAggregation {
    static func representative<States: Sequence>(
        of states: States
    ) -> DisplayState? where States.Element == DisplayState {
        states.max { priority(of: $0) < priority(of: $1) }
    }

    /// Attention outranks activity, which outranks lifecycle transitions and
    /// rest. Ordering within each family is deterministic and severity-first.
    private static func priority(of state: DisplayState) -> Int {
        switch state {
        case .failed: return 110
        case .error: return 100
        case .permission: return 90
        case .finished: return 80
        case .statusUnavailable: return 70
        case .compacting: return 60
        case .working: return 50
        case .thinking: return 40
        case .launching: return 30
        case .idle: return 20
        case .inactive: return 10
        case .dead: return 0
        }
    }
}
