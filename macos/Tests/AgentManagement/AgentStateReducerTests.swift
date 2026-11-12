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
            _ = agent.displayState
            _ = (agent.surfaceState, agent.processState, agent.activityState, agent.interactionState)
            _ = (agent.telemetryHealth, agent.unreadCompletion, agent.lastAppliedCompletion)
            _ = (agent.failureMessage, agent.runtimeErrorMessage, agent.launchGeneration)
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
            event: .sessionStarted(sessionID: "session-1", model: nil, permissionMode: nil)), at: now)
        #expect(mutations.count == 2)
        #expect(agent.processState == .running && agent.sessionID == "session-1")
        #expect(agent.lastAuthoritativeChange == now)

        // An event of another launch changes nothing.
        agent.apply(.surfaceOpened(generation: UUID()), at: now)
        #expect(mutations.count == 2)
    }

    /// Only an agent that has never started and has nothing unread shows its
    /// provider's sign-in state.
    @Test func providerAuthenticationReachesOnlyNeverStartedAgents() {
        let signedOut = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .providerAuthentication(.signedOut)).state
        #expect(signedOut.interactionState == .authentication)
        let signedIn = AgentStateReducer.reduce(signedOut, event: .providerAuthentication(.signedIn))
        #expect(signedIn.state.interactionState == .none)
        #expect(signedIn.effects.isEmpty)

        let running = runningState(UUID())
        #expect(AgentStateReducer.reduce(running, event: .providerAuthentication(.signedOut)).state == running)
        let unread = AgentRuntimeSnapshot(unreadCompletion: AgentCompletionID(
            provider: .claudeCode,
            sessionID: "session",
            turnID: nil,
            launchGeneration: UUID(),
            eventID: "stop"))
        #expect(AgentStateReducer.reduce(unread, event: .providerAuthentication(.signedOut)).state == unread)
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
        #expect(failed.state.failureMessage?.contains("status 127") == true)
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
        #expect(failed.state.failureMessage?.contains("status 127") == true)
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
                event: .sessionStarted(
                    sessionID: "session-1",
                    model: nil,
                    permissionMode: nil)))
        #expect(started.state.processState == .running)

        // A session end is not the process's exit.
        let ended = AgentStateReducer.reduce(
            started.state,
            event: providerEvent(generation, id: "session-end", event: .sessionEnded))
        #expect(ended.state.processState == .running)
        #expect(ended.state.failureMessage == nil)

        let exited = AgentStateReducer.reduce(
            ended.state,
            event: providerEvent(
                generation,
                id: "exit",
                event: .providerExited(status: 130)))

        #expect(exited.state.processState == .exited)
        #expect(exited.state.surfaceState == .open)
        #expect(exited.state.turnState == .inactive)
        #expect(exited.state.failureMessage == nil)
        #expect(exited.effects == [.providerExited(130)])
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

        #expect(exited.state.failureMessage == "The provider exited before the agent session started (status 130).")
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
                event: .sessionStarted(
                    sessionID: "session-1",
                    model: nil,
                    permissionMode: nil))).state

        let exited = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "exit",
                event: .providerExited(status: 130)))

        #expect(exited.state.processState == .exited)
        #expect(exited.state.failureMessage == nil)
        #expect(exited.effects == [.providerExited(130)])
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
                event: .turnStarted(turnID: "turn-old")))
        #expect(staleHook.state == state)
        #expect(staleHook.effects.isEmpty)

        let staleFailure = AgentStateReducer.reduce(
            state,
            event: .launchFailed(generation: oldGeneration, message: "old failure"))
        #expect(staleFailure.state == state)
        #expect(staleFailure.effects.isEmpty)
    }

    @Test func completionIsUnreadOnlyWhenNotViewed() {
        let generation = UUID()
        var state = runningState(generation)
        state = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "turn-start",
                event: .turnStarted(turnID: "turn-1"))).state

        let unread = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "turn-complete",
                event: .turnCompleted(turnID: "turn-1")))
        #expect(unread.state.activityState == .idle)
        #expect(unread.state.unreadCompletion?.turnID == "turn-1")
        #expect(unread.effects == [.completed, .unreadChanged])

        let viewed = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "viewed-complete",
                event: .turnCompleted(turnID: "turn-1"),
                viewed: true))
        #expect(viewed.state.unreadCompletion == nil)
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
        let first = state.unreadCompletion

        state = AgentStateReducer.reduce(state, event: .completionViewed).state
        let secondResult = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "second",
                event: .turnCompleted(turnID: nil)))
        #expect(secondResult.state.unreadCompletion != first)
        #expect(secondResult.state.unreadCompletion?.eventID == "second")
        #expect(secondResult.effects == [.completed, .unreadChanged])
    }

    @Test func turnConfirmationPrecedesPermissionAttention() {
        let generation = UUID()
        let launching = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: generation)).state
        let started = AgentStateReducer.reduce(
            launching,
            event: providerEvent(
                generation,
                id: "turn-start",
                event: .turnStarted(turnID: "turn-1")))
        #expect(started.effects == [.becameAlive])

        let result = AgentStateReducer.reduce(
            started.state,
            event: providerEvent(
                generation,
                id: "permission",
                event: .turnInteractionChanged(.permission)))

        #expect(result.state.processState == .running)
        #expect(result.state.interactionState == .permission)
        #expect(result.effects == [.waitingForUser])
    }

    @Test func authenticationAndInputAreFirstClassAttentionStates() {
        let generation = UUID()
        let launching = AgentStateReducer.reduce(
            AgentRuntimeSnapshot(),
            event: .launchRequested(generation: generation)).state
        let authentication = AgentStateReducer.reduce(
            launching,
            event: .interactionRequired(
                generation: generation,
                interaction: .authentication))
        #expect(authentication.state.interactionState == .authentication)
        #expect(authentication.effects == [.waitingForUser])

        let started = AgentStateReducer.reduce(
            runningState(generation),
            event: providerEvent(
                generation,
                id: "turn-start",
                event: .turnStarted(turnID: "turn-1"))).state
        let input = AgentStateReducer.reduce(
            started,
            event: providerEvent(
                generation,
                id: "input",
                event: .turnInteractionChanged(.input)))
        #expect(input.state.interactionState == .input)
        #expect(input.effects == [.waitingForUser])
    }

    @Test func runtimeFailureDoesNotMasqueradeAsLaunchFailure() {
        let generation = UUID()
        let result = AgentStateReducer.reduce(
            runningState(generation),
            event: providerEvent(
                generation,
                id: "runtime-error",
                event: .turnFailed(nil)))

        #expect(result.state.surfaceState == .open)
        #expect(result.state.processState == .running)
        #expect(result.state.failureMessage == nil)
        #expect(result.state.runtimeErrorMessage == "The agent reported a runtime error.")
        #expect(result.effects == [.failed])
    }

    @Test func toolFailureKeepsTheTurnLiveAndLaterEventsStillReduce() {
        let generation = UUID()
        var state = AgentStateReducer.reduce(
            runningState(generation),
            event: providerEvent(
                generation,
                id: "turn-start",
                event: .turnStarted(turnID: "turn-1"))).state
        state = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "tool-start",
                event: .turnActivityChanged(.executing))).state

        // Claude's event table maps PostToolUseFailure to these
        // non-terminal events because Claude keeps working in the same turn.
        state = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "tool-failure-interaction",
                event: .turnInteractionChanged(.none))).state
        let afterFailure = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "tool-failure-activity",
                event: .turnActivityChanged(.reasoning)))

        #expect(afterFailure.state.turnState == .active(turnID: "turn-1"))
        #expect(afterFailure.state.activityState == .reasoning)
        #expect(afterFailure.state.runtimeErrorMessage == nil)
        #expect(afterFailure.state.telemetryHealth == .live)
        #expect(afterFailure.effects.isEmpty)

        let permission = AgentStateReducer.reduce(
            afterFailure.state,
            event: providerEvent(
                generation,
                id: "permission-after-failure",
                event: .turnInteractionChanged(.permission)))
        #expect(permission.state.interactionState == .permission)
        #expect(permission.effects == [.waitingForUser])

        let completed = AgentStateReducer.reduce(
            permission.state,
            event: providerEvent(
                generation,
                id: "turn-complete",
                event: .turnCompleted(turnID: "turn-1")))
        #expect(completed.state.turnState == .inactive)
        #expect(completed.state.unreadCompletion?.turnID == "turn-1")
        #expect(completed.effects == [.completed, .unreadChanged])
    }

    @Test func stopFailureStillEndsTheTurn() {
        let generation = UUID()
        let running = AgentStateReducer.reduce(
            runningState(generation),
            event: providerEvent(
                generation,
                id: "turn-start",
                event: .turnStarted(turnID: "turn-1"))).state
        let failed = AgentStateReducer.reduce(
            running,
            event: providerEvent(
                generation,
                id: "stop-failure",
                event: .turnFailed(nil)))

        #expect(failed.state.turnState == .inactive)
        #expect(failed.state.activityState == .idle)
        #expect(failed.state.runtimeErrorMessage == "The agent reported a runtime error.")
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
        state = AgentStateReducer.reduce(state, event: .completionViewed).state

        let replay = AgentStateReducer.reduce(state, event: event)
        #expect(replay.state.unreadCompletion == nil)
        #expect(replay.state.lastAppliedCompletion?.eventID == "stable-event-id")
        #expect(replay.effects.isEmpty)
    }

    @Test func delayedTelemetryChangesConfidenceWithoutInventingActivity() {
        let generation = UUID()
        var state = runningState(generation)
        state = AgentStateReducer.reduce(
            state,
            event: providerEvent(
                generation,
                id: "turn-start",
                event: .turnStarted(turnID: "turn-1"))).state
        state.activityState = .executing

        let delayed = AgentStateReducer.reduce(
            state,
            event: .telemetryDelayed(generation: generation)).state
        #expect(delayed.telemetryHealth == .delayed)
        #expect(delayed.activityState == .executing)
        #expect(delayed.turnState == .active(turnID: "turn-1"))

        let recovered = AgentStateReducer.reduce(
            delayed,
            event: providerEvent(
                generation,
                id: "tool-finished",
                event: .turnActivityChanged(.reasoning))).state
        #expect(recovered.telemetryHealth == .live)
        #expect(recovered.activityState == .reasoning)
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
                event: .sessionStarted(
                    sessionID: "session-1",
                    model: "model",
                    permissionMode: "default"),
                viewed: true))
        #expect(recovered.state.processState == .running)
        #expect(recovered.state.telemetryHealth == .live)
        #expect(recovered.state.sessionID == "session-1")
        #expect(recovered.effects == [.becameAlive])
    }

    @Test func compactionExpiryOnlyChangesMatchingLaunch() {
        let generation = UUID()
        var compacting = runningState(generation)
        compacting.activityState = .compacting

        let stale = AgentStateReducer.reduce(
            compacting,
            event: .compactionExpired(generation: UUID()))
        #expect(stale.state == compacting)

        let expired = AgentStateReducer.reduce(
            compacting,
            event: .compactionExpired(generation: generation))
        #expect(expired.state.activityState == .idle)

        compacting.turnState = .active(turnID: "turn-1")
        let activeTurnExpired = AgentStateReducer.reduce(
            compacting,
            event: .compactionExpired(generation: generation))
        #expect(activeTurnExpired.state.activityState == .reasoning)
    }

    @Test func completionIsATerminalBarrierUntilTheNextTurnStarts() {
        let generation = UUID()
        var state = AgentStateReducer.reduce(
            runningState(generation),
            event: providerEvent(
                generation,
                id: "turn-start",
                event: .turnStarted(turnID: "turn-1"))).state
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

        let nextTurn = AgentStateReducer.reduce(
            lateChildEvent.state,
            event: providerEvent(
                generation,
                id: "next-turn",
                event: .turnStarted(turnID: "turn-2"),
                viewed: true))
        #expect(nextTurn.state.activityState == .reasoning)
        #expect(nextTurn.state.turnState == .active(turnID: "turn-2"))
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
    }

    private func runningState(_ generation: UUID) -> AgentRuntimeSnapshot {
        AgentRuntimeSnapshot(
            surfaceState: .open,
            processState: .running,
            activityState: .idle,
            interactionState: .none,
            telemetryHealth: .live,
            launchGeneration: generation)
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
