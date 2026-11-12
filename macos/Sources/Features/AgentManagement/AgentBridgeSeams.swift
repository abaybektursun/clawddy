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

// MARK: - Providers

/// How the bridge reaches its providers, one closure per operation, so a
/// test can replace any of them.
struct AgentProviderTable: Sendable {
    var capabilities: @Sendable (AgentProviderID) -> AgentProviderCapabilities
    var prepareIntegration: @Sendable (AgentProviderID) -> Result<AgentIntegrationPreparation, AgentProviderIssue>
    /// Prepares the launch for the request's provider.
    var prepareLaunch: @Sendable (AgentLaunchRequest) -> Result<AgentPreparedLaunch, AgentProviderIssue>
    var normalize: @Sendable (AgentProviderID, AgentRawProviderEvent) -> [AgentDomainEvent]
    /// Probes installation and sign-in with the given PATH.
    var probe: @Sendable (AgentProviderID, String) -> AgentProviderHealth
    /// Removes the provider's files for the agent with this ID.
    var cleanup: @Sendable (AgentProviderID, UUID) -> Void
}

extension AgentProviderTable {
    /// Every operation answered by the registry's adapter for the provider.
    init(registry: AgentProviderRegistry) {
        self.init(
            capabilities: { registry.capabilities(for: $0) },
            prepareIntegration: { registry.adapter(for: $0).prepareIntegration() },
            prepareLaunch: { registry.adapter(for: $0.provider).prepareLaunch($0) },
            normalize: { registry.adapter(for: $0).normalize($1) },
            probe: { registry.adapter(for: $0).probe(environmentPath: $1) },
            cleanup: { registry.adapter(for: $0).cleanup(agentID: $1) })
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
    /// Reports each surface whose process has exited to the bridge as closed.
    func reportExitedSurfaces()
    func removeSurface(id: UUID)
}

extension AgentDetailViewController: AgentSurfaceHost {}

/// Reports one agent surface to the bridge, tagged with the agent and the
/// launch the surface was created for: its close, and each program-status
/// report. The host calls this in the same main-thread turn that creates the
/// surface, so no report is missed, and removes the returned observers when
/// it drops the surface.
func observeAgentSurface(
    _ surface: AnyObject,
    agentID: UUID,
    generation: UUID?,
    bridge: AgentBridge
) -> [NSObjectProtocol] {
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
    return [close, status]
}
