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

    let url: URL

    var agentsFile: URL { url.appendingPathComponent("agents.json") }
    var stateFile: URL { url.appendingPathComponent("state.json") }
    var preferencesFile: URL { url.appendingPathComponent("preferences.json") }
    var statusDir: URL { url.appendingPathComponent("status", isDirectory: true) }
    var hooksDir: URL { url.appendingPathComponent("hooks", isDirectory: true) }
    var runtimeDir: URL { url.appendingPathComponent("runtime", isDirectory: true) }
    var codexHookReviewMarker: URL { url.appendingPathComponent("codex-hook-review-required") }
    var lockFile: URL { url.appendingPathComponent("clawddy.lock") }

    static func isRunningTests(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// Under XCTest a fresh temporary folder, so a test host never shares
    /// data with anything; otherwise `~/.config/<directoryName>`.
    static func resolve(
        directoryName: String?,
        isRunningTests: Bool,
        homeDirectory: URL,
        temporaryDirectory: URL
    ) -> AgentDataRoot {
        if isRunningTests {
            return AgentDataRoot(url: temporaryDirectory.appendingPathComponent(
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

    /// Why this bundle must not run on this root, or nil when the pairing is
    /// allowed. Only the production bundle may use the production root, and
    /// the production bundle may use no other.
    static func identityMismatch(
        bundleIdentifier: String?,
        root: AgentDataRoot,
        homeDirectory: URL
    ) -> String? {
        let productionRoot = homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(productionDirectoryName, isDirectory: true)
        let isProductionBundle = bundleIdentifier == productionBundleIdentifier
        let isProductionRoot = root.url.standardizedFileURL.path
            == productionRoot.standardizedFileURL.path
        switch (isProductionBundle, isProductionRoot) {
        case (true, false):
            return "\(productionBundleIdentifier) must use \(productionRoot.path), not \(root.url.path)."
        case (false, true):
            return "\(bundleIdentifier ?? "A bundle without an identifier") must not use the production data folder \(productionRoot.path)."
        default:
            return nil
        }
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
