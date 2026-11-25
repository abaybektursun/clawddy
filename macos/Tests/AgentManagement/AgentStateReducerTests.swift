import Foundation
import Observation
import Testing
@testable import Ghostty

struct AgentStateReducerTests {
    /// One reducer application is one observable mutation of the agent, so a
    /// view never sees some fields of an event applied and others not. An
    /// application that changes nothing is no mutation.
    @MainActor
    @Test func applyIsOneObservableMutation() {
        let agent = AgentInstance(entry: AgentEntry(name: "Agent"))
        let mutations = MutationCounter {
            _ = agent.shownState
            _ = (agent.surfaceState, agent.processState, agent.activityState, agent.record)
            _ = (agent.telemetryHealth, agent.lastAppliedCompletion, agent.launchGeneration)
            _ = (agent.sessionID, agent.turnState)
        }
        let generation = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        // Surface, process, telemetry and generation change.
        agent.apply(.launchRequested(generation: generation), at: now)
        #expect(mutations.count == 1)

        // Process, activity, telemetry and session change.
        agent.apply(providerEvent(
            generation,
            id: "start",
            event: status(.idle)), at: now)
        #expect(mutations.count == 2)
        #expect(agent.processState == .running)

        // An event of another launch changes nothing.
        agent.apply(.surfaceOpened(generation: UUID()), at: now)
        #expect(mutations.count == 2)
    }

    @Test func launchSeparatesSurfaceFromProviderProcess() {
        let generation = UUID()
        var state = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: generation)).state

        #expect(state.surfaceState == .opening)
        #expect(state.processState == .launching)
        #expect(state.telemetryHealth == .awaiting)

        state = AgentStateReducer.reduce(
            state,
            event: .surfaceOpened(generation: generation)).state
        #expect(state.surfaceState == .open)
        #expect(state.processState == .launching)

        let exited = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "exit",
                event: .providerExited(status: 0)))
        #expect(exited.state.surfaceState == .open)
        #expect(exited.state.processState == .exited)
        #expect(exited.effects == [.providerExited(0)])
    }

    /// Review S1: a session the launch created is saved, and named for the
    /// next launch, by its first turn and nothing earlier: Claude writes a
    /// new or forked session only with its first entry. Being alive saves
    /// nothing; a turn that fails or waits at once saves it too; later turns
    /// save nothing more.
    @Test func createdSessionIsSavedByItsFirstTurnOnly() {
        let generation = UUID()
        func report(_ state: Ghostty.Action.ProgramStatus.State) -> AgentRuntimeEvent {
            .provider(
                generation: generation,
                provider: .claudeCode,
                eventID: UUID().uuidString,
                event: .programStatus(Ghostty.Action.ProgramStatus(
                    state: state, kind: nil, progress: nil, id: nil,
                    app: "claude-code", title: nil, message: nil)),
                isViewed: false)
        }
        var state = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(sessionID: "earlier"),
            event: .launchRequested(generation: generation)).state
        state = AgentStateReducer.reduce(
            state,
            event: .surfaceOpened(generation: generation, newSessionID: "chosen")).state
        #expect(state.sessionID == "chosen" && state.sessionUnsaved)

        let alive = AgentStateReducer.reduce(state, event: report(.idle))
        #expect(alive.effects == [.becameAlive, .inputReady])
        #expect(alive.state.sessionUnsaved)
        let working = AgentStateReducer.reduce(alive.state, event: report(.working))
        #expect(working.effects.isEmpty && working.state.sessionUnsaved)
        let started = AgentStateReducer.reduce(working.state, event: .turnStartSettled(generation: generation))
        #expect(started.effects == [.sessionSaved])
        #expect(!started.state.sessionUnsaved && started.state.sessionID == "chosen")

        var next = AgentStateReducer.reduce(started.state, event: report(.done)).state
        next = AgentStateReducer.reduce(next, event: report(.working)).state
        #expect(!AgentStateReducer.reduce(next, event: .turnStartSettled(generation: generation))
            .effects.contains(.sessionSaved))

        // A failure or a permission prompt before the `working` settles.
        for first in [Ghostty.Action.ProgramStatus.State.error, .blocked] {
            #expect(AgentStateReducer.reduce(working.state, event: report(first)).effects.contains(.sessionSaved))
        }
        // A launch that resumes a saved session has nothing to save.
        let resumed = AgentStateReducer.reduce(
            AgentStateReducer.reduce(
                AgentRuntimeSnapshot(),
                event: .launchRequested(generation: generation)).state,
            event: .surfaceOpened(generation: generation, resumedSessionID: "saved")).state
        #expect(!resumed.sessionUnsaved)
    }

    @Test func nonzeroExitBeforeFirstLifecycleEventIsAStartFailure() {
        let generation = UUID()
        let launching = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: generation)).state
        let failed = AgentStateReducer.reduce(
            launching,
            event: providerEvent(
                generation,
                id: "exit",
                event: .providerExited(status: 127)))

        #expect(failed.state.processState == .exited)
        #expect(failed.state.record.problem?.text == "It exited before its session started.")
        #expect(failed.effects == [.failed, .providerExited(127)])
    }

    @Test func nonzeroExitAfterAnOpenSurfaceButBeforeASessionIsStillAStartFailure() {
        let generation = UUID()
        var state = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: generation)).state
        state = AgentStateReducer.reduce(
            state,
            event: .surfaceOpened(generation: generation)).state

        let failed = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "exit",
                event: .providerExited(status: 127)))

        #expect(failed.state.processState == .exited)
        #expect(failed.state.record.problem?.text == "It exited before its session started.")
        #expect(failed.effects == [.failed, .providerExited(127)])
    }

    @Test func sessionEndThenNonzeroExitDoesNotBecomeALaunchFailure() {
        let generation = UUID()
        var state = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: generation)).state
        state = AgentStateReducer.reduce(
            state,
            event: .surfaceOpened(generation: generation)).state
        let started = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "session",
                event: status(.idle)))
        #expect(started.state.processState == .running)

        // A session end is not the process's exit.
        let ended = AgentStateReducer.reduce(
            started.state,
            event: providerEvent(generation, id: "session-end", event: .sessionEnded))
        #expect(ended.state.processState == .running)
        #expect(ended.state.record.problem == nil)

        let exited = AgentStateReducer.reduce(
            ended.state,
            event: providerEvent(
                generation,
                id: "exit",
                event: .providerExited(status: 130)))

        // An exit with a status other than 0 after the session started is no
        // launch failure, but the CLI stopped unexpectedly.
        #expect(exited.state.processState == .exited)
        #expect(exited.state.surfaceState == .open)
        #expect(exited.state.turnState == .inactive)
        #expect(exited.state.record.problem == AgentRecord.Problem(kind: .exited, status: 130))
        #expect(exited.effects == [.failed, .providerExited(130)])
    }

    /// A session end before any session start does not mark the process
    /// exited, so a nonzero exit that follows is still a start failure: a
    /// fork of a session Claude cannot find ends this way.
    @Test func sessionEndBeforeSessionStartDoesNotHideAStartFailure() {
        let generation = UUID()
        var state = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: generation)).state
        state = AgentStateReducer.reduce(
            state,
            event: .surfaceOpened(generation: generation)).state
        state = AgentStateReducer.reduce(
            state,
            event: providerEvent(generation, id: "session-end", event: .sessionEnded)).state
        #expect(state.processState == .launching)

        let exited = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "exit",
                event: .providerExited(status: 130)))

        #expect(exited.state.record.problem?.text == "It exited before its session started.")
        #expect(exited.effects == [.failed, .providerExited(130)])
    }

    @Test func nonzeroExitAfterAStartedSessionWithoutSessionEndIsNotALaunchFailure() {
        let generation = UUID()
        var state = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: generation)).state
        state = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "session",
                event: status(.idle))).state

        let exited = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "exit",
                event: .providerExited(status: 130)))

        #expect(exited.state.processState == .exited)
        #expect(exited.state.record.problem == AgentRecord.Problem(kind: .exited, status: 130))
        #expect(exited.effects == [.failed, .providerExited(130)])
    }

    @Test func staleEventsCannotMutateANewerLaunch() {
        let oldGeneration = UUID()
        let currentGeneration = UUID()
        let state = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: currentGeneration)).state

        let staleHook = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                oldGeneration,
                id: "stale",
                event: .promptSubmitted("old")))
        #expect(staleHook.state == state)
        #expect(staleHook.effects.isEmpty)

        let staleFailure = AgentStateReducer.reduce(
            state,
            event: .launchFailed(generation: oldGeneration, problem: AgentRecord.Problem(kind: .launch, text: "old")))
        #expect(staleFailure.state == state)
        #expect(staleFailure.effects.isEmpty)
    }

    @Test func completionIsUnreadOnlyWhenNotViewed() {
        let generation = UUID()
        var state = runningState(generation)
        state.turnState = .active(turnID: nil)

        let unread = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "turn-complete",
                event: .turnCompleted(turnID: "turn-1")))
        #expect(unread.state.activityState == .idle)
        #expect(unread.state.lastAppliedCompletion?.turnID == "turn-1")
        #expect(unread.effects == [.completed, .unreadChanged])

        let viewed = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "viewed-complete",
                event: .turnCompleted(turnID: "turn-1"),
                viewed: true))
        #expect(!viewed.state.record.unread)
        #expect(viewed.effects == [.completed])
    }

    @Test func distinctCompletionEventsDoNotCollapseWithoutTurnIDs() {
        let generation = UUID()
        var state = runningState(generation)
        state = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "first",
                event: .turnCompleted(turnID: nil))).state
        let first = state.lastAppliedCompletion

        state = AgentStateReducer.reduce(state, event: .opened).state
        let secondResult = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "second",
                event: .turnCompleted(turnID: nil)))
        #expect(secondResult.state.lastAppliedCompletion != first)
        #expect(secondResult.state.lastAppliedCompletion?.eventID == "second")
        #expect(secondResult.effects == [.completed, .unreadChanged])
    }

    @Test func aPermissionReportConfirmsTheProviderAndAsks() {
        let generation = UUID()
        let launching = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: generation)).state
        let result = AgentStateReducer.reduce(
            launching,
            event: providerEvent(generation, id: "permission", event: status(.blocked, kind: .permission)))

        #expect(result.state.processState == .running)
        #expect(result.state.record.state == .asks)
        #expect(result.effects == [.becameAlive, .waitingForUser])
    }

    @Test func authenticationAndInputAreFirstClassAttentionStates() {
        let generation = UUID()
        let launching = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: generation)).state
        let authentication = AgentStateReducer.reduce(
            launching,
            event: providerEvent(generation, id: "auth", event: status(.blocked, kind: .auth)))
        #expect(authentication.state.record.problem == AgentRecord.Problem(kind: .loginExpired))
        #expect(authentication.effects == [.becameAlive, .failed])

        let input = AgentStateReducer.reduce(
            runningState(generation),
            event: providerEvent(generation, id: "input", event: status(.blocked, kind: .question)))
        #expect(input.state.record.state == .asks)
        #expect(input.effects == [.waitingForUser])
    }

    @Test func runtimeFailureDoesNotMasqueradeAsLaunchFailure() {
        let generation = UUID()
        let result = AgentStateReducer.reduce(
            runningState(generation),
            event: providerEvent(
                generation,
                id: "runtime-error",
                event: .turnFailed(AgentFailure())))

        #expect(result.state.surfaceState == .open)
        #expect(result.state.processState == .running)
        #expect(result.state.record.problem == AgentRecord.Problem(kind: .error))
        #expect(result.effects == [.failed])
    }

    @Test func stopFailureStillEndsTheTurn() {
        let generation = UUID()
        var running = runningState(generation)
        running.turnState = .active(turnID: nil)
        let failed = AgentStateReducer.reduce(
            running,
            event: providerEvent(
                generation,
                id: "stop-failure",
                event: .turnFailed(AgentFailure())))

        #expect(failed.state.turnState == .inactive)
        #expect(failed.state.activityState == .idle)
        #expect(failed.state.record.problem == AgentRecord.Problem(kind: .error))
        #expect(failed.effects == [.failed])

        let lateActivity = AgentStateReducer.reduce(
            failed.state,
            event: providerEvent(
                generation,
                id: "late-activity",
                event: .turnActivityChanged(.reasoning)))
        #expect(lateActivity.state.turnState == .inactive)
        #expect(lateActivity.state.activityState == .idle)
        #expect(lateActivity.effects.isEmpty)
    }

    @Test func replayedCompletionIsIdempotentAfterItWasViewed() {
        let generation = UUID()
        let event = providerEvent(
            generation,
            id: "stable-event-id",
            event: .turnCompleted(turnID: "turn-1"))
        var state = AgentStateReducer.reduce(runningState(generation), event: event).state
        state = AgentStateReducer.reduce(state, event: .opened).state

        let replay = AgentStateReducer.reduce(state, event: event)
        #expect(!replay.state.record.unread)
        #expect(replay.state.lastAppliedCompletion?.eventID == "stable-event-id")
        #expect(replay.effects.isEmpty)
    }

    @Test func timeoutDegradesTelemetryAndFirstEventRecovers() {
        let generation = UUID()
        var state = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: generation)).state
        state = AgentStateReducer.reduce(
            state,
            event: .launchTimedOut(generation: generation)).state

        #expect(state.processState == .launching)
        guard case .unavailable = state.telemetryHealth else {
            Issue.record("Expected unavailable telemetry")
            return
        }

        let recovered = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "session",
                event: status(.idle),
                viewed: true))
        #expect(recovered.state.processState == .running)
        #expect(recovered.state.telemetryHealth == .live)
        #expect(recovered.effects == [.becameAlive, .inputSettling])
    }

    @Test func completionIsATerminalBarrierUntilTheNextTurnStarts() {
        let generation = UUID()
        var state = runningState(generation)
        state.turnState = .active(turnID: "turn-1")
        state = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "tool-start",
                event: .turnActivityChanged(.executing))).state
        state = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "turn-complete",
                event: .turnCompleted(turnID: "turn-1"),
                viewed: true)).state

        let lateChildEvent = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "late-subagent-stop",
                event: .turnActivityChanged(.reasoning),
                viewed: true))
        #expect(lateChildEvent.state.activityState == .idle)
        #expect(lateChildEvent.state.turnState == .inactive)
        #expect(lateChildEvent.effects.isEmpty)

        let working = AgentStateReducer.reduce(
            lateChildEvent.state,
            event: providerEvent(generation, id: "next-working", event: status(.working), viewed: true)).state
        let nextTurn = AgentStateReducer.reduce(
            working,
            event: providerEvent(generation, id: "next-turn", event: .promptSubmitted("next"), viewed: true))
        #expect(nextTurn.state.activityState == .reasoning)
        #expect(nextTurn.state.turnState == .active(turnID: nil))
    }

    @Test func subordinateHooksCannotConfirmOrResurrectAProviderProcess() {
        let generation = UUID()
        let launching = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: generation)).state
        let prematureChildEvent = AgentStateReducer.reduce(
            launching,
            event: providerEvent(
                generation,
                id: "tool-before-turn",
                event: .turnActivityChanged(.executing)))
        #expect(prematureChildEvent.state.processState == .launching)
        #expect(prematureChildEvent.state.activityState == .unknown)
        #expect(prematureChildEvent.effects.isEmpty)

        let exited = AgentStateReducer.reduce(
            launching,
            event: providerEvent(
                generation,
                id: "exit",
                event: .providerExited(status: 0))).state
        let lateChildEvent = AgentStateReducer.reduce(
            exited,
            event: providerEvent(
                generation,
                id: "tool-after-exit",
                event: .turnActivityChanged(.executing)))
        #expect(lateChildEvent.state.processState == .exited)
        #expect(lateChildEvent.state.turnState == .inactive)
        #expect(lateChildEvent.effects.isEmpty)

        // The exit report skips the event file's delay, so records written
        // before the exit can arrive after it. A late session start or
        // prompt brings nothing back; a late completion still counts; and a
        // second exit, such as Codex's exit record, changes nothing.
        let lateStart = AgentStateReducer.reduce(
            exited,
            event: providerEvent(
                generation,
                id: "start-after-exit",
                event: status(.idle)))
        #expect(lateStart.state.processState == .exited)
        #expect(lateStart.effects.isEmpty)
        let latePrompt = AgentStateReducer.reduce(
            exited,
            event: providerEvent(generation, id: "prompt-after-exit", event: .promptSubmitted("late")))
        #expect(latePrompt.state == exited)
        #expect(latePrompt.effects.isEmpty)
        let lateCompletion = AgentStateReducer.reduce(
            exited,
            event: providerEvent(generation, id: "stop-after-exit", event: .turnCompleted(turnID: "turn-1")))
        #expect(lateCompletion.state.processState == .exited)
        #expect(lateCompletion.effects == [.completed, .unreadChanged])
        let secondExit = AgentStateReducer.reduce(
            exited,
            event: providerEvent(generation, id: "exit-record", event: .providerExited(status: 1)))
        #expect(secondExit.state == exited)
        #expect(secondExit.effects.isEmpty)
    }

    private func runningState(_ generation: UUID) -> AgentRuntimeSnapshot {
        var state = AgentRuntimeSnapshot(
            surfaceState: .open,
            processState: .running,
            activityState: .idle,
            telemetryHealth: .live,
            launchGeneration: generation)
        state.inputReady = true
        return state
    }

    private func status(
        _ state: Ghostty.Action.ProgramStatus.State,
        kind: Ghostty.Action.ProgramStatus.Kind? = nil
    ) -> AgentDomainEvent {
        .programStatus(Ghostty.Action.ProgramStatus(
            state: state, kind: kind, progress: nil, id: nil, app: nil, title: nil, message: nil))
    }

    private func providerEvent(
        _ generation: UUID,
        id: String,
        event: AgentDomainEvent,
        viewed: Bool = false
    ) -> AgentRuntimeEvent {
        .provider(
            generation: generation,
            provider: .codex,
            eventID: id,
            event: event,
            isViewed: viewed)
    }
}

/// Counts every observable mutation of what `read` reads. Observation
/// tracking reports only the first change, so it is armed again after each
/// one, and a second mutation within the same call is counted too.
@MainActor
private final class MutationCounter {
    private(set) var count = 0
    private let read: @MainActor () -> Void

    init(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        arm()
    }

    private func arm() {
        withObservationTracking {
            read()
        } onChange: {
            // Called on the thread that mutates: the agent is main-actor.
            MainActor.assumeIsolated {
                self.count += 1
                self.arm()
            }
        }
    }
}
