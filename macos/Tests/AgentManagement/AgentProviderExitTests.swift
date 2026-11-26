import Foundation
import Testing
@testable import Ghostty

/// The launch script's exit report (P3.7). Once the provider returns, the
/// script prints `ESC ] 7501 ; state=clear:id=clawddy:msg=<status> BEL`,
/// with the exit status in decimal, base64, as `msg`, and ends, so the
/// terminal closes (`docs/clawddy-design/flows.md` 6 and 7).
@MainActor
struct AgentProviderExitTests {
    /// Coordinator item 2 (the real agy, declining its trust dialog):
    /// Ghostty tells of the process's exit without waiting to read the
    /// terminal's last bytes, so the exit report can be lost. The launch
    /// script writes the status to its exit status file before the exit,
    /// and the terminal's death reads it: status 0 is a clean exit, any
    /// other the problem with its status. With no file (the script itself
    /// was killed) the terminal closed under the provider, as before.
    @Test(arguments: [(0, nil), (1, 1), (nil, nil)] as [(Int?, Int?)])
    func aLostExitReportIsReadFromTheStatusFile(_ written: Int?, _ problemStatus: Int?) throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent", provider: .antigravity)
        h.start()
        try h.activate(id)
        let script = try #require(try h.launchScripts().first)
        #expect(try h.launchScript().contains("printf '%s' \"$command_status\" > "))
        try h.osc(id, "state=idle:app=antigravity")
        if let written {
            try Data(String(written).utf8).write(to: h.root.launchDir.appendingPathComponent(script + ".status"))
        }
        try h.terminalClosed(id)
        let agent = try h.agent(id)
        #expect(agent.processState == .exited)
        if written == 0 {
            #expect(agent.record.problem == nil && agent.record.state == .finished)
        } else {
            #expect(agent.record.problem == AgentRecord.Problem(kind: .exited, status: problemStatus))
        }
        #expect(try !h.launchScripts().contains(script + ".status"))
    }

    /// Review of the fixes, defect 1: an exit status belongs to one launch.
    /// Launch 1 exits with status 1 (its report read), the agent is
    /// restarted before launch 1's terminal closes, and launch 2 goes
    /// before its terminal closes (the agent removed): launch 1's file is
    /// gone with launch 1, and nothing from it reaches launch 2. A status
    /// file of the current launch is not read when the app or the person
    /// closes the terminal. No file is left in the launch folder.
    @Test func anExitStatusBelongsToOneLaunch() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let first = try h.addAgent("First", provider: .antigravity)
        let second = try h.addAgent("Second", provider: .antigravity)
        h.start()
        try h.activate(first)
        let script = try #require(try h.launchScripts().first)
        try h.osc(first, "state=idle:app=antigravity")
        try Data("1".utf8).write(to: h.root.launchDir.appendingPathComponent(script + ".status"))
        try h.providerExited(first, status: 1)
        #expect(try h.agent(first).record.problem == AgentRecord.Problem(kind: .exited, status: 1))
        try h.activate(first)
        #expect(try !h.launchScripts().contains(script + ".status"))
        let posted = h.notifier.posted.count

        try h.activate(second)
        let current = try #require(try h.launchScripts().first { $0.contains(second.uuidString) })
        try h.osc(second, "state=idle:app=antigravity")
        try Data("1".utf8).write(to: h.root.launchDir.appendingPathComponent(current + ".status"))
        try h.editConfigExternally { $0.removeAll { $0.id == first || $0.id == second } }
        #expect(h.notifier.posted.count == posted)
        #expect(try h.launchScripts().filter { $0.hasSuffix(".status") }.isEmpty)
    }

    /// The exit report ends the launch at once, in the app tick that
    /// delivers it, without touching the terminal, which closes after it.
    /// It ends Codex's launch the same way. What its terminal reports
    /// afterwards changes nothing.
    @Test func exitReportEndsGeneration() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let claudeID = try h.addAgent("Claude")
        let codexID = try h.addAgent("Codex", provider: .codex)
        h.start()

        try h.launch(claudeID)
        try h.startTurn(claudeID)
        let claude = try h.agent(claudeID)
        #expect(claude.activityState == .executing)
        let calls = h.host.calls
        try h.providerExited(claudeID, status: 0)

        #expect(claude.processState == .exited)
        #expect(claude.terminal == .notRunning)
        #expect(claude.turnState == .inactive)
        #expect(claude.record.problem == nil)
        #expect(h.host.calls == calls)
        #expect(h.host.hasSurface(id: claudeID))
        #expect(h.bridge.runningAgentCount == 0)
        #expect(h.diagnostics.messages.contains(
            "provider of \(claudeID) exited with status 0, generation \(try h.generation(claudeID))"))

        try h.launch(codexID)
        try h.startTurn(codexID)
        let codex = try h.agent(codexID)
        #expect(codex.activityState == .executing)
        try h.providerExited(codexID, status: 130)

        #expect(codex.processState == .exited)
        #expect(codex.record.problem == AgentRecord.Problem(kind: .exited, status: 130))
        let exited = codex.runtime
        try h.osc(codexID, "state=working:app=codex")
        try h.osc(codexID, "state=blocked:kind=permission:app=codex")
        #expect(codex.runtime == exited)

        #expect(h.bridge.runningAgentCount == 0)
        #expect(h.waitingCounts == [0, 1])
        #expect(h.notifier.announced == ["Codex, Codex stopped (signal 2). Type here to continue."])
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
        #expect(agent.terminal == .idle)
        #expect(h.diagnostics.messages.filter { $0.hasPrefix("ignored ") && $0.contains("record clawddy") }.count == 4)
        #expect(h.diagnostics.messages.contains(
            "ignored clear on record clawddy for \(id): an exit report is a clear with a decimal exit status as its message, here ok"))
        #expect(h.notifier.posted.isEmpty)
    }

    /// Runs real launch scripts as the terminal does, with a stand-in for
    /// the provider, in the harness's temporary folder, and reads what the
    /// terminal receives. Neither launch gives the terminal an identity:
    /// each passes it to its hooks or notify program as arguments. Once the
    /// provider returns, each script prints the exit report with the
    /// provider's status, last, and ends, so the terminal closes. The bytes
    /// it printed end the agent's launch.
    @Test func launchScriptEndsWithTheExitReport() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let claude = ClaudeCodeProvider(root: h.root)
        let codex = CodexProvider(
            root: h.root,
            configFile: h.folder.appendingPathComponent("home/.codex/config.toml"))
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
            let output = try runLaunchScript(h, id)

            let body = "state=clear:id=clawddy:msg=\(Data(String(status).utf8).base64EncodedString())"
            #expect(body == exitReport(status))
            let parts = output.components(separatedBy: "\u{1B}]7501;\(body)\u{07}")
            try #require(parts.count == 2, "the exit report is printed once: \(output)")
            #expect(parts[0].contains("provider started"))
            #expect(try h.launchScripts().contains { name in
                name.hasSuffix(".sh.status")
                    && (try? String(contentsOf: h.root.launchDir.appendingPathComponent(name), encoding: .utf8)) == "\(status)"
            })
            #expect(!parts[0].contains("CLAWDDY_AGENT_ID"))
            #expect(parts[1].isEmpty)

            try h.osc(id, body)
            let agent = try h.agent(id)
            #expect(agent.processState == .exited)
            #expect(agent.record.problem?.text
                == "It exited before its session started.")
            h.poll()
            #expect(agent.record.problem?.text
                == "It exited before its session started.")
        }
        #expect(h.notifier.posted.map(\.identifier) == [
            "clawddy.\(claudeID.uuidString).error",
            "clawddy.\(codexID.uuidString).error",
        ])
        // No script writes an exit record.
        #expect(!h.exists(h.statusFile(claudeID, "events")))
        #expect(!h.exists(h.statusFile(codexID, "events")))
    }

    /// Runs the agent's one launch script as its terminal would: with the
    /// launch's environment on top of a plain one, and with zsh reading its
    /// startup files from the harness's home folder, not the user's.
    private func runLaunchScript(_ h: AgentBridgeHarness, _ id: UUID) throws -> String {
        // An earlier run's exit status file stays beside its script's place.
        let names = try h.launchScripts().filter { $0.hasSuffix(".sh") }
        try #require(names.count == 1)
        let surface = try #require(h.host.surfaces[id])
        let home = h.folder.appendingPathComponent("home").path
        let process = Process()
        process.executableURL = h.root.launchDir.appendingPathComponent(names[0])
        process.environment = [
            "HOME": home,
            "ZDOTDIR": home,
            "PATH": "/usr/bin:/bin",
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
