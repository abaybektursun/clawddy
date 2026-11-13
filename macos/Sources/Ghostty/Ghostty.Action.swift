import SwiftUI
import GhosttyKit

extension Ghostty {
    struct Action {}
}

extension Ghostty.Action {
    struct ColorChange {
        let kind: Kind
        let color: Color

        enum Kind {
            case foreground
            case background
            case cursor
            case palette(index: UInt8)
        }

        init(c: ghostty_action_color_change_s) {
            switch c.kind {
            case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
                self.kind = .foreground
            case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
                self.kind = .background
            case GHOSTTY_ACTION_COLOR_KIND_CURSOR:
                self.kind = .cursor
            default:
                self.kind = .palette(index: UInt8(c.kind.rawValue))
            }

            self.color = Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
        }
    }

    struct MoveTab {
        let amount: Int

        init(c: ghostty_action_move_tab_s) {
            self.amount = c.amount
        }
    }

    struct OpenURL {
        /// Where the URL came from. `unknown` and `osc8` may come from
        /// terminal output and must be opened through ``UntrustedURL``.
        enum Kind {
            /// May be a plain path, such as `~/notes.txt`, instead of a URL.
            case unknown
            case text
            case html
            case osc8

            init(_ c: ghostty_action_open_url_kind_e) {
                switch c {
                case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT:
                    self = .text
                case GHOSTTY_ACTION_OPEN_URL_KIND_HTML:
                    self = .html
                case GHOSTTY_ACTION_OPEN_URL_KIND_OSC8:
                    self = .osc8
                default:
                    self = .unknown
                }
            }
        }

        let kind: Kind
        let url: String

        init(c: ghostty_action_open_url_s) {
            self.kind = Kind(c.kind)
            let data = Data(bytes: c.url, count: Int(c.len))
            self.url = String(data: data, encoding: .utf8) ?? ""
        }
    }

    struct ProgressReport {
        enum State {
            case remove
            case set
            case error
            case indeterminate
            case pause

            init(_ c: ghostty_action_progress_report_state_e) {
                switch c {
                case GHOSTTY_PROGRESS_STATE_REMOVE:
                    self = .remove
                case GHOSTTY_PROGRESS_STATE_SET:
                    self = .set
                case GHOSTTY_PROGRESS_STATE_ERROR:
                    self = .error
                case GHOSTTY_PROGRESS_STATE_INDETERMINATE:
                    self = .indeterminate
                case GHOSTTY_PROGRESS_STATE_PAUSE:
                    self = .pause
                default:
                    self = .remove
                }
            }
        }

        let state: State
        let progress: UInt8?
    }

    /// A program status report (OSC 7501). See `apprt.action.ProgramStatus`.
    struct ProgramStatus: Equatable {
        enum State: Equatable {
            case idle
            case working
            case done
            case blocked
            case error
            /// Removes the record with `id` and every record beneath it, or
            /// every record when `id` is nil.
            case clear
        }

        enum Kind: Equatable {
            case permission
            case question
            case auth
        }

        let state: State
        let kind: Kind?
        let progress: UInt8?
        /// Nil is the root record, the program itself.
        let id: String?
        let app: String?
        let title: String?
        let message: String?
    }

    struct Scrollbar {
        let total: UInt64
        let offset: UInt64
        let len: UInt64

        init(c: ghostty_action_scrollbar_s) {
            total = c.total
            offset = c.offset
            len = c.len
        }
    }

    struct StartSearch {
        let needle: String

        init(c: ghostty_action_start_search_s) {
            self.needle = String(cString: c.needle)
        }
    }

    enum PromptTitle {
        case surface
        case tab

        init(_ c: ghostty_action_prompt_title_e) {
            switch c {
            case GHOSTTY_PROMPT_TITLE_TAB:
                self = .tab
            default:
                self = .surface
            }
        }
    }

    enum KeyTable {
        case activate(name: String)
        case deactivate
        case deactivateAll

        init?(c: ghostty_action_key_table_s) {
            switch c.tag {
            case GHOSTTY_KEY_TABLE_ACTIVATE:
                let data = Data(bytes: c.value.activate.name, count: c.value.activate.len)
                let name = String(data: data, encoding: .utf8) ?? ""
                self = .activate(name: name)
            case GHOSTTY_KEY_TABLE_DEACTIVATE:
                self = .deactivate
            case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
                self = .deactivateAll
            default:
                return nil
            }
        }
    }
}

// Putting the initializer in an extension preserves the automatic one.
extension Ghostty.Action.ProgressReport {
    init(c: ghostty_action_progress_report_s) {
        self.state = State(c.state)
        self.progress = c.progress >= 0 ? UInt8(c.progress) : nil
    }
}

extension Ghostty.Action.ProgramStatus {
    init?(c: ghostty_action_program_status_report_s) {
        switch c.state {
        case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_IDLE:
            self.state = .idle
        case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_WORKING:
            self.state = .working
        case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_DONE:
            self.state = .done
        case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_BLOCKED:
            self.state = .blocked
        case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_ERROR:
            self.state = .error
        case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_CLEAR:
            self.state = .clear
        default:
            return nil
        }

        switch c.kind {
        case GHOSTTY_ACTION_PROGRAM_STATUS_KIND_PERMISSION:
            self.kind = .permission
        case GHOSTTY_ACTION_PROGRAM_STATUS_KIND_QUESTION:
            self.kind = .question
        case GHOSTTY_ACTION_PROGRAM_STATUS_KIND_AUTH:
            self.kind = .auth
        default:
            self.kind = nil
        }

        self.progress = c.progress >= 0 ? UInt8(c.progress) : nil
        self.id = Self.text(c.id)
        self.app = Self.text(c.app)
        self.title = Self.text(c.title)
        self.message = Self.text(c.message)
    }

    private static func text(_ cString: UnsafePointer<CChar>?) -> String? {
        guard let cString else { return nil }
        let value = String(cString: cString)
        return value.isEmpty ? nil : value
    }
}
