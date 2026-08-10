import AppKit
import Testing
@testable import Ghostty

struct AgentKeyEventRoutingPolicyTests {
    @Test func editableFieldEditorBypassesApplicationBindings() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.isEditable = true

        #expect(AgentKeyEventRoutingPolicy.isTextEditingResponder(editor))
    }

    @Test func ordinaryRespondersRemainEligibleForApplicationBindings() {
        #expect(!AgentKeyEventRoutingPolicy.isTextEditingResponder(NSView()))
        #expect(!AgentKeyEventRoutingPolicy.isTextEditingResponder(nil))
    }
}
