import Foundation
import Testing
@testable import Ghostty

struct AgentWorkspacePolicyTests {
    @Test func creationDraftDerivesNormalizedLaunchProfile() {
        var draft = AgentCreationDraft(
            provider: .codex,
            preferences: AgentPreferences())
        draft.modelID = "  gpt-5.6  "
        draft.reasoningEffort = "xhigh"

        #expect(draft.launchProfile == AgentLaunchProfile(
            modelID: "gpt-5.6",
            reasoningEffort: "xhigh",
            startMode: .unrestricted))
    }

    @Test func aNameTakenInTheProjectTakesTheLowestFreeNumber() {
        let agents = [AgentEntry(id: UUID(), name: "review"), AgentEntry(id: UUID(), name: "Review 2")]
        #expect(AgentNames.free("docs", among: agents) == "docs")
        #expect(AgentNames.free("Review", among: agents) == "Review 3")
    }
}
