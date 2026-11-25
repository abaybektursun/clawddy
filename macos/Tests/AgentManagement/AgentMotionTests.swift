import AppKit
import QuartzCore
import Testing
@testable import Ghostty

/// Motion's decisions (flows.md 7, native-look.md 2.7): durations under
/// Reduce Motion and while unseen, the enter and leave motion's kind, the
/// one curve, and the one way a layer property moves.
@MainActor
struct AgentMotionTests {
    /// A movement happens at once under Reduce Motion; a fade takes 100 ms;
    /// nothing animates while the window cannot be seen.
    @Test func reduceMotionAndAnUnseenWindowDecideTheDuration() {
        #expect(AgentMotion.duration(.move(0.16), reduced: false, visible: true) == 0.16)
        #expect(AgentMotion.duration(.move(0.16), reduced: true, visible: true) == 0)
        #expect(AgentMotion.duration(.fade(0.40), reduced: false, visible: true) == 0.40)
        #expect(AgentMotion.duration(.fade(0.40), reduced: true, visible: true) == AgentMotion.gone)
        for change in [AgentMotion.Change.move(0.15), .fade(0.15)] {
            for reduced in [false, true] {
                #expect(AgentMotion.duration(change, reduced: reduced, visible: false) == 0)
            }
        }
        // Every duration is the table's.
        #expect([AgentMotion.big, AgentMotion.zoom, AgentMotion.small, AgentMotion.gone, AgentMotion.light, AgentMotion.flash]
            == [0.20, 0.16, 0.15, 0.10, 0.40, 1.40])
    }

    /// Entering or leaving grows from a tile in view; without one, or under
    /// Reduce Motion, the views cross-fade (100 ms under Reduce Motion);
    /// unseen, at once.
    @Test func theZoomsKind() {
        #expect(AgentWindowView.zoomKind(tileInView: true, reduced: false, visible: true)?.kind == .grow)
        #expect(AgentWindowView.zoomKind(tileInView: true, reduced: false, visible: true)?.duration == 0.16)
        #expect(AgentWindowView.zoomKind(tileInView: false, reduced: false, visible: true)?.kind == .fade)
        #expect(AgentWindowView.zoomKind(tileInView: false, reduced: false, visible: true)?.duration == 0.15)
        #expect(AgentWindowView.zoomKind(tileInView: true, reduced: true, visible: true)?.kind == .fade)
        #expect(AgentWindowView.zoomKind(tileInView: true, reduced: true, visible: true)?.duration == 0.10)
        #expect(AgentWindowView.zoomKind(tileInView: true, reduced: false, visible: false) == nil)
    }

    /// The one curve, cubic-bezier(.32, .72, 0, 1): a fifth of the change in
    /// the first sixth of the time, and monotonic.
    @Test func theOneCurve() {
        #expect(AgentMotion.progress(0) == 0)
        #expect(AgentMotion.progress(1) == 1)
        #expect(AgentMotion.progress(1.0 / 6) > 0.2)
        var last = 0.0
        for step in 1...100 {
            let value = AgentMotion.progress(Double(step) / 100)
            #expect(value >= last)
            last = value
        }
        #expect(abs(AgentMotion.progress(0.5) - 0.9548) < 0.001)
    }

    /// A movement sets the end value at once and adds one animation from the
    /// old value; another for the same key path replaces it (from what is
    /// on screen, never queued); a fresh start may hold part of the way, a
    /// retarget never does; a duration of 0 is at once.
    @Test func oneAnimationPerKeyPathRetargetedFromTheScreen() throws {
        let layer = CALayer()
        layer.opacity = 1
        AgentMotion.animate(layer, "opacity", to: Float(0), duration: 0.16, hold: [(0.5, Float(0))])
        #expect(layer.opacity == 0)
        let first = try #require(layer.animation(forKey: "opacity") as? CAKeyframeAnimation)
        #expect(first.keyTimes == [0, 0.5, 1])
        #expect(first.values?.first as? Float == 1)
        AgentMotion.animate(layer, "opacity", to: Float(1), duration: 0.16, hold: [(0.5, Float(1))])
        #expect(layer.animationKeys() == ["opacity"])
        #expect(layer.animation(forKey: "opacity") is CABasicAnimation)
        #expect(layer.opacity == 1)
        AgentMotion.animate(layer, "opacity", to: Float(0.5), duration: 0)
        #expect(layer.animationKeys() == nil)
        #expect(layer.opacity == 0.5)
    }

    /// Ending when its animations end, on their own clock: a held clock
    /// holds the end too.
    @Test func theEndFollowsTheAnimationsClock() async throws {
        let layer = CALayer()
        var ended = false
        AgentMotion.run({
            AgentMotion.animate(layer, "opacity", to: Float(0), duration: 0.05)
        }, then: { ended = true })
        try await Task.sleep(for: .milliseconds(300))
        #expect(ended)
    }
}
