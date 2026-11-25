import AppKit
import Testing
@testable import Ghostty

/// The parts of the agent window, on their own: what they draw and when.
@MainActor
struct AgentChromeTests {
    /// A text layer draws once for its text, and not again until its text
    /// or its size changes.
    @Test func aTextLayerRedrawsOnlyWhenItsTextChanges() {
        let layer = AgentTextLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 200, height: 18)
        let text = AgentText(string: "Running the tests", font: AgentMetrics.body, color: CGColor(gray: 1, alpha: 1))
        layer.text = text
        layer.displayIfNeeded()
        #expect(layer.draws == 1)
        layer.text = text
        layer.frame = CGRect(x: 10, y: 0, width: 200, height: 18)
        layer.displayIfNeeded()
        #expect(layer.draws == 1)
        layer.text?.string = "Writing the tests"
        layer.displayIfNeeded()
        #expect(layer.draws == 2)
    }

    /// A long line ends in a real "…" within its width; wrapping keeps to
    /// its line count.
    @Test func textIsCutWithAnEllipsis() {
        var text = AgentText(string: "The alarm sounds the siren even when the phone is set to silent", font: AgentMetrics.body, color: CGColor(gray: 1, alpha: 1))
        let one = AgentTextLayer.lines(of: text, width: 120)
        #expect(one.count == 1)
        #expect(CTLineGetTypographicBounds(one[0], nil, nil, nil) <= 120)
        text.maxLines = 2
        #expect(AgentTextLayer.lines(of: text, width: 120).count == 2)
    }

    /// No project moves when another becomes current: a project's width does
    /// not depend on whether it is current.
    @Test func aProjectsWidthDoesNotDependOnBeingCurrent() {
        for name in ["tidepool", "field_notes", "paper-kite", "a-project-name-longer-than-24"] {
            let rest = AgentTopBar.Project(id: UUID(), name: name, agents: 4, waiting: 2, isCurrent: false)
            var current = rest
            current.isCurrent = true
            #expect(AgentProjectButton.width(of: rest) == AgentProjectButton.width(of: current), "\(name)")
        }
    }

    /// No project name moves when a waiting count appears, changes or goes:
    /// each project keeps a slot of two digits for its count.
    @Test func aProjectsWidthDoesNotDependOnItsWaitingCount() {
        for name in ["tidepool", "field_notes"] {
            let widths = [0, 1, 7, 12, 99].map { waiting in
                AgentProjectButton.width(of: AgentTopBar.Project(id: UUID(), name: name, agents: 4, waiting: waiting, isCurrent: false))
            }
            #expect(Set(widths).count == 1, "\(name): \(widths)")
        }
    }

    /// The working mark turns by one repeating animation while marks may
    /// turn, and stands still otherwise; no other state turns.
    @Test func onlyTheWorkingMarkTurnsAndOnlyWhileAllowed() {
        let working = AgentMarkLayer()
        let finished = AgentMarkLayer()
        working.state = .working
        finished.state = .finished
        AgentMarkLayer.setTurning(true)
        #expect(working.animation(forKey: "turn")?.repeatCount == .infinity)
        #expect(finished.animation(forKey: "turn") == nil)
        AgentMarkLayer.setTurning(false)
        #expect(working.animation(forKey: "turn") == nil)
        AgentMarkLayer.setTurning(true)
        #expect(working.animation(forKey: "turn") != nil)
        working.state = .finishedUnread
        #expect(working.animation(forKey: "turn") == nil)
    }

    /// Only an agent that waits on the person is news; a paused one is not.
    @Test func onlyAnAgentWaitingOnThePersonIsNews() {
        func agent(_ change: (inout AgentRecord) -> Void) -> AgentInstance {
            var runtime = AgentRuntimeSnapshot()
            change(&runtime.record)
            return AgentInstance(entry: AgentEntry(name: "agent"), runtime: runtime)
        }
        let paused = agent { $0.state = .paused }
        let asks = agent { $0.state = .asks }

        let header = AgentPaneHeader()
        header.showNews(paused)
        #expect(header.newsAgentID == nil)
        header.showNews(asks)
        #expect(header.newsAgentID == asks.id)
    }
}
