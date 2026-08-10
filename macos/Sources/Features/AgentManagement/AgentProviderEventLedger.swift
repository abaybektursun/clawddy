import Foundation

/// Exactly-once delivery barrier for one provider launch epoch. Journal byte
/// offsets make normal polling cheap; this ledger owns correctness if a file is
/// truncated, replaced, or replayed while that launch is still alive.
struct AgentProviderEventLedger {
    private var generation: UUID?
    private var appliedEventIDs: Set<String> = []

    mutating func shouldApply(eventID: String, generation: UUID) -> Bool {
        if self.generation != generation {
            self.generation = generation
            appliedEventIDs.removeAll(keepingCapacity: true)
        }
        return appliedEventIDs.insert(eventID).inserted
    }
}
