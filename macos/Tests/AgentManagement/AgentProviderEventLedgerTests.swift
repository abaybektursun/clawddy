import Foundation
import Testing
@testable import Ghostty

struct AgentProviderEventLedgerTests {
    @Test func providerFactsApplyExactlyOnceWithinALaunchEpoch() {
        var ledger = AgentProviderEventLedger()
        let generation = UUID()

        let firstStart = ledger.shouldApply(eventID: "turn-start:0", generation: generation)
        let replayedStart = ledger.shouldApply(eventID: "turn-start:0", generation: generation)
        let completion = ledger.shouldApply(eventID: "turn-complete:0", generation: generation)

        #expect(firstStart)
        #expect(!replayedStart)
        #expect(completion)
    }

    @Test func newerLaunchEpochCanReuseAnEventIdentifier() {
        var ledger = AgentProviderEventLedger()
        let oldGeneration = UUID()
        let newGeneration = UUID()

        let oldLaunch = ledger.shouldApply(eventID: "event", generation: oldGeneration)
        let newLaunch = ledger.shouldApply(eventID: "event", generation: newGeneration)
        let replayedNewLaunch = ledger.shouldApply(eventID: "event", generation: newGeneration)

        #expect(oldLaunch)
        #expect(newLaunch)
        #expect(!replayedNewLaunch)
    }
}
