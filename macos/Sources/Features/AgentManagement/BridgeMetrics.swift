import Foundation
import os

/// Surgical metrics for diagnosing freezes.
///
/// Accumulates counters from any thread, flushes summary every 5s on a background queue.
/// Watchdog pings main thread every 1s; logs alert if delta > 3s (main thread stalled).
///
/// View in Console.app: subsystem com.mitchellh.ghostty, category Metrics
final class BridgeMetrics {
    static let shared = BridgeMetrics()

    private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "Metrics")
    private let queue = DispatchQueue(label: "clawddy.metrics", qos: .utility)

    // Atomic counters (touched from any thread, mutated under queue)
    private var watcherFires = 0
    private var pollsFired = 0
    private var pollsThrottled = 0
    private var applyRawEventsCalls = 0
    private var applyRawEventsTotalMs = 0.0
    private var applyRawEventsMaxMs = 0.0
    private var configWatcherFires = 0
    private var configReloads = 0
    private var configReloadsDeduped = 0
    private var processExitNotifs = 0
    private var heartbeats = 0
    private var aggregateChanges = 0
    private var dockBadgeUpdates = 0

    // Per-property mutation counts (only counted when value actually changed)
    private var mutClaudeState = 0
    private var mutProcessState = 0
    private var mutIsUnread = 0
    private var mutAgentName = 0
    private var mutLastEventContent = 0
    private var mutLastAggregateState = 0
    private var mutAgentsDict = 0   // add/remove from bridge.agents

    // Surface lifecycle
    private var surfacesCreated = 0
    private var surfacesDestroyedExit = 0
    private var surfacesDestroyedDelete = 0

    // Watchdog state (queue-isolated)
    private var lastMainPing = Date()
    private var maxStallSec = 0.0
    private var stallAlertCount = 0
    private var wasStalled = false  // for capturing on stall onset

    // Periodic flush + watchdog timers
    private var flushTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?

    private init() {}

    // MARK: - Public recording API (call from any thread; cheap)

    func recordWatcherFire()           { queue.async { self.watcherFires += 1 } }
    func recordPollFired()             { queue.async { self.pollsFired += 1 } }
    func recordPollThrottled()         { queue.async { self.pollsThrottled += 1 } }
    func recordConfigWatcherFire()     { queue.async { self.configWatcherFires += 1 } }
    func recordConfigReload()          { queue.async { self.configReloads += 1 } }
    func recordConfigReloadDeduped()   { queue.async { self.configReloadsDeduped += 1 } }
    func recordProcessExitNotif()      { queue.async { self.processExitNotifs += 1 } }
    func recordHeartbeat()             { queue.async { self.heartbeats += 1 } }
    func recordAggregateChange()       { queue.async { self.aggregateChanges += 1 } }
    func recordDockBadgeUpdate()       { queue.async { self.dockBadgeUpdates += 1 } }

    func recordMutClaudeState()        { queue.async { self.mutClaudeState += 1 } }
    func recordMutProcessState()       { queue.async { self.mutProcessState += 1 } }
    func recordMutIsUnread()           { queue.async { self.mutIsUnread += 1 } }
    func recordMutAgentName()          { queue.async { self.mutAgentName += 1 } }
    func recordMutLastEventContent()   { queue.async { self.mutLastEventContent += 1 } }
    func recordMutLastAggregateState() { queue.async { self.mutLastAggregateState += 1 } }
    func recordMutAgentsDict()         { queue.async { self.mutAgentsDict += 1 } }

    func recordSurfaceCreated()         { queue.async { self.surfacesCreated += 1 } }
    func recordSurfaceDestroyedExit()   { queue.async { self.surfacesDestroyedExit += 1 } }
    func recordSurfaceDestroyedDelete() { queue.async { self.surfacesDestroyedDelete += 1 } }

    func recordApplyRawEvents(durationMs: Double) {
        queue.async {
            self.applyRawEventsCalls += 1
            self.applyRawEventsTotalMs += durationMs
            if durationMs > self.applyRawEventsMaxMs { self.applyRawEventsMaxMs = durationMs }
        }
    }

    /// Called only from main thread (by ping handler).
    func recordMainThreadPing() {
        let now = Date()
        queue.async {
            let delta = now.timeIntervalSince(self.lastMainPing)
            if delta > self.maxStallSec { self.maxStallSec = delta }
            self.lastMainPing = now
        }
    }

    // MARK: - Lifecycle

    func start(agentCount: @escaping () -> Int, surfaceCount: @escaping () -> Int) {
        // Periodic flush every 5s
        let flush = DispatchSource.makeTimerSource(queue: queue)
        flush.schedule(deadline: .now() + 5, repeating: 5)
        flush.setEventHandler { [weak self] in
            self?.flush(agentCount: agentCount(), surfaceCount: surfaceCount())
        }
        flush.resume()
        self.flushTimer = flush

        // Watchdog ping every 1s on main; checked on metrics queue
        let ping = DispatchSource.makeTimerSource(queue: .main)
        ping.schedule(deadline: .now() + 1, repeating: 1)
        ping.setEventHandler { [weak self] in
            self?.recordMainThreadPing()
        }
        ping.resume()
        self.pingTimer = ping

        logger.info("metrics started")
    }

    // MARK: - Stack capture (post-mortem analysis on stall)

    private func captureStackTrace() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let timestamp = Int(Date().timeIntervalSince1970)
        let path = "/tmp/clawddy_stall_\(timestamp).txt"
        logger.error("📸 capturing stack to \(path, privacy: .public)")

        // Run sample on ourselves from a detached background process.
        // Doesn't depend on main thread — uses Mach API to read stacks.
        let task = Process()
        task.launchPath = "/usr/bin/sample"
        task.arguments = ["\(pid)", "3", "-file", path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            // Don't wait — let it complete in background
        } catch {
            logger.error("📸 sample failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Flush summary

    private func flush(agentCount: Int, surfaceCount: Int) {
        // Compute current stall (if main thread is stuck right now)
        let stallNow = Date().timeIntervalSince(lastMainPing)

        let avgApply = applyRawEventsCalls > 0 ? applyRawEventsTotalMs / Double(applyRawEventsCalls) : 0

        let stallAlert = stallNow > 3.0
        let summary = String(
            format: "watcher=%d polls=%d/throttled=%d applyRawEvents=%d avg=%.1fms max=%.1fms | MUT cs=%d ps=%d un=%d nm=%d lec=%d agg=%d ad=%d | cfg w=%d r=%d d=%d | surfaces alive=%d +%d -exit=%d/del=%d | exitNotif=%d hb=%d aggCh=%d dock=%d | stall max=%.2fs now=%.2fs | agents=%d",
            watcherFires, pollsFired, pollsThrottled,
            applyRawEventsCalls, avgApply, applyRawEventsMaxMs,
            mutClaudeState, mutProcessState, mutIsUnread, mutAgentName,
            mutLastEventContent, mutLastAggregateState, mutAgentsDict,
            configWatcherFires, configReloads, configReloadsDeduped,
            surfaceCount, surfacesCreated, surfacesDestroyedExit, surfacesDestroyedDelete,
            processExitNotifs, heartbeats, aggregateChanges, dockBadgeUpdates,
            maxStallSec, stallNow, agentCount
        )
        if stallAlert {
            stallAlertCount += 1
            logger.error("⚠️ STALL alerts=\(self.stallAlertCount, privacy: .public) | \(summary, privacy: .public)")
            // Capture main thread stack on stall onset (transition from healthy → stalled)
            if !wasStalled {
                captureStackTrace()
            }
            wasStalled = true
        } else {
            logger.info("5s: \(summary, privacy: .public)")
            wasStalled = false
        }
        // Reset counters for next window
        watcherFires = 0; pollsFired = 0; pollsThrottled = 0
        applyRawEventsCalls = 0; applyRawEventsTotalMs = 0; applyRawEventsMaxMs = 0
        configWatcherFires = 0; configReloads = 0; configReloadsDeduped = 0
        processExitNotifs = 0; heartbeats = 0; aggregateChanges = 0; dockBadgeUpdates = 0
        mutClaudeState = 0; mutProcessState = 0; mutIsUnread = 0; mutAgentName = 0
        mutLastEventContent = 0; mutLastAggregateState = 0; mutAgentsDict = 0
        surfacesCreated = 0
        surfacesDestroyedExit = 0; surfacesDestroyedDelete = 0
        maxStallSec = 0
    }
}
