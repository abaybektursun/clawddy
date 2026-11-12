import Foundation

// What `AgentBridge` needs from outside itself. Each production
// implementation is the code the bridge used to run inline, so behaviour is
// unchanged; a test passes its own to drive the bridge without real timers,
// queues, notifications, providers or terminals.

// MARK: - Scheduler

/// A timer the bridge can cancel.
protocol AgentTimer: AnyObject {
    func invalidate()
}

extension Timer: AgentTimer {}

/// The bridge's clock, timers and delayed calls.
@MainActor
protocol AgentScheduler {
    var now: Date { get }

    /// Runs `action` after `interval` seconds, and again every `interval`
    /// seconds if `repeats`, until the returned timer is invalidated.
    func timer(
        interval: TimeInterval,
        repeats: Bool,
        _ action: @escaping @MainActor () -> Void
    ) -> any AgentTimer

    /// Runs `action` once after `delay` seconds. It cannot be cancelled.
    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void)
}

/// Timers on the main run loop and delayed calls on the main queue, each
/// running its action in a main-actor task.
struct AgentRunLoopScheduler: AgentScheduler {
    /// Nonisolated so it can be a default argument.
    nonisolated init() {}

    var now: Date { Date() }

    func timer(
        interval: TimeInterval,
        repeats: Bool,
        _ action: @escaping @MainActor () -> Void
    ) -> any AgentTimer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            Task { @MainActor in action() }
        }
    }

    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in action() }
        }
    }
}

// MARK: - IO executor

/// Where the bridge's file and process work runs, and how it returns to the
/// main actor.
protocol AgentIOExecutor: Sendable {
    /// Runs `work` on the serial IO queue.
    func async(_ work: @escaping @Sendable () -> Void)
    /// Runs `work` on the serial IO queue and waits for it.
    func sync(_ work: @Sendable () -> Void)
    /// Runs a provider probe on the concurrent provider-health queue.
    func probe(_ work: @escaping @Sendable () -> Void)
    /// Runs `work` on the main actor in a new task.
    func onMainActor(_ work: @escaping @MainActor () -> Void)
    /// Runs `work` on the main dispatch queue.
    func onMainQueue(_ work: @escaping @MainActor () -> Void)
}

/// A serial queue for file work and a concurrent queue for provider probes,
/// one pair per bridge.
struct AgentDispatchIO: AgentIOExecutor {
    private let ioQueue = DispatchQueue(label: "clawddy.io", qos: .utility)
    private let healthQueue = DispatchQueue(
        label: "clawddy.provider-health",
        qos: .utility,
        attributes: .concurrent)

    func async(_ work: @escaping @Sendable () -> Void) {
        ioQueue.async(execute: work)
    }

    func sync(_ work: @Sendable () -> Void) {
        ioQueue.sync(execute: work)
    }

    func probe(_ work: @escaping @Sendable () -> Void) {
        healthQueue.async(execute: work)
    }

    func onMainActor(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }

    func onMainQueue(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { work() }
    }
}
