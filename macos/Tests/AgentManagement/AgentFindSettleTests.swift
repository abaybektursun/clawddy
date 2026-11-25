import AppKit
import Testing
@testable import Ghostty

/// Find, settle and undo (`docs/clawddy-design/flows.md` 3.4, 6.2, 6.7,
/// 6.8): the pure rules, and the bridge's settle with its CLI's end.
@MainActor
struct AgentFindSettleTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func source(
        _ name: String, project: UUID = UUID(), projectName: String = "p", state: AgentRecord.State = .finished,
        unread: Bool = false, settled: Bool = false, age: TimeInterval = 60, message: String? = nil,
        first: String? = nil, prompts: [String] = [], question: String? = nil, sentence: String = "its sentence"
    ) -> AgentSearchSource {
        var record = AgentRecord()
        record.state = state
        record.unread = unread
        record.changedAt = now - age
        record.settledAt = settled ? now : nil
        record.lastMessage = message
        record.lastMessageAt = message.map { _ in now - age }
        record.firstInstruction = first
        record.prompts = prompts.map { AgentRecord.Prompt(text: $0, at: now - age, by: .person) }
        record.question = question
        return AgentSearchSource(
            id: UUID(), name: name, project: projectName, projectID: project, version: 0, record: { record },
            sentence: { sentence })
    }

    // MARK: Find

    /// An agent is found by a word of its name, first instruction, prompts
    /// or last message, ignoring case; the row shows the line that matched
    /// with the match marked, and for a name match its last message.
    @Test func findSearchesTheStoredRecordAndMarksTheMatch() {
        let tide = Self.source("Tide chart blank", message: "Fixed it: the chart ran an hour Early.\nAll pass.")
        let wind = Self.source("Wind barbs", first: "make the barbs follow the knots setting", prompts: ["also draw GUSTS in KNOTS"])
        let quiet = Self.source("Quiet", message: "nothing here")
        let index = AgentSearchIndex()
        let early = index.search("early", in: [tide, wind, quiet], currentProject: nil)
        #expect(early.map(\.name) == ["Tide chart blank"])
        #expect(early[0].line == "Fixed it: the chart ran an hour Early.")
        #expect(early[0].lineMatches.map { (early[0].line as NSString).substring(with: $0) } == ["Early"])
        // The first instruction before the prompts.
        let knots = index.search("knots", in: [tide, wind, quiet], currentProject: nil)
        #expect(knots.first?.line == "make the barbs follow the knots setting")
        #expect(index.search("draw gusts", in: [tide, wind, quiet], currentProject: nil).first?.line == "also draw GUSTS in KNOTS")
        let byName = index.search("wind", in: [tide, wind, quiet], currentProject: nil)
        #expect(byName.first?.nameMatches == [NSRange(location: 0, length: 4)])
        // Only the name matched: the line is its current sentence.
        #expect(byName.first?.line == "its sentence")
        #expect(index.search("terminal output", in: [tide, wind, quiet], currentProject: nil).isEmpty)
    }

    /// Waiting on the person first, then not settled, then settled, then
    /// the most recent; 5 for an empty field, 8 for typed text.
    @Test func findOrdersAndCaps() {
        let sources = [
            Self.source("old", age: 900, message: "x"),
            Self.source("settled new", settled: true, age: 10, message: "x"),
            Self.source("new", age: 20, message: "x"),
            Self.source("waiting", state: .asks, age: 500, message: "x"),
        ]
        let index = AgentSearchIndex()
        #expect(index.search("x", in: sources, currentProject: nil).map(\.name) == ["waiting", "new", "old", "settled new"])
        let many = (0..<12).map { Self.source("a\($0)", age: Double($0), message: "x") }
        #expect(index.search("", in: many, currentProject: nil).count == 5)
        #expect(index.search("x", in: many, currentProject: nil).count == 8)
        #expect(AgentSearchIndex.commands(["New agent", "Settle", "Rename", "Remove project", "Keys", "Smaller tiles"], matching: "").count == 5)
        #expect(AgentSearchIndex.commands(["New agent", "Settle", "Remove project"], matching: "re").map(\.index) == [2])
        #expect(AgentSearchIndex.commands(["Remove project"], matching: "proj rem").first?.marks
            == [NSRange(location: 7, length: 4), NSRange(location: 0, length: 3)])
        #expect(AgentSearchIndex.commands(["Settle"], matching: "settled ").isEmpty)
    }

    /// Coordinator item 3: each CLI's "New <CLI> agent" is found by the
    /// CLI's name and by its program's ("agy", "claude", "codex"), through
    /// the command's search text; only what matched in the title is marked.
    @Test func aCLIsCommandIsFoundByItsProgramName() {
        let commands = AgentCommand.newAgentWithEachCLI + [.settle, .rename]
        for (index, provider) in AgentProviderID.allCases.enumerated() {
            for query in [provider.executableName, provider.displayName.lowercased()] {
                let chosen = AgentSearchIndex.commands(
                    commands.map(\.title), searchTexts: commands.map(\.searchText), matching: query)
                #expect(chosen.map(\.index) == [index], "\(query)")
                #expect(chosen.first?.marks.allSatisfy { NSMaxRange($0) <= (commands[index].title as NSString).length } == true)
            }
        }
        #expect(AgentCommand.newAgentWith(.antigravity).searchText == "New Antigravity agent agy")
        #expect(AgentCommand.settle.searchText == "Settle")
    }

    /// "settled" lists the current project's settled agents only, the rest
    /// of the text filtering them, and no commands.
    @Test func settledListsThisProjectsSettledAgents() {
        let here = UUID()
        let sources = [
            Self.source("a", project: here, settled: true, message: "fix login"),
            Self.source("b", project: here, settled: true, message: "docs"),
            Self.source("c", project: here, message: "fix"),
            Self.source("d", settled: true, message: "fix"),
        ]
        let index = AgentSearchIndex()
        #expect(index.search("settled ", in: sources, currentProject: here).map(\.name).sorted() == ["a", "b"])
        #expect(index.search("settled fix", in: sources, currentProject: here).map(\.name) == ["a"])
        #expect(index.search("settled", in: sources, currentProject: here).map(\.name).sorted() == ["a", "b"])
        // Only as a whole first word.
        #expect(index.search("settledown", in: sources, currentProject: here).isEmpty)
    }

    /// Matching is by words, in any order and any field, case and accents
    /// folded, composed and decomposed forms equal; each word is marked. The
    /// question is searched, and an asking agent found by its name shows it
    /// (its sentence).
    @Test func findMatchesWordsFoldingCaseAndAccents() {
        let tide = Self.source("Tide chart blank", message: "Fixed it: the chart asked an hour early.")
        let cafe = Self.source("Café menu", message: "Moved the cafe\u{301} prices.")
        let asks = Self.source("Anchor alarm", state: .asks, question: "Siren or vibrate only?", sentence: "Siren or vibrate only?")
        let index = AgentSearchIndex()
        let both = index.search("blank tide", in: [tide, cafe, asks], currentProject: nil)
        #expect(both.map(\.name) == ["Tide chart blank"])
        #expect(index.search("early asked", in: [tide, cafe, asks], currentProject: nil).first?.lineMatches.count == 2)
        #expect(index.search("tide early", in: [tide, cafe, asks], currentProject: nil).first?.line == "Fixed it: the chart asked an hour early.")
        #expect(index.search("cafe", in: [tide, cafe, asks], currentProject: nil).map(\.name) == ["Café menu"])
        #expect(index.search("CAFÉ PRICES", in: [tide, cafe, asks], currentProject: nil).first?.lineMatches.count == 2)
        #expect(index.search("cafe\u{301}", in: [tide, cafe, asks], currentProject: nil).map(\.name) == ["Café menu"])
        #expect(index.search("siren", in: [tide, cafe, asks], currentProject: nil).map(\.name) == ["Anchor alarm"])
        #expect(index.search("anchor", in: [tide, cafe, asks], currentProject: nil).first?.line == "Siren or vibrate only?")
        #expect(index.search("tide nothing", in: [tide, cafe, asks], currentProject: nil).isEmpty)
    }

    /// A settled agent's mark in find is the finished check in the third
    /// text tone whatever its state; amber marks only an agent waiting on
    /// the person.
    @Test func aSettledAgentsMarkInFindIsTheQuietCheck() {
        for state in AgentShownState.allCases {
            #expect(AgentShownState.inFind(state, settled: true) == .finished)
            #expect(AgentShownState.inFind(state, settled: false) == state)
        }
        #expect(AgentShownState.finished.symbol(.prototype, scale: 2).color == ClawddyPalette.prototype.text3)
    }

    /// A long line starts a little before the match, after "…".
    @Test func theMatchingLineStartsNearTheMatch() {
        let text = String(repeating: "word ", count: 30) + "needle and more"
        let (line, marks) = AgentSearchIndex.excerpt(text, words: ["needle"])
        #expect(line.hasPrefix("…"))
        #expect((line as NSString).substring(with: marks[0]) == "needle")
        #expect(marks[0].location < 40)
    }

    /// 500 agents with long records: a key is searched well inside a frame
    /// once the words are in memory, and only an agent whose record changed
    /// is lowercased again.
    @Test func findIsInstantAt500Agents() {
        let words = ["login", "crash", "retry", "export", "parser", "layout", "cache", "token"]
        var sources = (0..<500).map { index in
            Self.source(
                "agent \(index) \(words[index % 8])", age: Double(index),
                message: String(repeating: "The change touched \(words[(index + 3) % 8]) and its tests. ", count: 40),
                first: "please look at the \(words[(index + 5) % 8]) code",
                prompts: (0..<20).map { "prompt \($0) about \(words[($0 + index) % 8])" })
        }
        let index = AgentSearchIndex()
        _ = index.search("", in: sources, currentProject: nil)
        #expect(index.rebuilt == 500)
        var times: [Double] = []
        for query in ["l", "lo", "log", "logi", "login", "x", "xyz", "tests", "prompt 19", "zzzz", "login cache", "touched tests export"] {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = index.search(query, in: sources, currentProject: nil)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        times.sort()
        // One 120 Hz frame is 8.3 ms.
        #expect(times[times.count / 2] < 8.3, "median \(times[times.count / 2]) ms")
        #expect(index.rebuilt == 500)
        sources[7].version += 1
        _ = index.search("a", in: sources, currentProject: nil)
        #expect(index.rebuilt == 501)
    }

    // MARK: Undo

    /// One list (rulings 8, 10, S7 review ruling 4): a start is cancelled
    /// only where starts happen, within its time, and elsewhere it stops
    /// older actions while it can be cancelled; actions that no longer
    /// apply are passed over; a new action ends the start.
    @Test func theOneUndoList() {
        let settled = AgentUndoable.settled([UUID()], project: UUID())
        let start = AgentUndoable.started(id: UUID(), name: "s", at: Self.now)
        var list = AgentUndoList()
        list.push(settled)
        list.push(start)
        #expect(list.peek(inStartPlace: false, applies: { _ in true }, cancellable: { _, _ in true }) == nil)
        #expect(list.peek(inStartPlace: true, applies: { _ in true }, cancellable: { _, _ in true }) == start)
        // Too late where starts happen; passed over elsewhere.
        var late = list
        #expect(late.take(inStartPlace: true, applies: { _ in true }, cancellable: { _, _ in false }) == .tooLate)
        late = list
        #expect(late.take(inStartPlace: false, applies: { _ in true }, cancellable: { _, _ in false }) == .undo(settled))
        // An action that no longer applies is passed over.
        var gone = list
        #expect(gone.take(inStartPlace: true, applies: { $0 != start && $0 != settled }, cancellable: { _, _ in true }) == .nothing)
        // A new action ends the start.
        list.push(.removedProject(UUID(), index: 0, agents: [], view: .home, home: AgentProjectHome(selection: AgentTileSelection(), scroll: 0), wasCurrent: true))
        #expect(!list.actions.contains(start))
        list.endStarts()
        #expect(list.actions.count == 2)
    }

    // MARK: Home

    /// The default rows come from the window's height alone (S7 review
    /// ruling 7): 846 pt 3, 900 pt 3, 800 pt 3, 560 pt 2.
    @Test func defaultRowsComeFromTheWindowHeight() {
        for (height, rows) in [(846.0, 3), (900, 3), (800, 3), (560, 2)] {
            let layout = AgentHomeLayout(width: 1440, visibleHeight: height - AgentTopBar.height - AgentLineView.reserved, density: 0)
            #expect(layout.rows == rows, "\(height) pt")
        }
    }

    /// Arrows step over the places of settled agents; Shift never selects
    /// one.
    @Test func arrowsStepOverSettledPlaces() {
        let ids = (0..<6).map { _ in UUID() }
        let settled: Set<UUID> = [ids[1], ids[4]]
        var selection = AgentTileSelection.only(ids[0])
        selection.move(.right, extend: false, in: ids, columns: 3, skipping: settled)
        #expect(selection.cursor == ids[2])
        selection.move(.down, extend: false, in: ids, columns: 3, skipping: settled)
        #expect(selection.cursor == ids[5])
        selection = .only(ids[0])
        selection.move(.down, extend: false, in: ids, columns: 3, skipping: [ids[3]])
        #expect(selection.cursor == ids[0])
        selection = .only(ids[0])
        selection.move(.right, extend: true, in: ids, columns: 3, skipping: settled)
        #expect(selection.selected == [ids[0], ids[2]])
        var none = AgentTileSelection()
        none.move(.down, extend: false, in: ids, columns: 3, skipping: [ids[0]])
        #expect(none.cursor == ids[1])
    }

    // MARK: Keys

    /// Every chord the table lists has a stated outcome in every context:
    /// a command, "nothing", or a deliberate pass to the terminal or the
    /// field (`AgentChords.passesOn`). None reaches a Ghostty binding by
    /// omission (S7 review ruling 3).
    @Test func everyListedChordHasAnOutcomeInEveryContext() {
        let chords = Set(AgentChords.table.flatMap(\.chords))
        for context in AgentKeyContext.allCases {
            for chord in chords {
                let command = AgentChords.command(for: chord, in: context)
                let passes = AgentChords.passesOn[context]?.contains(chord) == true
                #expect((command != nil) != passes, "\(chord) in \(context): \(String(describing: command)), passes \(passes)")
            }
        }
        #expect(AgentChords.command(for: AgentChord(.returnKey, .command), in: .inside) == .nothing)
        #expect(AgentChords.command(for: AgentChord(.f2, []), in: .homeLine) == .nothing)
    }

    // MARK: The bridge

    /// Settle (flows.md 6.7): never a working agent unless its project is
    /// removed; its CLI ends 60 s later and a working turn it cuts ends
    /// interrupted; undone it comes back in its state; findable all along.
    @Test func settleAndTheCLIsEnd() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let done = try h.addAgent("done")
        let busy = try h.addAgent("busy")
        h.start()
        try h.launch(done)
        try h.completeTurn(done)
        try h.launch(busy)
        try h.startTurn(busy)
        #expect(!h.bridge.settle(id: busy))
        #expect(h.bridge.settle(id: done))
        #expect(try h.agent(done).isRunning)
        h.scheduler.advance(by: 59)
        #expect(try h.agent(done).isRunning)
        h.bridge.unsettle(id: done)
        h.scheduler.advance(by: 5)
        #expect(try h.agent(done).isRunning, "undone within 60 s, its CLI runs on")
        #expect(try h.agent(done).record.state == .finished)

        #expect(h.bridge.settle(id: busy, includingWorking: true))
        h.scheduler.advance(by: 60)
        let agent = try h.agent(busy)
        #expect(!agent.isRunning)
        #expect(agent.record.state == .finished && agent.record.interrupted)
        h.bridge.unsettle(id: busy)
        #expect(!agent.isSettled && !agent.isRunning)
    }

    /// Mark as unread: only a finished agent.
    @Test func markUnread() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("a")
        h.start()
        try h.launch(id)
        try h.startTurn(id)
        #expect(!h.bridge.markUnread(id: id))
        try h.osc(id, "state=done:app=claude-code")
        h.bridge.agentViewed(id)
        #expect(h.bridge.markUnread(id: id))
        #expect(try h.agent(id).record.isWaitingOnYou)
    }

    /// Interrupt and send never interrupts away what the person typed into
    /// the agent's input (S7 review ruling 1): skipped, no Escape sent.
    @Test func interruptingSendSkipsTypedText() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let id = try h.addAgent("a")
        h.start()
        try h.launch(id)
        try h.startTurn(id)
        let rule = String(repeating: "─", count: 60)
        h.host.screens[id] = ["⏺ Working.", rule, "❯\u{00A0}half a line", rule].joined(separator: "\n")
        var result: AgentSendResult?
        h.bridge.send("instead", to: id, by: .person, interrupting: true) { result = $0 }
        #expect(result == .holdsText)
        #expect(h.host.inputs[id] ?? [] == [])
    }
}
