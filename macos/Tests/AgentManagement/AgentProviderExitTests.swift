import Foundation
import Testing
@testable import Ghostty

/// The launch script's exit report (P3.7). Once the provider returns, the
/// script prints `ESC ] 7501 ; state=clear:id=clawddy:msg=<status> BEL`,
/// with the exit status in decimal, base64, as `msg`; removes the agent
/// identity it gave the terminal; and starts the user's login shell.
@MainActor
struct AgentProviderExitTests {
    /// The exit report ends the launch at once, in the app tick that
    /// delivers it, without touching the terminal the login shell keeps.
    /// Codex's turn activity comes from its hooks, but its script prints the
    /// report too, and it ends Codex's launch the same way. What the event
    /// file brings afterwards, a prompt Codex recorded just before it exited
    /// and the exit record its script still writes, changes nothing.
    @Test func exitReportEndsGeneration() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let claudeID = try h.addAgent("Claude")
        let codexID = try h.addAgent("Codex", provider: .codex)
        h.start()

        try h.launch(claudeID)
        try h.startTurn(claudeID)
        let claude = try h.agent(claudeID)
        #expect(claude.displayState == .working)
        let calls = h.host.calls
        try h.providerExited(claudeID, status: 0)

        #expect(claude.processState == .exited)
        #expect(claude.displayState == .dead)
        #expect(claude.turnState == .inactive)
        #expect(claude.failureMessage == nil)
        #expect(h.host.calls == calls)
        #expect(h.host.hasSurface(id: claudeID))
        #expect(h.bridge.runningAgentCount == 0)
        #expect(h.diagnostics.messages.contains(
            "provider of \(claudeID) exited with status 0, generation \(try h.generation(claudeID))"))

        try h.launch(codexID)
        try h.hook(codexID, "UserPromptSubmit")
        let codex = try h.agent(codexID)
        #expect(codex.displayState == .thinking)
        try h.providerExited(codexID, status: 130)

        #expect(codex.processState == .exited)
        #expect(codex.displayState == .dead)
        #expect(codex.failureMessage == nil)
        let exited = codex.runtime
        try h.hook(codexID, "UserPromptSubmit")
        try h.hook(codexID, "PermissionRequest")
        try h.providerExitRecord(codexID, status: 130)
        #expect(codex.runtime == exited)

        #expect(h.bridge.runningAgentCount == 0)
        #expect(h.aggregateChanges == [.idle, .running(1), .idle, .running(1), .idle])
        #expect(h.notifier.posted.isEmpty)
        #expect(h.notifier.announced.isEmpty)
    }

    /// After the provider exits, the terminal runs the user's login shell.
    /// A `claude` typed there reports in the same terminal, from the trust
    /// dialog through a turn, a wait, a completion, a failure and its own
    /// exit, and the agent stays exited: no turn, no wait, no completion, no
    /// notification, and nothing touches the terminal. Its hooks cannot
    /// reach the agent at all: it gets no per-agent settings, and the shell
    /// has no agent identity (`fallbackShellHasNoAgentIdentity`). Only a new
    /// launch brings the agent back.
    @Test func manualClaudeInFallbackShellDoesNotReviveAgent() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let agent = try h.agent(id)
        let first = try h.generation(id)
        try h.providerExited(id, status: 0)
        let exited = agent.runtime
        let calls = h.host.calls
        let aggregate = h.aggregateChanges

        for body in [
            "state=idle:app=claude-code",
            "state=working:app=claude-code",
            "state=blocked:app=claude-code:kind=permission:msg=YXBwcm92ZSBCYXNoOiB0b3VjaCBzcGlrZV9tYXJrZXIudHh0",
            "state=working:app=claude-code",
            "state=done:app=claude-code",
            "state=done:app=claude-code:msg=cmVwbGllZCBvayBhcyByZXF1ZXN0ZWQ=",
            "state=working:app=claude-code",
            "state=error:app=claude-code:msg=bm8gcm91dGU=",
            "state=clear",
        ] {
            try h.osc(id, body)
            h.scheduler.advance(by: 1)
        }

        #expect(agent.runtime == exited)
        #expect(agent.displayState == .dead)
        #expect(agent.unreadCompletion == nil)
        #expect(h.bridge.runningAgentCount == 0)
        #expect(h.host.calls == calls)
        #expect(h.aggregateChanges == aggregate)
        #expect(h.notifier.posted.isEmpty)
        #expect(h.notifier.announced.isEmpty)

        try h.activate(id)
        #expect(try h.generation(id) != first)
        #expect(agent.displayState == .launching)
    }

    /// Only what the launch script prints ends a launch. On the record
    /// `clawddy`, a report that is not `clear`, or has no decimal exit
    /// status as its message, is ignored and logged as an error.
    @Test func onlyTheLaunchScriptsReportEndsTheLaunch() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        let agent = try h.agent(id)

        for body in [
            "state=error:id=clawddy",
            "state=clear:id=clawddy",
            "state=clear:id=clawddy:msg=b2s=",
            "state=done:id=clawddy:msg=MA==",
        ] {
            try h.osc(id, body)
        }

        #expect(agent.processState == .running)
        #expect(agent.displayState == .idle)
        #expect(h.diagnostics.messages.filter { $0.hasPrefix("ignored ") && $0.contains("record clawddy") }.count == 4)
        #expect(h.diagnostics.messages.contains(
            "ignored clear on record clawddy for \(id): an exit report is a clear with a decimal exit status as its message, here ok"))
        #expect(h.notifier.posted.isEmpty)
    }

    /// Runs real launch scripts as the terminal does, with stand-ins for the
    /// provider and the login shell, in the harness's temporary folder, and
    /// reads what the terminal receives. Codex's launch gives the terminal
    /// its identity, the CLAWDDY_* names, and the provider sees it; Claude's
    /// gives none. Once the provider returns, each script prints the exit
    /// report with the provider's status, then starts the login shell with
    /// no CLAWDDY_* or GHOSTTY_AGENT_* name in its environment. The bytes it
    /// printed end the agent's launch; Codex's exit record, which its script
    /// also wrote, changes nothing after them.
    @Test func fallbackShellHasNoAgentIdentity() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let shell = h.folder.appendingPathComponent("login-shell")
        try writeExecutable(shell, "#!/bin/sh\necho \"login shell $*\"\n/usr/bin/env\n")
        let claude = ClaudeCodeProvider(root: h.root)
        let codex = CodexProvider(
            root: h.root,
            hooksFile: h.folder.appendingPathComponent("home/.codex/hooks.json"),
            isProduction: false)
        h.providers.prepareLaunch = { request in
            request.provider == .codex ? codex.prepareLaunch(request) : claude.prepareLaunch(request)
        }
        h.bridge.environmentPath = "\(h.binFolder.path):/usr/bin:/bin"
        let claudeID = try h.addAgent("Claude")
        let codexID = try h.addAgent("Codex", provider: .codex)
        h.start()

        for (id, provider, status) in [
            (claudeID, AgentProviderID.claudeCode, 2),
            (codexID, AgentProviderID.codex, 3),
        ] {
            try writeExecutable(
                h.binFolder.appendingPathComponent(provider.executableName),
                "#!/bin/sh\necho provider started\n/usr/bin/env\nexit \(status)\n")
            try h.activate(id)
            let output = try runLaunchScript(h, id, shell: shell)

            let body = "state=clear:id=clawddy:msg=\(Data(String(status).utf8).base64EncodedString())"
            #expect(body == exitReport(status))
            let parts = output.components(separatedBy: "\u{1B}]7501;\(body)\u{07}")
            try #require(parts.count == 2, "the exit report is printed once: \(output)")
            let (beforeExit, loginShell) = (parts[0], parts[1])
            #expect(beforeExit.contains("provider started"))
            #expect(beforeExit.contains("CLAWDDY_AGENT_ID=\(id.uuidString)") == (provider == .codex))
            #expect(loginShell.contains("login shell -l"))
            let names = loginShell.split(separator: "\n").map { line in line.prefix { $0 != "=" } }
            #expect(names.contains("PATH"))
            #expect(!names.contains { $0.hasPrefix("CLAWDDY_") || $0.hasPrefix("GHOSTTY_AGENT_") })

            try h.osc(id, body)
            let agent = try h.agent(id)
            #expect(agent.processState == .exited)
            #expect(agent.failureMessage
                == "The provider exited before the agent session started (status \(status)).")
            h.poll()
            #expect(agent.failureMessage
                == "The provider exited before the agent session started (status \(status)).")
        }
        #expect(h.notifier.posted.map(\.identifier) == [
            "clawddy.\(claudeID.uuidString).error",
            "clawddy.\(codexID.uuidString).error",
        ])
        // Claude's script writes no exit record; Codex's does.
        #expect(!h.exists(h.statusFile(claudeID, "events")))
        #expect(h.exists(h.statusFile(codexID, "events")))
    }

    /// Runs the agent's one launch script as its terminal would: with the
    /// launch's environment on top of a plain one whose login shell is
    /// `shell`, and with zsh reading its startup files from the harness's
    /// home folder, not the user's.
    private func runLaunchScript(_ h: AgentBridgeHarness, _ id: UUID, shell: URL) throws -> String {
        let names = try h.launchScripts()
        try #require(names.count == 1)
        let surface = try #require(h.host.surfaces[id])
        let home = h.folder.appendingPathComponent("home").path
        let process = Process()
        process.executableURL = h.root.launchDir.appendingPathComponent(names[0])
        process.environment = [
            "HOME": home,
            "ZDOTDIR": home,
            "PATH": "/usr/bin:/bin",
            "SHELL": shell.path,
            "TERM": "xterm-256color",
            "TMPDIR": h.folder.appendingPathComponent("tmp").path,
        ].merging(surface.configuration.environmentVariables) { _, launch in launch }
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try #require(String(data: data, encoding: .utf8))
    }

    private func writeExecutable(_ url: URL, _ text: String) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
