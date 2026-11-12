I've produced the design without editing or building anything. Upstream has not done this, so nothing can be cherry-picked. Every code fragment below copies a pattern already compiling in this tree, but none of it has been compiled. Treat compile success as UNCONFIRMED until step 4 of the commands in section 6 passes.

## Step 1: has upstream done it? No

- **Local `upstream`** sits at the fork point 9ee02ae60 and is stale. `git log -S program_status` finds only the parser work: bae2c3cdb (#14560) and b7207b2ef (#14630). 8c425a7bd (#14793) is in too. The fork already has all three.
- **GitHub main at 72ac7dced8 (2026-11-12)** still lists `.program_status` under "Unimplemented" at `src/termio/stream_handler.zig:391`. `src/apprt/action.zig`, `src/Surface.zig`, `src/apprt/surface.zig`, `include/ghostty.h` and `Ghostty.App.swift` have no `program_status` at all.
- **PR searches** for "program_status", "program status" and "7501" find only #14560, #14630, #14793 (parser side, merged), #14791 (closed) and #14998 (open, fuzzing).
- **No commit since the fork** touches the program status code.
- **1.4.0 release notes:** "libghostty can parse it all, but the Ghostty GUI ignores it for now." On #14560, mitchellh notes it was not added to terminfo "because Ghostty itself doesn't do anything with this yet".
- **Design discussion:** #15081 (2026-11-05, no replies) asks for exactly this change. It wants a per-surface apprt action modelled on `progress_report`, an answer to `OSC 7501 ; ? ST`, and the action exposed in `ghostty.h`. It also says Claude Code 2.1.295 and Codex 0.166.0 send OSC 7501.
- **Upstream's stated rules, which this design keeps:**
  - The core keeps no records, same as OSC 9;4.
  - A full reset (RIS) reports a `clear` of every record (`stream_terminal.zig:740-742`).
  - The support query is answered only while something consumes the reports.

**Root cause:** the GUI handler drops the command at `stream_handler.zig:383-389`, and there is no apprt action for it. The rule to enforce at that boundary:
- Each OSC 7501 report becomes exactly one ordered apprt event tagged with its surface.
- The query is answered with fixed bytes.
- RIS produces one root `clear`.

## Step 2: the model feature, hop by hop (progress report, OSC 9;4)

| Hop | Location |
|---|---|
| Parse | `src/terminal/osc/parsers/osc9.zig:153-168` produces `conemu_progress_report` (`osc.zig:127`). Its type, C mapping and header test are at `osc.zig:265-301`. |
| Stream dispatch | `src/terminal/stream.zig:2936-2937` calls `handler.vt(.progress_report, v)`. The program status dispatch already exists at `stream.zig:2948-2949` (field `:139`, alias `:510`). |
| GUI handler (io-reader thread, renderer mutex held) | `vt` at `stream_handler.zig:188-196`, then `:347`, then `progressReport` `:1946-1949`, then `surfaceMessageWriter` `:138-149`. That writer tries an instant push; if the queue is full it unlocks the renderer mutex and waits. The io-reader thread enters through `Termio.processOutput` (`src/termio/Termio.zig:705-711`) from `Exec.zig:1495/1806`. |
| Surface message | `src/apprt/surface.zig:141`. `Mailbox.push` (`:192-206`) rewraps it as an app message and pushes to `App.zig:595-602`, a 64-slot BlockingQueue (`:589`), then calls `rt_app.wakeup()`. |
| Hop to main thread | `embedded.zig:269-271` calls `Ghostty.App.swift:539-547`, which does `DispatchQueue.main.async { appTick() }`. That runs `:119-122`, then `ghostty_app_tick` (`embedded.zig:1732`), `App.tick` `:164`, `drainMailbox` `:273/293`, and `surfaceMessage` `:522-532`. The last one drops the message silently if the surface is gone. |
| Surface → action | `Surface.zig:1017`, then `:1179-1187` calls `rt_app.performAction(.{ .surface = self }, .progress_report, v)` and logs on error. |
| Action definition | Field `action.zig:327`, Key `:428`. The "adding actions" guide is at `:64-78`. CValue is built from each payload's `C` decl at `:446-467`. A comptime assert at `:475-484` requires the union to be 24 bytes. Conversion is at `:497-510`. |
| Header | `ghostty.h:900-915` (enum and struct), `:1008` (tag), `:1056` (union member). The test at `action.zig:440-442` checks every Zig key against `ghostty.h`; the checker is `lib/enum.zig:108-158`. |
| Embedded apprt | `embedded.zig:303-323` passes every action straight through. Its special-casing switch (`:325-358`) ends in `else => {}`, so nothing is filtered. |
| Swift | `Ghostty.App.swift:586` dispatches; `:722-723` is the case; the handler is `:2237-2271`; the surface is resolved through `:579-582` (`ghostty_surface_userdata`). Conversion is `Ghostty.Action.swift:83-111,174-179`. The property is `OSSurfaceView.swift:33`. The staleness timeout is a 15 s Timer at `SurfaceView_AppKit.swift:23-37` (GTK's is at `gtk/class/surface.zig:1143-1146`). Unknown actions hit `default:` at `:785-787`, which logs and returns false. |
| RIS | `stream_handler.zig:930-945` (`:944` removes the progress bar). |

Other features I traced for specific pieces:
- **String payload:** desktop notification, `stream_handler.zig:1833-1841` → `surface.zig:20-58,110` → `Surface.zig:1143-1152` → `action.zig:802-831` → `Ghostty.App.swift:1599-1618`. It uses fixed `[63:0]`/`[255:0]` buffers, which makes it the largest message type at 320 bytes.
- **Notification delivery:** the scrollbar handler (`Ghostty.App.swift:2273-2297`, key at `GhosttyPackage.swift:331-333`).
- **Pointer-in-struct payload:** `ConfigChange` (`action.zig:924-937`).
- **Replies written to the pty:**
  - Static bytes via `write_stable`: DSR at `stream_handler.zig:863`.
  - `writeReq`: XTVERSION at `:972-987`.
  - Matching the query's terminator: OSC color `:1820` and kitty color `:1931-1938`.
  - The libghostty-vt library's own 7501 reply: `stream_terminal.zig:975-993`.

**What gets reused:**
- `osc.Command.ProgramStatus`, `Report.readOption`/`writeText`, `query_reply` and the size limits, all in `program_status.zig`.
- The vt C types cannot be reused. `terminal.c_api` only exists when `c_abi` is set (`terminal/main.zig:94`). Without it, `lib.Enum(lib.target, …)` produces a `u3` tag (`lib/enum.zig:38-41`), which a C struct cannot hold. So the design copies the vt API's conventions instead: `kind` has `none` first, missing progress is -1, missing text is an empty string. Enums are mapped by name with `inline else`, as `c/terminal.zig:757-759` does, so the build breaks if the parser adds a state.

## Step 3: changes, in order to apply

**Design decisions:**
- **D1, surface message:** carries `{state, copy of the validated body}`, and decoding happens on the main thread with the parser's own `Report` methods. The parser says reports point into its buffer and must be copied (`program_status.zig:189-190`). A decoded fixed-size copy would need about 2.4 KB per mailbox slot. The copy uses `WriteReq` (inline up to 255 bytes, heap above), which stays under the 320-byte largest message, so slot size does not grow.
- **D2, action payload:** one pointer to the decoded report. A flat struct with four strings is 48 bytes and would trip the 24-byte assert at `action.zig:479-483`.
- **D3, Swift delivery:** NotificationCenter with the SurfaceView as `object`, not a `@Published` property. Records are kept per id and one surface can hold many, so a single property would lose data. Clawddy already observes per-surface notifications this way.
- **D4:** the query is always answered in the GUI, since the apprt always receives the reports.
- **D5:** RIS sends one `clear` with an empty body, the same as `stream_terminal.zig:742`.

### 1. `src/apprt/action.zig`

Add a union field at the end of the union (after `resize_window: ResizeWindow,`):
```zig
    /// A program status report (OSC 7501) from the program running in the
    /// target surface. See `ProgramStatus`.
    program_status: ProgramStatus,
```
Add to the end of the `Key` enum (after `resize_window,`):
```zig
        program_status,
```
New type and tests (for example after `CommandFinished`, around line 1027):
```zig
/// A program status report (OSC 7501). See `terminal.osc.program_status`.
///
/// Each action is one report. The core keeps no records: the apprt keeps
/// one record per id and applies the specification's lifetime rules. A
/// `clear` removes the addressed record and every record beneath it, or
/// every record when the id is empty. A full reset (RIS) sends a `clear`
/// with an empty id.
pub const ProgramStatus = extern struct {
    /// Only valid for the duration of the action.
    report: *const Report,

    // Sync with: ghostty_action_program_status_state_e
    pub const State = enum(c_int) {
        idle,
        working,
        done,
        blocked,
        @"error",
        clear,

        test "ghostty.h ProgramStatus.State" {
            try lib.checkGhosttyHEnum(State, "GHOSTTY_ACTION_PROGRAM_STATUS_STATE_");
        }
    };

    // Sync with: ghostty_action_program_status_kind_e
    pub const Kind = enum(c_int) {
        none,
        permission,
        question,
        auth,

        test "ghostty.h ProgramStatus.Kind" {
            try lib.checkGhosttyHEnum(Kind, "GHOSTTY_ACTION_PROGRAM_STATUS_KIND_");
        }
    };

    // Sync with: ghostty_action_program_status_report_s
    pub const Report = extern struct {
        state: State,
        /// `none` unless the state is `blocked` and the kind is known.
        kind: Kind,
        /// 0 to 100, or -1 when absent or indeterminate. Only set for
        /// `working` and `blocked`.
        progress: i8,
        /// NUL-terminated, empty when absent. An empty id is the root
        /// record, the program itself.
        id: [*:0]const u8,
        app: [*:0]const u8,
        title: [*:0]const u8,
        message: [*:0]const u8,

        const limits = terminal.osc.program_status;

        /// Storage for the text of one report, sized for the longest
        /// values the parser accepts.
        pub const Text = struct {
            id: [limits.max_id_bytes + 1]u8,
            app: [limits.max_app_bytes + 1]u8,
            title: [limits.max_title_bytes + 1]u8,
            message: [limits.max_msg_bytes + 1]u8,
        };

        /// Decode a parsed report. The strings point into `text`.
        pub fn init(
            text: *Text,
            parsed: terminal.osc.Command.ProgramStatus.Report,
        ) Report {
            return .{
                .state = switch (parsed.state) {
                    inline else => |tag| @field(State, @tagName(tag)),
                },
                .kind = if (parsed.readOption(.kind)) |kind| switch (kind) {
                    inline else => |tag| @field(Kind, @tagName(tag)),
                } else .none,
                .progress = if (parsed.readOption(.progress)) |v| @intCast(v) else -1,
                .id = copyZ(&text.id, parsed.readOption(.id) orelse ""),
                .app = copyZ(&text.app, parsed.readOption(.app) orelse ""),
                .title = writeTextZ(.title, &text.title, parsed),
                .message = writeTextZ(.msg, &text.message, parsed),
            };
        }

        fn copyZ(buf: []u8, value: []const u8) [*:0]const u8 {
            @memcpy(buf[0..value.len], value);
            buf[value.len] = 0;
            return buf[0..value.len :0].ptr;
        }

        fn writeTextZ(
            comptime option: terminal.osc.Command.ProgramStatus.Option,
            buf: []u8,
            parsed: terminal.osc.Command.ProgramStatus.Report,
        ) [*:0]const u8 {
            // The buffer holds the longest text the parser accepts.
            var writer: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
            parsed.writeText(option, &writer) catch unreachable;
            const len = writer.buffered().len;
            buf[len] = 0;
            return buf[0..len :0].ptr;
        }
    };
};

test "ghostty.h ProgramStatus.Report layout" {
    const testing = std.testing;
    const C = @import("ghostty.h").ghostty_action_program_status_report_s;
    try testing.expectEqual(@sizeOf(C), @sizeOf(ProgramStatus.Report));
    inline for (.{ "state", "kind", "progress", "id", "app", "title", "message" }) |name| {
        try testing.expectEqual(@offsetOf(C, name), @offsetOf(ProgramStatus.Report, name));
    }
}

test "program status: Report.init decodes every key" {
    const testing = std.testing;
    var p: terminal.osc.Parser = .init(testing.allocator);
    defer p.deinit();

    // "Plan" and "Apply?"
    p.nextSlice("7501;state=blocked:kind=permission:progress=40:id=tf/plan" ++
        ":app=terraform:title=UGxhbg==:msg=QXBwbHk/");
    var text: ProgramStatus.Report.Text = undefined;
    const report: ProgramStatus.Report = .init(&text, p.end('\x1b').?.program_status.report);
    try testing.expectEqual(ProgramStatus.State.blocked, report.state);
    try testing.expectEqual(ProgramStatus.Kind.permission, report.kind);
    try testing.expectEqual(@as(i8, 40), report.progress);
    try testing.expectEqualStrings("tf/plan", std.mem.span(report.id));
    try testing.expectEqualStrings("terraform", std.mem.span(report.app));
    try testing.expectEqualStrings("Plan", std.mem.span(report.title));
    try testing.expectEqualStrings("Apply?", std.mem.span(report.message));
}

test "program status: absent values and the reset clear" {
    const testing = std.testing;
    var text: ProgramStatus.Report.Text = undefined;
    const Parsed = terminal.osc.Command.ProgramStatus.Report;
    const cases = [_]struct { Parsed, ProgramStatus.State }{
        // kind and progress only apply to blocked/working
        .{ .{ .state = .done, .data = "state=done:kind=auth:progress=10" }, .done },
        // what a full reset sends
        .{ .{ .state = .clear }, .clear },
    };
    for (cases) |case| {
        const report: ProgramStatus.Report = .init(&text, case[0]);
        try testing.expectEqual(case[1], report.state);
        try testing.expectEqual(ProgramStatus.Kind.none, report.kind);
        try testing.expectEqual(@as(i8, -1), report.progress);
        inline for (.{ "id", "app", "title", "message" }) |field| {
            try testing.expectEqualStrings("", std.mem.span(@field(report, field)));
        }
    }
}

test "program status: Report.Text holds the longest values" {
    const testing = std.testing;
    const limits = terminal.osc.program_status;
    var p: terminal.osc.Parser = .init(testing.allocator);
    defer p.deinit();

    @setEvalBranchQuota(4096);
    const seg: [limits.max_id_segment_bytes]u8 = @splat('a');
    const id = seg ++ "/" ++ seg ++ "/" ++ seg ++ "/" ++ @as([29]u8, @splat('a'));
    const app: [limits.max_app_bytes]u8 = @splat('a');
    // "QUFB" decodes to "AAA" and "QUE" to "AA".
    const title: [limits.max_title_encoded_bytes]u8 = std.simd.repeat(limits.max_title_encoded_bytes, "QUFB".*);
    const msg: [limits.max_msg_bytes / 3 * 4]u8 = std.simd.repeat(limits.max_msg_bytes / 3 * 4, "QUFB".*);
    p.nextSlice("7501;state=done:id=" ++ id ++ ":app=" ++ app ++
        ":title=" ++ title ++ ":msg=" ++ msg ++ "QUE");
    var text: ProgramStatus.Report.Text = undefined;
    const report: ProgramStatus.Report = .init(&text, p.end('\x1b').?.program_status.report);
    try testing.expectEqual(limits.max_id_bytes, std.mem.span(report.id).len);
    try testing.expectEqual(limits.max_app_bytes, std.mem.span(report.app).len);
    try testing.expectEqual(limits.max_title_bytes, std.mem.span(report.title).len);
    try testing.expectEqual(limits.max_msg_bytes, std.mem.span(report.message).len);
}
```
The extern struct with one pointer is 8 bytes, so the 24-byte assert at `:479-483` stays untouched. It has no `C`/`cval` decls, so `CValue`/`cval` (`:457`, `:502`) use it as is, the same as `ResizeWindow`. An Action field with a bare pointer type is left out on purpose: the `@hasDecl(Type, "C")` call at `:457` would not accept a pointer type (UNCONFIRMED; there is no precedent for one in the union).

### 2. `include/ghostty.h`

Insert after `ghostty_action_progress_report_s` (line 915):
```c
// apprt.action.ProgramStatus.State
typedef enum {
  GHOSTTY_ACTION_PROGRAM_STATUS_STATE_IDLE,
  GHOSTTY_ACTION_PROGRAM_STATUS_STATE_WORKING,
  GHOSTTY_ACTION_PROGRAM_STATUS_STATE_DONE,
  GHOSTTY_ACTION_PROGRAM_STATUS_STATE_BLOCKED,
  GHOSTTY_ACTION_PROGRAM_STATUS_STATE_ERROR,
  GHOSTTY_ACTION_PROGRAM_STATUS_STATE_CLEAR,
} ghostty_action_program_status_state_e;

// apprt.action.ProgramStatus.Kind
typedef enum {
  GHOSTTY_ACTION_PROGRAM_STATUS_KIND_NONE,
  GHOSTTY_ACTION_PROGRAM_STATUS_KIND_PERMISSION,
  GHOSTTY_ACTION_PROGRAM_STATUS_KIND_QUESTION,
  GHOSTTY_ACTION_PROGRAM_STATUS_KIND_AUTH,
} ghostty_action_program_status_kind_e;

// apprt.action.ProgramStatus.Report
typedef struct {
  ghostty_action_program_status_state_e state;
  // NONE unless state is BLOCKED and the kind is known.
  ghostty_action_program_status_kind_e kind;
  // -1 if absent or indeterminate, otherwise 0-100 (WORKING/BLOCKED only).
  int8_t progress;
  // NUL-terminated, "" when absent. An empty id is the root record.
  const char* id;
  const char* app;
  const char* title;
  const char* message;
} ghostty_action_program_status_report_s;

// apprt.action.ProgramStatus
typedef struct {
  // Only valid for the duration of the action callback.
  const ghostty_action_program_status_report_s* report;
} ghostty_action_program_status_s;
```
Then add `GHOSTTY_ACTION_PROGRAM_STATUS,` after `GHOSTTY_ACTION_RESIZE_WINDOW,` (line 1018); its position must match the Key enum exactly. Add `ghostty_action_program_status_s program_status;` after `ghostty_action_progress_report_s progress_report;` (line 1056); member order inside a C union does not matter.

The `GHOSTTY_ACTION_` prefix keeps these names apart from the vt header's `GHOSTTY_PROGRAM_STATUS_*` names (`vt/terminal.h:1426-1469`). Do not add `_MAX_VALUE`: that rule in AGENTS.md covers only `include/ghostty/vt/`, and no `ghostty.h` enum uses it.

### 3. `src/apprt/surface.zig`

Field after `progress_report` (line 141):
```zig
    /// A program status report (OSC 7501).
    program_status: ProgramStatus,
```
Decl next to `ChildExited`:
```zig
    pub const ProgramStatus = struct {
        state: terminal.osc.Command.ProgramStatus.State,

        /// A copy of the report body, already validated by the parser.
        /// Empty for the `clear` sent on a full reset.
        data: WriteReq,
    };
```

### 4. `src/termio/stream_handler.zig`

In `vtFallible`, after `.progress_report => self.progressReport(value),` (line 347):
```zig
            .program_status => switch (value) {
                .report => |report| try self.programStatusReport(report),
                .query => |terminator| self.programStatusQuery(terminator),
            },
```
Delete `.program_status,` from the "Unimplemented" list (line 388).

In `fullReset`, after `self.progressReport(.{ .state = .remove });` (line 944):
```zig
        // A full reset removes every program status record (OSC 7501).
        self.surfaceMessageWriter(.{ .program_status = .{
            .state = .clear,
            .data = .{ .stable = "" },
        } });
```
New methods, placed after `showDesktopNotification` (line 1841):
```zig
    /// Forward a program status report (OSC 7501) to the surface. The core
    /// keeps no records. See apprt.action.ProgramStatus.
    fn programStatusReport(
        self: *StreamHandler,
        report: terminal.osc.Command.ProgramStatus.Report,
    ) !void {
        // The report points into the parser's buffer, so send a copy of
        // its already validated body.
        self.surfaceMessageWriter(.{ .program_status = .{
            .state = report.state,
            .data = try apprt.surface.Message.WriteReq.init(self.alloc, report.data),
        } });
    }

    /// Answer `OSC 7501 ; ?`. The reply is fixed bytes with nothing from
    /// any report, ended with the query's terminator.
    fn programStatusQuery(self: *StreamHandler, terminator: terminal.osc.Terminator) void {
        switch (terminator) {
            inline else => |t| self.messageWriter(.{
                .write_stable = "\x1b]7501;" ++
                    terminal.osc.program_status.query_reply ++
                    comptime t.string(),
            }),
        }
    }
```
The exact reply bytes are `ESC ] 7501 ; ?:states=idle,working,done,blocked,error:kinds=permission,question,auth`, followed by `ESC \` or BEL to match the query. The string comes from `query_reply`, which is pinned by the test at `program_status.zig:467-477`.

New test, placed after the "kitty clipboard read" test (around line 1966), copying the setup of the EFBIG test:
```zig
test "program status query reply" {
    const testing = std.testing;
    var mailbox = try termio.Mailbox.initSPSC(testing.allocator);
    defer mailbox.deinit(testing.allocator);
    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(global.io());
    defer mutex.unlock(global.io());
    var renderer_state: renderer.State = .{ .mutex = &mutex, .terminal = undefined };
    var handler: StreamHandler = undefined;
    handler.alloc = testing.allocator;
    handler.termio_mailbox = &mailbox;
    handler.renderer_state = &renderer_state;

    const reply = "\x1B]7501;?:states=idle,working,done,blocked,error" ++
        ":kinds=permission,question,auth";
    const cases = .{
        .{ terminal.osc.Terminator.st, reply ++ "\x1B\\" },
        .{ terminal.osc.Terminator.bel, reply ++ "\x07" },
    };
    inline for (cases) |case| {
        handler.programStatusQuery(case[0]);
        const msg = mailbox.spsc.queue.pop(global.io()).?;
        defer msg.deinit();
        try testing.expectEqualStrings(case[1], msg.write_stable);
    }
    try testing.expect(mailbox.spsc.queue.pop(global.io()) == null);
}
```
The test calls only `programStatusQuery`. In Zig unit tests the apprt is `none.App`, which has no `wakeup`, so any code path that reaches `surfaceMessageWriter` should not compile in a test. That matches how the existing tests stay away from it (UNCONFIRMED).

### 5. `src/Surface.zig`

In `handleMessage`, after the `.progress_report` arm (line 1187):
```zig
        .program_status => |v| {
            defer v.data.deinit();
            var text: apprt.action.ProgramStatus.Report.Text = undefined;
            const report: apprt.action.ProgramStatus.Report = .init(&text, .{
                .state = v.state,
                .data = v.data.slice(),
            });
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .program_status,
                .{ .report = &report },
            ) catch |err| {
                log.warn("apprt failed to report program status err={}", .{err});
            };
        },
```

### 6. `src/apprt/gtk/class/application.zig`

The only exhaustive switch over actions is at `:695-825`. Add after `.progress_report` (line 757):
```zig
            // GTK has no consumer for program status reports yet.
            .program_status => return false,
```
Every other action switch has a fallback: `embedded.zig:355` `else`, `Ghostty.App.swift:785` `default`. The `union(Key)` declaration forces the field and Key to exist together. The only exhaustive switch over surface messages is `Surface.handleMessage`. No docs generator or action-count test covers apprt actions; I searched outside `src/`, `include/` and `macos/Sources` and found only the stale headers mentioned in Step 4.

### 7. `macos/Sources/Ghostty/GhosttyPackage.swift`

In `extension Notification.Name`, after `ScrollbarKey` (line 333):
```swift
    /// A program status report (OSC 7501). Object is the surface it came from;
    /// userInfo holds a `Ghostty.Action.ProgramStatus`. Posted on the main
    /// thread, once per report, in the order the program sent them.
    static let ghosttyDidReceiveProgramStatus = Notification.Name("com.mitchellh.ghostty.didReceiveProgramStatus")
    static let ProgramStatusKey = ghosttyDidReceiveProgramStatus.rawValue + ".status"
```

### 8. `macos/Sources/Ghostty/Ghostty.Action.swift`

After `ProgressReport` (line 111):
```swift
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
```
At the end of the file, as an extension, which keeps the memberwise init the same way `ProgressReport` does:
```swift
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
```

### 9. `macos/Sources/Ghostty/Ghostty.App.swift`

Case right after `GHOSTTY_ACTION_PROGRESS_REPORT` (line 723):
```swift
            case GHOSTTY_ACTION_PROGRAM_STATUS:
                programStatus(app, target: target, v: action.action.program_status)
```
Handler after `progressReport` (line 2271):
```swift
        private static func programStatus(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_program_status_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("program status does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let status = Ghostty.Action.ProgramStatus(c: v.report.pointee) else {
                    Ghostty.logger.warning("program status with unknown state=\(v.report.pointee.state.rawValue, privacy: .public)")
                    return
                }

                // We are on the main thread inside ghostty_app_tick. Post
                // synchronously so observers get reports in order.
                NotificationCenter.default.post(
                    name: .ghosttyDidReceiveProgramStatus,
                    object: surfaceView,
                    userInfo: [SwiftUI.Notification.Name.ProgramStatusKey: status]
                )

            default:
                assertionFailure()
            }
        }
```

### 10. `macos/Sources/Features/AgentManagement/AgentTerminalBridge.swift`

Line 467 becomes:
```swift
    private var surfaceObservers: [UUID: [NSObjectProtocol]] = [:]
```
In `shutdown` (lines 533-535):
```swift
        for observer in surfaceObservers.values.joined() {
            NotificationCenter.default.removeObserver(observer)
        }
```
Replace lines 867-877:
```swift
            let center = NotificationCenter.default
            let closeObserver = center.addObserver(
                forName: Ghostty.Notification.ghosttyCloseSurface,
                object: surface,
                queue: .main
            ) { [weak self] _ in
                BridgeMetrics.shared.recordProcessExitNotif()
                Task { @MainActor [weak self] in
                    self?.handleSurfaceDeath(id: agentID)
                }
            }
            let statusObserver = center.addObserver(
                forName: .ghosttyDidReceiveProgramStatus,
                object: surface,
                queue: .main
            ) { [weak self] notification in
                guard let status = notification.userInfo?[Notification.Name.ProgramStatusKey]
                    as? Ghostty.Action.ProgramStatus
                else { return }
                // Handle inline, not in a Task, so reports apply in the order sent.
                MainActor.assumeIsolated {
                    self?.handleProgramStatus(id: agentID, status: status)
                }
            }
            surfaceObservers[agentID] = [closeObserver, statusObserver]
```
Replace both single-observer removals (lines 1474-1476 and 1502-1504) with `removeSurfaceObservers(id: id)`, and add:
```swift
    private func removeSurfaceObservers(id: UUID) {
        for observer in surfaceObservers.removeValue(forKey: id) ?? [] {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// One OSC 7501 report from an agent's surface. The core keeps no
    /// records; the specification's record rules belong here (see the edge
    /// semantics section).
    private func handleProgramStatus(id: UUID, status: Ghostty.Action.ProgramStatus) {
        guard agents[id] != nil else { return }
        logger.debug("program status \(id): \(String(describing: status.state)) id=\(status.id ?? "-")")
        // Next change: keep records per status.id and feed the root record
        // into AgentStateReducer.
    }
```
`MainActor.assumeIsolated` is available from macOS 10.15 (`@_alwaysEmitIntoClient`, checked in the installed SDK). The deployment target is 14.0.

Feeding records into the reducer is a separate change. A suggested mapping:
- `blocked`/`permission` → `.interactionRequired(.permission)`
- `question` → `.input`
- `auth` → `.authentication`
- `done` → completed; `error` → failed; `idle` → idle

The hooks-based input and OSC 7501 will then both drive state, so that change needs a rule for which wins.

### 11. `macos/Tests/Ghostty/ProgramStatusTests.swift` (new)

`Tests` is a file-system-synchronized group, so the file is picked up automatically.
```swift
import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

struct ProgramStatusTests {
    @Test func blockedReportKeepsEveryField() {
        let id = strdup("tf/plan")!, app = strdup("terraform")!
        let title = strdup("")!, message = strdup("Apply?")!
        defer { [id, app, title, message].forEach { free($0) } }
        let c = ghostty_action_program_status_report_s(
            state: GHOSTTY_ACTION_PROGRAM_STATUS_STATE_BLOCKED,
            kind: GHOSTTY_ACTION_PROGRAM_STATUS_KIND_PERMISSION,
            progress: 40, id: id, app: app, title: title, message: message)
        #expect(Ghostty.Action.ProgramStatus(c: c) == Ghostty.Action.ProgramStatus(
            state: .blocked, kind: .permission, progress: 40,
            id: "tf/plan", app: "terraform", title: nil, message: "Apply?"))
    }
}
```

### Threading

1. **io-reader thread**, holding the renderer mutex: parse, copy the body (heap allocation if over 255 bytes), push to the app mailbox, then `wakeup`. The query reply goes from the same thread through the termio mailbox to the writer thread, in order with other replies such as DA and DSR.
2. **Hop to the main thread** happens in exactly one place: `Ghostty.App.swift:546`, `DispatchQueue.main.async { appTick() }`.
3. **Everything after that runs on the main thread, synchronously:** drain, `handleMessage`, decode into a stack buffer of about 2.4 KB, `performAction`, the Swift callback, `NotificationCenter.post`, then the observer on the main queue and `assumeIsolated`.
4. **Re-entrancy:** Clawddy's handler runs inside `ghostty_app_tick`, so it must be quick and must not tick again.

## Edge semantics (what Clawddy must handle)

- **Event only.** Nothing is kept in Zig, in SurfaceView, or anywhere else, and there is no API to ask for the current state; an observer attached late misses earlier reports. Clawddy registers in the same main-thread turn that creates the surface, so no report can be processed in between (UNCONFIRMED: assumes `presentPreparedSurface` does not spin the run loop). Clawddy keeps one record per `id`; nil is the root record. Per the spec:
  - A report replaces its record entirely.
  - A missing `app` is inherited from the nearest ancestor.
  - `clear` removes the record and every record beneath it; with no id, it removes all.
  - The cap is 256 records, with least-recently-updated eviction (at least 64 required).
- **RIS** (`ESC c`) delivers one `clear` with no id, after the progress-bar removal, in order. A soft reset (DECSTR) delivers nothing, which is correct per the spec. Switching to the alternate screen has no effect, since records belong to the terminal, not the screen.
- **Surface close** sends no event. Queued messages for a freed surface are dropped (`App.zig:526`). A heap-allocated body leaks in that case, the same way `pwd_change` and `clipboard_write` already do; the leak is bounded by the 64-slot queue. Clawddy must drop the agent's records in `destroySurface` and `discardSurfaceForRestart`.
- **Program exits without sending idle:** there is no timeout, deliberately. The spec says "terminals MUST NOT require re-sending to keep a record alive". Progress reports have 15 s timers on macOS and GTK (`SurfaceView_AppKit.swift:23-37`, `gtk/class/surface.zig:1143-1146`); do not copy them.
  - The spec's rule is: on process exit or a new shell prompt (OSC 133 A), the terminal MUST drop `working`/`blocked` and MAY drop `idle`; `done`/`error` survive both events.
  - Clawddy's launch script runs `exec "$SHELL" -l` after the agent exits (`AgentTerminalBridge.swift:373`), so the surface outlives the agent. The GUI does not forward OSC 133 A (`stream_handler.zig:1496-1503`).
  - So apply the rule on Clawddy's own exit hook event (`exitEventCommand`, `:368`) and on surface death. Caveat: that hook arrives through files, and nothing orders it against the pty path. A late `working` from a crash could in theory arrive after the exit event (UNCONFIRMED, theoretical). The robust follow-up would be forwarding OSC 133 A, which comes in-band and is strictly ordered after the agent's last output.
- **Ordering:** reports from one surface are delivered in order end to end. There is a single producer thread, a FIFO queue, a main-thread drain, and synchronous action and post. They also stay in order relative to that surface's title, pwd, bell, progress and child-exit messages. Across surfaces, delivery order is arrival order. Clawddy keeps order only with the `assumeIsolated` form; `Task { @MainActor }` is FIFO in practice but not guaranteed by the language (UNCONFIRMED).
- **Spam:** there is no coalescing. Each report takes one slot of the 64-slot queue shared by every surface. When the queue is full, the producing io thread unlocks the renderer mutex and blocks (`stream_handler.zig:144-148`), which back-pressures that program through the pty. Other surfaces trying to push also block. Each report costs main-thread work for the decode, four Swift strings and one post. The spec says terminals SHOULD rate-limit side effects outside the terminal (notifications, sounds), so Clawddy's notifications must be rate-limited.

## Tests and commands

**What can only be checked by hand** (in the Release app, per `macos/AGENTS.md`, launched with `env -u NO_COLOR open -na <absolute app path>`, touching no other process):
- The query: in zsh, `printf '\e]7501;?\a'; IFS= read -rs -t1 -d $'\a' r; print -r -- ${(q)r}` should show the reply.
- A report: `printf '\e]7501;state=working:app=test:msg=%s\e\\' "$(printf Syncing | base64)"` should produce Clawddy's debug log line.
- RIS: `printf '\ec'` should produce a `clear`.
- No "unknown action" warnings in the logs.
- A real Claude Code ≥2.1.295 in an agent surface sends reports. Whether it probes first or gates on environment variables is UNCONFIRMED; I did not read the Claude Code or Codex sources, since that was outside the allowed fetch scope.
- The GTK prong cannot be compiled on macOS.

**Commands, in order:**
1. Select the compiler and check the paths:
   ```
   export GHOSTTY_ZIG=/Volumes/Xcode/GhosttyBuilds/ghostty/tools/zig-0.17.0/zig
   ./build.nu --show-paths
   ```
2. Format with 0.17, not the `zig` on PATH:
   ```
   $GHOSTTY_ZIG fmt src/apprt/action.zig src/apprt/surface.zig src/Surface.zig src/termio/stream_handler.zig src/apprt/gtk/class/application.zig
   ```
3. Targeted Zig tests (the "ghostty.h" filter re-checks Action.Key, State, Kind and the struct layout against the header):
   ```
   ./build.nu test -Dtest-filter="program status" -Dtest-filter="ghostty.h" -Dtest-filter=program_status
   ```
   Keep at least one filter: an unfiltered `test` on macOS also pulls in the Xcode app tests (`build.zig:325`).
4. Build the library: `./build.nu -Demit-macos-app=false`. This is the first real compile of `Surface.zig`, `embedded.zig` and the stream handler, and it regenerates the xcframework header.
5. Check the regenerated header:
   ```
   grep -c GHOSTTY_ACTION_PROGRAM_STATUS /Volumes/Xcode/GhosttyBuilds/ghostty/xcframework/GhosttyKit.xcframework/*/Headers/ghostty.h
   ```
6. `cd macos && swiftlint lint --strict --fix`
7. `macos/build.nu` (Release).
8. `macos/build.nu --action test`.
9. The manual run above.

## Merge cost

Upstream-owned files this touches: `action.zig`, `ghostty.h`, `apprt/surface.zig`, `stream_handler.zig`, `Surface.zig`, the GTK `application.zig`, `GhosttyPackage.swift`, `Ghostty.Action.swift` and `Ghostty.App.swift`. The fork has not modified any of them (`git diff upstream --numstat` is empty for all).

Fetching would write to `.git`, so instead of `git merge-tree` I compared each file's fork-point version against upstream main at 72ac7dced8. Both copies are in `/private/tmp/claude-501/-Users-abaybektursun-projects-ghostty/ecee68dc-7e24-4e70-a0d9-554f08565b6d/scratchpad/osc7501/{base,upstream}`.

- **Certain conflicts, easy to resolve:** upstream's `set_window_theme` (6ba2c2b270, dce5a9464a) is also appended to the end of the `action.zig` union and Key enum, and to the end of the `ghostty.h` tag enum. Keep both, with upstream's entry first.
- **Everywhere else** the hunks are at least 5 lines from upstream's changes:
  - `stream_handler.zig`: upstream's `set_attributes` rewrite is at lines 356-372, and its new code goes at the end of the file. That is why the new functions sit after `showDesktopNotification` and the test sits mid-file.
  - `Ghostty.App.swift`: upstream's new case is after `RELOAD_CONFIG`, line 729.
  - The other files have no overlap.

To keep this rebase-friendly, commit the core and header change, the generic Swift delivery (items 7-9), and Clawddy separately. If upstream ships its own action later, take upstream's core, header and GTK changes and rewrite only `Ghostty.Action.ProgramStatus.init(c:)` and the `Ghostty.App.swift` case against their struct. The notification name and Swift type are the interface Clawddy depends on, so Clawddy does not change. The names follow upstream conventions (`program_status`, `GHOSTTY_ACTION_PROGRAM_STATUS_*`), so a collision would show up as a conflict on the same lines, not as silent ABI drift.

## Step 4: risks and how to catch them early

1. **Zig compile (UNCONFIRMED until command step 4).** `std.Io.Writer.fixed`, sentinel slices, the `inline else`/`@field` enum mapping, `.init` decl literals, and the `@intCast` with the -1 fallback all copy `c/terminal.zig:747-765` or the parser tests. In-tree imports of `@import("ghostty.h")` exist only in `lib/enum.zig`; the one in action.zig's layout test is new (UNCONFIRMED, same module).
2. **Header struct drift.** The enum tests do not cover struct field order. The new "ghostty.h ProgramStatus.Report layout" test and the Swift test do.
3. **Stale generated header.** The xcframework header is a copy made at build time (`GhosttyXCFramework.zig:33`), currently dated Oct 27. Swift builds against it until command step 4 runs; step 5 checks it. There is also a stray, untracked April copy in `macos/macos/GhosttyKit.xcframework`; the Xcode project does not reference it, but it can mislead a grep.
4. **Missing Swift case.** The embedded apprt does not filter actions. Without the Swift case you get an "unknown action" warning per report and nothing worse.
5. **GTK** is not compiled on macOS, so a mistake in that prong would surface only upstream or on Linux.
6. **Surface-message size.** The new payload should be about 272 bytes, under the 320-byte largest message (UNCONFIRMED exact numbers). A temporary `@compileLog(@sizeOf(apprt.surface.Message))` would confirm.
7. **Tests that touch the surface mailbox** should not compile under the `none` apprt (UNCONFIRMED). That is why the Zig tests stop at the query and decode.
8. **Divergence from upstream.** Answering the query for every surface makes programs in plain tabs report too; that is harmless, since nobody observes them. Upstream may later gate the reply or add a terminfo entry, which would change behaviour on merge.
9. **`MainActor.assumeIsolated` traps** if a post ever comes from off the main thread. That is a deliberate fail-loud choice.
10. **Two state sources in Clawddy** (hook files and OSC 7501) can disagree. The reducer change needs a precedence rule.

Besides the `gh` calls to ghostty-org/ghostty, I fetched two public pages anonymously: the ghostty.org 1.4.0 release notes and the spec at superlogical.com. I used the spec for the lifetime, cap and rate-limit rules. Nothing about the fork or its owner was sent.
