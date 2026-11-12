import XCTest
@testable import Ghostty

final class AgentTerminalEnvironmentPolicyTests: XCTestCase {
    func testExplicitEnvironmentRemovesInheritedColorOptOutAndParentAgentMarkers() {
        let environment = AgentTerminalEnvironmentPolicy.explicitEnvironment(from: [
            "NO_COLOR": "1",
            "CLICOLOR": "0",
            "AI_AGENT": "claude-code_2-1-316_agent",
            "CLAUDECODE": "1",
            "CLAUDE_PID": "59562",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDE_CODE_SESSION_ID": "parent-session",
            "CLAUDE_CODE_SESSION_ATTENDED": "1",
            "CLAUDE_CODE_BRIDGE_SESSION_ID": "cse_parent",
            "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/cc-socks/59562.sock",
            "CLAUDE_CODE_MESSAGING_TOKEN": "secret-token",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_CODE_EXECPATH": "/Users/example/.local/share/claude/versions/2.1.316",
            "CLAUDE_CONFIG_DIR": "/tmp/claude",
        ])

        for key in AgentTerminalEnvironmentPolicy.inheritedAutomationVariables {
            XCTAssertNil(environment[key], "Expected \(key) to be removed")
        }
        XCTAssertEqual(environment["CLICOLOR"], "1")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/claude")
    }

    func testShellPreludeUnsetsVariablesThatCannotBeRemovedBySurfaceOverlay() {
        let expectedUnset = "unset " + AgentTerminalEnvironmentPolicy
            .inheritedAutomationVariables
            .joined(separator: " ")
        XCTAssertEqual(
            AgentTerminalEnvironmentPolicy.shellPrelude,
            "\(expectedUnset)\nexport CLICOLOR='1'")
    }

    func testProviderEntrypointRemovesInheritedOptOutAndParentAgentMarkersAtExecutionBoundary() throws {
        let command = AgentTerminalEnvironmentPolicy.interactiveCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [])
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.environment = [
            "NO_COLOR": "1",
            "CLICOLOR": "0",
            "AI_AGENT": "claude-code_2-1-316_agent",
            "CLAUDECODE": "1",
            "CLAUDE_PID": "59562",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDE_CODE_SESSION_ID": "parent-session",
            "CLAUDE_CODE_SESSION_ATTENDED": "1",
            "CLAUDE_CODE_BRIDGE_SESSION_ID": "cse_parent",
            "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/cc-socks/59562.sock",
            "CLAUDE_CODE_MESSAGING_TOKEN": "secret-token",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_CODE_EXECPATH": "/Users/example/.local/share/claude/versions/2.1.316",
            "CLAUDE_CONFIG_DIR": "/tmp/claude",
            "PATH": "/usr/bin:/bin",
        ]
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        let lines = Set(text.split(whereSeparator: \Character.isNewline).map(String.init))

        XCTAssertEqual(process.terminationStatus, 0)
        for key in AgentTerminalEnvironmentPolicy.inheritedAutomationVariables {
            XCTAssertFalse(
                lines.contains(where: { $0.hasPrefix("\(key)=") }),
                "Expected \(key) to be stripped at execution boundary")
        }
        XCTAssertTrue(lines.contains("CLICOLOR=1"))
        XCTAssertTrue(lines.contains("CLAUDE_CONFIG_DIR=/tmp/claude"))
    }
}
