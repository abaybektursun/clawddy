import Foundation
import Testing
@testable import Ghostty

/// Regression coverage for H8: a malformed persisted agent must fail the whole
/// load (naming the offending record) rather than decoding a task to an empty
/// agent list, and no save may replace the raw entries that failed to decode.
struct AgentConfigDurabilityTests {
    private static let projectID = "11111111-1111-4111-8111-111111111111"
    private static let taskID = "22222222-2222-4222-8222-222222222222"
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

    private func configuration(agents: [String], schemaVersion: Int = 5) -> String {
        """
        {
          "schemaVersion": \(schemaVersion),
          "projects": [
            {
              "id": "\(Self.projectID)",
              "name": "Project",
              "tasks": [
                {
                  "id": "\(Self.taskID)",
                  "name": "Task",
                  "agents": [
                    \(agents.joined(separator: ",\n"))
                  ]
                }
              ]
            }
          ]
        }
        """
    }

    private func nullAgentListConfiguration() -> String {
        """
        {
          "schemaVersion": 5,
          "projects": [
            {
              "id": "\(Self.projectID)",
              "name": "Project",
              "tasks": [
                { "id": "\(Self.taskID)", "name": "Task", "agents": null }
              ]
            }
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

        // One malformed sibling must not collapse the task to an empty list.
        let nameMessage = decodeFailureMessage(configuration(agents: [valid, brokenName]))
        #expect(nameMessage?.contains("projects[0].tasks[0].agents[1].name") == true)

        let providerMessage = decodeFailureMessage(configuration(agents: [valid, brokenProvider]))
        #expect(providerMessage?.contains("projects[0].tasks[0].agents[1]") == true)

        let missingMessage = decodeFailureMessage(configuration(agents: [valid, missingName]))
        #expect(missingMessage?.contains("projects[0].tasks[0].agents[1].name") == true)

        let scalarMessage = decodeFailureMessage(configuration(agents: [valid, scalarEntry]))
        #expect(scalarMessage?.contains("projects[0].tasks[0].agents[1]") == true)

        // The whole-file decode throws instead of yielding a partial model.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                AgentConfigFile.self,
                from: Data(configuration(agents: [valid, brokenName]).utf8))
        }
    }

    @Test func structurallyCorruptCollectionsFailInsteadOfDecodingEmpty() {
        // A null agent list is corruption, not an empty task.
        let nullAgents = decodeFailureMessage(nullAgentListConfiguration())
        #expect(nullAgents?.contains("null agent list") == true)
        #expect(throws: AgentConfigFormatError.self) {
            try JSONDecoder().decode(
                AgentConfigFile.self,
                from: Data(nullAgentListConfiguration().utf8))
        }

        // A null entry inside an otherwise readable list is malformed too.
        let nullEntry = decodeFailureMessage(configuration(agents: [
            agentObject(id: Self.agentID, name: "Valid"),
            "null",
        ]))
        #expect(nullEntry?.contains("projects[0].tasks[0].agents[1]") == true)

        // A modern schema without its projects array is truncated.
        let missingProjects = decodeFailureMessage(#"{ "schemaVersion": 5 }"#)
        #expect(missingProjects?.contains("no projects array") == true)

        // A task that never had agents is still a legitimate legacy shape.
        let taskWithoutAgents = """
        {
          "schemaVersion": 5,
          "projects": [
            {
              "id": "\(Self.projectID)",
              "name": "Project",
              "tasks": [{ "id": "\(Self.taskID)", "name": "Task" }]
            }
          ]
        }
        """
        let decoded = try? JSONDecoder().decode(
            AgentConfigFile.self,
            from: Data(taskWithoutAgents.utf8))
        #expect(decoded?.projects.first?.tasks.first?.agents.isEmpty == true)

        // Unknown future fields are additive and must not fail the load.
        let forwardCompatible = """
        {
          "schemaVersion": 5,
          "futureRoot": true,
          "projects": [
            {
              "id": "\(Self.projectID)",
              "name": "Project",
              "futureProject": "x",
              "tasks": [
                {
                  "id": "\(Self.taskID)",
                  "name": "Task",
                  "agents": [{
                    "id": "\(Self.agentID)",
                    "name": "Valid",
                    "provider": "claudeCode",
                    "futureAgent": 1
                  }]
                }
              ]
            }
          ]
        }
        """
        let forwardDecoded = try? JSONDecoder().decode(
            AgentConfigFile.self,
            from: Data(forwardCompatible.utf8))
        #expect(forwardDecoded?.projects.first?.tasks.first?.agents.map(\.name) == ["Valid"])
    }

    // MARK: - Legacy migration

    @Test func legacyStringAgentsStillMigrateAndPersistTheirIdentity() throws {
        let directory = try makeDataDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agents.json")
        let legacy = """
        {
          "projects": [
            {
              "name": "Legacy",
              "tasks": [
                { "name": "Task", "agents": ["alpha", "beta"] }
              ]
            }
          ]
        }
        """
        try Data(legacy.utf8).write(to: file)

        let config = AgentConfig(dataDirectory: directory)
        #expect(config.errorMessage == nil)
        let project = try #require(config.projects.first)
        let task = try #require(project.tasks.first)
        #expect(task.agents.map(\.name) == ["alpha", "beta"])
        #expect(task.agents.allSatisfy { $0.provider == .claudeCode })
        #expect(task.agents.allSatisfy { $0.launchProfile == AgentLaunchProfile() })
        #expect(Set(task.agents.map(\.id)).count == 2)

        // Migration wrote the modern schema back with the generated identities.
        let migrated = try JSONDecoder().decode(
            AgentConfigFile.self,
            from: Data(contentsOf: file))
        #expect(migrated.schemaVersion == AgentConfigFile.currentSchemaVersion)
        #expect(migrated.projects.first?.id == project.id)
        #expect(migrated.projects.first?.tasks.first?.id == task.id)
        #expect(migrated.projects.first?.tasks.first?.agents.map(\.id) == task.agents.map(\.id))
        #expect(migrated.projects.first?.tasks.first?.agents.map(\.name) == ["alpha", "beta"])
    }

    // MARK: - Reload and save durability

    @Test func malformedReloadKeepsPreviousModelAndNeverOverwritesFile() throws {
        let directory = try makeDataDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agents.json")
        let validJSON = configuration(agents: [agentObject(id: Self.agentID, name: "Valid")])
        try Data(validJSON.utf8).write(to: file)

        let config = AgentConfig(dataDirectory: directory)
        #expect(config.errorMessage == nil)
        #expect(config.allAgentEntries.map(\.name) == ["Valid"])
        let projectID = try #require(config.projects.first?.id)

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
        #expect(!config.renameProject(id: projectID, newName: "Renamed"))
        #expect(config.projects.first?.name == "Project")
        #expect(config.addAgent(project: "Project", task: "Task", name: "New") == nil)
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

        let config = AgentConfig(dataDirectory: directory)
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
        #expect(try !Data(contentsOf: file).isEmpty)
    }
}
