import Testing
@testable import Ghostty

struct AgentStateAggregationTests {
    @Test func emptyHierarchyHasNoDerivedState() {
        #expect(AgentStateAggregation.representative(of: [DisplayState]()) == nil)
    }

    @Test func attentionPropagatesAheadOfActiveAndIdleStates() {
        #expect(AgentStateAggregation.representative(
            of: [.idle, .working, .finished]) == .finished)
        #expect(AgentStateAggregation.representative(
            of: [.permission, .finished, .thinking]) == .permission)
        #expect(AgentStateAggregation.representative(
            of: [.working, .failed, .permission]) == .failed)
    }

    @Test func activeAndTransitionalPrecedenceIsDeterministic() {
        #expect(AgentStateAggregation.representative(
            of: [.inactive, .idle, .launching]) == .launching)
        #expect(AgentStateAggregation.representative(
            of: [.thinking, .working, .compacting]) == .compacting)
    }

    @Test func resultDoesNotDependOnDescendantOrder() {
        let forward: [DisplayState] = [.idle, .error, .failed, .working]
        #expect(AgentStateAggregation.representative(of: forward) == .failed)
        #expect(AgentStateAggregation.representative(of: forward.reversed()) == .failed)
    }
}
