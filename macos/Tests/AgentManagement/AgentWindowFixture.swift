import Foundation
import Testing
@testable import Ghostty

/// Two projects of agents, each brought to a state through the reports its
/// CLI would send (the harness's terminal reports and hooks), for the tests
/// that drive the agent window.
@MainActor
enum WorkspaceFixture {
    enum Variant: Sendable {
        case standard
        /// No agent waits on the person.
        case nothingWaiting
    }

    /// The engine state a fixture agent is brought to.
    enum Reached: Equatable, Sendable {
        case notStarted, starting, question, done, working, ready, failedTurn
    }

    private struct Agent {
        var project: String
        var name: String
        var state: Reached
    }

    private static let standard: [Agent] = [
        Agent(project: "ghostty", name: "soundings", state: .question),
        Agent(project: "ghostty", name: "review", state: .done),
        Agent(project: "ghostty", name: "sunrise-tables", state: .working),
        Agent(project: "ghostty", name: "docs", state: .notStarted),
        Agent(project: "coral", name: "anchor-alarm", state: .question),
        Agent(project: "coral", name: "import-logbooks", state: .working),
        Agent(project: "coral", name: "slow-builds", state: .failedTurn),
        Agent(project: "coral", name: "buoy-catalog", state: .ready),
        Agent(project: "coral", name: "store-listing", state: .notStarted),
    ]

    private static func agents(_ variant: Variant) -> [Agent] {
        standard.map { agent in
            var agent = agent
            if variant == .nothingWaiting {
                switch agent.state {
                case .question: agent.state = .working
                case .done, .failedTurn: agent.state = .ready
                default: break
                }
            }
            return agent
        }
    }

    static func add(_ variant: Variant, to h: AgentBridgeHarness, states: [String: Reached] = [:]) throws {
        let agents = agents(variant).map { agent in
            var agent = agent
            agent.state = states[agent.name] ?? agent.state
            return agent
        }
        for agent in agents {
            if !h.config.projects.contains(where: { $0.name == agent.project }) {
                let folder = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("projects/\(agent.project)").path
                try #require(h.config.addProject(name: agent.project, workingDirectory: folder) != nil)
            }
            try #require(h.config.addAgent(project: agent.project, name: agent.name, provider: .claudeCode))
        }
        h.start()
        // Starting agents last, so that no later report moves the clock
        // past theirs.
        for agent in agents.filter({ $0.state != .starting }) + agents.filter({ $0.state == .starting }) {
            try drive(h, try id(of: agent.name, in: h), to: agent.state)
        }
    }

    static func id(of name: String, in h: AgentBridgeHarness) throws -> UUID {
        try #require(h.config.allAgentEntries.first { $0.name == name }).id
    }

    static func drive(_ h: AgentBridgeHarness, _ id: UUID, to state: Reached) throws {
        switch state {
        case .notStarted:
            return
        case .starting:
            try h.activate(id)
            return
        default:
            try h.launch(id)
        }
        switch state {
        case .question:
            try h.startTurn(id)
            try h.osc(id, "state=blocked:app=claude-code:kind=question")
        case .done:
            try h.completeTurn(id)
        case .working:
            try h.startTurn(id)
        case .failedTurn:
            try h.startTurn(id)
            let message = Data("API Error: Rate limit reached".utf8).base64EncodedString()
            try h.osc(id, "state=error:app=claude-code:msg=\(message)")
        case .ready, .notStarted, .starting:
            break
        }
    }
}
