import AppKit
import QuartzCore

/// Motion (flows.md 7, native-look.md 2.7): one curve, a few durations, and
/// the one way a layer property moves. Every movement is a Core Animation
/// animation the render server runs: the main thread sets the end state at
/// the key and adds the animation, and does nothing per frame. A movement
/// starts from what is on screen (the presentation value) when another of
/// the same layer and key path is running, so nothing queues and nothing
/// jumps; at most one animation runs per layer and key path.
@MainActor
enum AgentMotion {
    static let out = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    /// Fades that end something without a key.
    static let big: CFTimeInterval = 0.20
    /// Entering and leaving a terminal.
    static let zoom: CFTimeInterval = 0.16
    /// In-place changes the person causes; the end of a hover.
    static let small: CFTimeInterval = 0.15
    /// Things going away because of a key; every fade under Reduce Motion.
    static let gone: CFTimeInterval = 0.10
    /// A screen lighting.
    static let light: CFTimeInterval = 0.40
    /// A new tile's lighter background returning to its own.
    static let flash: CFTimeInterval = 1.40
    /// The tile's snapshot cross-fade, and the delay of the list and header,
    /// when entering and leaving.
    static let snapFade: CFTimeInterval = 0.05
    /// The palette's dim reaching full opacity.
    static let veilIn: CFTimeInterval = 0.075
    /// Runs `work` after the frame of the key is committed: a later turn of
    /// the run loop, whose sleep before it lets Core Animation commit what
    /// the key changed. For what the first frames do not show (a region
    /// that fades in after 50 ms), so the key's own frame does only what it
    /// shows.
    static func afterThisFrame(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { MainActor.assumeIsolated(work) }
    }

    /// Set by the harness to stand for the system's Reduce Motion, which no
    /// test may change; nil follows the system.
    static var reduceOverride: Bool?

    static var reduced: Bool { reduceOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// What a change is, for its duration (flows.md 7's Reduce Motion
    /// column): a movement translates, scales or resizes, and under Reduce
    /// Motion happens at once; a fade changes opacity or colour, and under
    /// Reduce Motion takes 100 ms.
    enum Change: Equatable {
        case move(CFTimeInterval)
        case fade(CFTimeInterval)
    }

    /// How long `change` takes: 0 (at once) while the window cannot be
    /// seen, so nothing animates unseen; else as Reduce Motion says.
    static func duration(_ change: Change, reduced: Bool, visible: Bool) -> CFTimeInterval {
        guard visible else { return 0 }
        switch change {
        case .move(let duration): return reduced ? 0 : duration
        case .fade(let duration): return reduced ? gone : duration
        }
    }

    /// `change`'s duration for a view in its window as it is now.
    static func duration(_ change: Change, in view: NSView?) -> CFTimeInterval {
        duration(change, reduced: reduced, visible: view?.window?.occlusionState.contains(.visible) ?? false)
    }

    /// Sets `keyPath` of `layer` to `value` and, over `duration`, moves it
    /// there on the one curve from what is on screen: the running
    /// animation's presentation value, else `start`, else the old value. A
    /// fresh start may hold part of the way (`hold`: the values at the
    /// given fractions of the time, each segment on the curve); a retarget
    /// never does. A duration of 0 sets the value at once.
    static func animate(
        _ layer: CALayer, _ keyPath: String, to value: Any?, duration: CFTimeInterval,
        from start: Any? = nil, hold: [(time: Double, value: Any?)] = []
    ) {
        let running = layer.animation(forKey: keyPath) != nil
        let from = running ? layer.presentation()?.value(forKeyPath: keyPath) : start ?? layer.value(forKeyPath: keyPath)
        layer.removeAnimation(forKey: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        guard duration > 0 else { return }
        let animation: CAAnimation
        if hold.isEmpty || running {
            let basic = CABasicAnimation(keyPath: keyPath)
            basic.fromValue = from
            basic.toValue = value
            basic.timingFunction = out
            animation = basic
        } else {
            let frames = CAKeyframeAnimation(keyPath: keyPath)
            frames.values = [from as Any] + hold.map { $0.value as Any } + [value as Any]
            frames.keyTimes = ([0] + hold.map(\.time) + [1]).map { NSNumber(value: $0) }
            frames.timingFunctions = Array(repeating: out, count: hold.count + 1)
            animation = frames
        }
        animation.duration = duration
        layer.add(animation, forKey: keyPath)
    }

    /// Fades `layer` to `opacity` over `duration` (100 ms under Reduce
    /// Motion, at once while unseen).
    static func fade(_ layer: CALayer, to opacity: Float, duration: CFTimeInterval, in view: NSView?) {
        animate(layer, "opacity", to: opacity, duration: self.duration(.fade(duration), in: view))
    }

    /// Runs `animations`, then `done` once every animation they added has
    /// ended or been replaced: on the animations' own clock (so a picture
    /// of a held clock sees them run), at once when they added none.
    static func run(_ animations: () -> Void, then done: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        animations()
        CATransaction.commit()
    }

    /// The one curve's progress at `t` of its time (0 to 1), for tests and
    /// for judging frames: the cubic Bézier (0.32, 0.72, 0, 1).
    static func progress(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        // Solve x(u) = t for u by bisection, then y(u).
        func bezier(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - u) * (1 - u) * u * p1 + 3 * (1 - u) * u * u * p2 + u * u * u
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if bezier(mid, 0.32, 0) < t { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, 0.72, 1)
    }
}
