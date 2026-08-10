import Foundation

/// Defines the environment contract for an interactive agent PTY.
///
/// The application process may inherit automation-oriented variables from the
/// tool that launched it. Provider authentication still needs the complete
/// account environment, but presentation opt-outs must not leak into a real
/// terminal whose capabilities are supplied by Ghostty.
enum AgentTerminalEnvironmentPolicy {
    private static let inheritedPresentationOptOuts = ["NO_COLOR"]

    static func explicitEnvironment(
        from environment: [String: String]
    ) -> [String: String] {
        var result = environment
        for key in inheritedPresentationOptOuts {
            result.removeValue(forKey: key)
        }
        return result
    }

    /// A surface configuration overlays variables but cannot delete values
    /// inherited by Ghostty's child process. Unset opt-outs inside the login
    /// shell before launching the provider or the user's fallback shell.
    static var shellPrelude: String {
        "unset \(inheritedPresentationOptOuts.joined(separator: " "))"
    }
}
