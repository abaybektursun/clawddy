import XCTest
@testable import Ghostty

final class AgentTerminalEnvironmentPolicyTests: XCTestCase {
    func testExplicitEnvironmentRemovesInheritedColorOptOut() {
        let environment = AgentTerminalEnvironmentPolicy.explicitEnvironment(from: [
            "NO_COLOR": "1",
            "CLAUDE_CONFIG_DIR": "/tmp/claude",
        ])

        XCTAssertNil(environment["NO_COLOR"])
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/claude")
    }

    func testShellPreludeUnsetsVariablesThatCannotBeRemovedBySurfaceOverlay() {
        XCTAssertEqual(AgentTerminalEnvironmentPolicy.shellPrelude, "unset NO_COLOR")
    }
}
