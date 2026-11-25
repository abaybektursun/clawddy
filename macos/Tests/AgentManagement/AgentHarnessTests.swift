import AppKit
import Foundation
import Testing
@testable import Ghostty

/// The harness's pure parts: the keys its requests name, the scene it
/// writes as the app's own data, and which bundles it runs in.
@MainActor
struct AgentHarnessTests {
    // MARK: Keys

    @Test func chordsNameAKeyAndItsModifiers() throws {
        func chord(_ text: String) throws -> AgentHarnessKeys.Key { try AgentHarnessKeys.chord(text) }
        #expect(try chord("cmd+]") == .init(code: 30, flags: .maskCommand))
        #expect(try chord("cmd+shift+]") == .init(code: 30, flags: [.maskCommand, .maskShift]))
        // A shifted symbol brings its Shift.
        #expect(try chord("cmd+}") == .init(code: 30, flags: [.maskCommand, .maskShift]))
        #expect(try chord("cmd++") == .init(code: 24, flags: [.maskCommand, .maskShift]))
        #expect(try chord("ctrl+c") == .init(code: 8, flags: .maskControl))
        #expect(try chord("opt+left") == .init(code: 123, flags: .maskAlternate))
        #expect(try chord("Return") == .init(code: 36, flags: []))
        #expect(try chord("escape") == .init(code: 53, flags: []))
        #expect(try chord("cmd+1") == .init(code: 18, flags: .maskCommand))
        #expect(throws: AgentHarness.Refused.self) { try chord("hyper+a") }
        #expect(throws: AgentHarness.Refused.self) { try chord("cmd+banana") }
        #expect(throws: AgentHarness.Refused.self) { try chord("cmd+") }
    }

    @Test func typedCharactersUseTheirUSKeys() throws {
        func key(_ character: Character) throws -> AgentHarnessKeys.Key { try AgentHarnessKeys.key(for: character) }
        #expect(try key("a") == .init(code: 0, flags: []))
        #expect(try key("A") == .init(code: 0, flags: .maskShift))
        #expect(try key("~") == .init(code: 50, flags: .maskShift))
        #expect(try key("\n") == .init(code: 36, flags: []))
        #expect(try key(" ") == .init(code: 49, flags: []))
        #expect(throws: AgentHarness.Refused.self) { try key("é") }
    }

    // MARK: Bundles

    /// Only Clawddy Dev (and the test identity) runs as a harness; the
    /// production bundle with the variable stops at launch.
    @Test func productionBundleRefusesTheHarness() throws {
        #expect(throws: AgentHarness.Refused.self) {
            try AgentHarness.resolve("/Volumes/x/run", bundleIdentifier: AgentDataRoot.productionBundleIdentifier)
        }
        #expect(try AgentHarness.resolve(nil, bundleIdentifier: AgentDataRoot.productionBundleIdentifier) == nil)
        #expect(try AgentHarness.resolve("/Volumes/x/run/", bundleIdentifier: AgentDataRoot.devBundleIdentifier)?
            .path == "/Volumes/x/run")
        #expect(throws: AgentHarness.Refused.self) {
            try AgentHarness.resolve("relative/run", bundleIdentifier: AgentDataRoot.devBundleIdentifier)
        }
        // The test host was not started as a harness.
        #expect(AgentHarness.directory == nil)
        #expect(ProcessInfo.processInfo.environment[AgentHarness.environmentKey] == nil)
    }

    // MARK: Scene

    /// A scene gives any field of a record, whole, under `record`.
    @Test func sceneSeedsEveryRecordField() throws {
        let scene = """
            {"projects": [{"name": "alpha", "agents": [{"name": "One", "record": {
              "state": "working", "changedAt": "2026-11-23T10:00:00Z", "cutOff": true, "continuedInARow": 2,
              "nameSource": "firstInstruction", "firstInstruction": "fix it",
              "prompts": [{"text": "fix it", "at": "2026-11-23T09:59:00Z", "by": "person"}],
              "lastMessage": "Done.", "activity": "Testing", "question": "A?", "queued": "also",
              "problem": {"kind": "exited", "status": 2}, "limit": {"message": "Limit.", "resetsAt": "2026-11-23T15:00:00Z"},
              "unread": true, "interrupted": true, "settledAt": "2026-11-23T11:00:00Z"}}]}]}
            """
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        try AgentHarness.write(scene: Data(scene.utf8), into: directory)
        let root = AgentHarness.root(of: directory)
        let id = try #require(AgentConfig(root: root).allAgentEntries.first?.id)
        let record = try #require(try AgentRecord.load(id, from: root.statusDir))
        let object = try JSONSerialization.jsonObject(with: Data(scene.utf8)) as? [String: Any]
        let agents = try #require((object?["projects"] as? [[String: Any]])?.first?["agents"] as? [[String: Any]])
        let given = try #require(agents.first?["record"])
        let expected = try AgentRecord.decoder.decode(AgentRecord.self, from: JSONSerialization.data(withJSONObject: given))
        #expect(record == expected)
        #expect(record.cutOff && record.continuedInARow == 2 && record.prompts.count == 1)
    }

    /// An agy agent with a session resumes that conversation: its file is in
    /// the stand-in's data folder, where the provider looks before a resume
    /// (without it every such agent read "cannot find this conversation").
    @Test func anAgyAgentsSessionExistsForTheStandIn() throws {
        let scene = """
            {"projects": [{"name": "alpha", "agents": [
              {"name": "One", "provider": "antigravity", "session": "c-1"},
              {"name": "Two", "provider": "claudeCode", "session": "c-2"}]}]}
            """
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        try AgentHarness.write(scene: Data(scene.utf8), into: directory)
        let conversations = directory.appendingPathComponent("agy-data/conversations")
        #expect(try FileManager.default.contentsOfDirectory(atPath: conversations.path) == ["c-1.db"])
    }

    /// The checked-in scene is one the writer takes.
    @Test func twoCatsSceneWritesTwoRunningAgents() throws {
        let scene = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Scenes/two-cats.json")
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        try AgentHarness.write(scene: Data(contentsOf: scene), into: directory)

        let root = AgentHarness.root(of: directory)
        let config = AgentConfig(root: root)
        #expect(config.projects.map(\.name) == ["cats"])
        #expect(config.projects[0].agents.map(\.name) == ["Tom", "Jerry"])
        #expect(config.projects[0].workingDirectory == directory.appendingPathComponent("work/cats").path)
        for agent in config.projects[0].agents {
            #expect(try AgentRecord.load(agent.id, from: root.statusDir) != nil)
        }
        #expect(AgentHarness.agent(named: "Tom", in: config) == config.projects[0].agents[0].id)
        #expect(AgentHarness.agent(named: "cats/Jerry", in: config) == config.projects[0].agents[1].id)
        #expect(AgentHarness.agent(named: "Spike", in: config) == nil)
    }

    /// The prototype's scene: 3 projects, 33 agents, 28 of them running,
    /// each stand-in's script under its session.
    @Test func prototypeSceneWritesEveryAgentAndItsStandIn() throws {
        let scene = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Scenes/prototype.json")
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        try AgentHarness.write(scene: Data(contentsOf: scene), into: directory)
        let root = AgentHarness.root(of: directory)
        let config = AgentConfig(root: root)
        #expect(config.projects.map(\.name) == ["tidepool", "field_notes", "paper-kite"])
        #expect(config.allAgentEntries.count == 33)
        let records = try config.allAgentEntries.map { try #require(try AgentRecord.load($0.id, from: root.statusDir)) }
        #expect(records.count == 33)
        // Whose CLI the harness starts at its first start stays in the scene.
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: scene)) as? [String: Any]
        let agents = (object?["projects"] as? [[String: Any]] ?? []).flatMap { $0["agents"] as? [[String: Any]] ?? [] }
        #expect(agents.filter { $0["running"] as? Bool == true }.count == 28)
        // The prototype's keys reach the records.
        let tideID = try #require(AgentHarness.agent(named: "tidepool/Tide chart blank at sunrise", in: config))
        let tide = try #require(try AgentRecord.load(tideID, from: root.statusDir))
        #expect(tide.state == .finished && tide.unread)
        #expect(tide.lastMessage?.hasPrefix("Fixed it: the chart") == true)
        #expect(tide.firstInstruction?.hasPrefix("the tide chart goes blank") == true)
        #expect(records.filter { $0.settledAt != nil }.count == 5)
        #expect(records.filter { $0.state == .asks }.count == 1)
        #expect(records.filter { $0.state == .paused }.count == 1)
        let scripts = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("standin").path)
        #expect(scripts.count == 33)
        #expect(AgentHarness.agent(named: "tidepool/Tide chart blank at sunrise", in: config) != nil)
    }

    /// Every field of an agent reads back through the stores the app reads
    /// at start, and a stand-in's object lands as it is under its session.
    @Test func sceneReadsBackThroughTheAppsStores() throws {
        let scene = """
            {"projects": [
              {"name": "alpha", "agents": [
                {"name": "One", "provider": "codex", "session": "sess-1", "unread": true, "autoNamed": true,
                 "launchProfile": {"startMode": "standard", "modelID": "m", "reasoningEffort": "high"},
                 "standin": {"steps": [{"say": "hi"}], "rate": 3}},
                {"name": "Two"}
              ]},
              {"name": "beta", "agents": [{"name": "One", "running": true}]}
            ]}
            """
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        try AgentHarness.write(scene: Data(scene.utf8), into: directory)

        let root = AgentHarness.root(of: directory)
        let config = AgentConfig(root: root)
        #expect(config.projects.map(\.name) == ["alpha", "beta"])
        let one = config.projects[0].agents[0]
        let two = config.projects[0].agents[1]
        let betaOne = config.projects[1].agents[0]
        #expect(one.provider == .codex)
        #expect(one.launchProfile == AgentLaunchProfile(modelID: "m", reasoningEffort: "high", startMode: .standard))
        #expect(two.provider == .claudeCode)
        #expect(two.launchProfile == AgentLaunchProfile())
        #expect(try AgentSessionStore.session(for: one.id, provider: .codex, directory: root.statusDir)?.sessionID
            == "sess-1")
        #expect(try AgentSessionStore.persistedProvider(for: two.id, directory: root.statusDir) == nil)

        func record(_ id: UUID) throws -> AgentRecord { try #require(try AgentRecord.load(id, from: root.statusDir)) }
        #expect(try record(one.id).unread && !record(two.id).unread)
        #expect(try record(one.id).nameSource == .app && record(two.id).nameSource == .person)
        #expect(AgentHarness.agent(named: "beta/One", in: config) == betaOne.id)

        let standin = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("standin/sess-1.json"))) as? NSDictionary
        #expect(standin == ["steps": [["say": "hi"]], "rate": 3] as NSDictionary)
    }

    @Test func standinWithoutSessionIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        #expect(throws: AgentHarness.Refused.self) {
            try AgentHarness.write(
                scene: Data(#"{"projects":[{"name":"p","agents":[{"name":"a","standin":{}}]}]}"#.utf8),
                into: directory)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-harness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func remove(_ url: URL) {
        #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) }
    }
}
