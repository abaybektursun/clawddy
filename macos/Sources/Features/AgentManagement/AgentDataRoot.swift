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
    /// Where agy's hook folders go, one per agent
    /// (`AntigravityProvider.hookFolder`). agy lists its workspace folders
    /// sorted by path and gives the model the first as the one it works in
    /// (cli-facts, "Workspace folders, sorted"), so the app's are in the
    /// per-user cache folder under `/var/folders`, which sorts after every
    /// project under `/Users` or `/Volumes`. Inside `runtime` when none is
    /// given (tests).
    let agyHookBase: URL

    init(url: URL, agyHookBase: URL? = nil) {
        self.url = url
        self.agyHookBase = agyHookBase ?? url.appendingPathComponent("runtime", isDirectory: true)
    }

    /// The per-user cache folder macOS keeps under `/var/folders`
    /// (`DARWIN_USER_CACHE_DIR`), as macOS names it: not resolved through the
    /// `/var` link, which agy keeps as given.
    static var userCacheDirectory: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { fatalError("The per-user cache folder could not be read.") }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    var agentsFile: URL { url.appendingPathComponent("agents.json") }
    var stateFile: URL { url.appendingPathComponent("state.json") }
    var preferencesFile: URL { url.appendingPathComponent("preferences.json") }
    var statusDir: URL { url.appendingPathComponent("status", isDirectory: true) }
    var hooksDir: URL { url.appendingPathComponent("hooks", isDirectory: true) }
    var runtimeDir: URL { url.appendingPathComponent("runtime", isDirectory: true) }
    var launchDir: URL { runtimeDir.appendingPathComponent("launch", isDirectory: true) }
    var lockFile: URL { url.appendingPathComponent("clawddy.lock") }

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
        return AgentDataRoot(
            url: homeDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true),
            agyHookBase: userCacheDirectory.appendingPathComponent(directoryName, isDirectory: true))
    }

    static func production(homeDirectory: URL) -> AgentDataRoot {
        AgentDataRoot(
            url: homeDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent(productionDirectoryName, isDirectory: true),
            agyHookBase: userCacheDirectory.appendingPathComponent(productionDirectoryName, isDirectory: true))
    }

    /// Where a one-time change of this root backs up what it replaces:
    /// beside it, in `<root>-backups/<yyyyMMdd-HHmmss>-<name>/` (for the
    /// production root `~/.config/ghostty-agents-backups/…`), outside the
    /// root, so neither the app's watcher nor agent-cron sees it.
    func backupDir(named name: String, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent)-backups", isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: date))-\(name)", isDirectory: true)
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
        try fm.removeItemIfPresent(at: agyHookBase.appendingPathComponent(agentID.uuidString))
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
}
