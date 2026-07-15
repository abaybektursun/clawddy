import Testing
@testable import Ghostty

struct AgentStateReducerTests {
    @Test func completionBecomesUnreadWhenAgentIsNotViewed() {
        let working = AgentRuntimeSnapshot(
            processState: .alive,
            claudeState: .working,
            isUnread: false)

        let result = AgentStateReducer.reduce(
            working,
            event: .hook(.idle, isViewed: false))

        #expect(result.state.claudeState == .idle)
        #expect(result.state.isUnread)
        #expect(result.effects.contains(.completed))
        #expect(result.effects.contains(.unreadChanged))
    }

    @Test func viewedCompletionDoesNotBecomeUnread() {
        let working = AgentRuntimeSnapshot(
            processState: .alive,
            claudeState: .thinking,
            isUnread: false)

        let result = AgentStateReducer.reduce(
            working,
            event: .hook(.idle, isViewed: true))

        #expect(!result.state.isUnread)
        #expect(result.effects.contains(.completed))
        #expect(!result.effects.contains(.unreadChanged))
    }

    @Test func viewingCompletedAgentAcknowledgesOnlyThatCompletion() {
        var state = AgentRuntimeSnapshot(
            processState: .alive,
            claudeState: .idle,
            isUnread: true)

        let acknowledged = AgentStateReducer.reduce(state, event: .completionViewed)
        state = acknowledged.state
        #expect(!state.isUnread)
        #expect(acknowledged.effects == [.unreadChanged])

        let repeated = AgentStateReducer.reduce(state, event: .completionViewed)
        #expect(repeated.state == state)
        #expect(repeated.effects.isEmpty)

        state = AgentStateReducer.reduce(
            state,
            event: .hook(.working, isViewed: false)).state
        let nextCompletion = AgentStateReducer.reduce(
            state,
            event: .hook(.idle, isViewed: false))
        #expect(nextCompletion.state.isUnread)
        #expect(nextCompletion.effects.contains(.completed))
        #expect(nextCompletion.effects.contains(.unreadChanged))
    }

    @Test func orderedBurstPreservesCompletionTransition() {
        var state = AgentRuntimeSnapshot(processState: .launching)
        var effects = Set<AgentRuntimeEffect>()

        for hook in [ClaudeState.thinking, .working, .idle] {
            let result = AgentStateReducer.reduce(
                state,
                event: .hook(hook, isViewed: false))
            state = result.state
            effects.formUnion(result.effects)
        }

        #expect(state.processState == .alive)
        #expect(state.claudeState == .idle)
        #expect(state.isUnread)
        #expect(effects.contains(.becameAlive))
        #expect(effects.contains(.completed))
    }

    @Test func launchTimeoutReportsUnavailableStatusAndRecovers() {
        var state = AgentRuntimeSnapshot(processState: .launching)
        state = AgentStateReducer.reduce(state, event: .launchTimedOut).state
        #expect(state.processState == .unconfirmed)
        #expect(state.failureMessage == "The terminal is running, but agent activity status is unavailable.")

        let recovered = AgentStateReducer.reduce(
            state,
            event: .hook(.idle, isViewed: true))
        #expect(recovered.state.processState == .alive)
        #expect(recovered.state.failureMessage == nil)
        #expect(recovered.effects.contains(.becameAlive))
    }

    @Test func compactionExpiryOnlyChangesCompactingState() {
        let compacting = AgentRuntimeSnapshot(
            processState: .alive,
            claudeState: .compacting)
        let expired = AgentStateReducer.reduce(compacting, event: .compactionExpired)
        #expect(expired.state.claudeState == .idle)

        let working = AgentRuntimeSnapshot(
            processState: .alive,
            claudeState: .working)
        let unchanged = AgentStateReducer.reduce(working, event: .compactionExpired)
        #expect(unchanged.state == working)
    }
}
