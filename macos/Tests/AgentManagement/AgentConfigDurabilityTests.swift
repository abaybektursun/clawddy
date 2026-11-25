import Foundation
import Testing
@testable import Ghostty

/// Regression coverage for H8: a malformed persisted agent must fail the whole
/// load (naming the offending record) rather than decoding a project to an empty
/// agent list, and no save may replace the raw entries that failed to decode.
struct AgentConfigDurabilityTests {
    private static let projectID = "11111111-1111-4111-8111-111111111111"
    private static let agentID = "33333333-3333-4333-8333-333333333333"
    private static let secondAgentID = "44444444-4444-4444-8444-444444444444"

    // MARK: - Fixtures

    private func makeDataDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clawddy-config-durability-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func agentObject(
        id: String,
        name: String,
        provider: String = "claudeCode"
    ) -> String {
        """
        {
          "id": "\(id)",
          "name": "\(name)",
          "provider": "\(provider)",
          "launchProfile": { "startMode": "unrestricted" }
        }
        """
    }

    private func configuration(agents: [String]) -> String {
        """
        {
          "schemaVersion": 6,
          "projects": [
            {
              "id": "\(Self.projectID)",
              "name": "Project",
              "agents": [
                \(agents.joined(separator: ",\n"))
              ]
            }
          ]
        }
        """
    }

    private func nullAgentListConfiguration() -> String {
        """
        {
          "schemaVersion": 6,
          "projects": [
            { "id": "\(Self.projectID)", "name": "Project", "agents": null }
          ]
        }
        """
    }

    private func decodeFailureMessage(_ json: String) -> String? {
        do {
            _ = try JSONDecoder().decode(AgentConfigFile.self, from: Data(json.utf8))
            return nil
        } catch {
            return AgentConfig.describeLoadFailure(error)
        }
    }

    // MARK: - Decode boundary

    @Test func malformedAgentEntryFailsTheWholeDecodeWithItsLocation() {
        let valid = agentObject(id: Self.agentID, name: "Valid")
        let brokenName = """
        { "id": "\(Self.secondAgentID)", "name": 42, "provider": "claudeCode" }
        """
        let brokenProvider = agentObject(
            id: Self.secondAgentID,
            name: "Wrong provider",
            provider: "gemini")
        let missingName = """
        { "id": "\(Self.secondAgentID)", "provider": "claudeCode" }
        """
        let scalarEntry = "17"

        // One malformed sibling must not collapse the project to an empty list.
        let nameMessage = decodeFailureMessage(configuration(agents: [valid, brokenName]))
        #expect(nameMessage?.contains("projects[0].agents[1].name") == true)

        let providerMessage = decodeFailureMessage(configuration(agents: [valid, brokenProvider]))
        #expect(providerMessage?.contains("projects[0].agents[1]") == true)

        let missingMessage = decodeFailureMessage(configuration(agents: [valid, missingName]))
        #expect(missingMessage?.contains("projects[0].agents[1].name") == true)

        let scalarMessage = decodeFailureMessage(configuration(agents: [valid, scalarEntry]))
        #expect(scalarMessage?.contains("projects[0].agents[1]") == true)

        // The whole-file decode throws instead of yielding a partial model.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                AgentConfigFile.self,
                from: Data(configuration(agents: [valid, brokenName]).utf8))
        }
    }

    @Test func structurallyCorruptCollectionsFailInsteadOfDecodingEmpty() {
        // A null agent list is corruption, not an empty project.
        let nullAgents = decodeFailureMessage(nullAgentListConfiguration())
        #expect(nullAgents?.contains("projects[0].agents") == true)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                AgentConfigFile.self,
                from: Data(nullAgentListConfiguration().utf8))
        }

        // A null entry inside an otherwise readable list is malformed too.
        let nullEntry = decodeFailureMessage(configuration(agents: [
            agentObject(id: Self.agentID, name: "Valid"),
            "null",
        ]))
        #expect(nullEntry?.contains("projects[0].agents[1]") == true)

        // A schema without its projects array is truncated.
        let missingProjects = decodeFailureMessage(#"{ "schemaVersion": 6 }"#)
        #expect(missingProjects?.contains("projects is missing") == true)

        // The app always writes a project's agent list, even an empty one.
        let projectWithoutAgents = """
        {
          "schemaVersion": 6,
          "projects": [{ "id": "\(Self.projectID)", "name": "Project" }]
        }
        """
        let withoutAgents = decodeFailureMessage(projectWithoutAgents)
        #expect(withoutAgents?.contains("projects[0].agents is missing") == true)

        // Unknown future fields are additive and must not fail the load.
        let forwardCompatible = """
        {
          "schemaVersion": 6,
          "futureRoot": true,
          "projects": [
            {
              "id": "\(Self.projectID)",
              "name": "Project",
              "futureProject": "x",
              "agents": [{
                "id": "\(Self.agentID)",
                "name": "Valid",
                "provider": "claudeCode",
                "launchProfile": { "startMode": "unrestricted" },
                "futureAgent": 1
              }]
            }
          ]
        }
        """
        let forwardDecoded = try? JSONDecoder().decode(
            AgentConfigFile.self,
            from: Data(forwardCompatible.utf8))
        #expect(forwardDecoded?.projects.first?.agents.map(\.name) == ["Valid"])
    }

    // MARK: - Reload and save durability

    @Test func malformedReloadKeepsPreviousModelAndNeverOverwritesFile() throws {
        let directory = try makeDataDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agents.json")
        let validJSON = configuration(agents: [agentObject(id: Self.agentID, name: "Valid")])
        try Data(validJSON.utf8).write(to: file)

        let config = AgentConfig(root: AgentDataRoot(url: directory))
        #expect(config.errorMessage == nil)
        #expect(config.allAgentEntries.map(\.name) == ["Valid"])
        // Simulate an external edit that corrupts one agent's name.
        let brokenJSON = configuration(agents: [
            agentObject(id: Self.agentID, name: "Valid"),
            """
            { "id": "\(Self.secondAgentID)", "name": ["not", "a", "string"], "provider": "claudeCode" }
            """,
        ])
        let brokenData = Data(brokenJSON.utf8)
        try brokenData.write(to: file)
        config.load()

        // The previous valid model survives; the error names the bad entry.
        #expect(config.allAgentEntries.map(\.name) == ["Valid"])
        #expect(config.projects.first?.name == "Project")
        #expect(config.errorMessage?.hasPrefix("Agents configuration could not be loaded") == true)
        #expect(config.errorMessage?.contains("agents[1]") == true)

        // Every durable write is refused while the file cannot be decoded.
        #expect(!config.save())
        #expect(config.persistenceErrorMessage != nil)
        #expect(config.addAgent(project: "Project", name: "New") == nil)
        #expect(config.allAgentEntries.count == 1)
        let afterBlockedWrites = try Data(contentsOf: file)
        #expect(afterBlockedWrites == brokenData)

        // Repairing the file (the documented recovery path) unblocks writes.
        try Data(validJSON.utf8).write(to: file)
        config.load()
        #expect(config.errorMessage == nil)
        #expect(config.allAgentEntries.map(\.name) == ["Valid"])
        #expect(config.save())
        #expect(config.errorMessage == nil)
    }

    /// A file an app with tasks wrote is only ever read by the migration.
    /// Should one reach the loader, it is refused and never replaced, so
    /// its agents cannot be lost to the first save.
    @Test func schema5ConfigurationIsRefusedAndNeverReplaced() throws {
        let directory = try makeDataDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agents.json")
        let schema5 = Data("""
        {
          "schemaVersion": 5,
          "projects": [
            {
              "id": "\(Self.projectID)",
              "name": "Project",
              "tasks": [{
                "id": "22222222-2222-4222-8222-222222222222",
                "name": "Task",
                "agents": [\(agentObject(id: Self.agentID, name: "Valid"))]
              }]
            }
          ]
        }
        """.utf8)
        try schema5.write(to: file)

        let config = AgentConfig(root: AgentDataRoot(url: directory))

        #expect(config.projects.isEmpty)
        #expect(config.errorMessage?.contains("schemaVersion 5; this version reads 6") == true)
        #expect(config.addProject(name: "New") == nil)
        #expect(try Data(contentsOf: file) == schema5)
    }

    /// `agents.json` is written off the main thread, in the order of the
    /// changes: a save returns at once, the last change is what the file
    /// holds once the queue is through, and a configuration read anew sees
    /// it (final review part 2; quitting waits the same way).
    @Test func savesAreQueuedInOrder() throws {
        let directory = try makeDataDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = AgentConfig(root: AgentDataRoot(url: directory))
        let id = try #require(config.addProject(name: "ghostty"))
        for index in 0..<20 {
            #expect(config.addAgent(project: "ghostty", name: "agent \(index)") != nil)
        }
        let order = config.projects[0].agents.map(\.id)
        config.reorderAgents(in: id, order.reversed())
        config.waitForWrites()
        let again = AgentConfig(root: AgentDataRoot(url: directory))
        #expect(again.projects[0].agents.map(\.id) == order.reversed())
    }

    @Test func malformedConfigurationAtLaunchIsNotSavedAsAnEmptyModel() throws {
        let directory = try makeDataDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agents.json")
        let brokenJSON = configuration(agents: [
            agentObject(id: Self.agentID, name: "Valid"),
            agentObject(id: Self.secondAgentID, name: "Wrong provider", provider: "gemini"),
        ])
        let brokenData = Data(brokenJSON.utf8)
        try brokenData.write(to: file)

        let config = AgentConfig(root: AgentDataRoot(url: directory))
        #expect(config.projects.isEmpty)
        #expect(config.errorMessage?.hasPrefix("Agents configuration could not be loaded") == true)

        // A user's first mutation must not turn the unreadable file into an
        // empty `agents.json`.
        #expect(config.addProject(name: "New") == nil)
        #expect(config.projects.isEmpty)
        #expect(!config.save())
        #expect(try Data(contentsOf: file) == brokenData)

        // Deleting the broken file leaves nothing to protect.
        try FileManager.default.removeItem(at: file)
        #expect(config.addProject(name: "Fresh") != nil)
        #expect(config.projects.map(\.name) == ["Fresh"])
        #expect(config.errorMessage == nil)
        config.waitForWrites()
        #expect(try !Data(contentsOf: file).isEmpty)
    }
}
