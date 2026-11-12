import AppKit
import Foundation
import Testing
@testable import Ghostty

struct AgentDataRootTests {
    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    /// Runs inside the real test host. If hosted runs did not set
    /// `XCTestConfigurationFilePath`, Clawddy would have started at launch and
    /// this test fails.
    @Test @MainActor func testHostDoesNotStartClawddy() throws {
        #expect(AgentDataRoot.isRunningTests(environment: ProcessInfo.processInfo.environment))
        #expect(Bundle.main.bundleIdentifier == "com.mitchellh.ghostty.clawddy-tests")
        let clawddy = try #require(NSApp.delegate as? AppDelegate).clawddy
        // `setup()` sets the environment path first, so nil means it returned at once.
        #expect(clawddy.bridge.environmentPath == nil)
        #expect(clawddy.bridge.agents.isEmpty)
        #expect(NSApp.mainMenu?.items.contains { $0.title == "Agent" } != true)
        #expect(clawddy.workspaceModel.defaults == nil)
        #expect(clawddy.config.root.url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test func dataRootFromInfoKey() {
        let root = AgentDataRoot.resolve(
            directoryName: "clawddy-dev",
            isRunningTests: false,
            homeDirectory: home)
        #expect(root.url.path == "/Users/example/.config/clawddy-dev")
        #expect(root.agentsFile.path == "/Users/example/.config/clawddy-dev/agents.json")
        #expect(root.statusDir.path == "/Users/example/.config/clawddy-dev/status")
        // The test host's own Info.plist carries the value `build.nu` sets.
        #expect(Bundle.main.object(forInfoDictionaryKey: AgentDataRoot.infoKey) as? String
            == "clawddy-tests")
    }

    @Test func productionBundleRefusesForeignRoot() {
        let production = AgentDataRoot(url: home.appendingPathComponent(".config/ghostty-agents"))
        let dev = AgentDataRoot(url: home.appendingPathComponent(".config/clawddy-dev"))
        let disguisedProduction = AgentDataRoot(
            url: URL(fileURLWithPath: "/Users/example/.config/clawddy-dev/../ghostty-agents/"))
        func mismatch(_ bundleIdentifier: String?, _ root: AgentDataRoot) -> String? {
            AgentDataRoot.identityMismatch(
                bundleIdentifier: bundleIdentifier,
                root: root,
                homeDirectory: home)
        }

        #expect(mismatch("com.mitchellh.ghostty", production) == nil)
        #expect(mismatch("com.mitchellh.ghostty", dev)?.contains(dev.url.path) == true)
        #expect(mismatch("com.mitchellh.ghostty.clawddy-dev", dev) == nil)
        #expect(mismatch("com.mitchellh.ghostty.clawddy-dev", production) != nil)
        #expect(mismatch("com.mitchellh.ghostty.clawddy-dev", disguisedProduction) != nil)
        #expect(mismatch(nil, production) != nil)
    }

    @Test @MainActor func onlyProductionBundleTakesHotKeyAndUpdater() throws {
        #expect(AgentDataRoot.isProductionBundle("com.mitchellh.ghostty"))
        #expect(!AgentDataRoot.isProductionBundle("com.mitchellh.ghostty.clawddy-dev"))
        #expect(!AgentDataRoot.isProductionBundle("com.mitchellh.ghostty.clawddy-tests"))
        #expect(!AgentDataRoot.isProductionBundle("com.mitchellh.ghostty.debug"))
        #expect(!AgentDataRoot.isProductionBundle(nil))

        // The test host is not the production bundle, so launch hid the item.
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let mainMenu = try #require(NSApp.mainMenu)
        let checkForUpdates = try #require(items(mainMenu).first {
            $0.action == #selector(AppDelegate.checkForUpdates(_:))
        })
        #expect(checkForUpdates.isHidden)
    }

    @Test func xctestUsesTemporaryRoot() {
        let first = AgentDataRoot.resolve(
            directoryName: "ghostty-agents",
            isRunningTests: true,
            homeDirectory: home)
        let second = AgentDataRoot.resolve(
            directoryName: nil,
            isRunningTests: true,
            homeDirectory: home)
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(first.url.deletingLastPathComponent().standardizedFileURL.path == temporary)
        #expect(second.url.deletingLastPathComponent().standardizedFileURL.path == temporary)
        #expect(first != second)
        #expect(AgentDataRoot.isRunningTests(environment: [
            "XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration",
        ]))
        #expect(!AgentDataRoot.isRunningTests(environment: [:]))
    }

    @Test func secondInstanceOnSameRootRefuses() throws {
        let root = AgentDataRoot(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-lock-tests-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: root.url) }

        let holder = try root.lock()
        let error = #expect(throws: AgentDataRoot.InUse.self) { try root.lock() }
        #expect(error?.localizedDescription.contains(root.url.path) == true)

        // Another process cannot take it either: lockf(1) uses flock(2) and
        // exits with EX_TEMPFAIL (75) when the lock is held.
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        other.arguments = ["-s", "-t", "0", root.lockFile.path, "/usr/bin/true"]
        try other.run()
        other.waitUntilExit()
        #expect(other.terminationStatus == 75)

        // Ends the holder's lifetime here, not at its last use above.
        try holder.close()
    }

    /// Launch scripts live in `<root>/runtime/launch/`, and the startup
    /// sweep empties only that folder. A `clawddy-*.sh` file outside it, as
    /// another instance once kept in the shared temporary folder, survives.
    @Test func launchScriptsUnderRoot() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .appendingPathComponent("clawddy-launch-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: sandbox) }
        let root = AgentDataRoot(url: sandbox.appendingPathComponent("root", isDirectory: true))
        let agentID = UUID()

        let script = root.newLaunchScriptURL(agentID: agentID)
        #expect(script.deletingLastPathComponent().path == root.url.path + "/runtime/launch")
        #expect(script.lastPathComponent.hasPrefix("clawddy-\(agentID.uuidString)-"))
        #expect(script.pathExtension == "sh")
        #expect(root.newLaunchScriptURL(agentID: agentID) != script)

        let foreign = sandbox.appendingPathComponent("shared/clawddy-\(UUID().uuidString).sh")
        try fm.createDirectory(
            at: foreign.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("#!/bin/zsh\n".utf8).write(to: foreign)
        try fm.createDirectory(at: root.launchDir, withIntermediateDirectories: true)
        try Data("#!/bin/zsh\n".utf8).write(to: script)

        try root.resetLaunchDir()

        #expect(try fm.contentsOfDirectory(atPath: root.launchDir.path).isEmpty)
        let attributes = try fm.attributesOfItem(atPath: root.launchDir.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(fm.fileExists(atPath: foreign.path))
    }
}
