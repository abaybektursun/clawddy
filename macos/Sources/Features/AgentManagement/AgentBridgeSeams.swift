import Foundation
import GhosttyKit
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

/// A presented agent terminal. It posts `Ghostty.Notification.ghosttyCloseSurface`
/// with itself as the object when it closes, and knows whether its process
/// has exited.
@MainActor
protocol AgentSurface: AnyObject {
    var processExited: Bool { get }
}

extension Ghostty.SurfaceView: AgentSurface {}

/// What presents agent terminals for the bridge. It is passed to each
/// activation rather than held by the bridge; `AgentDetailViewController`
/// is the production host.
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
        createConfig: () -> (ghostty_app_t, Ghostty.SurfaceConfiguration)?
    ) -> Bool
    /// Presents the agent's terminal and returns whether it was newly created.
    @discardableResult
    func presentPreparedSurface(
        projectName: String,
        agent: AgentInstance,
        createConfig: () -> (ghostty_app_t, Ghostty.SurfaceConfiguration)?
    ) -> Bool
    func agentSurface(for id: UUID) -> (any AgentSurface)?
    func removeSurface(id: UUID)
}

extension AgentDetailViewController: AgentSurfaceHost {
    func agentSurface(for id: UUID) -> (any AgentSurface)? { surfaceView(for: id) }
}
