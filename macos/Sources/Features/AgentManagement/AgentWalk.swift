import CoreGraphics
import Foundation

/// One walk through the agents waiting on the person (`docs/clawddy-design/
/// flows.md` 6.6, rulings 5 to 7, final review rulings 4 to 6): its order,
/// where it is, and where it began. A pure value; the workspace model holds
/// the one walk under way, and only the controller changes it.
///
/// The order is the waiting order (`AgentWaitingOrder`) at the first press,
/// without the agent shown then. Each agent is visited once for each time it
/// starts waiting: an agent passed without an answer is not visited again.
/// Agents that come to wait after the walk began join the end, in the same
/// order, and so does an agent that stopped waiting and came to wait again
/// after the walk passed it. Each press lands on the next agent of that order
/// that still waits; one that stopped waiting before it was reached is passed
/// over and no longer counted. The agent the person is on stays theirs while
/// it is on screen, whatever it does meanwhile. When no one is ahead, the
/// next press ends the walk.
struct AgentWalk: Equatable {
    /// Where the walk began, to return to exactly at its end.
    struct Origin: Equatable {
        var project: UUID?
        /// Home, or inside an agent.
        var view: AgentProjectView
        /// The selection at that project's home.
        var selection: AgentTileSelection
        /// How far home was scrolled.
        var scroll: CGFloat
        /// Every project's view as the walk found it: the projects it passes
        /// through keep the view they were left in.
        var views: [UUID: AgentProjectView]
    }

    /// An agent waiting on the person now, and since when (its state's last
    /// change, `AgentWaitingKey.since`).
    struct Waiting: Equatable {
        let id: UUID
        let since: Date
    }

    /// One place in the walk: an agent, and when the walk landed on it there.
    private struct Stop: Equatable {
        let id: UUID
        var landed: Date?
    }

    let origin: Origin
    /// The agent shown at the first press, which the walk visits only if it
    /// comes to wait again after `began`.
    private let shownAtStart: UUID?
    private let began: Date
    /// The stops in order: the first press's, then the arrivals (an agent
    /// may have a later stop again); an undone settle is inserted next.
    private var stops: [Stop]
    /// The stop on screen; nil before the first landing.
    private var current: Int?

    /// A walk over `waiting` (the waiting order now), without `shown`.
    init(origin: Origin, waiting: [Waiting], shown: UUID?, at now: Date) {
        self.origin = origin
        shownAtStart = shown
        began = now
        stops = waiting.filter { $0.id != shown }.map { Stop(id: $0.id) }
    }

    /// The agent on screen, landed on by the walk.
    var onScreen: UUID? { current.map { stops[$0].id } }

    /// Where the stops after the one on screen begin.
    private var nextIndex: Int { (current ?? -1) + 1 }

    /// The stops with the agents of `waiting` that join the end now: those
    /// with no stop yet or passed over before they were reached, and those
    /// landed on that came to wait again since. Never the agent on screen,
    /// never one landed on that has waited ever since.
    private func joined(_ waiting: [Waiting]) -> [Stop] {
        var all = stops
        for entry in waiting where entry.id != onScreen && !all[nextIndex...].contains(where: { $0.id == entry.id }) {
            let landed = stops.last { $0.id == entry.id }?.landed ?? (entry.id == shownAtStart ? began : nil)
            if landed.map({ entry.since > $0 }) ?? true { all.append(Stop(id: entry.id)) }
        }
        return all
    }

    /// The agents still ahead that wait now, in the walk's order.
    func ahead(waiting: [Waiting]) -> [UUID] {
        let now = Set(waiting.map(\.id))
        var seen: Set<UUID> = []
        return joined(waiting)[nextIndex...].map(\.id).filter { now.contains($0) && seen.insert($0).inserted }
    }

    /// "k of N": N is the stops of this walk, those landed on still counted
    /// while they wait since the landing, plus the one on screen and those
    /// still to come; k is the place of the one on screen. Moving on never
    /// lowers either; an agent settled or no longer waiting leaves the count.
    func position(waiting: [Waiting]) -> (at: Int, of: Int) {
        let next = ahead(waiting: waiting)
        let since = Dictionary(waiting.map { ($0.id, $0.since) }) { first, _ in first }
        var behind: Set<UUID> = []
        for stop in stops[..<(current ?? 0)] {
            if let landed = stop.landed, let waits = since[stop.id], waits <= landed { behind.insert(stop.id) }
        }
        behind.subtract(next)
        if let onScreen { behind.remove(onScreen) }
        let here = onScreen == nil ? 0 : 1
        return (behind.count + here, behind.count + here + next.count)
    }

    /// The top bar's words for the position (words.md).
    func words(waiting: [Waiting]) -> String {
        let (at, of) = position(waiting: waiting)
        return "\(at) of \(of) waiting"
    }

    /// The next press: the agent it lands on, or nil when no one is ahead
    /// and the walk returns to where it began.
    mutating func advance(waiting: [Waiting], at now: Date) -> UUID? {
        let waitingNow = Set(waiting.map(\.id))
        stops = joined(waiting)
        guard let next = stops.indices.dropFirst(nextIndex).first(where: { waitingNow.contains(stops[$0].id) }) else {
            return nil
        }
        stops[next].landed = now
        current = next
        return stops[next].id
    }

    /// Agents brought back by undoing their settle during the walk are its
    /// next stops (final review ruling 5), and nowhere later.
    mutating func comeNext(_ ids: [UUID]) {
        let later = stops[nextIndex...].filter { !ids.contains($0.id) }
        stops = Array(stops[..<nextIndex]) + ids.map { Stop(id: $0) } + later
    }

    /// The agents landed on, in order (an agent landed on twice twice).
    var visited: [UUID] { stops.compactMap { $0.landed == nil ? nil : $0.id } }

    /// The walk has landed on no one yet.
    var isEmpty: Bool { current == nil }
}
