# Clawddy Agent Architecture

This document describes the stable architecture and invariants of Clawddy's
multi-agent workspace. It intentionally avoids copying method bodies or UI
styling from the implementation; those details change more often than the
design.

For Apple-framework policy, deployment targets, permissions, accessibility,
and compatibility work, see [`MACOS_DEVELOPMENT.md`](MACOS_DEVELOPMENT.md).

## Scope

Clawddy adds a native macOS workspace to Ghostty for organizing Claude Code and
Codex sessions by project and task. Each agent owns a stable UUID, an immutable
provider identity, a real Ghostty terminal surface while active, and
independently derived runtime state.

The feature has six boundaries:

1. **Configuration:** projects, tasks, agent identities, and working directories.
2. **Provider table:** one entry per provider says which source reports its
   turn activity, which hook events it subscribes to and what each means in
   shared domain events, and how it is launched and probed.
3. **Event ingestion:** provider hooks append minimal, provider-tagged lifecycle
   records; the app consumes them in order from persisted byte offsets.
4. **Session metadata:** the UI presents provider-reported or explicitly
   configured values and labels unavailable capabilities instead of inferring them.
5. **Terminal ownership:** each live agent has one Ghostty surface hosted through
   Ghostty's normal terminal view model and focus path.
6. **Presentation:** navigation, the agent list, terminal detail, command palette,
   badge and notifications render derived state.

Clawddy does not replace Ghostty's terminal renderer, input stack, configuration,
or process model.

## Component Ownership

| Component                         | Responsibility                                                                                                    |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `AgentConfig.swift`               | Versioned JSON model, atomic persistence, and provider-identity recovery                                          |
| `AgentPreferences.swift`          | Versioned provider start-mode defaults, isolated persistence, and canonical launch policy                         |
| `AgentProvider.swift`             | Provider table, health/auth state, launch records, and provider event vocabulary                                 |
| `ClaudeCodeProvider.swift`        | Claude Code command construction, per-agent overlay hooks, old global hook removal, auth probe, and event table  |
| `CodexProvider.swift`             | Codex command construction with its per-launch notify program, auth probe, and event table                       |
| `AgentHookRuntime.swift`          | Provider-tagged POSIX hook, safe shell quoting, and provider-exit journaling                                      |
| `AgentSessionStore.swift`         | Validated provider-tagged session persistence plus legacy Claude migration                                       |
| `AgentEnvironmentResolver.swift`  | Asynchronous login-shell PATH discovery with timeout and deterministic fallback                                   |
| `AgentEventJournal.swift`         | Complete-record parsing across append bursts, partial writes, and journal replacement                             |
| `AgentHookJournalSource.swift`    | File-level watcher, in-memory offsets and compaction for the event files; feeds `AgentBridge.ingest`              |
| `AgentMetadataRuntime.swift`      | Per-agent Claude settings overlay, status-line forwarding, and atomic metadata publication                        |
| `AgentSessionMetadata.swift`      | Provider-neutral metadata plus strict decoding and presentation-safe normalization of official telemetry fields   |
| `AgentStateReducer.swift`         | Pure surface/process/activity/interaction/telemetry transitions and ordered semantic effects                     |
| `AgentPresentation.swift`         | The seven shown states (flows.md 2.1), a function of the record, with their words and ages                        |
| `ClawddyPalette.swift`            | Chrome colours derived in OKLCH from the terminal background and foreground (native-look.md 2.1); dark only      |
| `AgentWorkspacePolicies.swift`    | Launch presentation, viewing, quit and close questions, free names, the waiting order                            |
| `AgentTerminalBridge.swift`       | Ordered event ingestion, runtime state, surface lifecycle, notifications, persistence, and the waiting count      |
| `AgentTerminalHost.swift`         | `TerminalViewModel` and `TerminalViewDelegate` adapter for one agent surface tree                                 |
| `AgentTerminalsController.swift`  | The only creator of agent surfaces, kept in `AgentTerminalStack`; the rounded screen the shown one sits in        |
| `AgentWorkspaceController.swift`  | The agent window: its single gate for the keys and first responder, restoration, and its construction           |
| `AgentWindowController.swift`     | The window's content laid out by hand: top bar, list, header, screen, keys panel; the one authority for hover    |
| `AgentTopBar.swift`, `AgentListView.swift`, `AgentPaneHeader.swift`, `AgentKeysPanel.swift` | The regions, AppKit, text drawn by CoreText into layers |
| `AgentHomeView.swift`             | Home: the tile grid placed by `AgentHomeLayout` (width and density only), the selection, keys, drags, numbers |
| `AgentTileView.swift`             | One tile: mark, name, age, sentence and the terminal's last lines, in place; its content layer for S10's motion |
| `AgentTail.swift`                 | A terminal's last lines above the CLI's input box, and the saved last screen (`<id>.screen.txt`, 0600)         |
| `AgentReorder.swift`              | Moving agents within a project: ⌥← ⌥→ and drops                                                                 |
| `AgentChrome.swift`               | Shared parts: layers without implicit animation, the text layer, the button, key caps, marks, motion             |
| `AgentWorkspaceModel.swift`       | The current project and each project's view (home or inside an agent), kept for the next start; viewing        |
| `AgentCommands.swift`             | The Agent menu's commands and keys, and the rule for which keys reach the workspace or the terminal             |

| `AgentPaletteView.swift`          | The palette over the stage: find with its results, and the floating new-agent line                               |
| `AgentSearch.swift`               | Find over the stored records, by words, case and accents folded                                                 |
| `AgentUndo.swift`                 | The session's one list of undoable actions: starts, settles, project removals                                   |
| `AgentWalk.swift`                 | The walk through the agents waiting on the person: its order, position and start                                 |
| `AgentTextView.swift`, `AgentLineView.swift`, `AgentNameField.swift` | The one text field class; the typing line; a name edited in place |
| `AppDelegate.swift`               | Composition root, menus, global shortcut, workspace ownership (launch and Dock reopen show the agent window), routing, and Dock badge |

The composition is deliberately one-way:

```text
AppDelegate
 ├─ AgentConfig ───────────────► agents.json + provider identity migration
 ├─ AgentEnvironmentResolver ──► per-surface PATH
 ├─ AgentBridge ───────────────► adapters + event journal + metadata + AgentStateReducer
 │    └─ callbacks ────────────► ClawddyController / AgentTerminalsController
 └─ AgentWindowController ─────► top bar, home, line, list, header, palette (observe model, config, records)
      └─ AgentTerminalsController
           └─ AgentTerminalStack ─► AgentTerminalHost ─► Ghostty SurfaceView
```

Views issue user actions through configuration and bridge methods. They do not
read hook files, create Ghostty surfaces directly, or persist derived state.

Interactive provider surfaces inherit the account environment needed for
authentication, proxies, and provider configuration. At the PTY boundary,
`AgentTerminalEnvironmentPolicy` removes presentation opt-outs such as
`NO_COLOR` before the provider starts. Ghostty remains authoritative for
terminal capability variables such as `TERM` and `COLORTERM`; an automation
environment inherited by the app must not silently downgrade terminal output.

The agent window shows one project at a time, at home or inside one of its
agents; each project keeps where it was left (`AgentWorkspaceModel`). The list
beside a terminal shows the project's agents that are not settled, in
configuration order; state, unread and names never move a row. Each row is made
once per agent and follows its own agent through Observation, setting only the
layers that changed. Moving between agents with ⌘[ ⌘], ⌘J or switching project
starts no CLI; a deliberate open (a click, ⌘1 to ⌘9, the news) does.
A deliberate project or task selection reveals one descendant through the
shared importance policy: attention severity first, then the user's last
explicitly inspected descendant, latest authoritative display transition,
configuration rank, and UUID fallback. Runtime transitions never invoke this
policy on their own, so an urgent agent cannot steal focus. Reveal selection
does not start work or acknowledge completion.

Workspace selection is one transaction, not a collection of independently
observed view properties. `AgentWorkspaceSelectionState` owns scope and agent
identity together, and `AgentWorkspaceSelectionReducer` is the only boundary
that commits a user selection, reveal, or visibility reconciliation. Each
action returns at most one presentation intent for AppKit to execute after the
state commit. SwiftUI bindings forward actions to that boundary; `onChange`
observers and row gestures must not infer duplicate selection or focus work.
This keeps project, task, and agent switching ordered even when filtering,
configuration reloads, or window activation occur in the same run-loop turn.

Completion acknowledgment is reducer-owned persisted state, not a visual badge
override. A completion becomes unread only while its agent is not being viewed.
An intentional list selection acknowledges it only when the workspace is key,
visible, and displaying that agent's existing terminal. Programmatic selection
changes remain passive so filtering cannot cascade through the Attention scope
and acknowledge agents the user did not choose. A later completion creates a new
unread transition normally.

Keyboard focus has a matching three-part invariant: the workspace window must
be key, the surface must be the selected surface, and that surface must be the
actual AppKit first responder. `AgentWorkspaceWindow` reconciles Ghostty's
logical focus after every accepted responder transition, including transitions
to the window-owned `NSTextView` field editor behind `NSTextField` and
`NSSearchField`. Application-level key routing exempts an active field editor
even while a sheet or panel has no main window. This preserves Command-V,
selection, Undo/Redo, input methods, and the standard Cocoa command selectors.
Only the safe navigation and agent-list hosting views accept the inactive
window's first mouse event; the terminal intentionally retains Ghostty's
suppression behavior so an activation click cannot become PTY input.

Task and project state is also derived, never persisted. Each parent selects
one representative descendant state with deterministic precedence: failures,
permission, completion, unavailable status, compaction, active work, launch,
then rest. The parent icon uses that state's color, so any agent transition or
completion acknowledgment propagates through its task and project in the same
observation update without a second mutable state tree.

## Identity and Configuration

Projects, tasks, and agents use UUIDs as stable identities. Names are editable
labels and must never be used as runtime keys.

```swift
struct AgentEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let provider: AgentProviderID
    var launchProfile: AgentLaunchProfile
}
```

The on-disk configuration lives at:

```text
~/.config/ghostty-agents/agents.json
```

Current encoded shape:

```json
{
  "schemaVersion": 5,
  "projects": [
    {
      "id": "B150F75F-55CD-44BE-8994-3B8A840D71B5",
      "name": "ghostty",
      "workingDirectory": "/path/to/ghostty",
      "tasks": [
        {
          "id": "2FCF5403-85C9-4B95-85A9-9978FB1C2F02",
          "name": "chart-tiles",
          "agents": [
            {
              "id": "534A7DB8-4623-4C40-A3C6-DF5914D1302B",
              "name": "soundings",
              "provider": "codex",
              "launchProfile": {
                "modelID": null,
                "reasoningEffort": "high",
                "startMode": "unrestricted"
              }
            }
          ]
        }
      ]
    }
  ]
}
```

The decoder reads schema 5 only and requires every key the app writes; older
shapes (records without IDs, string-only agent arrays, agents without a
provider or launch profile) fail the load. The migration preflight aborts on
them before switch-over, so live data never reaches the decoder in an old
format. Once a tagged session exists, its provider is authoritative; an external config edit cannot make
another provider consume that identity.

`AgentLaunchProfile.startMode` is durable per-agent launch policy and is
required; `unrestricted` is the default for new agents, preserving Claude
Code's established behavior and making Codex YOLO the requested product
default. The native Settings window
stores separate defaults for newly created Claude Code and Codex agents in
`preferences.json`; a new agent snapshots the selected default.

Configuration writes are atomic and leave the main thread: each change of
`agents.json` is queued in the turn of the change and written in order on its
own serial queue, as the records are; quitting waits for the queue
(`AgentConfig.waitForWrites`). A change refused before writing (the file on
disk could not be loaded) restores the previous observable model; a write that
fails afterwards surfaces a configuration error and the change stays, as for a
record. The directory watcher ignores the file while writes of the app are
pending.
The directory watcher compares raw file data with the last successfully written
or loaded snapshot so it ignores the app's own writes and reloads actual external
edits.

## State Model

Runtime state is provider-neutral and separates facts that have different
owners. `AgentRuntimeSnapshot` contains five orthogonal dimensions:

| Dimension     | States                                                        | Owner                         |
| ------------- | ------------------------------------------------------------- | ----------------------------- |
| Surface       | inactive, opening, open, failed, closed                      | Ghostty/AppKit                |
| Process       | not started, launching, running, exited                      | launcher plus provider events |
| Activity      | unknown, idle, reasoning, executing, compacting              | normalized provider events    |
| Interaction   | none, permission, input, authentication                      | normalized provider events    |
| Telemetry     | not started, awaiting, live, delayed, unavailable with an explanation | lifecycle transport    |

Every launch receives a new generation UUID. Surface callbacks, timeout events,
and hook records carry that generation; the reducer rejects stale events from a
previous process. Each provider's event table maps raw hook names into the
shared domain vocabulary before reduction, and `ingest` drops a hook record
whose event is not in that table.

Every observation, a hook record or a terminal's close or program-status
report, enters through `AgentBridge.ingest`, which drops one from another
generation.

Every provider's turn activity and liveness come from its terminal's OSC 7501
reports; Codex's `working` must stand 3 s before it starts a turn, past its
start-up `working`. Claude's turn activity and liveness come from its terminal's OSC 7501 reports,
the program's own record only (no `id`): its first report other than `clear`
shows it alive. `working` starts a turn only once it has stood for 250 ms
without `idle`, `clear` or `done`, so the blips of `/clear`, `/exit` and the
`/exit` confirmation change nothing; `blocked` waits for permission, an answer
or sign-in; a bare `done` completes the turn and a `done` with a summary only
ends it; `idle` ends it as interrupted; `clear` resets the activity; `error`
fails it at once. A `PreCompact` hook with `trigger: "manual"` makes the turn
under way a compaction, which completes nothing. Claude's `error` report and
its `StopFailure` hook fail a turn once, whichever comes first. Reports after
the provider exited or the terminal closed change nothing. Exactly-once delivery lives in the transport: the journal source
keeps byte offsets in memory, starts each journal at its end when the app
starts, and resets an offset only after its own compaction.

A program reports nothing during a long tool call (131 s captured), so no
timer on an active turn manufactures idle, delay or completion.

Launch failures and runtime failures are separate facts. A provider executable
that cannot start produces **Couldn't Start**; a failure reported by an already
running agent produces **Needs Attention** without pretending its Ghostty surface
failed. Signed-out and input-required states are likewise distinct interaction
states and propagate through task/project attention.

`AgentStateReducer` is the only definition of runtime transitions. It accepts an
immutable snapshot and an event, then returns the next snapshot plus an ordered
effect list such as completion, waiting for user, failure, unread change, or
provider exit. The bridge performs notifications, cleanup, and persistence only
after reducing state.

Completion identity includes provider, session, turn when available, launch
generation, and journal event ID. Unread completion is durable state, shown as
Done and never counted as attention: it remains visible even if the provider
or surface exits and clears only after the user actually exposes that agent's
terminal in the key workspace window.

`AgentShownState`, what the window shows of an agent, is computed from the
record rather than stored. Whether an agent waits on the person is the record's
`isWaitingOnYou` (a question, a problem, a finished turn not yet read, a usage
limit reset); the bridge counts it across all agents and publishes each change
(`onWaitingCountChanged`).

The top bar and the Dock badge consume those same derived
states. They must not maintain a second state machine.

## Hook and Event Pipeline

The selected provider adapter lazily installs one shared POSIX hook when an
agent is first launched:

```text
~/.config/ghostty-agents/hooks/clawddy-provider-hook.sh
```

The script's arguments are `STATUS_DIR PROVIDER AGENT_ID GENERATION`, and it
records only into `STATUS_DIR`. Without a complete identity it drains its input,
records nothing and exits 0. When it cannot record an event it says why in
`STATUS_DIR/hook-errors.log` and appends a `HookFailed` record to the agent's
event file; that record, like a line of the file that is no record, stops the
agent with a problem saying a report was lost, so no failure stays silent.

- **Claude Code.** Each launch's settings overlay (see Session Metadata Pipeline)
  hooks `SessionStart`, `UserPromptSubmit`, `Stop`, `StopFailure`,
  `PermissionRequest`, `PreCompact`, `PostCompact` and `SessionEnd` with all
  four arguments; Claude's terminal reports its turns. No agent variable is exported, so a `claude` started
  from an agent's tools, which does not receive the overlay, cannot report as
  that agent. Nothing is written to `<CLAUDE_CONFIG_DIR>/settings.json`; at
  startup the production app removes the global entries that older builds put
  there, matched by the exact path of its own script, and writes the file only
  when it removed one.
- **Codex.** Each launch passes `-c notify=[script, STATUS_DIR, codex,
  AGENT_ID, GENERATION, notify, <the owner's own notify>…]`, so the hook
  script is Codex's notify program for that session. It first runs the
  `notify` command of the owner's `config.toml`, which the per-launch setting
  replaces, with the same payload, then records the completed turn: its
  session (`thread-id`), turn, prompts and last message. Codex also notifies
  for the turn in which it titles a new conversation; the event table ignores
  that one by its prompt. No global Codex file is written; at startup the
  production app removes the entries older builds put in
  `<CODEX_HOME>/hooks.json`, as for Claude. A `-c notify` setting needs no hook
  review, and Codex hook trust is never bypassed.

The hook depends only on macOS system tools. For each invocation it:

1. Reads the official hook payload from standard input (Codex's notify: its
   last argument) into a private temporary file `mktemp` makes.
2. Uses `plutil` to extract the session, event, turn, model, permission,
   compaction trigger, failure kind, end reason and start source as
   identifiers, the turn from the field the provider's event table names
   (`prompt_id` for Claude, `turn-id` for Codex), and the event's text: the
   prompt, the agent's last message, a failure's text, an asked question, or
   Codex's list of prompts. Text is never parsed by the shell: `plutil` reads
   the raw value, it travels as one argument into a fresh property list, and
   `plutil` writes that list as JSON, so quotes, newlines, emoji and shell
   syntax arrive exactly. An event outside the table records nothing.
3. Adds a stable event ID plus the provider and launch generation from its
   arguments.
4. Appends one JSONL record, on a line of its own (a newline before and
   after, so a line a full disk cut short never takes the next record with
   it), while holding the macOS `lockf` lock for that agent. The append waits for the short kernel-managed critical section
   instead of timing out and silently dropping a lifecycle fact.

The script writes no session binding. The bridge rewrites the provider-tagged
binding from each `SessionStart` record of the agent's current launch, whatever
its source (`startup`, `resume`, `clear`, `compact`), so after `/clear`
the next launch resumes the new session.

```text
~/.config/ghostty-agents/status/<agent-uuid>.session.json
~/.config/ghostty-agents/status/<agent-uuid>.events
```

A legacy `.session` binding is accepted only as Claude Code state and is
migrated to a tagged record. A session tagged for one provider is never passed to another provider. The journal carries prompts, last messages,
failure texts and questions (see Security and Privacy Boundaries); it
excludes tool inputs, tool results and the rest of the transcript.

`AgentHookJournalSource` watches the status directory with FSEvents file
events, which report appends to existing files. Events are throttled into one
nonoverlapping read per 200-millisecond window. Reads seek directly to the
in-memory byte offset and stop at the last complete newline, so cost follows new
events rather than total history and a concurrent partial write is never decoded.
Every complete record is handed to `AgentBridge.ingest` in order on the main
thread. Offsets start at the end of each journal when the app starts, so a
restarted app never replays history. Once an acknowledged prefix reaches one MiB,
the source compacts it under the same kernel-managed per-agent lock used by
hooks, retains any concurrent suffix, resets the offset, and immediately reads
again. There is no polling timer: a process exit that leaves its terminal open
reaches the bridge from the surface's child-exited message.

Every record must carry its provider and launch generation, and use the
supported event schema; an untagged record does not decode and is skipped. Unknown schema versions and
provider/generation mismatches are logged and skipped while their complete byte
range is acknowledged, preventing an incompatible record from poisoning every
later poll.

Legacy `.lastEvent` files are migration inputs only. New hooks never use the
lossy single-value register.

## Session Metadata Pipeline

Metadata is capability-driven. Both providers report the active model and
permission mode through official hook fields, and Clawddy knows any model or
reasoning effort explicitly configured in the launch profile. Runtime version
comes from the provider health probe.

The header shows only reported values: the model and the context used appear
once the provider reports them. The details card shows the reported effort, or
the launch profile's when none is reported.

Claude Code additionally supplies effective reasoning effort, context-window
use, token totals, duration, and cost data to a configured `statusLine` command.
That payload is the authoritative source for Claude telemetry: Clawddy does not
scrape terminal output or read transcript contents.

Before starting or resuming an agent, `AgentMetadataRuntime` creates a private,
per-agent settings overlay and passes it with Claude's `--settings` option. The
overlay adds the agent's hooks and sets `statusLine`; the user's own hooks and
all unrelated user, project, and local settings continue to come from their
normal scopes, and Claude merges the overlay's hooks with them. The
runtime resolves the existing effective status-line object, preserves unknown
presentation fields, and forwards the exact input to the user's original
command. Only that command's output reaches Claude, so an existing status line
continues to render unchanged.

The proxy atomically publishes the same status-line input into the status
folder passed as its first argument. There is no default; without the argument
it exits non-zero and writes nothing:

```text
~/.config/ghostty-agents/status/<agent-uuid>.metadata.json
```

Configuration and status directories are mode `0700`; generated settings,
upstream-command files, and snapshots are mode `0600`. A publication failure is
non-fatal and must not prevent the original status-line command from running.
When managed settings own the status line, the overlay carries only the hooks.
`disableAllHooks` turns off both, and no overlay is written. Neither case is a
launch failure; the header then shows no model or context.

The bridge reads only a changed snapshot on its serial I/O queue and decodes an
allowlist into one provider-neutral `AgentSessionMetadata` value on the main
actor. Metadata is not duplicated into the record; the atomic snapshot is its
sole on-disk source
of truth. Claude may report null context usage before the first API response and
immediately after compaction; the header then shows no context rather than a
false zero.

Codex's stable interactive hook interface does not currently report context
usage, session cost, or effective reasoning effort. Codex app-server provides a
richer client protocol, but Clawddy does not currently run a second control
channel alongside the real interactive TUI. A field it does not report is
left out; Clawddy never substitutes a fabricated value.

The header (design plan section 4) is one 44-point line in the titlebar band:
the agent's name, its state in words, and at the right a quiet cluster of model,
context ring and percentage. Hovering the cluster, or Space while it has
keyboard focus, opens a card with the provider, model, effort, context used,
session ID (a click copies it), working folder (a click shows it in Finder) and
start mode. Model and effort are searchable in the command palette.

## Concurrency and Observation

`AgentConfig`, `AgentBridge`, `AgentInstance`, and workspace models use the
Observation framework. `AgentBridge`, `AgentInstance`, and workspace UI state
are main-actor isolated. The bridge's serial I/O queue is limited to integration
preparation, launch-script creation, and ordered file operations over sendable
captured values. Provider health probes use a separate concurrent queue and
generation-check results so a slow or stale probe cannot block launches or
journal reads. Both paths return to the main actor before creating surfaces or
applying state.

Required invariants:

- A background closure must not mutate an observable model.
- Configuration and bridge creation of an agent must complete synchronously so
  the UI never sees a configured agent without a runtime instance.
- File watcher callbacks must be weakly captured and cancelled during teardown.
- Surface notifications and launch timers must be removed or invalidated when an
  agent dies, is deleted, or the application terminates.
- New concurrency annotations must follow the staged Swift 6 policy in
  [`MACOS_DEVELOPMENT.md`](MACOS_DEVELOPMENT.md#swift-concurrency).

## Terminal Surface Lifecycle

An agent has at most one live terminal surface.

Activation proceeds as follows:

1. Assign a fresh launch generation, set the instance to opening/launching, and
   start a one-shot telemetry timer.
2. On the serial I/O queue, resolve provider-tagged resume state, validate
   the provider executable and arguments, install the selected adapter's
   integration, and create a mode-0700 launch script.
3. Back on the main actor, reject stale preparation and ask
   `AgentDetailViewController` to show an existing host or create one.
4. For a new terminal, create `Ghostty.SurfaceView` and add it to
   `AgentTerminalStack`, which hosts it in Ghostty's AppKit
   `SurfaceScrollView`, placed by frame, with an `AgentTerminalHost` for its
   clipboard confirmations.
5. The stack retains the surface, host, and scroll view by agent UUID.
6. Observe the surface-specific close notification.
7. On explicit activation, give the shown terminal the keys
   (`AgentTerminalStack.giveKeysToPresented`) and mark the agent read.

The terminal is never reparented. No terminal has a SwiftUI view of its own:
Ghostty's SwiftUI `TerminalView` observed every published change of its
surface, so a hidden terminal's progress report or title ran a SwiftUI
transaction and a layout in the same turn as the person's key. A hidden
terminal is laid out only when the terminal area's size changes. Ghostty's
overlays (search, a link's address, key sequences, secure input, bell and
error views) are drawn by one SwiftUI view (`AgentSurfaceOverlay`) for the
shown terminal only. Focus and input are the stack's (below).

Every live terminal stays in the window at the terminal area's full size
(`AgentTerminalStack`). Only the presented agent's terminal is shown and draws;
the others are hidden with drawing stopped (`ghostty_surface_set_occlusion`).
Only the presented terminal may be the window's first responder: the window
refuses any other. Ghostty's focus of every terminal is re-derived after every
change of presentation, first responder, or key state. No terminal is removed
from the window and put back.
Closing or deleting an agent removes the scroll view, host, surface reference,
observer, timer, and associated status files.

If no hook arrives within ten seconds, the reducer marks telemetry unavailable
and presents a non-fatal **Status Unavailable** state. The live terminal remains
authoritative: missing telemetry is not reported as a failed launch. A later
valid hook recovers the same process to running/live without recreating its
surface.

## Command Construction and Resume

Each new terminal starts a unique, mode-0700 temporary login-shell script. It
sets `HOME` to the macOS account home so provider authentication uses the user's
normal Keychain and account context. It propagates an explicit
`CLAUDE_CONFIG_DIR` or `CODEX_HOME` only when the caller selected one, and always
sets the isolated status directory, provider ID, agent UUID, and launch
generation. Command selection is ordered:

1. Resume the UUID's provider-matching tagged session when one exists.
2. Start a fresh interactive provider TUI.

Claude Code starts a new session as `--session-id <new>` and resumes as `--resume <id>`. A new session's ID is written as the agent's binding before
the process starts. Every Claude launch adds `--name <agent label>`, plus
optional model, effort, and status-line settings. A resume that Claude ends
with `SessionEnd` before any `SessionStart` found no such session; the agent
then shows a failed start whose only action, Start Fresh, forgets the saved
session and launches a new one. Its unrestricted mode adds
`--dangerously-skip-permissions`. Codex uses the stable interactive `resume` subcommand plus optional `--model` and `model_reasoning_effort`
configuration. Its YOLO mode adds the canonical
`--dangerously-bypass-approvals-and-sandbox` flag. Standard mode omits these
provider-specific overrides. Clawddy does not use Codex's experimental
app-server or bypass Codex hook trust.

Before the provider command yields to the fallback shell, the launcher appends a
provider-exit event under the same journal lock. The script then replaces itself
with the user's login shell so the terminal remains useful. A fallback shell is
surface state, not evidence that the provider is still alive. Launch scripts are
tracked and removed after a confirmed hook, provider exit, surface death,
shutdown, or next-start stale cleanup.

Session IDs are accepted only when every character is alphanumeric or one of
`_`, `-`, `.`, `:`, and `/`. Agent names, paths, and arguments are shell-escaped
before interpolation. PATH discovery runs away
from the launch path, drains stdout and stderr concurrently, has a bounded
timeout, and is injected per surface rather than mutating process-global
environment.



Renaming updates Clawddy's label at once.
Nothing is typed into a running terminal: Claude receives the label as
`--name` at its next launch, and Codex sessions are not renamed. "New agent"
creates an agent under a free "agent N" and edits its name in its row; the
agent starts only when the name is set (Return, Esc, leaving the field, or ten
seconds without a key), so its first launch already carries the name it keeps
and no session is ever labelled with a name the user then changed.

## Persistence and Recovery

Each agent's lasting state is its record, one file per agent:

```text
~/.config/ghostty-agents/status/<agent-uuid>.record.json
```

`AgentRecord` holds the agent's state as `docs/clawddy-design/flows.md` 2
names it (working, asks, problem, finished, paused at its usage limit, limit
reset), unread, settled and when, whether its CLI ran, whether a quit or
crash cut its turn off and how many continuations followed, whether the person
interrupted it, where its name came from, its first instruction, its last 20
prompts each marked as the person's or the app's, its last message, what it
is doing, its question, its problem and its usage limit, and when its state
last changed. The sentence a tile shows is a function of the record
(`AgentRecord.sentence`), which tells the CLI's own words from the app's. Its
name, CLI and place in its project stay in `agents.json`, and its session in
`<agent-uuid>.session.json`: each fact has one home. A removed project stays
in `agents.json` under `removedProjects` with its agents, all settled, until it
comes back (undo, opening one of its agents, or adding its folder again):
removing a project or settling an agent deletes nothing. A settled agent's CLI
ends 60 s after settling (`AgentBridge.settledCLIEnd`); only a start cancelled
within 6 s deletes an agent and its files. `AgentStateReducer` is
the one reducer of the record's states and transitions; the bridge queues
the record for writing, atomically and mode `0600`, in the turn of each change
of its durable part (`AgentRecord.durable`: everything but the step a working
CLI reports, which changes many times a second and which a restart clears).
The IO queue writes the changes in order within milliseconds, none is merged
away, the main thread never waits for the disk, and quitting waits for the
queue. A turn under way at a quit or crash is found cut off at the next start,
and only those agents start by themselves (`AgentBridge.continueCutOffAgents`).
At most three CLIs start at once, whatever starts them (a burst of new
agents, these continuations, opens): the rest wait their turn, their start
limit counting from when they begin, and the person's open goes first; the
launches of one burst share one listing of the running conversations for the
open-elsewhere check (`AgentLiveSessions`). Each continuation resumes
its conversation with the continuation message as its first prompt, marked as
the app's; a fourth in a row is not sent. One cut off before it had a
conversation starts fresh with its first instruction, labelled; a settled
agent is never continued. Every other agent starts nothing until opened.
Before a resume, the conversation is checked not to be live elsewhere:
Claude's own list of its sessions (`claude agents --json --all`), and for
Codex, which lists none, a running Codex given that id. A record that cannot
be read is reported and kept; nothing is saved over it.

Text reaches a CLI one way, `AgentBridge.send`: only once the CLI reads its
input, never on top of text left in its input line or into a question, as a
paste followed by Return, recorded once as the person's or the app's. An
interrupting send checks all of that again after the interrupt. Keys the
person types while a CLI starts are held until its first status report
(`AgentBridge.holdsKeys`), and thrown away, with a status line, when the start
fails, asks, is left, or shows a screen with no report within
`AgentBridge.holdLimit`.

`state.json`, which earlier builds kept, is folded into records once at the
first start (`AgentStateFold`): unread and interrupted agents become unread,
running ones stay on their tiles, and the rest start settled; the file is moved to
`<root>-backups/<date>-state-json/`.

The data root (`AgentDataRoot`) is resolved once at launch and passed to
everything that touches the configuration, status, hook, and state tree. It is
`~/.config/<ClawddyDataDirectoryName>`, an Info.plist key set by the
`CLAWDDY_DATA_DIRECTORY_NAME` build setting, or a fresh temporary folder in a
test host. Launch fails if the production bundle ID `com.mitchellh.ghostty`
is paired with any other root than `~/.config/ghostty-agents`, or another
bundle ID with that root. A lock file, `<root>/clawddy.lock`, refuses a second
instance on the same root. There is no environment override.

`macos/build.nu --identity dev` builds a side-by-side app: bundle ID
`com.mitchellh.ghostty.clawddy-dev`, name "Clawddy Dev", root
`~/.config/clawddy-dev`, products under `<build root>/dev`. `--action test`
always builds the test identity (`com.mitchellh.ghostty.clawddy-tests`,
products under `<build root>/tests`), whatever `--identity` says. Only the
production bundle ID registers Option-Space and starts the updater.

At launch, before any terminal exists, the app removes the agent identity
variables (`GHOSTTY_AGENT_ID`, `GHOSTTY_AGENT_NAME`, `GHOSTTY_AGENT_PROVIDER`,
`GHOSTTY_AGENT_LAUNCH_GENERATION`, `GHOSTTY_AGENT_STATUS_DIR`, and the four
`CLAWDDY_*` agent names) from its own environment, so an app started from an
agent's terminal cannot pass that identity on. agent-cron's
`GHOSTTY_AGENT_CRON_*` variables are left alone.

Surface, process, activity, telemetry and aggregate state are reconstructed
from configuration, records, ordered hooks and live surfaces.

Startup order:

1. Ensure config, hook, and status directories exist.
2. Load configuration and restore provider identities from persisted bindings.
3. Fold `state.json` into records if it exists, then load each agent's record.
4. Recreate inactive, provider-specific runtime instances.
5. Start config and status directory watchers and consume unseen complete events.
6. Probe provider installation/auth health away from the main actor.
7. Start journal/process reconciliation.

Provider hook installation remains a first-launch action, not a startup action.
The one startup write to a provider file is the production app removing older
builds' global Claude entries, and only when there is one to remove.

Shutdown cancels timers and watchers and removes surface observers; every
record was written with its last change. Launch scripts live in `<root>/runtime/launch/`; the next start
empties that folder and nothing else.

## Workspace and Focus

The workspace is an `NSSplitViewController` with three native macOS columns:
project/task navigation, a searchable agent list, and an AppKit detail controller
hosting Ghostty's terminal view.

- The workspace window has a stable identifier, an `NSWindowRestoration` class,
  frame autosaving, and split-position autosaving.
- System-standard chrome follows the application appearance; terminal content
  retains the configured terminal appearance.
- Navigation, search, editing, and terminal controls participate in the key-view loop.
- Editable fields use AppKit's shared field editor; drag payloads resolve into
  durable hierarchy commands with Undo/Redo rather than view-local reordering.
- Selection changes detail context but never launches a process or steals focus.
- Double-click, Return, and the terminal area's one action (Start, Resume,
  Start fresh, Sign in, Retry) are explicit activation paths. Next waiting,
  previous and next agent, and the finder select an agent and focus its
  terminal; they start nothing. The keys are in
  `docs/clawddy-design/shortcuts.md`.
- Window key/resign-key transitions reapply the stack's focus invariant to every
  terminal; a window that becomes key with the keys on itself gives them to the
  shown terminal.
- Hidden surfaces never report themselves as focused and never take the keys.

The Option-Space shortcut is currently registered through Carbon hot-key APIs.
Treat this as a legacy integration boundary: keep registration and teardown
paired, test conflicts and keyboard layouts, and prefer a supported replacement
if Apple provides equivalent global-shortcut behavior.

The search panel hosts the finder on the chrome palette. Canceling a global search restores the previously frontmost
application; choosing a result keeps Clawddy active.

## Notifications and Attention

The top bar's count and the Dock badge are the durable attention mechanisms; the badge is the same count, set without asking the system for any permission (where macOS shows no badge without one, there is none until the person turns notifications on).
System notifications are supplementary and must degrade cleanly when permission
is denied. A notification's title is the agent's name, its subtitle the
project and its body the agent's sentence (words.md).

| Transition           | Intended presentation                                              |
| -------------------- | ------------------------------------------------------------------ |
| Active to idle       | Passive completion notification; unread state only when not viewed |
| Permission requested | Time-sensitive notification and attention state                    |
| Sign-in/input needed | Actionable attention state with provider-specific text              |
| Error                | Active notification and attention state                            |

Notification authorization is requested only when the person turns on "Notify when an agent is waiting" in the Agent menu (off by default), never at launch; every request goes through `AgentPermissionRequests`, which the harness reports. An agent's terminal posts no desktop notification of its own, and no Clawddy notification plays a sound. Denial is normal and never blocks
in-app attention state. Critical sounds are not used.

Notification identifiers begin with `clawddy.` and payloads include the stable
agent UUID. Activation opens the window, enters the target in its project and
gives its terminal the keys: a deliberate open, which starts its CLI when it is
not running. Visible agents do not receive redundant completion banners;
clearing is scoped to the viewed agent rather than global notification history.

## Accessibility and Visual Effects

State must never be encoded by color or animation alone. Agent rows expose a
text label and symbol for each non-inactive state; the top bar says how many agents wait for the user.

All new controls require keyboard operation and accessible names. Command-palette
and workspace changes require an automated accessibility audit plus manual
VoiceOver verification. Animations must honor Reduce Motion.

The search panel may use `NSGlassEffectView` on macOS 26 or newer. Older systems
use the established fallback. Glass is presentation only; contrast, focus, hit
testing, and accessible semantics must not depend on it.

## Security and Privacy Boundaries

- What the person and the agents said is stored as text on this Mac only:
  the prompts, the agent's last messages, failure texts and questions, in the
  agent's event file (`status/<agent-uuid>.events`, appended by the hook
  script, mode `0600` under a `umask 077` script) and in its record
  (`status/<agent-uuid>.record.json`, mode `0600`), both under the app's
  data folder (`0700`). Clawddy sends none of it anywhere and reads no
  transcript file; a record keeps at most 20 prompts and 16 KB of a message.
  Tool inputs, tool results and the rest of the conversation are not stored.
- UUIDs, session IDs, and names are validated or escaped before entering shell
  commands and paths.
- Writes that coordinate hook and app state are atomic.
- Hook installation must preserve unrelated entries in Claude and Codex settings,
  serialize Clawddy writers, detect concurrent external changes, and keep its
  backup behavior. Codex hook trust is never bypassed.
- Keychain access uses the account home. Configuration and telemetry isolation
  uses `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, and the status folder passed to the
  hook script and the status-line proxy; do not
  copy credentials or create a second login Keychain for an alternate-home
  installation.
- New installations default Claude Code to `--dangerously-skip-permissions` and
  Codex to `--dangerously-bypass-approvals-and-sandbox`. These are explicit,
  user-visible product defaults—not macOS entitlements. Settings can choose the
  providers' standard permission behavior, and the header's details card shows
  the mode captured when each agent was created.
- Notification denial must not prevent in-app state from updating.
- Clawddy does not read the general pasteboard directly. Any future clipboard
  integration must follow the pasteboard privacy policy in the macOS guide.

## Accepted Limitations

### Provider-to-shell transition

The provider may exit while the fallback login shell remains alive. The launch
script journals provider exit before replacing itself, while a surface-close
notification remains an independent fallback. The UI must never equate the
shell's continued surface lifetime with a live provider process.

### Launch timeout

The ten-second launch timeout only governs status telemetry. A slow resume or
missing hook is presented as **Status Unavailable**, while the terminal remains
usable. A later valid hook recovers tracked state without recreating the surface.

### Single application instance

Multiple Clawddy-enabled Ghostty processes share configuration, hook, and status
files. The current architecture does not coordinate writers across application
instances; run one instance at a time.

### One surface per agent

An agent UUID owns at most one terminal surface. Explicit activation reuses the
existing surface rather than opening another view.

## Validation

Changes to this feature require the general macOS matrix in
[`MACOS_DEVELOPMENT.md`](MACOS_DEVELOPMENT.md#required-validation-matrix) plus:

- Fresh and resumed launch for each provider, including mixed projects.
- Signed-out first use, disabled hooks, and late telemetry recovery.
- Rename while running and stopped; the next Claude launch carries `--name`.
- `/clear`, then Restart resumes the post-clear session; a resume of a missing
  session offers Start Fresh.
- External `agents.json` edit and provider-identity enforcement.
- Burst hook traffic, duplicate file events, and malformed event JSON.
- Agent process exit, deletion, app termination, and next-launch cleanup.
- Switching among multiple surfaces without hidden-surface focus or input.
- Option-Space search, keyboard navigation, badge, and notification
  activation.
- Notification authorization allowed and denied.
- VoiceOver and reduced-motion operation across navigation, agent list, detail,
  and command palette.

When behavior changes, update this document at the invariant or ownership level.
Do not paste a new copy of the implementation into the documentation.
