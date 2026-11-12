import Combine
import Foundation
@preconcurrency import UserNotifications
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentBridge")

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
    /// Runs `work` on the global utility queue, in no order with the IO queue.
    func global(_ work: @escaping @Sendable () -> Void)
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

    func global(_ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    func onMainActor(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }

    func onMainQueue(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { work() }
    }
}

// MARK: - Notifier

/// Where the bridge's user notifications go.
@MainActor
protocol AgentNotifier {
    func post(_ request: UNNotificationRequest)
    func removeNotifications(withIdentifiers identifiers: [String])
}

/// The user notification center, asking for permission at the first post.
struct AgentUserNotificationCenter: AgentNotifier {
    // Nonisolated so it can be a default argument; the synthesized one
    // would be main-actor isolated.
    // swiftlint:disable:next unneeded_synthesized_initializer
    nonisolated init() {}

    func post(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request) { error in
                    if let error {
                        logger.error("notification failed: \(error.localizedDescription)")
                    }
                }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        logger.error("notification authorization failed: \(error.localizedDescription)")
                    } else if granted {
                        center.add(request) { error in
                            if let error {
                                logger.error("notification failed: \(error.localizedDescription)")
                            }
                        }
                    }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    func removeNotifications(withIdentifiers identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

// MARK: - Diagnostics

/// Where the bridge reports what it did, failed to do or chose to ignore,
/// as a log level and a message. It can be called from any thread.
typealias AgentDiagnosticsSink = @Sendable (OSLogType, String) -> Void

enum AgentDiagnostics {
    /// The unified log, in the bridge's category. The whole message is
    /// public, including the agent IDs in it.
    static let unifiedLog: AgentDiagnosticsSink = { level, message in
        logger.log(level: level, "\(message, privacy: .public)")
    }
}

// MARK: - Surface host

/// What presents agent terminals for the bridge; `AgentDetailViewController`
/// is the production host. It is passed to each activation, and the bridge
/// keeps only a weak reference to the last one. The host is the only owner
/// of agent surfaces: it creates each one from its own app, observes it with
/// `observeAgentSurface`, and drops its observers with it.
@MainActor
protocol AgentSurfaceHost: AnyObject {
    func hasSurface(id: UUID) -> Bool
    func selectAgent(_ agent: AgentInstance, projectName: String)
    @discardableResult
    func showOrSwitch(
        projectName: String,
        agent: AgentInstance,
        focusTerminal: Bool,
        select: Bool,
        createConfig: () -> Ghostty.SurfaceConfiguration?
    ) -> Bool
    /// Presents the agent's terminal and returns whether it was newly created.
    @discardableResult
    func presentPreparedSurface(
        projectName: String,
        agent: AgentInstance,
        createConfig: () -> Ghostty.SurfaceConfiguration?
    ) -> Bool
    /// Asks the user before closing the agent's terminal while its process
    /// runs, and calls `close` only if they agree.
    func confirmClose(id: UUID, then close: @escaping @MainActor () -> Void)
    func removeSurface(id: UUID)
}

extension AgentDetailViewController: AgentSurfaceHost {}

/// Reports one agent surface to the bridge, tagged with the agent and the
/// launch the surface was created for: its close, the exit of its process,
/// and each program-status report. `childExited` publishes when Ghostty shows
/// that the process exited, which after an abnormally short run, or with
/// `wait-after-command`, it does without closing the terminal. The host calls
/// this in the same main-thread turn that creates the surface, so no report
/// is missed, and cancels the returned observations when it drops the surface.
func observeAgentSurface(
    _ surface: AnyObject,
    childExited: some Publisher<Void, Never>,
    agentID: UUID,
    generation: UUID?,
    bridge: AgentBridge
) -> [AnyCancellable] {
    let center = NotificationCenter.default
    let close = center.addObserver(
        forName: Ghostty.Notification.ghosttyCloseSurface,
        object: surface,
        queue: .main
    ) { [weak bridge] notification in
        let processAlive = notification.userInfo?["process_alive"] as? Bool ?? false
        // Closing frees the surface, which must not happen inside the app
        // tick that posted this.
        Task { @MainActor [bridge] in
            bridge?.surfaceClosed(id: agentID, generation: generation, processAlive: processAlive)
        }
    }
    let exit = childExited.sink { [weak bridge] in
        // Published inside the app tick too, so reported after it.
        Task { @MainActor [bridge] in
            bridge?.surfaceClosed(id: agentID, generation: generation, processAlive: false)
        }
    }
    let status = center.addObserver(
        forName: .ghosttyDidReceiveProgramStatus,
        object: surface,
        queue: .main
    ) { [weak bridge] notification in
        guard let report = notification.userInfo?[Notification.Name.ProgramStatusKey]
            as? Ghostty.Action.ProgramStatus
        else { return }
        // Inline, so reports apply in the order the program sent them.
        MainActor.assumeIsolated {
            bridge?.programStatus(id: agentID, generation: generation, report: report)
        }
    }
    return [
        AnyCancellable { center.removeObserver(close) },
        AnyCancellable { center.removeObserver(status) },
        exit,
    ]
}

// MARK: - Status observations

/// Something observed about one launch of an agent. Every observation
/// reaches the agent's state through `AgentBridge.ingest(_:)`, which drops
/// one that belongs to another launch.
struct AgentStatusObservation: Equatable, Sendable {
    /// Where the observation was made.
    enum Source: Equatable, Sendable {
        /// The agent's event file, which its hooks append to.
        case hookJournal
        /// The agent's terminal.
        case surface
    }

    enum Event: Equatable, Sendable {
        /// A record the agent's hook or launch script wrote.
        case hook(AgentRawProviderEvent)
        /// The terminal closed, or its process exited; `processAlive` when
        /// closing it would kill a running process.
        case surfaceClosed(processAlive: Bool)
        /// A program-status report the terminal received.
        case programStatus(Ghostty.Action.ProgramStatus)
    }

    let agentID: UUID
    /// The launch the observation belongs to.
    let generation: UUID?
    let source: Source
    let event: Event
}
