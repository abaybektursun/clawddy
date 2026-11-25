import Foundation
import Testing
@testable import Ghostty

/// Typing into agents' terminals (flows.md 4.6, 6.3, 6.5; probes.md P2):
/// reading the input line, the one send, readiness, starting from a task
/// and cancelling a start.
@MainActor
struct AgentTerminalInputTests {
    private static let rule = String(repeating: "─", count: 120)

    /// Claude's input sits between its last two rules; Codex's composer is
    /// the last row starting with "›" (screens as the real CLIs draw them).
    @Test func theInputLineIsReadFromTheScreen() {
        func claude(_ input: [String], prompted: Bool = true) -> AgentInputLine {
            let screen = (["⏺ Done.", "", Self.rule] + input + [Self.rule, "  ⏵⏵ bypass permissions on"]).joined(separator: "\n")
            return AgentInputLine.read(screen, provider: .claudeCode, prompted: prompted)
        }
        #expect(claude(["❯"]) == .empty)
        #expect(claude(["❯\u{00A0}Try \"edit <filepath> to…\""], prompted: false) == .empty)
        #expect(claude(["❯\u{00A0}Try \"edit <filepath> to…\""]) == .holdsText("Try \"edit <filepath> to…\""))
        #expect(claude(["❯\u{00A0}Press up to edit queued messages"]) == .empty)
        #expect(claude(["❯\u{00A0}half"]) == .holdsText("half"))
        #expect(claude(["❯\u{00A0}first line", "  second line"]) == .holdsText("first line\n  second line"))
        // A rule with the session's name set into it.
        let named = ["❯ old prompt", String(repeating: "─", count: 110) + " Real ─", "❯", Self.rule].joined(separator: "\n")
        #expect(AgentInputLine.read(named, provider: .claudeCode, prompted: true) == .empty)
        // The folder-trust dialog draws no input line.
        #expect(AgentInputLine.read("Do you trust the files in this folder?\n❯ 1. Yes\n  2. No, exit", provider: .claudeCode, prompted: false) == .none)

        func codex(_ composer: String) -> AgentInputLine {
            let screen = ["› fix the sheet", "• Done.", "", composer, "  gpt · ~/work", "  ← for agents · ? for shortcuts"].joined(separator: "\n")
            return AgentInputLine.read(screen, provider: .codex, prompted: true)
        }
        #expect(codex("› Ask Codex to do anything") == .empty)
        #expect(codex("›⠁Ask Codex to do anything") == .empty)
        #expect(codex("› half") == .holdsText("half"))
        #expect(codex("› 1. Update now (runs sh -c …)") == .none)
    }

    /// Nothing is typed before the CLI's first report, into a question, or
    /// on top of text the person left; otherwise paste then Return at once,
    /// recorded once as sent by the caller's sender.
    @Test func theOneSend() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.activate(id)
        try h.osc(id, "state=idle:app=claude-code")
        h.host.screens[id] = Self.screen("❯\u{00A0}half")
        #expect(send(h, "on top", to: id) == .holdsText)
        h.host.screens[id] = Self.screen("❯")
        #expect(send(h, "two\nlines", to: id) == .sent)
        #expect(h.host.inputs[id] == [.paste("two\nlines"), .enter])
        let agent = try h.agent(id)
        #expect(agent.record.prompts.map(\.text) == ["two\nlines"])
        #expect(agent.record.prompts.map(\.by) == [.app])
        // The CLI's own report of that prompt is not recorded twice.
        try h.osc(id, "state=working:app=claude-code")
        try h.hook(id, "UserPromptSubmit", text: "two\nlines")
        #expect(agent.record.prompts.count == 1)
        try h.osc(id, "state=blocked:app=claude-code:kind=question")
        #expect(send(h, "into a menu", to: id) == .menu)
        #expect(h.host.inputs[id]?.count == 2)
    }

    /// Interrupt then send: Escape, the CLI's `idle`, the line cleared of
    /// what the interrupt gave back (Claude: Escape twice), then the text.
    @Test func interruptThenSend() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        try h.startTurn(id)
        h.host.screens[id] = Self.screen("❯")
        var result: AgentSendResult?
        h.bridge.send("instead", to: id, by: .person, interrupting: true) { result = $0 }
        #expect(h.host.inputs[id] == [.escape])
        #expect(result == nil)
        // Claude gives the prompt back with its `idle`.
        h.host.screens[id] = Self.screen("❯\u{00A0}fix it")
        h.host.onInput = { id, input in if input == .escape { h.host.screens[id] = Self.screen("❯") } }
        try h.osc(id, "state=idle:app=claude-code")
        h.scheduler.advance(by: 0.5)
        #expect(result == .sent)
        #expect(h.host.inputs[id] == [.escape, .escape, .escape, .paste("instead"), .enter])
        let prompt = try #require(try h.agent(id).record.prompts.last)
        #expect(prompt.text == "instead" && prompt.by == .person)

        // No `idle` within 2 s: nothing is sent.
        try h.startTurn(id)
        result = nil
        h.bridge.send("again", to: id, by: .person, interrupting: true) { result = $0 }
        h.scheduler.advance(by: 2.1)
        #expect(result == .notReady)
    }

    /// A CLI reads its input after its first `idle`, or its first `working`
    /// when launched with a prompt; Codex's first `idle` only after 3 s with
    /// no start-up `working`; a `blocked` dialog is never readiness. One that
    /// is not ready within 30 s stops with a problem.
    @Test func readiness() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let claude = try h.addAgent("Claude")
        let codex = try h.addAgent("Codex", provider: .codex)
        let trust = try h.addAgent("Trust")
        h.start()
        var failed: [UUID] = []
        h.bridge.onKeysNotHeld = { failed.append($0) }
        for id in [claude, codex, trust] { try h.activate(id) }
        try h.osc(claude, "state=idle:app=claude-code")
        #expect(try h.agent(claude).runtime.inputReady)
        try h.osc(codex, "state=idle:app=codex")
        h.scheduler.advance(by: 1)
        try h.osc(codex, "state=working:app=codex")
        h.scheduler.advance(by: 3)
        #expect(try !h.agent(codex).runtime.inputReady)
        try h.osc(codex, "state=idle:app=codex")
        #expect(try h.agent(codex).runtime.inputReady)
        try h.osc(trust, "state=blocked:app=claude-code:kind=permission")
        #expect(try !h.agent(trust).runtime.inputReady)
        h.scheduler.advance(by: AgentBridge.startLimit)
        #expect(failed == [trust])
        #expect(try h.agent(trust).record.problem == AgentRecord.Problem(kind: .didNotStart))
        #expect(try h.agent(trust).record.sentence(cli: "Claude Code")
            == .app("Claude Code did not start in 30 s. Type here to try again."))
    }

    /// A new agent from a typed task exists at once, working, named from the
    /// task, its CLI launched with the task as its first prompt; its start can
    /// be cancelled within 6 s, not after.
    @Test func startingFromATaskAndCancelling() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        h.start()
        let project = try #require(h.config.projects.first)
        let entry = try #require(h.bridge.startAgent(
            task: "make the export button work offline, then add a test", provider: .claudeCode,
            launchProfile: AgentLaunchProfile(), config: h.config, project: project, host: h.host))
        #expect(entry.name == "Make the export button work")
        let agent = try h.agent(entry.id)
        #expect(agent.record.state == .working && agent.record.nameSource == .firstInstruction)
        #expect(agent.record.firstInstruction == "make the export button work offline, then add a test")
        #expect(agent.record.prompts.map(\.by) == [.person])
        #expect(h.providers.launchRequests.last?.firstPrompt == "make the export button work offline, then add a test")
        h.scheduler.advance(by: 5)
        #expect(h.bridge.cancelStart(id: entry.id, config: h.config))
        #expect(h.bridge.agents[entry.id] == nil && h.config.project(forAgent: entry.id) == nil)

        let again = try #require(h.config.projects.first)
        let late = try #require(h.bridge.startAgent(
            task: "tidy the copy", provider: .claudeCode, launchProfile: AgentLaunchProfile(),
            config: h.config, project: again, host: h.host))
        h.scheduler.advance(by: AgentBridge.cancelLimit + 0.1)
        #expect(!h.bridge.cancelStart(id: late.id, config: h.config))
        #expect(h.bridge.agents[late.id] != nil)
    }

    /// After the interrupt, everything a plain send checks is checked again,
    /// and nothing is pasted on a guess: a question that appears refuses it, a
    /// line that cannot be read refuses it, an exit refuses it, and a second
    /// interrupting send takes the first one's place.
    @Test func anInterruptingSendIsRefusedWhenTheCLIChangesMeanwhile() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        h.host.screens[id] = Self.screen("❯")
        func interrupting(_ text: String) -> () -> AgentSendResult? {
            var result: AgentSendResult?
            h.bridge.send(text, to: id, by: .person, interrupting: true) { result = $0 }
            return { result }
        }

        // A question appears while it waits for the idle.
        try h.startTurn(id)
        let asked = interrupting("instead")
        try h.osc(id, "state=blocked:app=claude-code:kind=question")
        #expect(asked() == .menu)

        // Two at once: the first is told, the second goes on.
        try h.osc(id, "state=working:app=claude-code")
        let first = interrupting("one")
        let second = interrupting("two")
        #expect(first() == .replaced && second() == nil)
        // The idle comes, but the line then shows a menu: nothing is pasted.
        h.host.screens[id] = "Select a model\n❯ 1. Opus\n  2. Sonnet"
        try h.osc(id, "state=idle:app=claude-code")
        h.scheduler.advance(by: 0.5)
        #expect(second() == .menu)
        #expect(h.host.inputs[id]?.contains { if case .paste = $0 { return true }; return false } == false)

        // Its CLI exits while it waits.
        h.host.screens[id] = Self.screen("❯")
        try h.startTurn(id)
        let gone = interrupting("again")
        try h.providerExited(id, status: 0)
        #expect(gone() == .notReady)
    }

    /// Keys typed while a CLI starts are held until its first report, then
    /// go; they are thrown away when its launch fails, when it asks first,
    /// and when it shows a screen with no report past the hold limit, after
    /// which keys reach the terminal. The app's sends still wait.
    @Test func keysAreHeldForAStartOnly() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let ready = try h.addAgent("Ready")
        let asks = try h.addAgent("Asks")
        let dialog = try h.addAgent("Dialog", provider: .codex)
        let failing = try h.addAgent("Failing")
        h.start()
        var delivered: [UUID] = []
        var dropped: [UUID] = []
        h.bridge.onKeysReady = { delivered.append($0) }
        h.bridge.onKeysNotHeld = { dropped.append($0) }

        try h.activate(ready)
        #expect(h.bridge.holdsKeys(for: ready))
        try h.osc(ready, "state=idle:app=claude-code")
        #expect(delivered == [ready] && !h.bridge.holdsKeys(for: ready))

        try h.activate(asks)
        try h.osc(asks, "state=blocked:app=claude-code:kind=permission")
        #expect(dropped == [asks] && !h.bridge.holdsKeys(for: asks))

        // A dialog drawn, no report: past the hold limit keys go to it.
        try h.activate(dialog)
        h.host.screens[dialog] = ""
        h.scheduler.advance(by: AgentBridge.holdLimit + 1)
        #expect(h.bridge.holdsKeys(for: dialog), "a blank screen is still a start")
        h.host.screens[dialog] = "✨ Update available! 0.169.0 -> 0.172.0\n› 1. Update now\n  2. Skip"
        h.scheduler.advance(by: 0.5)
        #expect(dropped == [asks, dialog] && !h.bridge.holdsKeys(for: dialog))
        // The app's send waits for its input, and is given up when the start
        // runs out of time.
        var sent: AgentSendResult?
        h.bridge.send("hi", to: dialog, by: .app) { sent = $0 }
        #expect(sent == nil)
        h.scheduler.advance(by: AgentBridge.startLimit)
        #expect(sent == .notReady)

        h.providers.prepareLaunch = { _ in .failure(.executableMissing(.claudeCode)) }
        try h.activate(failing)
        #expect(dropped == [asks, dialog, failing] && !h.bridge.holdsKeys(for: failing))
    }

    /// A task that starts with "-" goes after `--`, so neither CLI reads it as
    /// an option (both probed 2026-11-24).
    @Test func aTaskStartingWithADashIsNotAnOption() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clawddy-dash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["claude", "codex"] {
            let file = folder.appendingPathComponent(name)
            try Data("#!/bin/sh\n[ \"$1\" = agents ] && echo '[]'\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let root = AgentDataRoot(url: folder.appendingPathComponent("root"))
        var request = AgentLaunchRequest(
            agentID: UUID(), name: "Agent", provider: .claudeCode, launchProfile: AgentLaunchProfile(),
            workingDirectory: nil, environmentPath: folder.path, launchGeneration: UUID(), session: nil)
        request.firstPrompt = "-v, then fix it"
        let claude = try ClaudeCodeProvider(root: root).prepareLaunch(request).get()
        #expect(Array(claude.arguments.suffix(2)) == ["--", "-v, then fix it"])
        request.provider = .codex
        let codex = try CodexProvider(root: root, configFile: folder.appendingPathComponent("c.toml")).prepareLaunch(request).get()
        #expect(Array(codex.arguments.suffix(2)) == ["--", "-v, then fix it"])
    }

    /// A prompt the app sends is capped as the CLI's report of it is, so the
    /// report is recognised and not recorded a second time.
    @Test func aLongSentPromptIsRecordedOnce() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("Agent")
        h.start()
        try h.launch(id)
        h.host.screens[id] = Self.screen("❯")
        let long = String(repeating: "word ", count: AgentRecord.textLimit / 4)
        #expect(send(h, long, to: id) == .sent)
        #expect(try h.agent(id).record.state == .working)
        try h.hook(id, "UserPromptSubmit", text: long)
        let prompts = try h.agent(id).record.prompts
        #expect(prompts.count == 1 && prompts[0].text.count == AgentRecord.textLimit && prompts[0].by == .app)
    }

    @Test func aNameFromTheFirstInstruction() {
        #expect(AgentRecord.name(fromInstruction: "fix the tide chart gap after midnight") == "Fix the tide chart gap")
        #expect(AgentRecord.name(fromInstruction: "why?") == "Why")
        #expect(AgentRecord.name(fromInstruction: String(repeating: "a", count: 90)).count == 60)
        #expect(AgentRecord.name(fromInstruction: "  \n ") == "agent")
    }

    /// Both CLIs take the first prompt last on their command line (P5).
    @Test func theFirstPromptGoesOnTheCommandLine() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clawddy-prompt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["claude", "codex"] {
            let file = folder.appendingPathComponent(name)
            try Data("#!/bin/sh\n[ \"$1\" = agents ] && echo '[]'\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let root = AgentDataRoot(url: folder.appendingPathComponent("root"))
        var request = AgentLaunchRequest(
            agentID: UUID(), name: "Agent", provider: .claudeCode, launchProfile: AgentLaunchProfile(),
            workingDirectory: nil, environmentPath: folder.path, launchGeneration: UUID(), session: nil)
        request.firstPrompt = "do it \"now\""
        let claude = try ClaudeCodeProvider(root: root).prepareLaunch(request).get()
        #expect(Array(claude.arguments.suffix(2)) == ["--", "do it \"now\""])
        request.provider = .codex
        request.session = AgentSessionBinding(provider: .codex, sessionID: "s-1")
        let codex = try CodexProvider(root: root, configFile: folder.appendingPathComponent("c.toml")).prepareLaunch(request).get()
        #expect(Array(codex.arguments.suffix(4)) == ["resume", "s-1", "--", "do it \"now\""])
    }

    private static func screen(_ input: String) -> String {
        ["⏺ Done.", rule, input, rule, "  ⏵⏵ bypass permissions on"].joined(separator: "\n")
    }

    private func send(_ h: AgentBridgeHarness, _ text: String, to id: UUID) -> AgentSendResult? {
        var result: AgentSendResult?
        h.bridge.send(text, to: id, by: .app) { result = $0 }
        return result
    }
}
