import Foundation

/// The one folder that holds all of Clawddy's mutable data. It is resolved
/// once at launch and passed to everything that reads or writes that data;
/// nothing derives a data path any other way.
struct AgentDataRoot: Equatable, Sendable {
    /// Info.plist key naming the folder under `~/.config`. Set by the
    /// `CLAWDDY_DATA_DIRECTORY_NAME` build setting.
    static let infoKey = "ClawddyDataDirectoryName"
    static let productionBundleIdentifier = "com.mitchellh.ghostty"
    static let productionDirectoryName = "ghostty-agents"
    static let devBundleIdentifier = "com.mitchellh.ghostty.clawddy-dev"

    let url: URL

    var agentsFile: URL { url.appendingPathComponent("agents.json") }
    var stateFile: URL { url.appendingPathComponent("state.json") }
    var preferencesFile: URL { url.appendingPathComponent("preferences.json") }
    var statusDir: URL { url.appendingPathComponent("status", isDirectory: true) }
    var hooksDir: URL { url.appendingPathComponent("hooks", isDirectory: true) }
    var runtimeDir: URL { url.appendingPathComponent("runtime", isDirectory: true) }
    var launchDir: URL { runtimeDir.appendingPathComponent("launch", isDirectory: true) }
    var codexHookReviewMarker: URL { url.appendingPathComponent("codex-hook-review-required") }
    var lockFile: URL { url.appendingPathComponent("clawddy.lock") }
    /// agent-cron's folder. Clawddy never reads, writes or copies it.
    var cronDir: URL { url.appendingPathComponent("cron", isDirectory: true) }

    func migrationReportFile(mode: AgentMigrationMode) -> URL {
        url.appendingPathComponent("migration-\(mode.rawValue).json")
    }

    static func isRunningTests(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// Only the production bundle takes machine-wide resources: the global
    /// hot key and the updater. Dev, test and debug bundles leave them to it.
    static func isProductionBundle(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == productionBundleIdentifier
    }

    /// Under XCTest a fresh temporary folder, so a test host never shares
    /// data with anything; otherwise `~/.config/<directoryName>`.
    static func resolve(
        directoryName: String?,
        isRunningTests: Bool,
        homeDirectory: URL
    ) -> AgentDataRoot {
        if isRunningTests {
            return AgentDataRoot(url: FileManager.default.temporaryDirectory.appendingPathComponent(
                "clawddy-tests-\(UUID().uuidString)",
                isDirectory: true))
        }
        guard let directoryName, !directoryName.isEmpty else {
            fatalError("Info.plist key \(infoKey) is missing or empty; set CLAWDDY_DATA_DIRECTORY_NAME.")
        }
        return AgentDataRoot(url: homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true))
    }

    static func production(homeDirectory: URL) -> AgentDataRoot {
        AgentDataRoot(url: homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(productionDirectoryName, isDirectory: true))
    }

    /// Whether this start first copies the production root's Claude agents
    /// into its own root (`seedAgentDevCopy`). Only the dev bundle does,
    /// only while its own root has no `agents.json` (it has none before the
    /// first seed, nor after one that stopped), and only when the production
    /// root has an `agents.json` to copy (agent-cron alone may have created
    /// that folder). Every other start uses its root as it is, or empty.
    static func seedsDevCopy(
        bundleIdentifier: String?,
        configExists: Bool,
        productionConfigExists: Bool
    ) -> Bool {
        bundleIdentifier == devBundleIdentifier && !configExists && productionConfigExists
    }

    /// Whether this start first runs `cleanupV5` on its root
    /// (`runCleanupV5OnFirstStart`), the switch-over's conversion of the
    /// data older apps wrote. Only the production bundle does, only on a
    /// root that holds an `agents.json`, and only until that run has left its
    /// report in the root. Dev and test roots never hold older data.
    static func cleansUpV5(
        bundleIdentifier: String?,
        configExists: Bool,
        reportExists: Bool
    ) -> Bool {
        isProductionBundle(bundleIdentifier) && configExists && !reportExists
    }

    /// Where an in-place migration of the production root backs it up:
    /// `~/.config/ghostty-agents-backups/<yyyyMMdd-HHmmss>-<mode>/`, outside
    /// the root, so neither the app's watcher nor agent-cron sees it.
    static func migrationBackupDir(
        mode: AgentMigrationMode,
        homeDirectory: URL,
        date: Date
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("\(productionDirectoryName)-backups", isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: date))-\(mode.rawValue)", isDirectory: true)
    }

    /// Why this bundle must not run on this root, or nil when the pairing is
    /// allowed. Only the production bundle may use the production root, and
    /// the production bundle may use no other.
    static func identityMismatch(
        bundleIdentifier: String?,
        root: AgentDataRoot,
        homeDirectory: URL
    ) -> String? {
        let productionRoot = production(homeDirectory: homeDirectory).url
        let isProductionRoot = root.url.standardizedFileURL.path
            == productionRoot.standardizedFileURL.path
        switch (isProductionBundle(bundleIdentifier), isProductionRoot) {
        case (true, false):
            return "\(productionBundleIdentifier) must use \(productionRoot.path), not \(root.url.path)."
        case (false, true):
            return "\(bundleIdentifier ?? "A bundle without an identifier") must not use the production data folder \(productionRoot.path)."
        default:
            return nil
        }
    }

    /// A fresh path in the launch folder for one launch of `agentID`.
    func newLaunchScriptURL(agentID: UUID) -> URL {
        launchDir.appendingPathComponent("clawddy-\(agentID.uuidString)-\(UUID().uuidString).sh")
    }

    /// Deletes every file of the agent: each `<agent id>.*` in the status
    /// folder, and its runtime folder. No other agent's file matches.
    func removeFiles(ofAgent agentID: UUID) throws {
        let fm = FileManager.default
        let prefix = agentID.uuidString + "."
        for name in try fm.contentsOfDirectory(atPath: statusDir.path) where name.hasPrefix(prefix) {
            try fm.removeItemIfPresent(at: statusDir.appendingPathComponent(name))
        }
        try fm.removeItemIfPresent(at: runtimeDir.appendingPathComponent(agentID.uuidString))
    }

    /// Empties the launch folder, creating it if needed. Called once at
    /// start: only the instance holding this root's lock writes there, and
    /// no script from an earlier run is needed again.
    func resetLaunchDir() throws {
        if FileManager.default.fileExists(atPath: launchDir.path) {
            try FileManager.default.removeItem(at: launchDir)
        }
        try FileManager.default.createDirectory(
            at: launchDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    struct InUse: LocalizedError {
        let root: URL

        var errorDescription: String? {
            "Another Clawddy instance is already using \(root.path). Quit it before starting this one."
        }
    }

    /// Creates the root and takes its exclusive lock. The lock lasts as long
    /// as the returned handle is open, and the kernel releases it when the
    /// process exits, so a crash never leaves a stale lock behind. Throws
    /// `InUse` when another process (or another handle) holds it.
    func lock() throws -> FileHandle {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw InUse(root: url) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Runs `body` holding the root's lock, and unlocks however `body` ends.
    /// Unlocking does not wait for the handle to be deallocated, which can
    /// happen well after the call returns.
    func withLock<T>(_ body: () throws -> T) throws -> T {
        let handle = try lock()
        defer {
            precondition(
                flock(handle.fileDescriptor, LOCK_UN) == 0,
                "Unlocking \(lockFile.path) failed with errno \(errno).")
        }
        return try body()
    }
}
