import Foundation

/// Defines the stable, user-visible order of agents.
///
/// Configuration arrays are the source of truth: project order, then task
/// order, then agent insertion order. Runtime state must never affect rank.
enum AgentOrdering {
    static func ranks<IDs: Sequence>(in ids: IDs) -> [UUID: Int]
    where IDs.Element == UUID {
        var result: [UUID: Int] = [:]
        for id in ids where result[id] == nil {
            result[id] = result.count
        }
        return result
    }

    static func precedes(_ lhs: UUID, _ rhs: UUID, ranks: [UUID: Int]) -> Bool {
        let left = ranks[lhs] ?? Int.max
        let right = ranks[rhs] ?? Int.max
        if left != right { return left < right }
        return lhs.uuidString < rhs.uuidString
    }
}
