import Foundation
import Testing
@testable import Ghostty

struct AgentEnvironmentResolverTests {
    @Test func parsesMarkedPathFromNoisyShellOutput() {
        let data = Data("motd\n__CLAWDDY_PATH__/opt/homebrew/bin:/usr/bin:/usr/bin\n".utf8)
        #expect(AgentEnvironmentResolver.parsePath(from: data) == "/opt/homebrew/bin:/usr/bin")
    }

    @Test func rejectsMissingOrEmptyMarker() {
        #expect(AgentEnvironmentResolver.parsePath(from: Data("hello\n".utf8)) == nil)
        #expect(AgentEnvironmentResolver.parsePath(from: Data("__CLAWDDY_PATH__\n".utf8)) == nil)
    }
}
