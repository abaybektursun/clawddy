import Foundation
import Testing
@testable import Ghostty

/// The migration tests M1 to M21 of docs/clawddy-refactor/groundwork.md,
/// section 2.5. The planner tests build their snapshot in memory; M2, M11,
/// M12 and M18 to M21 run the IO layer on a root on disk.
struct AgentMigrationTests {
    // MARK: - Planner

    @Test func flattenPreservesOrderAndRenamesCollisions() throws {
        let plan = try planAgentMigration(MigrationFixture().snapshot(), mode: .flattenV6)
        let agentsJSON = try #require(plan.agentsJSON)
        let flattened = try JSONDecoder().decode(SchemaV6.self, from: agentsJSON)

        #expect(flattened.schemaVersion == 6)
        #expect(String(bytes: agentsJSON, encoding: .utf8)?.contains("\"tasks\"") == false)
        #expect(flattened.projects.map(\.name) == ["Project 1", "Project 2", "Project 3", "Project 4"])
        #expect(flattened.projects.flatMap(\.agents).map(\.id) == (1...69).map(fixtureID))
        #expect(plan.report.renames == [
            AgentRename(agentID: fixtureID(38), from: "reviewer", to: "reviewer (Task 10)"),
            AgentRename(agentID: fixtureID(42), from: "Reviewer", to: "Reviewer (Task 11)"),
        ])
        let names = flattened.projects[3].agents.map(\.name)
        #expect(names.contains("Reviewer") && names.contains("reviewer (Task 10)") && names.contains("Reviewer (Task 11)"))
        #expect(plan.report.projects == 4 && plan.report.tasks == 18)
        #expect(plan.report.agents == 69 && plan.report.claudeAgents == 66 && plan.report.codexAgents == 3)
    }

    @Test func legacySessionOnlyIsConverted() throws {
        let id = MigrationFixture.claudeIDs[0].uuidString
        var fixture = MigrationFixture()
        fixture.status = ["\(id).session": "legacy-session\n"]
        for mode in [AgentMigrationMode.cleanupV5, .flattenV6] {
            let plan = try planAgentMigration(fixture.snapshot(), mode: mode)
            let written = try JSONDecoder().decode(
                AgentSessionBinding.self,
                from: #require(plan.statusWrites["\(id).session.json"]))
            #expect(written == AgentSessionBinding(provider: .claudeCode, sessionID: "legacy-session", launchGeneration: nil))
            #expect(plan.statusWrites.count == 1)
            #expect(plan.deletions == ["status/\(id).session"])
            #expect(plan.report.sessionConversions == 1)
            #expect(plan.report.deletions == [.legacySession: 1])
        }
    }

    @Test func taggedBindingWinsOverLegacy() throws {
        let id = MigrationFixture.claudeIDs[0].uuidString
        var fixture = MigrationFixture()
        fixture.status = [
            "\(id).session.json": MigrationFixture.sessionJSON("claudeCode", "tagged-session"),
            "\(id).session": "legacy-session\n",
        ]
        let plan = try planAgentMigration(fixture.snapshot(), mode: .cleanupV5)
        #expect(plan.statusWrites.isEmpty)
        #expect(plan.deletions == ["status/\(id).session"])
        #expect(plan.report.sessionConversions == 0)

        let seed = try planAgentMigration(fixture.snapshot(), mode: .seedDevCopy)
        let fork = try JSONDecoder().decode(
            AgentPendingFork.self,
            from: #require(seed.statusWrites["\(id).fork.json"]))
        #expect(fork.sourceSessionID == "tagged-session")
    }

    @Test func orphansV1FilesLastEventAndTempLeftoversAreDeleted() throws {
        let plan = try planAgentMigration(MigrationFixture.messy().snapshot(), mode: .cleanupV5)
        #expect(plan.report.deletions == [
            .orphan: 7, .v1: 3, .lastEvent: 15, .legacySession: 7, .tempLeftover: 3, .legacyHook: 1,
        ])
        let removed = MigrationFixture.removedID.uuidString
        let configured = MigrationFixture.claudeIDs[0].uuidString
        for suffix in ["events", "events.lock", "session", "session.json", "lastEvent", "state", "session.123.tmp"] {
            #expect(plan.deletions.contains("status/\(removed).\(suffix)"))
        }
        for name in [
            "Project_1_Task_1_Old.session", "Project_1_Task_1_Old.state", "Project_2_Task_2_Gone.heartbeat",
            "leftover.tmp", "\(configured).session.4242.tmp", "\(configured).metadata.4243.tmp",
            "\(configured).lastEvent",
        ] {
            #expect(plan.deletions.contains("status/\(name)"))
        }
        #expect(plan.deletions.contains("hooks/clawddy-hook.sh"))
        for suffix in ["events", "events.lock", "session.json", "metadata.json"] {
            #expect(!plan.deletions.contains("status/\(configured).\(suffix)"))
        }
        #expect(plan.report.statusFiles == 83)
    }

    @Test func unknownStatusKindsAreReportedNotDeleted() throws {
        let plan = try planAgentMigration(MigrationFixture.messy().snapshot(), mode: .cleanupV5)
        let unknown = [
            "status/.DS_Store",
            "status/\(MigrationFixture.claudeIDs[0].uuidString).notes",
            "status/\(MigrationFixture.removedID.uuidString).notes",
            "hooks/custom.sh",
        ]
        #expect(plan.report.unknownFiles == unknown)
        #expect(plan.deletions.allSatisfy { !unknown.contains($0) })
    }

    @Test func providerMismatchAborts() throws {
        let codex = MigrationFixture.codexIDs[0].uuidString
        let claude = MigrationFixture.claudeIDs[0].uuidString
        for status in [
            ["\(codex).session.json": MigrationFixture.sessionJSON("claudeCode", "session")],
            ["\(codex).session": "legacy-session\n"],
            ["\(claude).session.json": MigrationFixture.sessionJSON("codex", "session")],
            ["\(claude).fork.json": #"{"provider":"codex","sourceSessionID":"session"}"#],
        ] {
            var fixture = MigrationFixture()
            fixture.status = status
            let snapshot = try fixture.snapshot()
            for mode in AgentMigrationMode.allCases {
                #expect(throws: AgentMigrationAbort.self, "\(status.keys) \(mode)") {
                    try planAgentMigration(snapshot, mode: mode)
                }
            }
        }
    }

    @Test func invalidLegacySessionIDAborts() throws {
        let claude = MigrationFixture.claudeIDs[0].uuidString
        for contents in ["not a session id\n", "", "../elsewhere\n"] {
            var fixture = MigrationFixture()
            fixture.status = ["\(claude).session": contents]
            let snapshot = try fixture.snapshot()
            for mode in AgentMigrationMode.allCases {
                #expect(throws: AgentMigrationAbort.self, "\(contents) \(mode)") {
                    try planAgentMigration(snapshot, mode: mode)
                }
            }
        }
    }

    @Test func schemaOtherThan5Or6Aborts() throws {
        var fixture = MigrationFixture()
        for version in [1, 4, 7] {
            fixture.config["schemaVersion"] = version
            let snapshot = try fixture.snapshot()
            for mode in AgentMigrationMode.allCases {
                #expect(throws: AgentMigrationAbort.self, "\(version) \(mode)") {
                    try planAgentMigration(snapshot, mode: mode)
                }
            }
        }
        fixture.config.removeValue(forKey: "schemaVersion")
        let unversioned = try fixture.snapshot()
        for mode in AgentMigrationMode.allCases {
            #expect(throws: AgentMigrationAbort.self) { try planAgentMigration(unversioned, mode: mode) }
        }

        // Schema 6 is what flattenV6 writes; only flattenV6 accepts it.
        var flattened = try MigrationFixture().snapshot()
        flattened.agentsJSON = try #require(planAgentMigration(flattened, mode: .flattenV6).agentsJSON)
        for mode in [AgentMigrationMode.cleanupV5, .seedDevCopy] {
            #expect(throws: AgentMigrationAbort.self) { try planAgentMigration(flattened, mode: mode) }
        }
    }

    @Test func schema6IsNoOp() throws {
        var snapshot = try MigrationFixture().snapshot()
        snapshot.agentsJSON = try #require(planAgentMigration(snapshot, mode: .flattenV6).agentsJSON)
        let plan = try planAgentMigration(snapshot, mode: .flattenV6)
        #expect(plan.isEmpty)
        #expect(plan.report.schemaVersion == 6)
        #expect(plan.report.agents == 69)
    }

    @Test func stringAgentsOrMissingKeysAbort() throws {
        let agent = MigrationFixture.agent(1, name: "Agent")
        func config(project: [String: Any]) -> [String: Any] { MigrationFixture.config([project]) }
        func config(agent: Any) -> [String: Any] {
            config(project: MigrationFixture.project(900, "Project", tasks: [MigrationFixture.task(500, "Task", [agent])]))
        }
        let cases: [(path: String, config: [String: Any])] = [
            ("projects[0].tasks[0].agents[0]", config(agent: "Legacy name")),
            ("agents[0].provider is missing", config(agent: agent.filter { $0.key != "provider" })),
            ("agents[0].color", config(agent: agent.merging(["color": "red"]) { $1 })),
            ("launchProfile.startMode is missing", config(agent: agent.merging(["launchProfile": [String: Any]()]) { $1 })),
            ("launchProfile.modelID", config(agent: agent.merging([
                "launchProfile": ["startMode": "unrestricted", "modelID": NSNull()] as [String: Any],
            ]) { $1 })),
            ("projects[0].workingDirectory is missing", config(project: MigrationFixture.project(
                900, "Project", tasks: []).filter { $0.key != "workingDirectory" })),
        ]
        for (path, config) in cases {
            var fixture = MigrationFixture()
            fixture.config = config
            let snapshot = try fixture.snapshot()
            for mode in AgentMigrationMode.allCases {
                let error = #expect(throws: AgentMigrationAbort.self) { try planAgentMigration(snapshot, mode: mode) }
                #expect(error?.message.contains(path) == true, "\(error?.message ?? "no error") should name \(path)")
            }
        }
    }

    /// Inputs that only the legacy decoders read, which P1.5 deleted on the
    /// strength of these aborts, and a duplicate agent ID.
    @Test func legacyInputsTheAppNoLongerReadsAbort() throws {
        let claude = MigrationFixture.claudeIDs[0]
        var forkFrom = MigrationFixture()
        forkFrom.status = ["\(claude.uuidString).forkFrom": "session\n"]
        var unreadAgents = MigrationFixture()
        unreadAgents.state = ["unreadAgents": [claude.uuidString]]
        // Agent 2 is "Agent 2" in task "Task 1" of "Project 1", and it has no
        // UUID-keyed `.session` file the schema 1 file would collide with.
        var movableV1 = MigrationFixture()
        movableV1.status = ["Project_1_Task_1_Agent_2.session": "session\n"]
        var duplicateID = MigrationFixture()
        duplicateID.config = MigrationFixture.config([MigrationFixture.project(900, "Project", tasks: [
            MigrationFixture.task(500, "A", [MigrationFixture.agent(1, name: "One")]),
            MigrationFixture.task(501, "B", [MigrationFixture.agent(1, name: "Two")]),
        ])])
        for fixture in [forkFrom, unreadAgents, movableV1, duplicateID] {
            let snapshot = try fixture.snapshot()
            for mode in AgentMigrationMode.allCases {
                #expect(throws: AgentMigrationAbort.self, "\(mode)") { try planAgentMigration(snapshot, mode: mode) }
            }
        }
    }

    /// The keys whose absence the app's decoders filled in for old formats
    /// until P1.5. The preflight aborts without each of them, and the
    /// configuration it accepts is one the app reads as it is: cleanupV5
    /// leaves `agents.json` alone.
    @Test func keysTheAppNoLongerDefaultsAbort() throws {
        let agent = MigrationFixture.agent(1, name: "Agent")
        let task = MigrationFixture.task(500, "Task", [agent])
        let project = MigrationFixture.project(900, "Project", tasks: [task])
        func without(_ key: String, _ object: [String: Any]) -> [String: Any] {
            object.filter { $0.key != key }
        }
        func config(task: [String: Any]) -> [String: Any] {
            MigrationFixture.config([MigrationFixture.project(900, "Project", tasks: [task])])
        }
        let cases: [(path: String, config: [String: Any])] = [
            ("projects is missing", ["schemaVersion": 5]),
            ("projects[0].id is missing", MigrationFixture.config([without("id", project)])),
            ("projects[0].tasks is missing", MigrationFixture.config([without("tasks", project)])),
            ("tasks[0].id is missing", config(task: without("id", task))),
            ("tasks[0].agents is missing", config(task: without("agents", task))),
            ("agents[0].id is missing", config(task: MigrationFixture.task(500, "Task", [without("id", agent)]))),
            ("agents[0].launchProfile is missing", config(task: MigrationFixture.task(
                500, "Task", [without("launchProfile", agent)]))),
        ]
        for (path, config) in cases {
            var fixture = MigrationFixture()
            fixture.config = config
            let snapshot = try fixture.snapshot()
            for mode in AgentMigrationMode.allCases {
                let error = #expect(throws: AgentMigrationAbort.self) { try planAgentMigration(snapshot, mode: mode) }
                #expect(error?.message.contains(path) == true, "\(error?.message ?? "no error") should name \(path)")
            }
        }

        let accepted = try MigrationFixture.messy().snapshot()
        #expect(try planAgentMigration(accepted, mode: .cleanupV5).agentsJSON == nil)
        let read = try JSONDecoder().decode(AgentConfigFile.self, from: accepted.agentsJSON)
        #expect(read.projects.flatMap { $0.tasks.flatMap(\.agents) }.map(\.id) == (1...69).map(fixtureID))
    }

    @Test func workspaceDefaultsMapTaskScopeToProject() throws {
        let project = fixtureID(903).uuidString
        let task = fixtureID(509).uuidString
        let agent = fixtureID(34).uuidString
        var fixture = MigrationFixture()
        fixture.defaults = AgentWorkspaceDefaults(
            scope: "task:\(project):\(task)",
            preferredAgents: ["project:\(project)": agent, "task:\(task)": agent])
        #expect(try planAgentMigration(fixture.snapshot(), mode: .flattenV6).workspaceDefaults
            == AgentWorkspaceDefaults(scope: "project:\(project)", preferredAgents: ["project:\(project)": agent]))
        // Schema 5 keeps its tasks, so cleanupV5 leaves the preferences alone.
        #expect(try planAgentMigration(fixture.snapshot(), mode: .cleanupV5).workspaceDefaults == nil)

        fixture.defaults = AgentWorkspaceDefaults(scope: "all", preferredAgents: ["project:\(project)": agent])
        #expect(try planAgentMigration(fixture.snapshot(), mode: .flattenV6).workspaceDefaults == nil)

        fixture.defaults = AgentWorkspaceDefaults(scope: "task:\(project)")
        let malformed = try fixture.snapshot()
        #expect(throws: AgentMigrationAbort.self) { try planAgentMigration(malformed, mode: .flattenV6) }
    }

    @Test func emptyTaskDroppedEmptyProjectKept() throws {
        var fixture = MigrationFixture()
        fixture.config = MigrationFixture.config([
            MigrationFixture.project(900, "Empty", tasks: [MigrationFixture.task(500, "Nothing yet", [])]),
            MigrationFixture.project(901, "Busy", tasks: [
                MigrationFixture.task(501, "Empty", []),
                MigrationFixture.task(502, "Work", [MigrationFixture.agent(1, name: "Agent")]),
            ]),
        ])
        let plan = try planAgentMigration(fixture.snapshot(), mode: .flattenV6)
        let flattened = try JSONDecoder().decode(SchemaV6.self, from: #require(plan.agentsJSON))
        #expect(flattened.projects.map(\.name) == ["Empty", "Busy"])
        #expect(flattened.projects[0].agents.isEmpty)
        #expect(flattened.projects[1].agents.map(\.id) == [fixtureID(1)])
        #expect(plan.report.tasks == 3 && plan.report.agents == 1)
    }

    @Test func collisionRenameNeverClobbersAnExistingName() throws {
        var fixture = MigrationFixture()
        fixture.config = MigrationFixture.config([MigrationFixture.project(900, "Project", tasks: [
            MigrationFixture.task(500, "A", [MigrationFixture.agent(1, name: "Bob")]),
            MigrationFixture.task(501, "B", [MigrationFixture.agent(2, name: "bob")]),
            MigrationFixture.task(502, "C", [MigrationFixture.agent(3, name: "Bob (B)")]),
            MigrationFixture.task(503, "D", [MigrationFixture.agent(4, name: "Bob (B) 2")]),
        ])])
        let plan = try planAgentMigration(fixture.snapshot(), mode: .flattenV6)
        #expect(plan.report.renames == [AgentRename(agentID: fixtureID(2), from: "bob", to: "bob (B) 3")])
        let names = try JSONDecoder().decode(SchemaV6.self, from: #require(plan.agentsJSON))
            .projects[0].agents.map(\.name)
        #expect(names == ["Bob", "bob (B) 3", "Bob (B)", "Bob (B) 2"])
        #expect(Set(names.map { $0.lowercased() }).count == names.count)
    }

    @Test func unreadForDeletedAgentsDropped() throws {
        let plan = try planAgentMigration(MigrationFixture.messy().snapshot(), mode: .cleanupV5)
        #expect(plan.report.stateEntriesDropped == 4)
        let stateJSON = try #require(plan.stateJSON)
        let state = try #require(try JSONSerialization.jsonObject(with: stateJSON) as? [String: [Any]])
        let configured = MigrationFixture.claudeIDs[0].uuidString
        #expect(state["unreadCompletions"]?.count == 2)
        #expect(state["unreadCompletions"]?.first as? String == configured)
        #expect(state["lastAppliedCompletions"]?.first as? String == configured)
        #expect(state["eventOffsets"]?.first as? String == configured)
        #expect(state["pendingRenames"]?.isEmpty == true)

        // The bridge decodes these keys the same way.
        struct Persisted: Decodable {
            var unreadCompletions: [UUID: AgentCompletionID]
            var eventOffsets: [UUID: Int]
        }
        let persisted = try JSONDecoder().decode(Persisted.self, from: stateJSON)
        #expect(Array(persisted.unreadCompletions.keys) == [MigrationFixture.claudeIDs[0]])
    }

    @Test func seedDevCopyConvertsEveryBindingToFork() throws {
        let plan = try planAgentMigration(MigrationFixture.messy().snapshot(), mode: .seedDevCopy)
        var expected: [UUID: String] = [:]
        for (index, id) in MigrationFixture.taggedClaudeIDs.enumerated() { expected[id] = "claude-session-\(index)" }
        for (index, id) in MigrationFixture.legacyOnlyIDs.enumerated() { expected[id] = "legacy-session-\(index)" }
        for (index, id) in MigrationFixture.bothBoundIDs.enumerated() { expected[id] = "both-tagged-\(index)" }

        #expect(Set(plan.statusWrites.keys) == Set(expected.keys.map { "\($0.uuidString).fork.json" }))
        for (id, source) in expected {
            let fork = try JSONDecoder().decode(
                AgentPendingFork.self,
                from: #require(plan.statusWrites["\(id.uuidString).fork.json"]))
            #expect(fork == AgentPendingFork(provider: .claudeCode, sourceSessionID: source))
        }
        #expect(plan.deletions.isEmpty)
        #expect(plan.workspaceDefaults == nil)
        #expect(plan.report.forkMarkers == expected.count)
        #expect(plan.report.sourceAgents == 69 && plan.report.agents == 66 && plan.report.codexAgents == 0)

        // The app reads the seeded configuration: Claude agents only, in their tasks.
        let seeded = try JSONDecoder().decode(AgentConfigFile.self, from: #require(plan.agentsJSON))
        let seededAgents = seeded.projects.flatMap { $0.tasks.flatMap(\.agents) }
        #expect(seeded.schemaVersion == 5)
        #expect(seeded.projects.map(\.tasks.count) == [1, 2, 4, 11])
        #expect(seededAgents.map(\.id) == MigrationFixture.claudeIDs)

        // Of the state, only the seeded agents' unread completions.
        let stateJSON = try #require(plan.stateJSON)
        let state = try #require(try JSONSerialization.jsonObject(with: stateJSON) as? [String: [Any]])
        #expect(Array(state.keys) == ["unreadCompletions"])
        #expect(state["unreadCompletions"]?.first as? String == MigrationFixture.claudeIDs[0].uuidString)
        #expect(state["unreadCompletions"]?.count == 2)
    }

    // MARK: - IO

    @Test func planIsIdempotent() throws {
        // The test host's own domain; its workspace model has no defaults.
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: AgentWorkspaceModel.DefaultsKey.scope)
            defaults.removeObject(forKey: AgentWorkspaceModel.DefaultsKey.preferredAgents)
        }
        let project = fixtureID(903).uuidString
        let task = fixtureID(509).uuidString
        for mode in [AgentMigrationMode.cleanupV5, .flattenV6] {
            let sandbox = MigrationSandbox()
            defer { sandbox.remove() }
            defaults.set("task:\(project):\(task)", forKey: AgentWorkspaceModel.DefaultsKey.scope)
            defaults.set(
                ["task:\(task)": fixtureID(34).uuidString, "project:\(project)": fixtureID(34).uuidString],
                forKey: AgentWorkspaceModel.DefaultsKey.preferredAgents)
            try MigrationFixture.messy().write(to: sandbox.root)

            let report = try migrateAgentDataInPlace(
                root: sandbox.root,
                mode: mode,
                backupDir: sandbox.backup("first"),
                defaults: defaults)
            #expect(report.sessionConversions == 5)

            let again = try planAgentMigration(AgentDataSnapshot.read(from: sandbox.root, defaults: defaults), mode: mode)
            #expect(again.isEmpty, "\(mode)")
            #expect(defaults.string(forKey: AgentWorkspaceModel.DefaultsKey.scope)
                == (mode == .flattenV6 ? "project:\(project)" : "task:\(project):\(task)"))
        }
    }

    @Test func untaggedRecordAfterOffsetAborts() throws {
        let sandbox = MigrationSandbox()
        defer { sandbox.remove() }
        let id = MigrationFixture.claudeIDs[0].uuidString
        let untagged = #"{"hook_event_name":"Stop","session_id":"session"}"# + "\n"
        let tagged = MigrationFixture.record + "\n"
        var fixture = MigrationFixture()
        func plan(journal: String, offset: Int) throws -> AgentMigrationPlan {
            fixture.status["\(id).events"] = journal
            fixture.state = ["eventOffsets": [id, offset] as [Any]]
            try fixture.write(to: sandbox.root)
            return try planAgentMigration(AgentDataSnapshot.read(from: sandbox.root, defaults: nil), mode: .cleanupV5)
        }

        // Before the offset the untagged record is history, and an unfinished
        // last line is not a record yet.
        _ = try plan(journal: untagged + tagged, offset: untagged.utf8.count)
        _ = try plan(journal: untagged + tagged + #"{"hook_event_name""#, offset: (untagged + tagged).utf8.count)
        // From the start, or from an offset past the end, it is unread.
        #expect(throws: AgentMigrationAbort.self) { try plan(journal: untagged + tagged, offset: 0) }
        #expect(throws: AgentMigrationAbort.self) { try plan(journal: untagged + tagged, offset: 10_000) }
        #expect(throws: AgentMigrationAbort.self) {
            try plan(journal: untagged + tagged + untagged, offset: (untagged + tagged).utf8.count)
        }
    }

    @Test func cronAndUnknownTopLevelFilesAreNeverPlanned() throws {
        let sandbox = MigrationSandbox()
        defer { sandbox.remove() }
        let root = sandbox.root
        try MigrationFixture.messy().write(to: root)
        let untouched = [
            "cron/jobs.json": "{}",
            "cron/runs/1.log": "ran",
            "debug.log": "debug",
            "statusline.sh": "#!/bin/sh\n",
            "\(fixtureID(6000).uuidString).tmp": "leftover",
            "runtime/\(MigrationFixture.claudeIDs[0].uuidString)/settings.json": "{}",
            "runtime/\(MigrationFixture.removedID.uuidString)/settings.json": "{}",
        ]
        try write(untouched, under: root.url)

        let plan = try planAgentMigration(AgentDataSnapshot.read(from: root, defaults: nil), mode: .flattenV6)
        #expect(plan.deletions.allSatisfy { $0.hasPrefix("status/") || $0.hasPrefix("hooks/") })
        #expect(plan.statusWrites.keys.allSatisfy { !$0.contains("/") })

        try migrateAgentDataInPlace(root: root, mode: .flattenV6, backupDir: sandbox.backup("m12"), defaults: nil)
        let after = try tree(root.url)
        for (path, contents) in untouched {
            #expect(after[path] == Data(contents.utf8), "\(path)")
        }
        let backup = try tree(sandbox.backup("m12"))
        #expect(backup.keys.allSatisfy { !$0.hasPrefix("cron/") })
        #expect(backup["debug.log"] == Data("debug".utf8))
    }

    @Test func seedNeverWritesSource() throws {
        let sandbox = MigrationSandbox()
        defer { sandbox.remove() }
        let source = sandbox.root
        try MigrationFixture.messy().write(to: source)
        try setWritable(false, source.url)
        defer { recordIssues { try setWritable(true, source.url) } }
        let before = try tree(source.url)
        let datesBefore = try modificationDates(source.url)
        let dev = AgentDataRoot(url: sandbox.url.appendingPathComponent("dev", isDirectory: true))

        let report = try seedAgentDevCopy(from: source, to: dev)

        #expect(try tree(source.url) == before)
        #expect(try modificationDates(source.url) == datesBefore)
        #expect(report.agents == 66 && report.forkMarkers == 17)
        let forks = (MigrationFixture.taggedClaudeIDs + MigrationFixture.legacyOnlyIDs + MigrationFixture.bothBoundIDs)
            .map { "status/\($0.uuidString).fork.json" }
        #expect(Set(try tree(dev.url).keys) == Set(["agents.json", "state.json", "migration-seedDevCopy.json"] + forks))
        let permissions = try FileManager.default.attributesOfItem(atPath: dev.url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        // The dev root exists now: seeding again refuses, and no staging
        // folder is left beside it.
        #expect(throws: AgentMigrationAbort.self) { try seedAgentDevCopy(from: source, to: dev) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.url.path).sorted() == ["dev", "root"])
    }

    /// The seeded root, as the app loads it, holds the Claude agents only,
    /// and no file in it belongs to or names a Codex agent, although every
    /// Codex agent in the source has a binding.
    @Test func seedContainsNoCodexAgents() throws {
        let sandbox = MigrationSandbox()
        defer { sandbox.remove() }
        try MigrationFixture.messy().write(to: sandbox.root)
        let dev = AgentDataRoot(url: sandbox.url.appendingPathComponent("dev", isDirectory: true))

        let report = try seedAgentDevCopy(from: sandbox.root, to: dev)

        #expect(report.codexAgents == 0 && report.claudeAgents == 66)
        let config = AgentConfig(root: dev)
        #expect(config.errorMessage == nil)
        #expect(config.allAgentEntries.map(\.id) == MigrationFixture.claudeIDs)
        #expect(config.allAgentEntries.allSatisfy { $0.provider == .claudeCode })
        for (path, contents) in try tree(dev.url) {
            let text = try #require(String(data: contents, encoding: .utf8))
            for id in MigrationFixture.codexIDs.map(\.uuidString) {
                #expect(!path.contains(id) && !text.contains(id), "\(path)")
            }
            #expect(!text.contains("codex-session"), "\(path)")
        }
    }

    @Test func interruptedApplyResumesCorrectly() throws {
        struct Injected: Error {}
        func withoutReports(_ files: [String: Data]) -> [String: Data] {
            files.filter { !$0.key.hasPrefix("migration-") }
        }
        for mode in [AgentMigrationMode.cleanupV5, .flattenV6] {
            let sandbox = MigrationSandbox()
            defer { sandbox.remove() }
            let clean = AgentDataRoot(url: sandbox.url.appendingPathComponent("clean", isDirectory: true))
            try MigrationFixture.messy().write(to: clean)
            try migrateAgentDataInPlace(root: clean, mode: mode, backupDir: sandbox.backup("clean"), defaults: nil)
            let expected = withoutReports(try tree(clean.url))

            for step in [AgentMigrationStep.statusWrites, .state, .agents, .deletions] {
                let root = AgentDataRoot(url: sandbox.url.appendingPathComponent("\(step)", isDirectory: true))
                try MigrationFixture.messy().write(to: root)
                #expect(throws: Injected.self) {
                    try migrateAgentDataInPlace(
                        root: root,
                        mode: mode,
                        backupDir: sandbox.backup("\(step)-interrupted"),
                        defaults: nil
                    ) { if $0 == step { throw Injected() } }
                }
                try migrateAgentDataInPlace(root: root, mode: mode, backupDir: sandbox.backup("\(step)-rerun"), defaults: nil)
                #expect(withoutReports(try tree(root.url)) == expected, "\(mode) interrupted after \(step)")
            }
        }
    }

    @Test func backupIsCompleteAndDecodes() throws {
        let sandbox = MigrationSandbox()
        defer { sandbox.remove() }
        let root = sandbox.root
        try MigrationFixture.messy().write(to: root)
        try write(["cron/jobs.json": "{}", "runtime/agent/settings.json": "{}", "debug.log": "debug"], under: root.url)
        let before = try tree(root.url).filter { !$0.key.hasPrefix("cron/") }
        let backup = sandbox.backup("m20")

        let report = try migrateAgentDataInPlace(root: root, mode: .cleanupV5, backupDir: backup, defaults: nil)

        let saved = try tree(backup)
        let added = ["clawddy.lock", "workspace-defaults.json", "migration-cleanupV5.json"]
        #expect(saved.filter { !added.contains($0.key) } == before)
        #expect(try JSONDecoder().decode(AgentMigrationReport.self, from: #require(saved["migration-cleanupV5.json"])) == report)
        // The backup is a root the migration reads, and it plans what was applied.
        let replanned = try planAgentMigration(
            AgentDataSnapshot.read(from: AgentDataRoot(url: backup), defaults: nil),
            mode: .cleanupV5)
        #expect(replanned.report == report)
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
    }

    /// M21, opt-in: `TEST_RUNNER_CLAWDDY_M21_COPY=<folder> macos/build.nu
    /// --action test`, where `<folder>/root` is a copy of a live data root
    /// without `cron/`. Each mode runs on its own fresh copy of it, and each
    /// report is saved as `<folder>/report-<mode>.json`, to be compared with
    /// what `docs/clawddy-refactor/review_inventory.py` counts on the same copy.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAWDDY_M21_COPY"] != nil))
    func rehearsalOnRealCopy() throws {
        let fm = FileManager.default
        let folder = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLAWDDY_M21_COPY"]),
            isDirectory: true)
        let pristine = folder.appendingPathComponent("root", isDirectory: true)
        let pristineTree = try tree(pristine)
        for mode in AgentMigrationMode.allCases {
            let run = folder.appendingPathComponent("run-\(mode.rawValue)", isDirectory: true)
            let root = AgentDataRoot(url: run.appendingPathComponent("root", isDirectory: true))
            try fm.createDirectory(at: run, withIntermediateDirectories: false)
            try fm.copyItem(at: pristine, to: root.url)
            let report: AgentMigrationReport
            if mode == .seedDevCopy {
                report = try seedAgentDevCopy(
                    from: root,
                    to: AgentDataRoot(url: run.appendingPathComponent("dev", isDirectory: true)))
                #expect(try tree(root.url) == pristineTree)
            } else {
                report = try migrateAgentDataInPlace(
                    root: root,
                    mode: mode,
                    backupDir: run.appendingPathComponent("backup", isDirectory: true),
                    defaults: nil)
                let statusDeletions = report.deletions.filter { $0.key != .legacyHook }.values.reduce(0, +)
                #expect(try fm.contentsOfDirectory(atPath: root.statusDir.path).count
                    == report.statusFiles - statusDeletions + report.sessionConversions)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: folder.appendingPathComponent("report-\(mode.rawValue).json"))
        }
        #expect(try tree(pristine) == pristineTree)
    }
}

// MARK: - Fixture

/// A UUID that reads as its number, so a failure names the agent.
private func fixtureID(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
}

/// One data root: snapshotted directly by the planner tests, written to disk
/// by the IO tests.
private struct MigrationFixture {
    var config: [String: Any] = MigrationFixture.realShape()
    var state: [String: Any]?
    /// Names and contents of the files in `status/`.
    var status: [String: String] = [:]
    var hooks = ["clawddy-provider-hook.sh", "clawddy-statusline-proxy.sh"]
    var defaults = AgentWorkspaceDefaults()

    /// In `realShape`, the first agent of the first task of each of the
    /// first three projects is a Codex agent.
    static let codexIDs = [fixtureID(1), fixtureID(6), fixtureID(14)]
    static let claudeIDs = (1...69).map(fixtureID).filter { !codexIDs.contains($0) }
    /// The bindings in `messy`.
    static let taggedClaudeIDs = Array(claudeIDs[0..<10])
    static let legacyOnlyIDs = Array(claudeIDs[10..<15])
    static let bothBoundIDs = Array(claudeIDs[15..<17])
    /// An agent that is no longer configured.
    static let removedID = fixtureID(5000)

    /// One hook record as the hook script writes it, empty fields included.
    static let record = #"{"eventID":"event-1","hookEventName":"Stop","launchGeneration":"\#(fixtureID(7000).uuidString)","model":"","permissionMode":"","provider":"claudeCode","schemaVersion":1,"sessionID":"session","turnID":""}"#

    /// The live data's shape: 4 projects with 1, 2, 4 and 11 tasks (18, the
    /// last one empty) holding 69 agents, 3 of them Codex. The first agents
    /// of tasks 9, 10 and 11 are "Reviewer", "reviewer" and "Reviewer": one
    /// collision group of 3 once tasks are flattened.
    static func realShape() -> [String: Any] {
        let taskSizes = [[5], [4, 4], [4, 4, 4, 4], Array(repeating: 4, count: 10) + [0]]
        let reviewers = [9: "Reviewer", 10: "reviewer", 11: "Reviewer"]
        var agentNumber = 0
        var taskNumber = 0
        var projects: [[String: Any]] = []
        for (projectIndex, sizes) in taskSizes.enumerated() {
            var tasks: [[String: Any]] = []
            for (taskIndex, size) in sizes.enumerated() {
                taskNumber += 1
                var agents: [Any] = []
                for agentIndex in 0..<size {
                    agentNumber += 1
                    let isCodex = projectIndex < 3 && taskIndex == 0 && agentIndex == 0
                    agents.append(agent(
                        agentNumber,
                        name: agentIndex == 0 ? reviewers[taskNumber] ?? "Agent \(agentNumber)" : "Agent \(agentNumber)",
                        provider: isCodex ? "codex" : "claudeCode"))
                }
                tasks.append(task(500 + taskNumber, "Task \(taskNumber)", agents))
            }
            projects.append(project(900 + projectIndex, "Project \(projectIndex + 1)", tasks: tasks))
        }
        return config(projects)
    }

    /// The real shape with every kind of status file the live data has, files
    /// of unknown kinds, and a state with entries of a removed agent.
    static func messy() -> MigrationFixture {
        var fixture = MigrationFixture()
        let configured = claudeIDs[0].uuidString
        let removed = removedID.uuidString
        for (index, id) in codexIDs.enumerated() {
            fixture.status["\(id.uuidString).session.json"] = sessionJSON("codex", "codex-session-\(index)")
        }
        for (index, id) in taggedClaudeIDs.enumerated() {
            let name = id.uuidString
            fixture.status["\(name).session.json"] = sessionJSON("claudeCode", "claude-session-\(index)")
            fixture.status["\(name).events"] = record + "\n"
            fixture.status["\(name).events.lock"] = ""
            fixture.status["\(name).metadata.json"] = "{}"
            fixture.status["\(name).lastEvent"] = "{}"
        }
        for (index, id) in legacyOnlyIDs.enumerated() {
            fixture.status["\(id.uuidString).session"] = "legacy-session-\(index)\n"
            fixture.status["\(id.uuidString).lastEvent"] = "{}"
        }
        for (index, id) in bothBoundIDs.enumerated() {
            fixture.status["\(id.uuidString).session.json"] = sessionJSON("claudeCode", "both-tagged-\(index)")
            fixture.status["\(id.uuidString).session"] = "both-legacy-\(index)\n"
        }
        for suffix in ["events", "events.lock", "session", "session.json", "lastEvent", "state", "session.123.tmp"] {
            fixture.status["\(removed).\(suffix)"] = suffix == "session" ? "removed-session\n" : "{}"
        }
        for name in [
            "Project_1_Task_1_Old.session", "Project_1_Task_1_Old.state", "Project_2_Task_2_Gone.heartbeat",
            "leftover.tmp", "\(configured).session.4242.tmp", "\(configured).metadata.4243.tmp",
            ".DS_Store", "\(configured).notes", "\(removed).notes",
        ] {
            fixture.status[name] = "x"
        }
        fixture.hooks += ["clawddy-hook.sh", "custom.sh"]
        let completions: [Any] = [configured, completion("claude-session-0"), removed, completion("removed-session")]
        let offsets: [Any] = [configured, (record + "\n").utf8.count, removed, 2]
        fixture.state = [
            "unreadCompletions": completions,
            "lastAppliedCompletions": completions,
            "pendingRenames": [removed, "Old name"],
            "eventOffsets": offsets,
        ]
        return fixture
    }

    static func config(_ projects: [[String: Any]]) -> [String: Any] {
        ["schemaVersion": 5, "projects": projects]
    }

    static func project(_ number: Int, _ name: String, tasks: [[String: Any]]) -> [String: Any] {
        ["id": fixtureID(number).uuidString, "name": name, "workingDirectory": "/work/\(number)", "tasks": tasks]
    }

    static func task(_ number: Int, _ name: String, _ agents: [Any]) -> [String: Any] {
        ["id": fixtureID(number).uuidString, "name": name, "agents": agents]
    }

    static func agent(_ number: Int, name: String, provider: String = "claudeCode") -> [String: Any] {
        [
            "id": fixtureID(number).uuidString,
            "name": name,
            "provider": provider,
            "launchProfile": ["startMode": "unrestricted"],
        ]
    }

    static func sessionJSON(_ provider: String, _ sessionID: String) -> String {
        #"{"launchGeneration":"\#(fixtureID(7001).uuidString)","provider":"\#(provider)","sessionID":"\#(sessionID)"}"#
    }

    static func completion(_ sessionID: String) -> [String: Any] {
        [
            "eventID": "\(fixtureID(7002).uuidString):0",
            "launchGeneration": fixtureID(7003).uuidString,
            "provider": "claudeCode",
            "sessionID": sessionID,
            "turnID": "",
        ]
    }

    func snapshot() throws -> AgentDataSnapshot {
        AgentDataSnapshot(
            agentsJSON: try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
            stateJSON: try state.map { try JSONSerialization.data(withJSONObject: $0) },
            statusFileNames: Array(status.keys),
            bindingFiles: status.filter { name, _ in
                ["session", "session.json", "fork.json"].contains { name.hasSuffix(".\($0)") }
            }.mapValues { Data($0.utf8) },
            journalTails: [:],
            hookFileNames: hooks,
            workspaceDefaults: defaults)
    }

    func write(to root: AgentDataRoot) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.statusDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.hooksDir, withIntermediateDirectories: true)
        let snapshot = try snapshot()
        try snapshot.agentsJSON.write(to: root.agentsFile)
        try snapshot.stateJSON?.write(to: root.stateFile)
        for (name, contents) in status {
            try Data(contents.utf8).write(to: root.statusDir.appendingPathComponent(name))
        }
        for name in hooks {
            try Data("#!/bin/sh\n".utf8).write(to: root.hooksDir.appendingPathComponent(name))
        }
    }
}

/// Schema 6 as the migration writes it.
private struct SchemaV6: Decodable {
    struct Project: Decodable {
        var name: String
        var workingDirectory: String
        var agents: [Agent]
    }

    struct Agent: Decodable {
        var id: UUID
        var name: String
        var provider: AgentProviderID
        var launchProfile: AgentLaunchProfile
    }

    var schemaVersion: Int
    var projects: [Project]
}

/// A temporary folder for one IO test.
private struct MigrationSandbox {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clawddy-migration-tests-\(UUID().uuidString)", isDirectory: true)

    var root: AgentDataRoot { AgentDataRoot(url: url.appendingPathComponent("root", isDirectory: true)) }

    func backup(_ name: String) -> URL {
        url.appendingPathComponent("backup-\(name)", isDirectory: true)
    }

    func remove() {
        recordIssues { try FileManager.default.removeItem(at: url) }
    }
}

/// Runs cleanup work that cannot throw out of a `defer`; a failure is
/// recorded as a test issue rather than lost.
private func recordIssues(_ work: () throws -> Void) {
    do {
        try work()
    } catch {
        Issue.record(error)
    }
}

/// Every file under `url`, by path relative to it, with its contents.
private func tree(_ url: URL) throws -> [String: Data] {
    let fm = FileManager.default
    var files: [String: Data] = [:]
    for path in try fm.subpathsOfDirectory(atPath: url.path) {
        let file = url.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            files[path] = try Data(contentsOf: file)
        }
    }
    return files
}

/// The modification date of `url` and of every item under it, folders
/// included, by path relative to `url`.
private func modificationDates(_ url: URL) throws -> [String: Date] {
    let fm = FileManager.default
    var dates: [String: Date] = [:]
    for path in try fm.subpathsOfDirectory(atPath: url.path) + [""] {
        let item = path.isEmpty ? url : url.appendingPathComponent(path)
        dates[path] = try #require(fm.attributesOfItem(atPath: item.path)[.modificationDate] as? Date)
    }
    return dates
}

private func write(_ files: [String: String], under url: URL) throws {
    for (path, contents) in files {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }
}

/// Makes `url` and everything under it read-only, or writable again.
private func setWritable(_ writable: Bool, _ url: URL) throws {
    let fm = FileManager.default
    for path in try fm.subpathsOfDirectory(atPath: url.path) + [""] {
        let item = path.isEmpty ? url : url.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: item.path, isDirectory: &isDirectory)
        let mode = isDirectory.boolValue ? (writable ? 0o755 : 0o555) : (writable ? 0o644 : 0o444)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: item.path)
    }
}
