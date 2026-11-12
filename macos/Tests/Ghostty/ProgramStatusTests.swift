import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

struct ProgramStatusTests {
    typealias ProgramStatus = Ghostty.Action.ProgramStatus

    @Test func blockedReportKeepsEveryField() {
        let values: [String] = ["tf/plan", "terraform", "Plan", "Apply?"]
        let text = values.map { strdup($0)! }
        defer { text.forEach { free($0) } }
        let c = ghostty_action_program_status_report_s(
            state: GHOSTTY_ACTION_PROGRAM_STATUS_STATE_BLOCKED,
            kind: GHOSTTY_ACTION_PROGRAM_STATUS_KIND_PERMISSION,
            progress: 40,
            id: text[0],
            app: text[1],
            title: text[2],
            message: text[3]
        )
        #expect(ProgramStatus(c: c) == ProgramStatus(
            state: .blocked,
            kind: .permission,
            progress: 40,
            id: "tf/plan",
            app: "terraform",
            title: "Plan",
            message: "Apply?"
        ))
    }

    /// What a full reset sends: empty text, no kind, no progress.
    @Test func emptyValuesReadAsNil() {
        "".withCString { empty in
            let c = ghostty_action_program_status_report_s(
                state: GHOSTTY_ACTION_PROGRAM_STATUS_STATE_CLEAR,
                kind: GHOSTTY_ACTION_PROGRAM_STATUS_KIND_NONE,
                progress: -1,
                id: empty,
                app: empty,
                title: empty,
                message: empty
            )
            #expect(ProgramStatus(c: c) == ProgramStatus(
                state: .clear,
                kind: nil,
                progress: nil,
                id: nil,
                app: nil,
                title: nil,
                message: nil
            ))
        }
    }

    @Test func unknownStateIsRejected() {
        "".withCString { empty in
            let c = ghostty_action_program_status_report_s(
                state: ghostty_action_program_status_state_e(rawValue: 99),
                kind: GHOSTTY_ACTION_PROGRAM_STATUS_KIND_NONE,
                progress: -1,
                id: empty,
                app: empty,
                title: empty,
                message: empty
            )
            #expect(ProgramStatus(c: c) == nil)
        }
    }
}
