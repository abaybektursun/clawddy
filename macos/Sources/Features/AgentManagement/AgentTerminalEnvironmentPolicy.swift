import Foundation

/// Defines the environment contract for an interactive agent PTY.
///
/// The application process may inherit automation-oriented or parent-agent
/// session variables from the tool that launched it. Provider authentication
/// still needs the complete account environment, but presentation opt-outs and
/// inherited parent-agent session markers must not leak into an independent
/// interactive agent terminal.
enum AgentTerminalEnvironmentPolicy {
    static let inheritedAutomationVariables = [
        "NO_COLOR",
        "AI_AGENT",
        "CLAUDECODE",
        "CLAUDE_PID",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH",
    ]
    private static let interactivePresentationDefaults = ["CLICOLOR": "1"]

    static func removingInheritedAutomationVariables(
        from environment: [String: String]
    ) -> [String: String] {
        var result = environment
        for key in inheritedAutomationVariables {
            result.removeValue(forKey: key)
        }
        return result
    }

    static func explicitEnvironment(
        from environment: [String: String]
    ) -> [String: String] {
        var result = removingInheritedAutomationVariables(from: environment)
        result.merge(interactivePresentationDefaults) { _, interactiveDefault in
            interactiveDefault
        }
        return result
    }

    /// A surface configuration overlays variables but cannot delete values
    /// inherited by Ghostty's child process. Normalize the login shell itself
    /// so the provider's eventual fallback shell retains interactive defaults
    /// and does not inherit parent-agent session markers.
    static var shellPrelude: String {
        let unset = "unset \(inheritedAutomationVariables.joined(separator: " "))"
        let exports = interactivePresentationDefaults.sorted(by: { $0.key < $1.key })
            .map { "export \($0.key)=\(AgentHookRuntime.shellQuote($0.value))" }
            .joined(separator: "\n")
        return "\(unset)\n\(exports)"
    }

    /// Returns the authoritative provider entrypoint. The explicit `env -u`
    /// boundary is intentional: embedded-surface environment values are
    /// overlays and therefore cannot express deletion of an inherited key.
    /// Keeping deletion adjacent to `exec` prevents an automation-oriented or
    /// agent-spawned app launch environment from silently disabling interactive
    /// provider UI or session transcript persistence.
    static func interactiveCommand(
        executableURL: URL,
        arguments: [String]
    ) -> String {
        var components = ["/usr/bin/env"]
        for key in inheritedAutomationVariables {
            components += ["-u", key]
        }
        components += interactivePresentationDefaults.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
        components.append(executableURL.path)
        components += arguments
        return components
            .map(AgentHookRuntime.shellQuote)
            .joined(separator: " ")
    }
}
