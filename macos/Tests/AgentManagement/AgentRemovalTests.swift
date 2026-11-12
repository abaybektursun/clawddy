import Foundation
import Testing
@testable import Ghostty

/// Every way an agent is removed deletes each of its files, `<agent id>.*`
/// in the status folder and its runtime folder, and no file of any other
/// agent (P3.10).
@MainActor
struct AgentRemovalTests {
    /// The flipped `knownWrong_externalDeleteLeavesStatusFiles`.
    @Test func externalDeleteRemovesStatusFiles() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let other = try h.addAgent("Other")
        try launchBoth(h, id, other)
        let kept = try files(h, other)

        try h.editConfigExternally { $0.removeAll { $0.id == id } }

        #expect(h.bridge.agents[id] == nil)
        #expect(try files(h, id).isEmpty)
        #expect(try files(h, other) == kept)
    }

    @Test func deleteRemovesEveryFileOfTheAgentOnly() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let other = try h.addAgent("Other")
        try launchBoth(h, id, other)
        let kept = try files(h, other)

        #expect(h.bridge.deleteAgent(id: id, config: h.config))

        #expect(h.bridge.agents[id] == nil)
        #expect(try files(h, id).isEmpty)
        #expect(try files(h, other) == kept)
    }

    @Test func projectAndTaskDeletionRemoveEveryFileOfTheirAgentsOnly() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let projectID = try #require(h.config.addProject(name: "Second"))
        try #require(h.config.addTask(project: "Second", name: "Kept") != nil)
        let taskID = try #require(h.config.addTask(project: "Second", name: "Removed"))
        let inTask = try #require(h.config.addAgent(project: "Second", task: "Removed", name: "In Task")).id
        let other = try #require(h.config.addAgent(project: "Second", task: "Kept", name: "Other")).id
        h.start()
        for agent in [id, inTask, other] {
            try h.launch(agent)
            try addEveryKindOfFile(h, agent)
        }
        let kept = try files(h, other)

        #expect(h.bridge.deleteTask(projectID: projectID, taskID: taskID, config: h.config))
        #expect(h.bridge.agents[inTask] == nil)
        #expect(try files(h, inTask).isEmpty)

        let first = try #require(h.config.project(forAgent: id)).id
        #expect(h.bridge.deleteProject(id: first, config: h.config))
        #expect(h.bridge.agents[id] == nil)
        #expect(try files(h, id).isEmpty)

        #expect(h.bridge.agents[other] != nil)
        #expect(try files(h, other) == kept)
    }

    /// A provider change replaces the runtime only of an agent with no saved
    /// session, whose files are then the old provider's leftovers.
    @Test func providerChangeRemovesTheReplacedRuntimesFilesOnly() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        let other = try h.addAgent("Other")
        h.start()
        try h.launch(other)
        try addEveryKindOfFile(h, other)
        for suffix in ["events", "events.lock", "metadata.json", "lastEvent"] {
            try Data("left".utf8).write(to: h.statusFile(id, suffix))
        }
        try runtimeFile(h, id)
        let kept = try files(h, other)

        try h.editConfigExternally { agents in
            agents[0] = AgentEntry(id: id, name: "Agent", provider: .codex)
        }

        #expect(try h.agent(id).provider == .codex)
        #expect(try files(h, id).isEmpty)
        #expect(try files(h, other) == kept)
    }

    // MARK: - Fixtures

    private func launchBoth(_ h: AgentBridgeHarness, _ id: UUID, _ other: UUID) throws {
        h.start()
        for agent in [id, other] {
            try h.launch(agent)
            try addEveryKindOfFile(h, agent)
        }
    }

    /// Beside what the launch wrote (events, its lock, the binding): the
    /// files older builds, the status-line proxy and compaction leave, and
    /// the runtime folder.
    private func addEveryKindOfFile(_ h: AgentBridgeHarness, _ id: UUID) throws {
        for suffix in ["session", "lastEvent", "metadata.json", "metadata.4242.tmp", "events.compact.tmp"] {
            try Data(id.uuidString.utf8).write(to: h.statusFile(id, suffix))
        }
        try runtimeFile(h, id)
        #expect(try files(h, id).count >= 9)
    }

    private func runtimeFile(_ h: AgentBridgeHarness, _ id: UUID) throws {
        let folder = h.root.runtimeDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("settings.json"))
    }

    /// Each file of the agent with its bytes, by path under the root.
    private func files(_ h: AgentBridgeHarness, _ id: UUID) throws -> [String: Data] {
        let fm = FileManager.default
        var result: [String: Data] = [:]
        for name in try fm.contentsOfDirectory(atPath: h.root.statusDir.path)
        where name.hasPrefix(id.uuidString) {
            result["status/\(name)"] = try Data(contentsOf: h.root.statusDir.appendingPathComponent(name))
        }
        let runtime = h.root.runtimeDir.appendingPathComponent(id.uuidString, isDirectory: true)
        if fm.fileExists(atPath: runtime.path) {
            for name in try fm.contentsOfDirectory(atPath: runtime.path) {
                result["runtime/\(id.uuidString)/\(name)"] = try Data(contentsOf: runtime.appendingPathComponent(name))
            }
            result["runtime/\(id.uuidString)"] = Data()
        }
        return result
    }
}
