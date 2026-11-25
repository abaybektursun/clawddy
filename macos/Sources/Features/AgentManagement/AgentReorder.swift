import Foundation

/// Moving agents within their project (flows.md 3.5): by the keyboard, the
/// selected agents one place earlier or later; by the pointer, the moved
/// agents dropped into a gap, landing side by side in their order. Pure:
/// each takes the project's order and returns the new one, or nil when
/// nothing moves.
enum AgentReorder {
    /// ⌥← (`offset` -1) or ⌥→ (+1): every one of `moving` one place over,
    /// together; at either end nothing.
    static func step(_ ids: [UUID], moving: Set<UUID>, by offset: Int) -> [UUID]? {
        let places = ids.indices.filter { moving.contains(ids[$0]) }
        guard let first = places.first, let last = places.last, !places.isEmpty else { return nil }
        if offset < 0, first == 0 { return nil }
        if offset > 0, last == ids.count - 1 { return nil }
        var result = ids
        // The neighbour each moved agent passes goes to the other side.
        let order = offset < 0 ? places : places.reversed()
        for place in order {
            result.swapAt(place, place + offset)
        }
        return result
    }

    /// `moving`, in the project's order, dropped so the first of them lands
    /// at `gap`, a place in the order without them.
    static func drop(_ ids: [UUID], moving: Set<UUID>, at gap: Int) -> [UUID]? {
        let moved = ids.filter(moving.contains)
        var rest = ids.filter { !moving.contains($0) }
        guard !moved.isEmpty else { return nil }
        rest.insert(contentsOf: moved, at: min(max(gap, 0), rest.count))
        return rest == ids ? nil : rest
    }
}
