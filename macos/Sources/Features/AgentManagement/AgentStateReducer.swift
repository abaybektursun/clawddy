import Foundation

enum AgentSurfaceState: Codable, Equatable, Sendable {
    case inactive
    case opening
    case open
    case failed
    case closed
}

enum AgentProcessState: Codable, Equatable, Sendable {
    case notStarted
    case launching
    case running
    case exited
}

enum AgentActivityState: Codable, Equatable, Sendable {
    case unknown
    case idle
    case reasoning
    case executing
    case compacting

    var isActive: Bool {
        self == .reasoning || self == .executing
    }
}

enum AgentTelemetryHealth: Equatable, Sendable {
    case notStarted
    case awaiting
    case live
    case unavailable(String)
}

enum AgentTurnState: Equatable, Sendable {
    case inactive
    /// The program reported `working` with no turn active. The turn starts
    /// with the prompt, or when that report has stood for the provider's
    /// `turnStartDelay`, so the `working` of a command that submits no
    /// prompt (`/clear`, `/exit`, `/resume`) starts nothing and changes
    /// nothing on screen.
    case starting
    case active(turnID: String?)
    /// A manual compaction (`/compact`): it ends as a turn does, but
    /// completes nothing.
    case compaction
}

struct AgentCompletionID: Codable, Equatable, Hashable, Sendable {
    var provider: AgentProviderID
    var sessionID: String?
    var turnID: String?
    var launchGeneration: UUID
    var eventID: String
}

/// An agent's state: its stored record, which says what the person sees
/// and survives restarts, and what its current launch knows of its CLI
/// process and turn, which does not.
struct AgentRuntimeSnapshot: Equatable, Sendable {
    var surfaceState: AgentSurfaceState = .inactive
    var processState: AgentProcessState = .notStarted
    var activityState: AgentActivityState = .unknown
    var telemetryHealth: AgentTelemetryHealth = .notStarted
    var lastAppliedCompletion: AgentCompletionID?
    var launchGeneration: UUID?
    var sessionID: String?
    var turnState: AgentTurnState = .inactive
    /// The saved session this launch resumes, until the provider starts it.
    var resumingSessionID: String?
    /// The saved session this launch found missing. The agent can only
    /// start fresh.
    var missingSessionID: String?
    /// The saved session could not be read, so this launch did not start.
    /// The agent can only start fresh.
    var sessionUnreadable = false
    /// This launch created its session, `sessionID`, and the session is not
    /// on disk yet: Claude writes a new session only with its
    /// first entry. It is saved, and becomes the agent's binding, when the
    /// first turn starts (`sessionSaved`); until then a relaunch creates it
    /// again instead of resuming a session that does not exist.
    var sessionUnsaved = false
    /// Failures this launch's `error` reports raised whose `StopFailure`
    /// record has not arrived. Claude reports one failed turn on both
    /// channels, the record 15 to 27 ms after the report and the event file
    /// up to 0.3 s later, when an `idle` or the next turn may already have
    /// come; the record must then not fail a turn again.
    var stopFailuresDue = 0
    /// A sign-in report that has not stood for its provider's
    /// `signInStandTime` yet: agy reports one at many starts while signed
    /// in. It counts once it has stood that long, unless another report
    /// replaces it first (`signInSettled`).
    var pendingSignIn: Ghostty.Action.ProgramStatus?
    /// The login problem was raised by a sign-in report that stood
    /// (`signInSettled`): the next report that shows the CLI past its
    /// sign-in clears it.
    var signInRaisedProblem = false
    /// What the record said before a dialog at start-up (a `blocked` report
    /// before the CLI read its input, such as the folder-trust question)
    /// made it ask; it says so again once the CLI reads its input.
    var stateBeforeStartDialog: AgentRecord.State?
    /// A turn that ended behind that dialog (agy runs a launch's first
    /// prompt before its folder-trust question is answered): it completes
    /// when the dialog does, so the agent asks until then.
    var completedBehindDialog: AgentCompletionID?
    /// The launch's first prompt runs behind a start-up dialog with no
    /// report at all (agy, `AgentReportRules.workingStartsTurn`): a turn
    /// has started that no `working` showed, and its Stop record ends it.
    /// Set when the dialog shows on a launch with a first prompt; cleared
    /// by that Stop, by a `working` (then the turn is a reported one), or
    /// when the launch ends or the agent stops first.
    var hiddenTurn = false
    /// The first line agy's `done` reported for the turn that ended last,
    /// which a Stop that comes with no turn under way must open with to be
    /// that turn's reply (`Reduction.reply(_:opensWith:)`); empty for the
    /// turn no report showed (any Stop is its reply). nil: no Stop to come
    /// is that turn's.
    var replyOpening: String?
    /// Prompts Clawddy sent while the turn worked, which the CLI holds
    /// until the turn ends (`AgentReportRules.queuedMessagesRunNextTurn`).
    var sentWhileWorking: [String] = []
    /// The provider's exit status, as its launch script reported it.
    var exitStatus: Int?
    /// The user stopped the agent: its provider exited with status 0, or
    /// its terminal was closed or "Stop agent" chosen.
    var stoppedOnPurpose = false
    /// The turn's last message, come before the turn's end.
    var pendingMessage: String?
    /// A `done` that ended a `working` before its prompt's record came.
    var endedBeforeItsPrompt: AgentCompletionID?
    /// Codex turns its terminal or title ended whose notify has not come.
    var turnsEndedWithoutNotify = 0
    /// The turn of Codex's last notify.
    var lastNotifiedTurn: String?
    /// This launch gave the CLI its first prompt on the command line.
    var launchPrompted = false
    /// The CLI reads its input: what is typed or sent reaches its prompt
    /// (probes.md, P2 "ready"). Nothing is typed into it before.
    var inputReady = false
    /// Codex reported `idle` before any `working`; its start-up `working`
    /// may still come, so it is ready once 3 s pass without one.
    var inputSettling = false
    /// Codex reported a `working` in this launch.
    var sawWorking = false
    /// A prompt was submitted in this launch.
    var prompted = false
    /// Prompts Clawddy put into the CLI, by the person or by the app, whose
    /// report by the CLI has not come: it is recorded once, when sent.
    var promptsDue: [String] = []
    /// A prompt was sent, or given on the command line, and no turn has
    /// started for it yet: the start-up `idle` before its `working` does not
    /// end the agent's work.
    var promptAwaitsTurn = false
    /// The agent's stored record.
    var record = AgentRecord()
}

enum AgentRuntimeEvent: Equatable, Sendable {
    /// `prompted` when the launch gives the CLI its first prompt.
    case launchRequested(generation: UUID, prompted: Bool = false)
    /// `newSessionID` is the session the launch creates under an ID it
    /// chose, which is not on disk until the first turn.
    case surfaceOpened(generation: UUID, resumedSessionID: String? = nil, newSessionID: String? = nil)
    case launchTimedOut(generation: UUID)
    /// `missingSessionID` when the session it would resume no longer exists.
    case launchFailed(
        generation: UUID, problem: AgentRecord.Problem, sessionUnreadable: Bool = false, missingSessionID: String? = nil)
    case provider(
        generation: UUID,
        provider: AgentProviderID,
        eventID: String,
        event: AgentDomainEvent,
        isViewed: Bool)
    /// The `working` report that put the turn in `.starting` has stood for
    /// the provider's `turnStartDelay`.
    case turnStartSettled(generation: UUID)
    /// Codex's `idle` has stood 3 s without a start-up `working`.
    case inputSettled(generation: UUID)
    /// The sign-in report in `pendingSignIn` has stood for the provider's
    /// `signInStandTime`.
    case signInSettled(generation: UUID)
    /// Clawddy put `prompt` into the CLI and submitted it, for `by`.
    case sent(prompt: String, by: AgentRecord.Prompt.Sender)
    /// The agent's terminal is gone; `byUser` when the user closed it or
    /// chose "Stop agent".
    case surfaceDied(generation: UUID?, byUser: Bool, isViewed: Bool = false)
    /// Clawddy started and read the record: a turn under way when it
    /// quit or crashed was cut off.
    case appStarted
    /// The person opened the agent.
    case opened
    case markedUnread
    /// The person settled it; removing its project settles a working one too.
    case settled(includingWorking: Bool)
    case unsettled
    /// The reset time its usage limit gave has passed.
    case usageLimitReset
    /// The app continues a turn a restart cut off, sending `prompt`.
    case continuedByApp(prompt: String)
    /// A cut-off agent that cannot be continued: no conversation and no
    /// first instruction.
    case notContinued
    /// The agent's name now comes from `source`.
    case named(by: AgentRecord.NameSource)
    /// What its CLI reported could not be read or recorded.
    case reportFailed
}

enum AgentRuntimeEffect: Equatable, Sendable {
    case becameAlive
    /// The session the launch created is on disk now: it is the agent's
    /// binding.
    case sessionSaved
    /// The session the launch resumed does not exist; its binding records
    /// that, so the agent offers only Start Fresh until it is discarded.
    case sessionMissing
    case completed
    case waitingForUser
    case failed
    case unreadChanged
    case providerExited(Int)
    /// The CLI reads its input now (`inputReady`).
    case inputReady
    /// Codex's first `idle` came before its start-up `working`: settle in 3 s.
    case inputSettling
    /// The CLI has started and waits on the person (a dialog or its sign-in
    /// at start-up): the start limit stops.
    case startedAsking
}

/// The one reducer of an agent's state: its record's states and every
/// transition between them (`docs/clawddy-design/flows.md` 2.2), from what
/// the CLI reports in its terminal and hooks and from what the person does.
/// `rules` are how the agent's CLI's reports read (its provider table
/// entry's `reports`).
enum AgentStateReducer {
    static func reduce(
        _ current: AgentRuntimeSnapshot,
        event: AgentRuntimeEvent,
        rules: AgentReportRules = .standard,
        at now: Date = .distantPast
    ) -> (state: AgentRuntimeSnapshot, effects: [AgentRuntimeEffect]) {
        var reduction = Reduction(state: current, rules: rules, now: now)
        reduction.apply(event)
        return (reduction.state, reduction.effects)
    }
}

/// One application of the reducer: the state as it changes, the effects it
/// raises, and the time of the event.
private struct Reduction {
    var state: AgentRuntimeSnapshot
    let rules: AgentReportRules
    let now: Date
    var effects: [AgentRuntimeEffect] = []
    var provider: AgentProviderID = .claudeCode

    init(state: AgentRuntimeSnapshot, rules: AgentReportRules, now: Date) {
        self.state = state
        self.rules = rules
        self.now = now
    }

    var record: AgentRecord {
        get { state.record }
        set { state.record = newValue }
    }

    mutating func apply(_ event: AgentRuntimeEvent) {
        switch event {
        case .launchRequested(let generation, let prompted):
            // A new launch leaves the last one's failure behind.
            if let kind = record.problem?.kind, [.launch, .notInstalled, .conversationMissing, .didNotStart, .openElsewhere].contains(kind) {
                change(to: .finished)
                record.problem = nil
            }
            let kept = state
            state = AgentRuntimeSnapshot(
                surfaceState: .opening,
                processState: .launching,
                activityState: .unknown,
                telemetryHealth: .awaiting,
                lastAppliedCompletion: kept.lastAppliedCompletion,
                launchGeneration: generation,
                sessionID: kept.sessionID,
                turnState: .inactive,
                launchPrompted: prompted,
                record: kept.record)
            state.promptAwaitsTurn = prompted

        case .surfaceOpened(let generation, let resumedSessionID, let newSessionID):
            guard state.launchGeneration == generation else { return }
            state.surfaceState = .open
            state.resumingSessionID = resumedSessionID
            if let newSessionID {
                state.sessionID = newSessionID
                state.sessionUnsaved = true
            }

        case .launchTimedOut(let generation):
            // Its CLI did not come to read its input within the limit.
            guard state.launchGeneration == generation, !state.inputReady,
                  state.processState != .exited
            else { return }
            state.telemetryHealth = .unavailable("It did not start within 30 seconds.")
            stop(AgentRecord.Problem(kind: .didNotStart))

        case .launchFailed(let generation, let problem, let sessionUnreadable, let missingSessionID):
            guard state.launchGeneration == generation else { return }
            state.sessionUnreadable = sessionUnreadable
            if let missingSessionID {
                state.missingSessionID = missingSessionID
                effects.append(.sessionMissing)
            }
            state.surfaceState = .failed
            state.processState = .exited
            state.activityState = .unknown
            state.turnState = .inactive
            stop(problem)

        case .provider(let generation, let provider, let eventID, let domainEvent, let isViewed):
            guard state.launchGeneration == generation else { return }
            applyProvider(domainEvent, provider: provider, generation: generation, eventID: eventID, isViewed: isViewed)

        case .turnStartSettled(let generation):
            guard state.launchGeneration == generation,
                  state.turnState == .starting
            else { return }
            startTurn(activity: .executing)

        case .inputSettled(let generation):
            guard state.launchGeneration == generation, state.inputSettling else { return }
            becomeReady(isViewed: false)

        case .signInSettled(let generation):
            guard state.launchGeneration == generation, state.processState != .exited,
                  let report = state.pendingSignIn
            else { return }
            state.pendingSignIn = nil
            confirmProviderAlive()
            state.telemetryHealth = .live
            failSignIn(report)
            state.signInRaisedProblem = record.problem?.kind == .loginExpired
            if rules.askingAtStartIsStarted && !state.inputReady { effects.append(.startedAsking) }

        case .sent(let raw, let by):
            // Capped as the CLI's report of it is, so that report matches.
            let prompt = String(raw.prefix(AgentRecord.textLimit))
            // Sent into a working CLI, which queues it until the turn ends
            // (flows.md 4.6). agy reports it only when its own turn starts,
            // so the send is the only sign it waits.
            let queued = state.turnState != .inactive && state.turnState != .starting
            record.prompts.append(AgentRecord.Prompt(text: prompt, at: now, by: by, queued: queued))
            trimPrompts()
            state.promptsDue.append(prompt)
            if queued && rules.queuedMessagesRunNextTurn { state.sentWhileWorking.append(prompt) }
            state.promptAwaitsTurn = true
            if record.firstInstruction == nil {
                record.firstInstruction = prompt
                record.firstInstructionAt = now
            }
            if by == .person { record.continuedInARow = 0 }
            // A sent prompt is a turn starting (flows.md 2.2): a quit in the
            // next instant cuts it off.
            if record.state != .working { change(to: .working) }
            clearStop()
            record.interrupted = false

        case .surfaceDied(let generation, let byUser, let isViewed):
            if let generation, state.launchGeneration != generation { return }
            endHiddenTurn()
            let underIt = state.processState == .running && !byUser
            endStartDialog(isViewed: isViewed, completing: !underIt)
            // A provider that was up and went without the user: its terminal
            // closed under it. An exit with a status other than 0 has said
            // so already, with the status.
            if underIt {
                stop(AgentRecord.Problem(kind: .exited))
            } else if record.state == .working || record.state == .asks {
                // Stopped or closed by the person: the turn is over.
                finish(interrupted: true)
            }
            state.stoppedOnPurpose = byUser || (state.processState == .exited && state.exitStatus == 0)
            state.surfaceState = .closed
            state.processState = .exited
            state.activityState = .unknown
            state.turnState = .inactive
            state.resumingSessionID = nil
            state.inputReady = false

        case .appStarted:
            // A turn under way when Clawddy quit or crashed was cut off; its
            // CLI is gone with the app. A settled agent is never continued:
            // its turn ended when its CLI did.
            if record.state == .working {
                if record.settledAt == nil {
                    record.cutOff = true
                } else {
                    finish(interrupted: true)
                }
            }
            record.activity = nil

        case .notContinued:
            // Cut off before its CLI had a conversation or an instruction to
            // start again from: its turn is over.
            guard record.state == .working else { return }
            finish(interrupted: true)

        case .opened:
            // Opening reads a finished turn; it never clears a question, a
            // problem or a reset limit.
            if record.unread {
                record.unread = false
                effects.append(.unreadChanged)
            }

        case .markedUnread:
            guard record.state == .finished, !record.unread else { return }
            record.unread = true
            effects.append(.unreadChanged)

        case .settled(let includingWorking):
            guard record.settledAt == nil, includingWorking || record.state != .working else { return }
            record.settledAt = now

        case .unsettled:
            record.settledAt = nil

        case .usageLimitReset:
            guard record.state == .paused else { return }
            change(to: .limitReset)
            effects.append(.waitingForUser)

        case .continuedByApp(let prompt):
            // The fourth continuation in a row is not sent.
            guard record.mayContinue else {
                record.cutOff = false
                stop(AgentRecord.Problem(kind: .cutOffTooOften))
                return
            }
            record.continuedInARow += 1
            record.prompts.append(AgentRecord.Prompt(text: prompt, at: now, by: .app))
            state.promptsDue.append(String(prompt.prefix(AgentRecord.textLimit)))
            trimPrompts()
            // It goes on with the turn the restart cut off, which keeps its
            // start: the age reads as before the restart.
            if record.state != .working { change(to: .working) }
            clearStop()

        case .named(let source):
            // A name the person gave is the agent's for good.
            guard record.nameSource != .person || source == .person else { return }
            record.nameSource = source

        case .reportFailed:
            stop(AgentRecord.Problem(kind: .reportFailed))
        }
    }

    private mutating func applyProvider(
        _ domainEvent: AgentDomainEvent,
        provider: AgentProviderID,
        generation: UUID,
        eventID: String,
        isViewed: Bool
    ) {
        if case .providerExited(let status) = domainEvent {
            // A launch's provider exits once; a report printed again later
            // changes nothing.
            guard state.processState != .exited else { return }
            endHiddenTurn()
            // "Pre-start" is the launch phase, not "not currently running":
            // a session that started has moved the process to .running, and
            // its exit, with any status, is no launch failure. A launch that
            // already failed because its session is missing keeps saying so.
            let stillLaunching = state.processState == .notStarted || state.processState == .launching
            let failing = status != 0 && state.missingSessionID == nil
            // A dialog at start-up goes with its process: the agent is as
            // the dialog found it, or as the turn behind it ended.
            endStartDialog(isViewed: isViewed, completing: !failing)
            state.processState = .exited
            state.exitStatus = status
            state.activityState = .unknown
            state.turnState = .inactive
            state.inputReady = false
            if failing {
                stop(stillLaunching
                    ? AgentRecord.Problem(kind: .launch, text: "It exited before its session started.")
                    : AgentRecord.Problem(kind: .exited, status: status))
            } else if record.state == .working || record.state == .asks {
                // `/exit` or Control-D during a turn: the turn is over, and
                // a process that has gone asks nothing.
                finish(interrupted: true)
            }
            effects.append(.providerExited(status))
            return
        }

        if case .programStatus(let report) = domainEvent, state.processState != .exited {
            // A sign-in report that must stand is no report yet: it changes
            // nothing until it has stood, and any other report replaces it.
            if report.state == .blocked, report.kind == .auth, rules.signInStandTime > 0 {
                if state.pendingSignIn == nil { state.pendingSignIn = report }
                return
            }
            state.pendingSignIn = nil
        }

        switch domainEvent {
        case .turnCompleted, .messageReported:
            confirmProviderAlive()
        case .turnFailed, .promptSubmitted, .selfStarted, .questionReported:
            // A prompt or a failure the event file delivers after the exit
            // report starts or fails no turn: the provider has gone.
            guard state.processState != .exited else { return }
            confirmProviderAlive()
        case .programStatus(let report):
            // The provider has exited or its terminal has closed: what the
            // terminal reports now is not this launch's provider.
            guard state.processState != .exited else { return }
            // `clear` is no sign of life: Claude sends it when the folder
            // trust dialog is declined and when it exits.
            if report.state != .clear { confirmProviderAlive() }
        case .sessionBound, .manualCompactionStarted, .turnActivityChanged, .sessionEnded, .providerExited:
            break
        }
        state.telemetryHealth = .live

        switch domainEvent {
        case .sessionBound(let sessionID):
            state.sessionID = sessionID ?? state.sessionID
            // The session exists, so a resume found it.
            state.resumingSessionID = nil

        case .promptSubmitted(let text):
            let underWay = state.turnState
            let endedEarly = state.endedBeforeItsPrompt
            state.endedBeforeItsPrompt = nil
            // A prompt reads the turn before it, unless every turn has its
            // `working` (agy): that report reads it, and the record, which
            // can come before it or after the turn ended, changes nothing
            // but the prompts.
            if record.unread && !rules.workingStartsTurn {
                record.unread = false
                effects.append(.unreadChanged)
            }
            if state.turnState == .starting || endedEarly != nil { startTurn(activity: .reasoning) }
            // One reported during a turn waits behind it, unless queued
            // messages run as their own next turn (agy), whose records come
            // only when that turn starts.
            // agy: the hook channel keeps its order, so a Stop waiting in
            // this turn came before this prompt's record: an earlier turn's.
            // A prompt Clawddy sent while the turn worked starts the next
            // turn (agy queues it), and the Stop waiting is this turn's.
            if rules.workingStartsTurn && underWay != .inactive && !Self.isQueued(text, sent: state.sentWhileWorking) {
                state.pendingMessage = nil
            }
            if let text {
                recordPrompt(text, queued: !rules.queuedMessagesRunNextTurn && underWay != .starting && underWay != .inactive)
            }
            if let endedEarly {
                endTurn()
                complete(endedEarly, isViewed: isViewed)
            }

        case .selfStarted:
            // A Stop waiting in the turn came before agy started its next
            // step itself (a wake-up): an earlier step's or turn's.
            if rules.workingStartsTurn && state.turnState != .inactive { state.pendingMessage = nil }

        case .messageReported(let text):
            // Claude's `Stop` is written just before its `done`, but the
            // event file can bring it after: during the turn it waits for
            // the turn's end; after it, it is that turn's message.
            let message = String(text.prefix(AgentRecord.textLimit))
            switch state.turnState {
            case .active, .compaction, .starting: state.pendingMessage = message
            case .inactive where state.hiddenTurn:
                // The end of the turn no report showed: agy runs a launch's
                // first prompt behind its folder-trust dialog.
                state.hiddenTurn = false
                state.promptAwaitsTurn = false
                state.pendingMessage = message
                complete(
                    AgentCompletionID(
                        provider: provider, sessionID: state.sessionID, turnID: nil,
                        launchGeneration: generation, eventID: eventID),
                    isViewed: isViewed)
            case .inactive:
                // agy: only the reply of the turn that ended last replaces
                // the one shown; a Stop that does not begin with what that
                // turn's `done` reported is another turn's or an earlier
                // step's (cli-facts, "`done` and its Stop").
                if rules.doneWithMessageCompletes {
                    guard let line = state.replyOpening, Self.reply(message, opensWith: line) else { return }
                }
                record.lastMessage = message
                record.lastMessageAt = now
            }

        case .questionReported(let text):
            // The hook can come before or after the `blocked` report.
            guard record.state == .asks || state.turnState != .inactive else { return }
            record.question = text

        case .programStatus(let report):
            applyProgramStatus(
                report,
                completion: AgentCompletionID(
                    provider: provider,
                    sessionID: state.sessionID,
                    turnID: nil,
                    launchGeneration: generation,
                    eventID: eventID),
                isViewed: isViewed)

        case .manualCompactionStarted:
            switch state.turnState {
            case .starting:
                // The `working` it follows is the compaction, no blip.
                startTurn(activity: .compacting)
                state.turnState = .compaction
            case .active:
                state.turnState = .compaction
                state.activityState = .compacting
            case .inactive, .compaction:
                // With no turn under way the hook came before its `working`,
                // or after its `done` ended a short compaction; nothing tells
                // the two apart. Marking the next turn would suppress a real
                // completion, so the hook changes nothing.
                break
            }

        case .turnActivityChanged(let activity):
            guard case .active = state.turnState else { return }
            state.activityState = activity

        case .turnCompleted(let turnID):
            // Codex's notify, after its terminal or title already ended that
            // turn, or a second notify of one turn, ends nothing: it must not
            // end the next one.
            if turnID != nil && turnID == state.lastNotifiedTurn { return }
            state.lastNotifiedTurn = turnID
            if state.turnsEndedWithoutNotify > 0 {
                state.turnsEndedWithoutNotify -= 1
                applyPendingMessage()
                return
            }
            endTurn()
            complete(
                AgentCompletionID(
                    provider: provider,
                    sessionID: state.sessionID,
                    turnID: turnID,
                    launchGeneration: generation,
                    eventID: eventID),
                isViewed: isViewed)

        case .turnFailed(let failure):
            // A failed turn fails once. Claude's own `error` report usually
            // comes first, and its record then only tells what kind of
            // failure it was, even after an `idle` or the next turn
            // (`stopFailuresDue`). A record that comes first fails the turn.
            if state.stopFailuresDue > 0 {
                state.stopFailuresDue -= 1
                if record.state == .problem, record.problem?.kind == .error {
                    fail(failure)
                }
                return
            }
            fail(failure)

        case .sessionEnded:
            // The process goes on after `/clear`, whose next `SessionStart`
            // rebinds the agent, and reports its own exit. What a session
            // end does tell: Claude ends a resume of a session it cannot
            // find before starting it, with `SessionEnd`, no `SessionStart`,
            // and exit status 1.
            if let missing = state.resumingSessionID {
                state.resumingSessionID = nil
                state.missingSessionID = missing
                stop(AgentRecord.Problem(kind: .conversationMissing))
                effects.append(.sessionMissing)
            }

        case .providerExited:
            break
        }
    }

    /// What one report the program made about itself (the root record)
    /// means, given the turn it finds. The reports are Claude's, as captured
    /// in `docs/clawddy-refactor/cli-facts.md`; `completion` is the one a
    /// `done` that completes the turn records.
    private mutating func applyProgramStatus(
        _ report: Ghostty.Action.ProgramStatus,
        completion: AgentCompletionID,
        isViewed: Bool
    ) {
        if report.state != .done { state.endedBeforeItsPrompt = nil }
        provider = completion.provider
        // A report past the sign-in clears the login problem a standing
        // sign-in report raised.
        if state.signInRaisedProblem {
            state.signInRaisedProblem = false
            if record.problem?.kind == .loginExpired {
                change(to: .finished)
                record.problem = nil
            }
        }
        noteReadiness(report.state, isViewed: isViewed)
        switch report.state {
        case .working:
            state.promptAwaitsTurn = false
            switch state.turnState {
            case .inactive where rules.workingStartsTurn:
                startTurn(activity: .reasoning)
            case .inactive: state.turnState = .starting
            case .starting: break
            case .active, .compaction:
                // A question answered, or the next step of the turn; a
                // turn behind a start-up dialog leaves the dialog asking.
                if record.state == .asks && state.stateBeforeStartDialog == nil {
                    change(to: .working)
                    record.question = nil
                }
            }
            // Claude's report names the step under way ("Creating empty
            // marker file", cli-facts.md); a bare `working` has none now.
            // agy's names a resumed conversation's title, never a step.
            if state.turnState != .inactive {
                let step = rules.workingMessageIsActivity ? report.message : nil
                record.activity = step.map { AgentSentence.label($0) }.flatMap { $0.isEmpty ? nil : $0 }
            }

        case .blocked:
            if report.kind == .auth {
                failSignIn(report)
                return
            }
            if !state.inputReady && (state.turnState == .inactive || state.turnState == .starting) {
                // A dialog at start-up, such as the folder-trust question:
                // no turn. Answered, the agent is as it was. (A turn under
                // way asks within it, whatever its CLI's readiness says.)
                if record.state != .asks { state.stateBeforeStartDialog = record.state }
                // A launch's first prompt runs behind it (agy).
                if rules.workingStartsTurn && state.promptAwaitsTurn { state.hiddenTurn = true }
                if rules.askingAtStartIsStarted { effects.append(.startedAsking) }
            } else if state.turnState == .inactive || state.turnState == .starting {
                startTurn(activity: .executing)
            }
            // The hook's question, in full, wins over the report's.
            let question = record.question ?? report.message.map(Self.question)
            if record.state != .asks {
                change(to: .asks)
                effects.append(.waitingForUser)
            }
            record.question = question

        case .done:
            switch state.turnState {
            case .inactive:
                // The summary that follows a completed turn, 1.5 to 2.5 s
                // later, or a repeat: never a second completion.
                break
            case .starting:
                // A blip, such as the `/exit` confirmation's `done` 14 ms
                // after its `working`, or a turn shorter than its prompt's
                // record is late: if that record comes, the turn completes.
                state.turnState = .inactive
                state.endedBeforeItsPrompt = completion
            case .active:
                endTurn()
                // Every captured `done` of Claude's that completed a turn was
                // bare; one with a summary ended something else, such as a
                // compaction. agy's always carries the reply's first line,
                // cut at 200 characters: the reply until its Stop record
                // brings the whole of it. A Stop come during the turn is its
                // reply only if it begins with that line: an earlier
                // turn's Stop, or one before a wake-up in this turn, is not.
                if report.message == nil || rules.doneWithMessageCompletes {
                    if rules.doneWithMessageCompletes {
                        let line = report.message ?? ""
                        state.replyOpening = line
                        if let message = report.message,
                           !(state.pendingMessage.map { Self.reply($0, opensWith: line) } ?? false) {
                            state.pendingMessage = String(message.prefix(AgentRecord.textLimit))
                        }
                    }
                    if completion.provider == .codex { state.turnsEndedWithoutNotify += 1 }
                    complete(completion, isViewed: isViewed)
                } else {
                    finish(interrupted: false)
                }
            case .compaction:
                endTurn()
                finish(interrupted: false)
            }

        case .idle:
            // An interrupt and Esc on a prompt end a turn here; `/clear`
            // ends only its blip. No turn is completed and nothing is
            // notified.
            let wasUnderWay = state.turnState != .inactive && state.turnState != .starting
            endTurn()
            if wasUnderWay && record.state != .problem && record.state != .paused {
                finish(interrupted: true)
                forgetSendsGivenBack()
            } else {
                leaveWorkingWithoutTurn()
            }

        case .clear:
            // Resets the activity; the launch goes on until the provider's
            // exit is reported. A turn under way is over.
            let known = state.activityState != .unknown
            let wasUnderWay = state.turnState != .inactive && state.turnState != .starting
            endTurn()
            if !known { state.activityState = .unknown }
            if wasUnderWay && record.state == .working {
                finish(interrupted: true)
            } else {
                leaveWorkingWithoutTurn()
            }

        case .error:
            // agy's usage limit came first, from its Stop, with no words: the
            // report is its words, and the agent stays paused. A limit that
            // has its words meets a new failure.
            if rules.failureRecordComesFirst, record.state == .paused, record.limit?.message == nil {
                let text = report.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let text, !text.isEmpty { record.limit?.message = text }
                return
            }
            // Never a blip: a failure can come 106 ms after its `working`.
            if state.turnState == .starting { startTurn(activity: .executing) }
            // A failure this report raises has its `StopFailure` record to
            // come; one the record raised first has had it.
            if record.state != .problem && record.state != .paused && !rules.failureRecordComesFirst { state.stopFailuresDue += 1 }
            fail(AgentFailure(text: report.message))
        }
    }

    /// Whether this report shows the CLI reading its input (probes.md, P2
    /// "ready"): an `idle`, `done` or `error`, or a `working` when the launch
    /// gave it its first prompt. Codex reports `idle`, then a start-up
    /// `working` of up to 2.4 s, then `idle`: its first `idle` counts only
    /// after a `working`, or once 3 s pass without one. A `blocked` report,
    /// such as Claude's folder-trust dialog, is never readiness.
    private mutating func noteReadiness(_ report: Ghostty.Action.ProgramStatus.State, isViewed: Bool) {
        guard !state.inputReady else { return }
        // A turn run behind a start-up dialog (a `working` or `done` while
        // it shows) is no answer to it: the CLI still waits on the person.
        if state.stateBeforeStartDialog != nil && (report == .working || report == .done) { return }
        switch report {
        case .working:
            state.inputSettling = false
            if state.launchPrompted {
                becomeReady(isViewed: isViewed)
            } else if provider == .codex {
                state.sawWorking = true
            }
        case .idle, .done, .error:
            if provider == .codex && !state.sawWorking && !state.launchPrompted {
                guard !state.inputSettling else { return }
                state.inputSettling = true
                effects.append(.inputSettling)
            } else {
                // An `error` that answers the dialog stops the agent with a
                // problem: a turn ended behind it keeps its reply only.
                becomeReady(isViewed: isViewed, completing: report != .error)
            }
        case .blocked, .clear:
            break
        }
    }

    private mutating func becomeReady(isViewed: Bool, completing: Bool = true) {
        state.inputReady = true
        state.inputSettling = false
        effects.append(.inputReady)
        if record.problem?.kind == .didNotStart {
            change(to: .finished)
            record.problem = nil
        }
        endStartDialog(isViewed: isViewed, completing: completing)
    }

    /// The start-up dialog is answered, or its process has gone: the agent
    /// is as the dialog found it, and a turn that ended behind it completes
    /// now, once.
    /// `completing` false when the agent is about to stop with a problem:
    /// the turn's reply is kept, but it is not also a finished, unread turn.
    private mutating func endStartDialog(isViewed: Bool, completing: Bool = true) {
        guard let before = state.stateBeforeStartDialog else { return }
        state.stateBeforeStartDialog = nil
        if record.state == .asks {
            change(to: before)
            record.question = nil
        }
        if let completion = state.completedBehindDialog {
            state.completedBehindDialog = nil
            if completing {
                complete(completion, isViewed: isViewed)
            } else {
                applyPendingMessage()
            }
        }
    }

    /// A sign-in that no longer works stops the agent with the login
    /// problem. It starts no turn: a saved last reply stays, and a repeated
    /// report changes nothing.
    private mutating func failSignIn(_ report: Ghostty.Action.ProgramStatus) {
        fail(AgentFailure(error: "authentication_failed", text: report.message))
    }

    /// An interrupt gave back, unsent, the messages Clawddy sent while the
    /// turn worked: they are no prompts, and a later prompt with the same
    /// words is the person's own.
    private mutating func forgetSendsGivenBack() {
        guard !state.sentWhileWorking.isEmpty else { return }
        // Every send since the turn's `working` is among them: no prompt
        // awaits a turn now.
        state.promptAwaitsTurn = false
        for prompt in state.sentWhileWorking {
            if let due = state.promptsDue.lastIndex(of: prompt) { state.promptsDue.remove(at: due) }
            if let sent = record.prompts.lastIndex(where: { $0.text == prompt }) { record.prompts.remove(at: sent) }
        }
        state.sentWhileWorking = []
    }

    /// The question in a `blocked` report's message, without Claude's
    /// "answer: " before a question.
    private static func question(_ message: String) -> String {
        message.hasPrefix("answer: ") ? String(message.dropFirst("answer: ".count)) : message
    }

    // MARK: Turns

    /// Starts a turn: the agent works, and what it asked, the problem it
    /// stopped with, its limit and its unread mark are behind it.
    private mutating func startTurn(turnID: String? = nil, activity: AgentActivityState) {
        // A turn a report shows is no hidden one, and a Stop that comes now
        // is no reply of the turn before.
        state.hiddenTurn = false
        state.replyOpening = nil
        // What was sent while the turn before worked runs in this one.
        state.sentWhileWorking = []
        if rules.queuedMessagesRunNextTurn { clearQueued() }
        state.turnState = .active(turnID: turnID)
        state.activityState = activity
        state.prompted = true
        if state.stateBeforeStartDialog != nil {
            // Behind a start-up dialog: the agent asks until it is answered.
            state.stateBeforeStartDialog = .working
        } else {
            if record.state != .working { change(to: .working) }
            clearStop()
        }
        record.interrupted = false
        record.lastMessage = nil
        record.lastMessageAt = nil
        state.pendingMessage = nil
        // A turn the person starts after a cut-off one ends that story; a
        // continuation's own turn keeps it, and says so.
        if record.continuedInARow == 0 { record.cutOff = false }
        // The turn's prompt is the session's first entry, which writes it.
        if state.sessionUnsaved {
            state.sessionUnsaved = false
            effects.append(.sessionSaved)
        }
    }

    private mutating func endTurn() {
        state.turnState = .inactive
        state.activityState = .idle
    }

    /// Records `completion` once: the agent is finished, unread unless it
    /// is viewed.
    private mutating func complete(_ completion: AgentCompletionID, isViewed: Bool) {
        guard state.lastAppliedCompletion != completion else { return }
        if state.stateBeforeStartDialog != nil {
            // Behind a start-up dialog: it completes when the dialog ends.
            state.completedBehindDialog = completion
            return
        }
        state.lastAppliedCompletion = completion
        effects.append(.completed)
        finish(interrupted: false)
        applyPendingMessage()
        record.continuedInARow = 0
        if !isViewed, !record.unread {
            record.unread = true
            effects.append(.unreadChanged)
        }
    }

    private mutating func applyPendingMessage() {
        guard let message = state.pendingMessage else { return }
        state.pendingMessage = nil
        record.lastMessage = message
        record.lastMessageAt = now
    }

    /// The agent is finished; `interrupted` when the person stopped it.
    private mutating func finish(interrupted: Bool) {
        if interrupted { state.pendingMessage = nil }
        if record.state != .finished { change(to: .finished) }
        record.interrupted = interrupted
        record.cutOff = false
        // Claude Code and Codex ran the queued messages in this turn; agy
        // runs them as the next one, unless an interrupt gave them back.
        if interrupted || !rules.queuedMessagesRunNextTurn { clearQueued() }
        record.activity = nil
        record.question = nil
    }

    /// The turn the queued prompts waited behind has ended.
    private mutating func clearQueued() {
        for index in record.prompts.indices where record.prompts[index].queued {
            record.prompts[index].queued = false
        }
    }

    /// The turn failed: at a usage limit the agent pauses, a sign-in that no
    /// longer works or any other failure stops it with a problem. A turn
    /// that has already failed only takes what this failure adds.
    private mutating func fail(_ failure: AgentFailure) {
        endTurn()
        // A failed turn's prompt has had its turn.
        state.promptAwaitsTurn = false
        let text = failure.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = text?.isEmpty == false ? text : nil
        if failure.isUsageLimit {
            // With no words of its own, the failure report's (agy's `error`
            // that came before its Stop) are the limit's.
            let reported = record.problem?.kind == .error ? record.problem?.text : nil
            if record.state != .paused { change(to: .paused) }
            record.problem = nil
            record.limit = AgentRecord.UsageLimit(
                message: message ?? record.limit?.message ?? reported,
                resetsAt: failure.resetsAt ?? record.limit?.resetsAt)
            finishStopping()
            return
        }
        let kind: AgentRecord.Problem.Kind = failure.isLogin ? .loginExpired : .error
        let raises = record.state != .problem
        stop(AgentRecord.Problem(kind: kind, text: message ?? (record.problem?.kind == kind ? record.problem?.text : nil)))
        if !raises { effects.removeAll { $0 == .failed } }
    }

    /// The agent stops with `problem`, announced once.
    private mutating func stop(_ problem: AgentRecord.Problem) {
        if record.state != .problem || record.problem != problem {
            if record.state != .problem { effects.append(.failed) }
            change(to: .problem)
            record.problem = problem
        }
        record.limit = nil
        finishStopping()
    }

    private mutating func finishStopping() {
        endHiddenTurn()
        // A turn that ended behind the start dialog keeps its reply only:
        // the agent stopped before the dialog was answered.
        if state.completedBehindDialog != nil {
            state.completedBehindDialog = nil
            applyPendingMessage()
        }
        record.cutOff = false
        clearQueued()
        record.activity = nil
        record.question = nil
        record.interrupted = false
    }

    /// The turn no report showed ends without its Stop: its launch ended or
    /// the agent stopped. A Stop still on its way brings its reply and
    /// completes nothing.
    private mutating func endHiddenTurn() {
        guard state.hiddenTurn else { return }
        state.hiddenTurn = false
        state.replyOpening = ""
    }

    /// Whether `reply` is the one whose first line agy's `done` reported as
    /// `line` (cli-facts, "`done` and its Stop"): a line cut to 199
    /// characters and "…" begins the reply; an uncut one is its whole first
    /// line. An empty line: any reply.
    private static func reply(_ reply: String, opensWith line: String) -> Bool {
        if line.isEmpty { return true }
        if line.count == 200 && line.hasSuffix("…") { return reply.hasPrefix(line.dropLast()) }
        return reply == line || reply.hasPrefix(line + "\n")
    }

    /// Whether the prompt `raw` is one Clawddy sent while the turn worked,
    /// alone or joined with the others (agy runs them as the next turn).
    private static func isQueued(_ raw: String?, sent: [String]) -> Bool {
        guard let raw else { return false }
        let text = String(AgentRecord.prompt(raw).prefix(AgentRecord.textLimit))
        return sent.contains(text) || joinedRun(of: sent, equalTo: text) != nil
    }

    /// An `idle` or `clear` with no turn under way: the agent is not working,
    /// unless a prompt it was given is still on its way to a turn (the
    /// start-up `idle` a launch with a prompt reports first, probes.md P5).
    private mutating func leaveWorkingWithoutTurn() {
        guard record.state == .working else { return }
        if state.promptAwaitsTurn {
            state.promptAwaitsTurn = false
            return
        }
        finish(interrupted: false)
    }

    private mutating func clearStop() {
        record.question = nil
        record.problem = nil
        record.limit = nil
        if record.unread {
            record.unread = false
            effects.append(.unreadChanged)
        }
    }

    private mutating func change(to newState: AgentRecord.State) {
        record.state = newState
        record.changedAt = now
    }

    /// Keeps a submitted prompt: the first is the agent's first instruction;
    /// one sent while the turn was already under way waits in the CLI for
    /// that turn.
    private mutating func recordPrompt(_ raw: String, queued: Bool) {
        let text = String(AgentRecord.prompt(raw).prefix(AgentRecord.textLimit))
        state.prompted = true
        // One Clawddy sent, recorded when it was sent.
        if let due = state.promptsDue.firstIndex(of: text) ?? state.promptsDue.firstIndex(of: String(raw.prefix(AgentRecord.textLimit))) {
            let sent = state.promptsDue.remove(at: due)
            // Its record shows it waits behind the running turn.
            if queued, let index = record.prompts.lastIndex(where: { $0.text == sent }) { record.prompts[index].queued = true }
            return
        }
        // Several Clawddy sent while a turn worked, run as one prompt joined
        // by newlines (agy, probes `stage5/queue2`).
        if let run = Self.joinedRun(of: state.promptsDue, equalTo: text) {
            state.promptsDue.removeSubrange(run)
            return
        }
        // Claude's own note that a background command ended comes as a
        // prompt; nobody typed it (seen 2026-11-24, Claude Code 2.1.331).
        if raw.hasPrefix("<task-notification>") { return }
        record.prompts.append(AgentRecord.Prompt(text: text, at: now, by: .person, queued: queued))
        record.continuedInARow = 0
        trimPrompts()
        if record.firstInstruction == nil {
            record.firstInstruction = text
            record.firstInstructionAt = now
        }
    }

    /// The consecutive prompts of `due` that, joined by newlines, are `text`.
    private static func joinedRun(of due: [String], equalTo text: String) -> ClosedRange<Int>? {
        for start in due.indices {
            var joined = due[start]
            for end in due.indices.dropFirst(start + 1) {
                joined += "\n" + due[end]
                if joined == text { return start...end }
            }
        }
        return nil
    }

    private mutating func trimPrompts() {
        if record.prompts.count > AgentRecord.promptLimit {
            record.prompts.removeFirst(record.prompts.count - AgentRecord.promptLimit)
        }
    }

    /// The provider is seen alive. A launch whose provider has exited, or
    /// whose terminal has closed, is never alive again: a hook record that
    /// arrives after the exit report was written before the exit, and the
    /// event file delivered it late.
    private mutating func confirmProviderAlive() {
        guard state.processState == .notStarted || state.processState == .launching else { return }
        state.processState = .running
        state.resumingSessionID = nil
        effects.append(.becameAlive)
    }
}

extension AgentRecord {
    /// A prompt as the person wrote it: Claude wraps a long paste in
    /// `<pasted_content id="…">` tags in the prompt it reports (probes,
    /// 2026-11-23), which are taken off.
    static func prompt(_ reported: String) -> String {
        reported
            .replacingOccurrences(of: #"\n*<pasted_content id="[^"]*">\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n?</pasted_content id="[^"]*">\n*"#, with: "", options: .regularExpression)
    }
}
