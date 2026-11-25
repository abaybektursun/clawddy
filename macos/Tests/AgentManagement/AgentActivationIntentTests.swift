import Foundation
import Testing
@testable import Ghostty

/// Regression coverage for H2: activation intent must survive asynchronous
/// launch preparation without ever claiming an agent is viewed before its
/// surface is presented.
struct AgentActivationIntentTests {
    private func context(
        explicit: UUID?,
        selected: UUID?,
        presented: UUID?,
        canSee: Bool = true,
        visible: Bool = true,
        key: Bool = true,
        miniaturized: Bool = false
    ) -> AgentViewingContext {
        AgentViewingContext(
            explicitAgentID: explicit,
            selectedAgentID: selected,
            presentedAgentID: presented,
            personCanSee: canSee,
            windowIsVisible: visible,
            windowIsKey: key,
            windowIsMiniaturized: miniaturized)
    }

    @Test func firstStartPreservesIntentUntilTheSurfaceIsPresented() {
        let agentID = UUID()

        // Launch request: the detail controller has selected the agent and the
        // user's activation is recorded, but no surface exists yet. The agent
        // must not count as viewed, and the pending intent must still authorize
        // presentation when preparation completes.
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: agentID,
            canSee: false)) == nil)
        #expect(AgentLaunchPresentationPolicy.decide(
            agentID: agentID,
            selectedAgentID: agentID,
            anotherViewHasKeys: false,
            windowIsVisible: true,
            windowIsMiniaturized: false) == AgentLaunchPresentation(
                presentsPane: true,
                focusesTerminal: true))

        // Presentation: the same intent now becomes viewing, so completions
        // from the newly live surface are not reduced as unread.
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: agentID)) == agentID)
    }

    @Test func restartKeepsIntentAcrossSurfaceDeathAndReprepare() {
        let agentID = UUID()

        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: agentID)) == agentID)

        // The old surface is discarded before the replacement is prepared. A
        // stale presented ID must not keep the agent viewed while it shows a
        // placeholder.
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: agentID,
            canSee: false)) == nil)
        #expect(AgentLaunchPresentationPolicy.decide(
            agentID: agentID,
            selectedAgentID: agentID,
            anotherViewHasKeys: false,
            windowIsVisible: true,
            windowIsMiniaturized: false).focusesTerminal)

        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: agentID)) == agentID)
    }

    @Test func selectionChangeDuringLaunchPreventsStaleFocusTheft() {
        let launchedAgentID = UUID()
        let newerSelectionID = UUID()

        let decision = AgentLaunchPresentationPolicy.decide(
            agentID: launchedAgentID,
            selectedAgentID: newerSelectionID,
            anotherViewHasKeys: false,
            windowIsVisible: true,
            windowIsMiniaturized: false)
        #expect(decision == AgentLaunchPresentation(
            presentsPane: false,
            focusesTerminal: false))

        // The pane is retained, not presented: the newer selection stays the
        // only presented surface and is the only candidate for viewing.
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: launchedAgentID,
            selected: newerSelectionID,
            presented: newerSelectionID)) == nil)
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: newerSelectionID,
            selected: newerSelectionID,
            presented: newerSelectionID)) == newerSelectionID)

        // No selection at all (for example a filter emptied the list) also
        // must not let the completing launch attach itself.
        #expect(!AgentLaunchPresentationPolicy.decide(
            agentID: launchedAgentID,
            selectedAgentID: nil,
            anotherViewHasKeys: false,
            windowIsVisible: true,
            windowIsMiniaturized: false).presentsPane)
    }

    @Test func launchCompletionAttachesButNeverFocusesAHiddenWindow() {
        let agentID = UUID()

        let decision = AgentLaunchPresentationPolicy.decide(
            agentID: agentID,
            selectedAgentID: agentID,
            anotherViewHasKeys: false,
            windowIsVisible: false,
            windowIsMiniaturized: false)
        #expect(decision == AgentLaunchPresentation(
            presentsPane: true,
            focusesTerminal: false))

        #expect(!AgentLaunchPresentationPolicy.decide(
            agentID: agentID,
            selectedAgentID: agentID,
            anotherViewHasKeys: false,
            windowIsVisible: true,
            windowIsMiniaturized: true).focusesTerminal)

        // Principle 3: the sidebar keeps the keys while it has them, as when
        // the arrow keys chose the agent that comes back.
        #expect(AgentLaunchPresentationPolicy.decide(
            agentID: agentID,
            selectedAgentID: agentID,
            anotherViewHasKeys: true,
            windowIsVisible: true,
            windowIsMiniaturized: false) == AgentLaunchPresentation(presentsPane: true, focusesTerminal: false))
    }

    @Test func focusIsNeverGrantedWithoutPresentation() {
        let agentID = UUID()
        for selected in [agentID, UUID(), nil] as [UUID?] {
            for visible in [true, false] {
                for miniaturized in [true, false] {
                    for sidebarHasKeys in [true, false] {
                        let decision = AgentLaunchPresentationPolicy.decide(
                            agentID: agentID,
                            selectedAgentID: selected,
                            anotherViewHasKeys: sidebarHasKeys,
                            windowIsVisible: visible,
                            windowIsMiniaturized: miniaturized)
                        #expect(!decision.focusesTerminal || decision.presentsPane)
                    }
                }
            }
        }
    }

    @Test func viewedStateRequiresPresentedLiveSurfaceInAKeyWorkspace() {
        let agentID = UUID()
        let otherID = UUID()

        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: agentID)) == agentID)

        // Passive (reveal) selection never acknowledges work by itself.
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: nil,
            selected: agentID,
            presented: agentID)) == nil)
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: otherID,
            presented: agentID)) == nil)
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: otherID)) == nil)
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: agentID,
            canSee: false)) == nil)
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: agentID,
            visible: false)) == nil)
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: agentID,
            key: false)) == nil)
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: agentID,
            miniaturized: true)) == nil)
    }

    @Test func activationIntentSurvivesAWindowKeyTransition() {
        let agentID = UUID()

        // Notification activation can present the surface before AppKit makes
        // the window key. Intent is retained and applies on the key transition
        // instead of being consumed and lost.
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: agentID,
            key: false)) == nil)
        #expect(AgentViewingPolicy.viewedAgentID(in: context(
            explicit: agentID,
            selected: agentID,
            presented: agentID,
            key: true)) == agentID)
    }

    /// The reading ruling (flows.md 3.3): shown in a key, visible, uncovered
    /// window to a person who can see it, whether its CLI runs or not.
    @Test func readOnlyWhileThePersonCanSeeIt() {
        let agentID = UUID()
        func viewed(canSee: Bool = true, visible: Bool = true, key: Bool = true, miniaturized: Bool = false) -> Bool {
            AgentViewingPolicy.viewedAgentID(in: context(
                explicit: agentID, selected: agentID, presented: agentID,
                canSee: canSee, visible: visible, key: key, miniaturized: miniaturized)) == agentID
        }
        #expect(viewed())
        #expect(!viewed(canSee: false))
        #expect(!viewed(visible: false))
        #expect(!viewed(key: false))
        #expect(!viewed(miniaturized: true))
    }
}
