import AppKit
import Testing
@testable import Ghostty

/// The typing line's parts that need no window (native-look.md 4, flows.md
/// "The line", 6.5): the one text field class, the words after a send to
/// several, a project's draft kept across a relaunch, a send to an agent
/// whose CLI does not run or is starting.
@MainActor
struct AgentLineTests {
    private func field() -> AgentTextView {
        let view = AgentTextView(font: .systemFont(ofSize: 14), lineHeight: 22, maxLines: 6, inset: NSSize(width: 0, height: 1))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        return view
    }

    /// Every automatic behaviour is off: plain text, no spelling marks,
    /// no substitutions, no completion, no predictions; its undo is its own.
    @Test func theFieldTypesPlainTextAndNothingElse() {
        let view = field()
        #expect(!view.isRichText)
        #expect(!view.isContinuousSpellCheckingEnabled)
        #expect(!view.isAutomaticQuoteSubstitutionEnabled)
        #expect(!view.isAutomaticDashSubstitutionEnabled)
        #expect(!view.isAutomaticTextCompletionEnabled)
        #expect(view.inlinePredictionType == .no)
        #expect(view.focusRingType == .none)
        #expect(!view.drawsBackground)
        #expect(view.undoManager === view.fieldUndo)
        #expect(!view.isFieldEditor)
    }

    /// Tab, Escape and completion never change the text; Escape and Return
    /// go to the owner's command.
    @Test func keysTheFieldLeavesAlone() {
        let view = field()
        var commands: [Selector] = []
        view.command = { commands.append($0); return $0 != #selector(NSResponder.insertTab(_:)) }
        view.insertText("keep", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        view.complete(nil)
        view.cancelOperation(nil)
        #expect(view.string == "keep")
        #expect(commands.contains(#selector(NSResponder.cancelOperation(_:))))
    }

    /// It grows a line at a time to six lines, then stays at six and
    /// scrolls; the text keeps its first line's place.
    @Test func theFieldGrowsToSixLinesThenScrolls() {
        let view = field()
        #expect(abs(view.textHeight - 24) < 0.01)
        view.insertText("one\ntwo\nthree", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.lineCount == 3)
        #expect(abs(view.textHeight - (3 * 22 + 2)) < 0.01)
        view.insertText("\nfour\nfive\nsix\nseven\neight", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.lineCount == 8)
        #expect(abs(view.textHeight - (6 * 22 + 2)) < 0.01)
        #expect(view.firstBaseline == 1 + AgentMetrics.baseline(.systemFont(ofSize: 14), lineHeight: 22))
    }

    /// Files and folders become their paths, quoted when they hold a space
    /// or a quote.
    @Test func filesBecomePaths() {
        let paths = AgentTextView.paths([
            URL(fileURLWithPath: "/tmp/plain.txt"), URL(fileURLWithPath: "/tmp/a folder/x.txt"), URL(fileURLWithPath: "/tmp/it's"),
        ])
        #expect(paths == "/tmp/plain.txt '/tmp/a folder/x.txt' '/tmp/it'\\''s'")
    }

    /// Replacing the text (a draft, a send) clears its undo history, so ⌘Z
    /// cannot bring back what was sent; it never replaces composing text.
    @Test func settingTheTextStartsAFreshHistory() {
        let view = field()
        view.insertText("sent text", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setText("")
        #expect(!view.fieldUndo.canUndo)
        view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        view.setText("draft")
        #expect(!view.hasMarkedText())
        #expect(view.string == "draft")
    }

    /// The status line after a send to several: one sentence per reason,
    /// singular and plural written out.
    @Test func whatASendToSeveralSays() {
        #expect(AgentSendReport.words(sent: 3, skipped: []).text == "Sent to 3 agents")
        #expect(AgentSendReport.words(sent: 1, skipped: []).text == "Sent to 1 agent")
        let some = AgentSendReport.words(sent: 2, skipped: [(.typed, ["Feeds"]), (.asking, ["Themes", "Search indexer"])])
        #expect(some.text == "Sent to 2. Skipped Feeds: its terminal holds text you typed. Skipped Themes, Search indexer: they are asking questions.")
        #expect(some.seconds == 6)
        #expect(AgentSendReport.words(sent: 0, skipped: [(.menu, ["Feeds"])]).text
            == "Nothing sent. Skipped Feeds: its terminal is showing a menu.")
    }

    /// Each project's draft is kept, and comes back after a relaunch.
    @Test func eachProjectKeepsItsDraftAcrossARelaunch() throws {
        let suite = "clawddy-line-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        let model = AgentWorkspaceModel(defaults: defaults)
        model.setDraft("half a task", in: first)
        model.setDraft("another", in: second)
        model.setDraft("", in: second)
        let relaunched = AgentWorkspaceModel(defaults: defaults)
        #expect(relaunched.draft(in: first) == "half a task")
        #expect(relaunched.draft(in: second) == "")
    }

    /// A send to an agent whose CLI does not run starts it with the text as
    /// its first prompt (flows.md 6.5 step 3); a send to one that is
    /// starting waits for its input to be ready, then goes.
    @Test func aSendStartsAnAgentOrWaitsForItsStart() throws {
        let h = try AgentBridgeHarness()
        defer { h.remove() }
        let stopped = try h.addAgent("stopped")
        let starting = try h.addAgent("starting")
        let other = try h.addAgent("other")
        h.start()
        try h.launch(other)

        var result: AgentSendResult?
        h.bridge.send("rebuild from a clean output folder", to: stopped, by: .person) { result = $0 }
        #expect(result == .sent)
        #expect(h.providers.launchRequests.last?.agentID == stopped)
        #expect(h.providers.launchRequests.last?.firstPrompt == "rebuild from a clean output folder")
        #expect(try h.agent(stopped).record.state == .working)

        try h.activate(starting)
        var waited: AgentSendResult?
        h.bridge.send("and this", to: starting, by: .person) { waited = $0 }
        #expect(waited == nil)
        try h.osc(starting, "state=idle:app=claude-code")
        h.host.screens[starting] = ["⏺ Done.", String(repeating: "─", count: 80), "❯", String(repeating: "─", count: 80)].joined(separator: "\n")
        h.scheduler.advance(by: 0)
        #expect(waited == .sent)
        #expect(h.host.inputs[starting]?.contains(.paste("and this")) == true)
    }
}
