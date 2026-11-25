import AppKit
import Foundation
import Testing
@testable import Ghostty

struct AgentDataRootTests {
    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

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

    /// Review S2: the project's own identity settings, which a plain Xcode
    /// build uses and `macos/build.nu` replaces only for `--identity
    /// production` or a test run, name a non-production bundle and its own
    /// data folder in every configuration, so no build makes the production
    /// app by accident.
    @Test func projectDefaultsAreNeverTheProductionIdentity() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Ghostty.xcodeproj/project.pbxproj")
        let lines = try String(contentsOf: project, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        func values(_ setting: String) -> [String] {
            lines.filter { $0.hasPrefix("\(setting) = ") && $0.hasSuffix(";") }.map {
                $0.dropFirst(setting.count + 3).dropLast()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        let bundles = values("CLAWDDY_BUNDLE_IDENTIFIER")
        let folders = values("CLAWDDY_DATA_DIRECTORY_NAME")
        // Debug, Release and ReleaseLocal.
        #expect(bundles.count == 3 && folders.count == 3)
        for (bundle, folder) in zip(bundles, folders) {
            #expect(!AgentDataRoot.isProductionBundle(bundle), "\(bundle)")
            #expect(folder != AgentDataRoot.productionDirectoryName)
            #expect(AgentDataRoot.identityMismatch(
                bundleIdentifier: bundle,
                root: AgentDataRoot.resolve(directoryName: folder, isRunningTests: false, homeDirectory: home),
                homeDirectory: home) == nil)
        }
        #expect(bundles.filter { $0 == AgentDataRoot.devBundleIdentifier }.count == 2)
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

    /// A one-time change backs a root up beside it, whatever the identity:
    /// the production root keeps the folder its earlier backups are in.
    @Test func backupGoesBesideTheRoot() {
        let date = Calendar.current.date(from: DateComponents(
            year: 2026, month: 11, day: 12, hour: 8, minute: 15, second: 48))
        let dev = AgentDataRoot(url: URL(fileURLWithPath: "/Users/example/.config/clawddy-dev", isDirectory: true))
        #expect(AgentDataRoot.production(homeDirectory: home).url.path
            == "/Users/example/.config/ghostty-agents")
        #expect(date.map {
            AgentDataRoot.production(homeDirectory: home).backupDir(named: "state-json", date: $0).path
        } == "/Users/example/.config/ghostty-agents-backups/20261112-081548-state-json")
        #expect(date.map {
            dev.backupDir(named: "state-json", date: $0).path
        } == "/Users/example/.config/clawddy-dev-backups/20261112-081548-state-json")
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
