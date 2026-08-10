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
