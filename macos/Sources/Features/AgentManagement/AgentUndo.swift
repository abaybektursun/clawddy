import CoreGraphics
import Foundation

/// A project's home as it was left: its selection and how far it was
/// scrolled.
struct AgentProjectHome: Equatable {
    var selection: AgentTileSelection
    var scroll: CGFloat
}

/// One undoable action of the session (flows.md 3.4). Undo lasts for the
/// session: a relaunch starts with none.
enum AgentUndoable: Equatable {
    /// An agent started from the line or the floating new-agent line.
    case started(id: UUID, name: String, at: Date)
    /// Agents settled together, in their project.
    case settled([UUID], project: UUID)
    /// A project removed: its place in the bar, the agents its removal
    /// settled, the view it was left in, with its home's selection and
    /// scroll, and whether it was the current project.
    case removedProject(UUID, index: Int, agents: [UUID], view: AgentProjectView, home: AgentProjectHome, wasCurrent: Bool)

    /// Edit ▸ Undo's title for it (words.md, "Other menus").
    var menuTitle: String {
        switch self {
        case .started: "Undo start"
        case .settled: "Undo settle"
        case .removedProject: "Undo remove project"
        }
    }
}

/// The one list of undoable actions (rulings 8 and 10): the newest last.
/// ⌘Z undoes the newest action that still applies, from anywhere, except a
/// start: a start is cancelled only where starts happen (the empty home line
/// or the empty floating new-agent line), and elsewhere, while it can still
/// be cancelled, it is the last action and nothing older is undone. A start
/// that can no longer be cancelled says "Too late" where starts happen and is
/// passed over elsewhere. Actions that no longer apply (agents brought back
/// another way, a project back in the bar, a start's agent gone) are passed
/// over everywhere.
struct AgentUndoList: Equatable {
    private(set) var actions: [AgentUndoable] = []

    /// What ⌘Z does.
    enum Outcome: Equatable {
        case undo(AgentUndoable)
        /// A start that can no longer be cancelled, where starts happen.
        case tooLate
        case nothing
    }

    /// A new action: any start before it stops being undoable, since it
    /// is no longer the last action (S7 review ruling 4).
    mutating func push(_ action: AgentUndoable) {
        endStarts()
        actions.append(action)
    }

    /// Starts stop being undoable: something else happened (a project
    /// switch, an edit in the field).
    mutating func endStarts() {
        actions.removeAll { if case .started = $0 { true } else { false } }
    }

    /// Takes the action ⌘Z undoes at a place where starts happen
    /// (`inStartPlace`) or not. `applies` says whether an action still
    /// applies; `cancellable` whether a start is within its time and its
    /// agent still works. `startsOnly`: the empty floating new-agent line,
    /// where ⌘Z cancels a start or does nothing, never restoring a settle or
    /// a project (ruling 10).
    mutating func take(
        inStartPlace: Bool,
        startsOnly: Bool = false,
        applies: (AgentUndoable) -> Bool,
        cancellable: (UUID, Date) -> Bool
    ) -> Outcome {
        while let top = actions.last {
            guard applies(top) else {
                actions.removeLast()
                continue
            }
            if startsOnly, case .started = top {} else if startsOnly { return .nothing }
            if case .started(let id, _, let at) = top {
                if inStartPlace {
                    actions.removeLast()
                    return cancellable(id, at) ? .undo(top) : .tooLate
                }
                if cancellable(id, at) { return .nothing }
                actions.removeLast()
                continue
            }
            actions.removeLast()
            return .undo(top)
        }
        return .nothing
    }

    /// What ⌘Z would undo now at such a place, without taking it: Edit ▸
    /// Undo's title and the settled places' Undo.
    func peek(
        inStartPlace: Bool,
        startsOnly: Bool = false,
        applies: (AgentUndoable) -> Bool,
        cancellable: (UUID, Date) -> Bool
    ) -> AgentUndoable? {
        var copy = self
        if case .undo(let action) = copy.take(
            inStartPlace: inStartPlace, startsOnly: startsOnly, applies: applies, cancellable: cancellable) {
            return action
        }
        return nil
    }
}
