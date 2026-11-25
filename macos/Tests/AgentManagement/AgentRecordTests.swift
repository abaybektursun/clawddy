import Foundation
import Testing
@testable import Ghostty

/// The agent's record and the one reducer that moves it between the states
/// of `docs/clawddy-design/flows.md` 2.1, one test per transition of 2.2,
/// driven by the reports and hook records the CLIs really send. Each test
/// states the whole record it expects, not one field.
struct AgentRecordTests {
    private let generation = UUID()
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Transitions

    /// A turn starts from any state but settled: the agent works, and its
    /// question, problem, limit, unread mark and last message are behind it.
    @Test func aTurnStartsFromEveryOtherState() {
        let befores = [
            record { $0.unread = true; $0.lastMessage = "Old."; $0.lastMessageAt = start },
            record { $0.state = .asks; $0.question = "A or B?" },
            record { $0.state = .problem; $0.problem = AgentRecord.Problem(kind: .error, text: "boom") },
            record { $0.state = .paused; $0.limit = AgentRecord.UsageLimit(message: "limit") },
            record { $0.state = .limitReset },
        ]
        for before in befores {
            var state = reduce(running(before), report("state=working"), at: 10)
            state = reduce(state, hook(.promptSubmitted("go on")), at: 11)
            #expect(state.record == record {
                $0.state = .working
                $0.changedAt = at(11)
                $0.firstInstruction = "go on"
                $0.firstInstructionAt = at(11)
                $0.prompts = [AgentRecord.Prompt(text: "go on", at: at(11), by: .person)]
            }, "\(before.state)")
        }
        // A `working` that stands for the start delay starts it too.
        let settled = AgentStateReducer.reduce(
            reduce(running(record()), report("state=working")), event: .turnStartSettled(generation: generation), at: at(2))
        #expect(settled.state.record == record { $0.state = .working; $0.changedAt = at(2) })
    }

    @Test func theCLIAsksAQuestion() {
        let result = AgentStateReducer.reduce(
            turn(), event: hook(.programStatus(status("state=blocked:kind=question", message: "answer: A or B? (A · B)"))), at: at(5))
        #expect(result.state.record == turnRecord { $0.state = .asks; $0.changedAt = at(5); $0.question = "A or B? (A · B)" })
        #expect(result.effects == [.waitingForUser])
        // The hook brings the question in full, after the report or before it.
        let full = reduce(result.state, hook(.questionReported("Which layout, A or B?")))
        #expect(full.record == turnRecord { $0.state = .asks; $0.changedAt = at(5); $0.question = "Which layout, A or B?" })
        let early = reduce(reduce(turn(), hook(.questionReported("Which layout, A or B?"))),
                           report("state=blocked:kind=question", message: "answer: A or B?"), at: 6)
        #expect(early.record == turnRecord { $0.state = .asks; $0.changedAt = at(6); $0.question = "Which layout, A or B?" })
        #expect(early.record.sentence(cli: .claudeCode) == .cli("Which layout, A or B?"))
        // A permission asks too; a hook question with no turn changes nothing.
        #expect(reduce(turn(), report("state=blocked:kind=permission")).record == turnRecord { $0.state = .asks })
        #expect(reduce(running(record()), hook(.questionReported("late"))).record == running(record()).record)
    }

    @Test func anAnsweredQuestionWorksAgain() {
        let asking = reduce(turn(), report("state=blocked:kind=question", message: "A?"), at: 5)
        let answered = reduce(asking, report("state=working"), at: 6)
        #expect(answered.record == turnRecord { $0.changedAt = at(6) })
    }

    /// The turn ends finished and unread, unless the agent is shown; its
    /// message comes from the Stop hook, a moment before or after the `done`.
    @Test func theTurnEnds() {
        let done = AgentStateReducer.reduce(turn(), event: hook(.programStatus(status("state=done"))), at: at(20))
        #expect(done.state.record == turnRecord { $0.state = .finished; $0.changedAt = at(20); $0.unread = true })
        #expect(done.effects == [.completed, .unreadChanged])
        let message = reduce(done.state, hook(.messageReported("Fixed it.\n\nDetails follow.")), at: 21)
        #expect(message.record == turnRecord {
            $0.state = .finished; $0.changedAt = at(20); $0.unread = true
            $0.lastMessage = "Fixed it.\n\nDetails follow."; $0.lastMessageAt = at(21)
        })
        #expect(message.record.sentence(cli: .claudeCode) == .cli("Fixed it."))
        // The Stop record can come before the `done`: it waits for it.
        let early = reduce(reduce(turn(), hook(.messageReported("Early.")), at: 19), report("state=done"), at: 20)
        #expect(early.record == turnRecord {
            $0.state = .finished; $0.changedAt = at(20); $0.unread = true; $0.lastMessage = "Early."; $0.lastMessageAt = at(20)
        })

        let viewed = AgentStateReducer.reduce(turn(), event: hook(.programStatus(status("state=done")), viewed: true), at: at(20))
        #expect(viewed.state.record == turnRecord { $0.state = .finished; $0.changedAt = at(20) })
        #expect(viewed.effects == [.completed])
    }

    /// A turn shorter than its prompt's late record still completes when the
    /// record comes; a `done` blip with no prompt after it completes nothing.
    @Test func aSubSecondTurnCompletes() {
        var state = reduce(running(record()), report("state=working"), at: 1)
        state = reduce(state, report("state=done"), at: 1.4)
        #expect(state.record == running(record()).record)
        let result = AgentStateReducer.reduce(state, event: hook(.promptSubmitted("quick")), at: at(1.6))
        #expect(result.state.record == record {
            $0.state = .finished; $0.changedAt = at(1.6); $0.unread = true
            $0.firstInstruction = "quick"; $0.firstInstructionAt = at(1.6)
            $0.prompts = [AgentRecord.Prompt(text: "quick", at: at(1.6), by: .person)]
        })
        #expect(result.effects.contains(.completed))
        let blip = reduce(reduce(reduce(running(record()), report("state=working")), report("state=done")), report("state=idle"))
        #expect(reduce(blip, hook(.promptSubmitted("later"))).record.state == .finished)
        #expect(reduce(blip, hook(.promptSubmitted("later"))).lastAppliedCompletion == nil)
    }

    @Test func thePersonInterrupts() {
        let interrupted = reduce(turn(), report("state=idle"), at: 7)
        #expect(interrupted.record == turnRecord { $0.state = .finished; $0.changedAt = at(7); $0.interrupted = true })
        #expect(interrupted.record.sentence(cli: .claudeCode) == .app("You interrupted it."))
        // An `idle` with no turn under way, as after `/clear`, interrupts nothing.
        let quiet = running(record { $0.lastMessage = "Done." })
        #expect(reduce(quiet, report("state=idle")).record == quiet.record)
    }

    /// Opening reads a finished turn and nothing else.
    @Test func readByOpening() {
        let opened = AgentStateReducer.reduce(running(record { $0.unread = true }), event: .opened)
        #expect(opened.state.record == record())
        #expect(opened.effects == [.unreadChanged])
        for kept in [AgentRecord.State.asks, .problem, .limitReset] {
            let before = record { $0.state = kept }
            #expect(AgentStateReducer.reduce(running(before), event: .opened).state.record == before)
        }
    }

    /// A finished agent opened but not answered stays finished, quiet, while
    /// its CLI's later reports come.
    @Test func aFinishedAgentOpenedButNotAnsweredStaysQuiet() {
        var state = reduce(turn(), report("state=done"), at: 20)
        state = AgentStateReducer.reduce(state, event: .opened).state
        state = reduce(state, report("state=done", message: "replied ok"), at: 21)
        state = reduce(state, hook(.messageReported("ok")), at: 22)
        #expect(state.record == turnRecord {
            $0.state = .finished; $0.changedAt = at(20); $0.lastMessage = "ok"; $0.lastMessageAt = at(22)
        })
        #expect(!state.record.isWaitingOnYou)
    }

    @Test func markedUnread() {
        let marked = AgentStateReducer.reduce(running(record()), event: .markedUnread)
        #expect(marked.state.record == record { $0.unread = true })
        #expect(marked.effects == [.unreadChanged] && marked.state.record.isWaitingOnYou)
        for other in [AgentRecord.State.working, .asks, .problem, .paused, .limitReset] {
            let before = record { $0.state = other }
            #expect(AgentStateReducer.reduce(running(before), event: .markedUnread).state.record == before)
        }
    }

    /// Settle takes any agent but a working one; removing its project takes
    /// a working one too; undo returns the state before.
    @Test func settleAndUndo() {
        let asking = record { $0.state = .asks; $0.question = "A or B?" }
        let settled = AgentStateReducer.reduce(running(asking), event: .settled(includingWorking: false), at: at(3))
        #expect(settled.state.record == record { $0.state = .asks; $0.question = "A or B?"; $0.settledAt = at(3) })
        #expect(!settled.state.record.isWaitingOnYou)
        #expect(AgentStateReducer.reduce(settled.state, event: .unsettled).state.record == asking)

        let working = record { $0.state = .working }
        #expect(AgentStateReducer.reduce(running(working), event: .settled(includingWorking: false)).state.record == working)
        #expect(AgentStateReducer.reduce(running(working), event: .settled(includingWorking: true), at: at(4)).state.record
            == record { $0.state = .working; $0.settledAt = at(4) })
    }

    /// A usage limit pauses the agent with the CLI's own message and the reset
    /// time; when that time passes the agent waits on the person.
    @Test func usageLimitAndItsReset() {
        let resets = at(3_600)
        var state = reduce(turn(), report("state=error", message: "Claude usage limit reached."), at: 5)
        #expect(state.record.state == .problem && state.stopFailuresDue == 1)
        state = reduce(state, hook(.turnFailed(AgentFailure(error: "rate_limit", text: "Claude usage limit reached.", resetsAt: resets))), at: 6)
        let paused = turnRecord {
            $0.state = .paused; $0.changedAt = at(6)
            $0.limit = AgentRecord.UsageLimit(message: "Claude usage limit reached.", resetsAt: resets)
        }
        #expect(state.record == paused)
        #expect(state.record.sentence(cli: .claudeCode, time: { _ in "3:00 pm" })
            == .cli("Claude usage limit reached. Resets at 3:00 pm."))
        #expect(!state.record.isWaitingOnYou)

        let reset = AgentStateReducer.reduce(state, event: .usageLimitReset, at: resets)
        var expected = paused
        expected.state = .limitReset
        expected.changedAt = resets
        #expect(reset.state.record == expected)
        #expect(reset.effects == [.waitingForUser] && reset.state.record.isWaitingOnYou)
        #expect(reset.state.record.sentence(cli: .claudeCode)
            == .app("Usage limit reset. Open it to continue."))
        #expect(AgentStateReducer.reduce(turn(), event: .usageLimitReset).state.record == turn().record)
    }

    /// Only the CLI's own report says a login expired, and the sentence is
    /// always the app's; the next turn clears it.
    @Test func loginExpired() {
        let blocked = AgentStateReducer.reduce(
            turn(), event: hook(.programStatus(status("state=blocked:kind=auth", message: "OAuth token has expired. Please run /login"))),
            at: at(5))
        let expired = turnRecord {
            $0.state = .problem; $0.changedAt = at(5)
            $0.problem = AgentRecord.Problem(kind: .loginExpired, text: "OAuth token has expired. Please run /login")
        }
        #expect(blocked.state.record == expired)
        #expect(blocked.effects == [.failed])
        let hooked = AgentStateReducer.reduce(blocked.state, event: hook(.turnFailed(AgentFailure(error: "authentication_failed"))))
        #expect(hooked.state.record == expired && hooked.effects.isEmpty)
        // The app's words; the CLI's raw text stays in its terminal.
        #expect(hooked.state.record.sentence(cli: .claudeCode) == .app("Login expired. Open it and run /login."))
        let silent = reduce(turn(), hook(.turnFailed(AgentFailure(error: "authentication_failed"))), at: 5)
        #expect(silent.record == turnRecord {
            $0.state = .problem; $0.changedAt = at(5); $0.problem = AgentRecord.Problem(kind: .loginExpired)
        })
        #expect(silent.record.sentence(cli: .claudeCode) == .app("Login expired. Open it and run /login."))
        let next = reduce(reduce(silent, report("state=working")), hook(.promptSubmitted("again")), at: 9)
        #expect(next.record.state == .working && next.record.problem == nil)
    }

    /// Claude's note that a background command ended arrives as a prompt:
    /// it is nobody's prompt, and is not a reply of the
    /// person's that would end a run of continuations.
    @Test func aTaskNotificationIsNobodysPrompt() {
        var start = running(AgentRecord())
        start.record.continuedInARow = 2
        let note = "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"
        let after = reduce(reduce(start, hook(.promptSubmitted(note)), at: 5), report("state=working"), at: 6)
        #expect(after.record.prompts.isEmpty && after.record.firstInstruction == nil)
        #expect(after.record.continuedInARow == 2)
    }

    @Test func theTurnFailsWithAnError() {
        let failed = AgentStateReducer.reduce(turn(), event: hook(.programStatus(status("state=error", message: "API Error: overloaded"))), at: at(5))
        #expect(failed.state.record == turnRecord {
            $0.state = .problem; $0.changedAt = at(5); $0.problem = AgentRecord.Problem(kind: .error, text: "API Error: overloaded")
        })
        #expect(failed.effects == [.failed])
        #expect(failed.state.record.sentence(cli: .codex) == .cli("API Error: overloaded"))
        #expect(reduce(turn(), report("state=error")).record.sentence(cli: .codex)
            == .app("Stopped with an error. Open it to see why."))
    }

    /// Any exit or close during a turn ends it: with status 0, or when the
    /// person stops the agent or closes its terminal, as interrupted; with
    /// another status, or a terminal closing under a running CLI, with a
    /// problem. Outside a turn an exit with status 0 changes nothing, except
    /// that a process that has gone asks nothing (final review 7): an agent
    /// asking is then finished, interrupted.
    @Test func theCLIExits() {
        let interrupted = turnRecord { $0.state = .finished; $0.changedAt = at(8); $0.interrupted = true }
        #expect(reduce(turn(), hook(.providerExited(status: 0)), at: 8).record == interrupted)
        #expect(reduce(turn(), .surfaceDied(generation: generation, byUser: true), at: 8).record == interrupted)
        let quiet = AgentStateReducer.reduce(running(record()), event: hook(.providerExited(status: 0)))
        #expect(quiet.state.record == record())
        #expect(quiet.effects == [.providerExited(0)])
        let asking = AgentStateReducer.reduce(running(record { $0.state = .asks; $0.question = "A?" }), event: hook(.providerExited(status: 0)))
        #expect(asking.state.record == record { $0.interrupted = true; $0.changedAt = .distantPast })
        #expect(asking.effects == [.providerExited(0)])
        let crashed = AgentStateReducer.reduce(turn(), event: hook(.providerExited(status: 137)), at: at(8))
        #expect(crashed.state.record == turnRecord {
            $0.state = .problem; $0.changedAt = at(8); $0.problem = AgentRecord.Problem(kind: .exited, status: 137)
        })
        #expect(crashed.effects == [.failed, .providerExited(137)])
        #expect(crashed.state.record.sentence(cli: .claudeCode) == .app(
            "Claude Code stopped (signal 9). Type here to continue."))
        #expect(reduce(running(record()), hook(.providerExited(status: 2))).record.sentence(cli: .codex).text
            == "Codex stopped (status 2). Type here to continue.")
        #expect(reduce(turn(), .surfaceDied(generation: generation, byUser: false), at: 8).record == turnRecord {
            $0.state = .problem; $0.changedAt = at(8); $0.problem = AgentRecord.Problem(kind: .exited)
        })
    }

    /// A quit and a crash leave the same record, written at the last change:
    /// at the next start a working agent was cut off, a question stays with
    /// its text, any other comes back as it was.
    @Test func cutOffByQuitOrCrash() {
        let working = turn().record
        #expect(AgentStateReducer.reduce(AgentRuntimeSnapshot(record: working), event: .appStarted).state.record
            == turnRecord { $0.cutOff = true })
        for kept in [record { $0.unread = true }, record { $0.state = .asks; $0.question = "A or B?" }] {
            #expect(AgentStateReducer.reduce(AgentRuntimeSnapshot(record: kept), event: .appStarted).state.record == kept)
        }
    }

    /// The app continues a cut-off turn at most three times in a row; the
    /// prompt it sends is marked as the app's and recorded once; a finished
    /// turn starts the count again.
    @Test func restartedByTheApp() {
        let prompt = "[Sent by Clawddy after a restart, not typed by you] Continue where you left off."
        var state = AgentRuntimeSnapshot(record: record { $0.state = .working; $0.cutOff = true })
        state = AgentStateReducer.reduce(state, event: .continuedByApp(prompt: prompt), at: at(1)).state
        let continued = record {
            // The turn the restart cut off goes on: its start, its age, stay.
            $0.state = .working; $0.cutOff = true; $0.continuedInARow = 1
            $0.prompts = [AgentRecord.Prompt(text: prompt, at: at(1), by: .app)]
        }
        #expect(state.record == continued)
        #expect(state.record.sentence(cli: .claudeCode) == .app("Continuing after a restart (1 of 3)"))
        state.launchGeneration = generation
        state.processState = .running
        state = AgentStateReducer.reduce(state, event: hook(.promptSubmitted(prompt)), at: at(2)).state
        #expect(state.record == continued)

        state = AgentStateReducer.reduce(state, event: .continuedByApp(prompt: prompt)).state
        state = AgentStateReducer.reduce(state, event: .continuedByApp(prompt: prompt)).state
        #expect(state.record.continuedInARow == 3)
        let fourth = AgentStateReducer.reduce(state, event: .continuedByApp(prompt: prompt), at: at(3))
        var stopped = state.record
        stopped.state = .problem
        stopped.changedAt = at(3)
        stopped.cutOff = false
        stopped.problem = AgentRecord.Problem(kind: .cutOffTooOften)
        #expect(fourth.state.record == stopped)
        #expect(fourth.effects == [.failed])
        #expect(fourth.state.record.sentence(cli: .claudeCode)
            == .app("Cut off by three restarts. Open it to continue."))

        state.turnState = .active(turnID: nil)
        let finished = reduce(state, report("state=done"))
        #expect(finished.record.continuedInARow == 0 && !finished.record.cutOff)
    }

    /// What the CLI reported but Clawddy could not read is a problem until
    /// the next turn.
    @Test func aLostReportIsAProblem() {
        let lost = AgentStateReducer.reduce(turn(), event: .reportFailed, at: at(4))
        #expect(lost.state.record == turnRecord {
            $0.state = .problem; $0.changedAt = at(4); $0.problem = AgentRecord.Problem(kind: .reportFailed)
        })
        #expect(lost.effects == [.failed])
        #expect(lost.state.record.isWaitingOnYou)
        #expect(lost.state.record.sentence(cli: .codex) == .app(
            "Could not read Codex status. Open it to check."))
    }

    /// Codex's notify after its terminal or title already ended the turn,
    /// or a second notify of one turn, ends nothing: not the next turn,
    /// already queued.
    @Test func aLateCodexNotifyEndsNoOtherTurn() {
        var state = codexTurn()
        state = reduce(state, codexReport("state=done"), at: 5)
        #expect(state.record.state == .finished && state.turnsEndedWithoutNotify == 1)
        state = reduce(reduce(state, codexReport("state=working")), .turnStartSettled(generation: generation), at: 6)
        #expect(state.record.state == .working)
        state = reduce(state, codexHook(.turnCompleted(turnID: "turn-1")), at: 7)
        state = reduce(state, codexHook(.messageReported("First.")), at: 7)
        #expect(state.record.state == .working && state.turnsEndedWithoutNotify == 0)
        state = reduce(state, codexHook(.turnCompleted(turnID: "turn-2")), at: 8)
        #expect(state.record.state == .finished && state.record.changedAt == at(8))
        let again = AgentStateReducer.reduce(
            reduce(reduce(state, codexReport("state=working")), .turnStartSettled(generation: generation)),
            event: codexHook(.turnCompleted(turnID: "turn-2")))
        #expect(again.state.record.state == .working && again.effects.isEmpty)
    }

    // MARK: Prompts, names and the record's fields

    /// The first prompt is the first instruction; a prompt sent while the
    /// turn is under way waits in the CLI, and the sentence says so; Claude's
    /// paste wrapper is taken off; only the last 20 prompts are kept.
    @Test func promptsAreKept() {
        var state = reduce(running(record()), report("state=working"))
        state = AgentStateReducer.reduce(state, event: hook(.promptSubmitted("fix the sheet")), at: at(1)).state
        #expect(state.record.firstInstruction == "fix the sheet" && state.record.firstInstructionAt == at(1))
        #expect(state.record.prompts == [AgentRecord.Prompt(text: "fix the sheet", at: at(1), by: .person)])
        state = reduce(state, report("state=working", message: "Running the tests"))
        state = reduce(state, hook(.promptSubmitted("also log it")))
        #expect(state.record.queued == "also log it")
        #expect(state.record.sentence(cli: .claudeCode) == .cli("Running the tests You sent: also log it"))
        state = reduce(state, report("state=done"))
        #expect(state.record.queued == nil && state.record.firstInstruction == "fix the sheet")

        let pasted = "\n\n<pasted_content id=\"a3d7\">\nline 1\nline 2\n</pasted_content id=\"a3d7\">\n"
        state = reduce(reduce(state, report("state=working")), hook(.promptSubmitted(pasted)))
        #expect(state.record.prompts.last?.text == "line 1\nline 2")
        for index in 0..<30 { state = reduce(state, hook(.promptSubmitted("p\(index)"))) }
        #expect(state.record.prompts.count == AgentRecord.promptLimit)
        #expect(state.record.prompts.last?.text == "p29")
    }

    /// A name the person gives stays for good; the CLI's title replaces only
    /// a name that is not the person's.
    @Test func aRenameStays() {
        var state = AgentRuntimeSnapshot(record: record { $0.nameSource = .app })
        state = AgentStateReducer.reduce(state, event: .named(by: .cli)).state
        #expect(state.record == record { $0.nameSource = .cli })
        state = AgentStateReducer.reduce(state, event: .named(by: .person)).state
        state = AgentStateReducer.reduce(state, event: .named(by: .cli)).state
        state = AgentStateReducer.reduce(state, event: .named(by: .firstInstruction)).state
        #expect(state.record == record { $0.nameSource = .person })
    }

    /// The record is stored whole, readable by its owner only, and reads back
    /// equal; a record with fewer fields reads with the defaults.
    @Test func theRecordIsStoredAndReadBack() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawddy-record-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        #expect(try AgentRecord.load(id, from: folder) == nil)
        var full = turn().record
        full.prompts = [AgentRecord.Prompt(text: "go \"on\" 🧪\n", at: Date(timeIntervalSince1970: 1_800_000_000), by: .person)]
        full.lastMessage = "Done."
        full.limit = AgentRecord.UsageLimit(message: "limit", resetsAt: Date(timeIntervalSince1970: 1_800_003_600))
        full.problem = AgentRecord.Problem(kind: .exited, status: 2)
        full.changedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try AgentRecord.save(full, for: id, in: folder)
        #expect(try AgentRecord.load(id, from: folder) == full)
        let attributes = try FileManager.default.attributesOfItem(atPath: AgentRecord.url(id, folder).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try Data(#"{"state":"asks","question":"A or B?"}"#.utf8).write(to: AgentRecord.url(id, folder))
        let partial = try #require(try AgentRecord.load(id, from: folder))
        #expect(partial.state == .asks && partial.question == "A or B?" && partial.prompts.isEmpty)
        try Data("{".utf8).write(to: AgentRecord.url(id, folder))
        #expect(throws: (any Error).self) { try AgentRecord.load(id, from: folder) }
    }

    // MARK: The sentence

    /// What a finished agent said, as its sentence: the first paragraph of
    /// prose, Markdown marks gone, whitespace collapsed; a list a colon
    /// introduces follows it; a question that ends the message follows too;
    /// headings, code and tables are not prose; a long paragraph is cut.
    @Test func theSentenceOfRealLookingMessages() {
        func sentence(_ message: String) -> AgentSentence {
            record { $0.lastMessage = message }.sentence(cli: .claudeCode)
        }
        #expect(sentence("Fixed it: the chart asked for the **next** day an hour early.\n\nAdded `TideChartTests`; all 186 pass.")
            == .cli("Fixed it: the chart asked for the next day an hour early."))
        #expect(sentence("""
            ## Summary

            I changed the unit handling in [WindFormatter](Sources/WindFormatter.swift)
            so the barbs   follow the knots setting.

            ```swift
            let knots = metres * 1.943_84
            ```

            | file | change |
            |---|---|
            | WindFormatter.swift | +12 −3 |
            """) == .cli("I changed the unit handling in WindFormatter so the barbs follow the knots setting."))
        #expect(sentence("Done:\n\n- Fixed the GPX export\n- Added a test\n- Updated the docs")
            == .cli("Done: Fixed the GPX export; Added a test; Updated the docs"))
        #expect(sentence("1. Read the store\n2. Fixed the query")
            == .cli("Read the store; Fixed the query"))
        #expect(sentence("""
            The alarm is quiet when the phone is set to silent.

            I tried three layouts; screenshots are in /tmp.

            Sound the siren even on silent, or vibrate only when silent?
            """) == .cli("The alarm is quiet when the phone is set to silent. Sound the siren even on silent, or vibrate only when silent?"))
        let long = sentence(String(repeating: "word ", count: 200))
        #expect(long.text.count <= AgentSentence.limit + 1 && long.text.hasSuffix("…"))
        // Only code, or only a table: its first line, as plain text.
        #expect(sentence("```swift\nlet x = retry(3)\n```") == .cli("let x = retry(3)"))
        #expect(sentence("| file | change |\n|---|---|\n| a.swift | +3 |") == .cli("file | change"))
        #expect(record().sentence(cli: .claudeCode) == .app("No output yet"))
    }

    /// The CLI's words reach a label without control characters, escape
    /// sequences or bidirectional overrides, and never longer than the cap.
    @Test func cliWordsAreMadeSafeForALabel() {
        func sentence(_ message: String) -> String { record { $0.lastMessage = message }.sentence(cli: .codex).text }
        #expect(sentence("Done \u{202E}evil.exe") == "Done evil.exe")
        #expect(sentence("\u{1B}[31mRed\u{1B}[0m and \u{1B}]0;title\u{07}plain") == "Red and plain")
        #expect(sentence("NUL\u{0}here\u{7F}\u{85}") == "NULhere")
        let long = sentence(String(repeating: "x", count: 30_000))
        #expect(long.count <= AgentSentence.limit + 1)
        let asking = record { $0.state = .asks; $0.question = "Which?\u{2066}\u{1B}[2J" }
        #expect(asking.sentence(cli: .codex) == .cli("Which?"))
        let failing = record { $0.state = .problem; $0.problem = AgentRecord.Problem(kind: .error, text: "\u{1B}[1mBold\u{202D}") }
        #expect(failing.sentence(cli: .codex) == .cli("Bold"))
        #expect(AgentConversationTitle.name(from: "Fix\u{202E} the \u{1B}[31mchart", folder: nil) == "Fix the chart")
    }

    /// A working agent says the step its CLI reports now, else the last
    /// instruction it was given, as written and not in italic; "Working"
    /// only when neither exists. A queued message follows, made safe.
    @Test func aWorkingAgentsSentence() {
        let told = record {
            $0.state = .working
            $0.prompts = [
                AgentRecord.Prompt(text: "first pass", at: start, by: .person),
                AgentRecord.Prompt(text: "split the offline chart download into packs so sailors fetch only their coast", at: start, by: .app),
            ]
        }
        #expect(told.sentence(cli: .claudeCode)
            == .cli("split the offline chart download into packs so sailors fetch only their coast"))
        var stepping = told
        stepping.activity = "Creating empty marker file"
        #expect(stepping.sentence(cli: .claudeCode) == .cli("Creating empty marker file"))
        stepping.prompts.append(AgentRecord.Prompt(text: "also \u{1B}[31mthe tests\u{202E}", at: start, by: .person, queued: true))
        #expect(stepping.sentence(cli: .claudeCode) == .cli("Creating empty marker file You sent: also the tests"))
        #expect(record { $0.state = .working }.sentence(cli: .codex) == .app("Working"))
        let launch = record { $0.state = .problem; $0.problem = AgentRecord.Problem(kind: .launch, text: "bad \u{1B}[1mpath\u{0}") }
        #expect(launch.sentence(cli: .codex) == .app("bad path"))
    }

    /// The step Claude's `working` report names is the activity; a bare
    /// `working` clears it. A sent prompt starts the agent working at once.
    @Test func theReportedStepAndASentPrompt() {
        let stepping = reduce(turn(), report("state=working", message: "Creating empty marker file"), at: 3)
        #expect(stepping.record == turnRecord { $0.activity = "Creating empty marker file" })
        #expect(reduce(stepping, report("state=working"), at: 4).record == turnRecord())
        let finished = reduce(turn(), report("state=done"), at: 5)
        let sent = reduce(finished, .sent(prompt: "and the docs", by: .app), at: 6)
        #expect(sent.record == turnRecord {
            $0.changedAt = at(6)
            $0.prompts.append(AgentRecord.Prompt(text: "and the docs", at: at(6), by: .app))
        })
    }

    /// The app's sentences, set in italic, where the CLI gave none.
    @Test func theAppsSentences() {
        func sentence(_ change: (inout AgentRecord) -> Void) -> AgentSentence {
            record(change).sentence(cli: .codex, time: { _ in "3:00 pm" })
        }
        #expect(sentence { $0.state = .working } == .app("Working"))
        #expect(sentence { $0.state = .working; $0.activity = "Running the tests" } == .cli("Running the tests"))
        #expect(sentence { $0.state = .asks } == .app("Has a question"))
        #expect(sentence { $0.state = .paused } == .app("Paused at the usage limit. Codex gave no reset time."))
        #expect(sentence { $0.state = .paused; $0.limit = AgentRecord.UsageLimit(resetsAt: Date()) }
            == .app("Paused at the usage limit, which resets at 3:00 pm."))
        #expect(sentence { $0.state = .paused; $0.limit = AgentRecord.UsageLimit(message: "Limit. Your limit will reset at 3pm.", resetsAt: Date()) }
            == .cli("Limit. Your limit will reset at 3pm."))
        #expect(sentence { $0.state = .problem; $0.problem = AgentRecord.Problem(kind: .notInstalled) }
            == .app("Codex is not installed. Install it, then type to start."))
        #expect(sentence { $0.state = .problem; $0.problem = AgentRecord.Problem(kind: .conversationMissing) }
            == .app("Codex cannot find this conversation. Type to start fresh."))
    }

    /// Every sentence that names the CLI names each CLI the same way
    /// (words.md, "Sentences the app writes on a tile"); only the step after
    /// an expired login differs, since agy has no /login.
    @Test(arguments: AgentProviderID.allCases)
    func theSentencesNameEachCLI(_ provider: AgentProviderID) {
        func sentence(_ kind: AgentRecord.Problem.Kind, status: Int? = nil) -> AgentSentence {
            record { $0.state = .problem; $0.problem = AgentRecord.Problem(kind: kind, status: status) }.sentence(cli: provider)
        }
        let cli = provider.displayName
        #expect(sentence(.notInstalled) == .app("\(cli) is not installed. Install it, then type to start."))
        #expect(sentence(.conversationMissing) == .app("\(cli) cannot find this conversation. Type to start fresh."))
        #expect(sentence(.openElsewhere) == .app("Open in another terminal. Close it there to continue."))
        #expect(sentence(.reportFailed) == .app("Could not read \(cli) status. Open it to check."))
        #expect(sentence(.didNotStart) == .app("\(cli) did not start in 30 s. Type here to try again."))
        #expect(sentence(.exited, status: 1) == .app("\(cli) stopped (status 1). Type here to continue."))
        #expect(sentence(.loginExpired) == .app(provider == .antigravity
            ? "Login expired. Open it and sign in again." : "Login expired. Open it and run /login."))
        #expect(record { $0.state = .paused }.sentence(cli: provider) == .app("Paused at the usage limit. \(cli) gave no reset time."))
    }

    /// Final review 6: the record knows which prompts wait behind the
    /// running turn, so the sentence is the running turn's instruction and
    /// then "You sent:" the last queued one, with two queued and with one
    /// that repeats the running prompt; each CLI's order of records: Claude
    /// reports a queued prompt at once, agy when its own turn starts, Codex
    /// not at all.
    @Test(arguments: AgentProviderID.allCases)
    func queuedPromptsAreKnownByTheRecord(_ provider: AgentProviderID) {
        let nowhere = URL(fileURLWithPath: "/nonexistent")
        let rules: AgentReportRules = {
            switch provider {
            case .claudeCode: return .standard
            case .codex: return CodexProvider(root: AgentDataRoot(url: nowhere), configFile: nowhere).entry.reports
            case .antigravity: return AntigravityProvider(root: AgentDataRoot(url: nowhere), dataFolder: nowhere).entry.reports
            }
        }()
        func apply(_ state: AgentRuntimeSnapshot, _ event: AgentRuntimeEvent) -> AgentRuntimeSnapshot {
            AgentStateReducer.reduce(state, event: event, rules: rules, at: start).state
        }
        func event(_ domain: AgentDomainEvent) -> AgentRuntimeEvent {
            .provider(generation: generation, provider: provider, eventID: UUID().uuidString, event: domain, isViewed: false)
        }
        var state = apply(running(record()), .sent(prompt: "count slowly", by: .person))
        state = apply(state, event(.programStatus(status("state=working"))))
        switch provider {
        case .claudeCode, .antigravity: state = apply(state, event(.promptSubmitted("count slowly")))
        case .codex: state = apply(state, .turnStartSettled(generation: generation))
        }
        func send(_ text: String) {
            state = apply(state, .sent(prompt: text, by: .person))
            if provider == .claudeCode { state = apply(state, event(.promptSubmitted(text))) }
        }
        send("queued one")
        #expect(state.record.sentence(cli: provider) == .cli("count slowly You sent: queued one"), "\(provider)")
        send("count slowly")
        #expect(state.record.sentence(cli: provider) == .cli("count slowly You sent: count slowly"), "\(provider)")
        #expect(state.record.prompts.map(\.queued) == [false, true, true], "\(provider)")
        state = apply(state, event(.programStatus(status("state=done", message: provider == .antigravity ? "Counted." : nil))))
        #expect(state.record.state == .finished && state.record.queued == nil, "\(provider)")
        #expect(state.record.prompts.allSatisfy { !$0.queued }, "\(provider)")
    }

    // MARK: Helpers

    private func at(_ seconds: TimeInterval) -> Date { start + seconds }

    private func record(_ change: (inout AgentRecord) -> Void = { _ in }) -> AgentRecord {
        var record = AgentRecord()
        record.changedAt = start
        change(&record)
        return record
    }

    /// The agent with its CLI running, idle at its prompt.
    private func running(_ record: AgentRecord) -> AgentRuntimeSnapshot {
        var state = AgentRuntimeSnapshot(
            surfaceState: .open,
            processState: .running,
            activityState: .idle,
            telemetryHealth: .live,
            launchGeneration: generation,
            record: record)
        state.inputReady = true
        return state
    }

    /// The agent in a turn, started by "fix it" at the start time.
    private func turn() -> AgentRuntimeSnapshot {
        reduce(reduce(running(record()), report("state=working")), hook(.promptSubmitted("fix it")))
    }

    /// `turn()`'s record, changed.
    private func turnRecord(_ change: (inout AgentRecord) -> Void = { _ in }) -> AgentRecord {
        record {
            $0.state = .working
            $0.firstInstruction = "fix it"
            $0.firstInstructionAt = start
            $0.prompts = [AgentRecord.Prompt(text: "fix it", at: start, by: .person)]
            change(&$0)
        }
    }

    private func codexTurn() -> AgentRuntimeSnapshot {
        reduce(reduce(running(record()), codexReport("state=working")), .turnStartSettled(generation: generation))
    }

    private func codexReport(_ body: String) -> AgentRuntimeEvent { codexHook(.programStatus(status(body))) }

    private func codexHook(_ event: AgentDomainEvent) -> AgentRuntimeEvent {
        .provider(generation: generation, provider: .codex, eventID: UUID().uuidString, event: event, isViewed: false)
    }

    /// A report as `state=<state>[:kind=<kind>]`, with its message.
    private func status(_ body: String, message: String? = nil) -> Ghostty.Action.ProgramStatus {
        let states: [String: Ghostty.Action.ProgramStatus.State] = [
            "idle": .idle, "working": .working, "done": .done, "blocked": .blocked, "error": .error, "clear": .clear,
        ]
        let kinds: [String: Ghostty.Action.ProgramStatus.Kind] = [
            "permission": .permission, "question": .question, "auth": .auth,
        ]
        var fields: [String: String] = [:]
        for pair in body.split(separator: ":") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            fields[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
        }
        return Ghostty.Action.ProgramStatus(
            state: states[fields["state"] ?? ""] ?? .clear,
            kind: fields["kind"].flatMap { kinds[$0] },
            progress: nil, id: nil, app: nil, title: nil, message: message)
    }

    private func report(_ body: String, message: String? = nil) -> AgentRuntimeEvent {
        hook(.programStatus(status(body, message: message)))
    }

    private func hook(_ event: AgentDomainEvent, viewed: Bool = false) -> AgentRuntimeEvent {
        .provider(generation: generation, provider: .claudeCode, eventID: UUID().uuidString, event: event, isViewed: viewed)
    }

    private func reduce(_ state: AgentRuntimeSnapshot, _ event: AgentRuntimeEvent, at seconds: TimeInterval = 0) -> AgentRuntimeSnapshot {
        AgentStateReducer.reduce(state, event: event, at: at(seconds)).state
    }
}
