# Clawddy Agent Architecture

This document describes the stable architecture and invariants of Clawddy's
multi-agent workspace. It intentionally avoids copying method bodies or UI
styling from the implementation; those details change more often than the
design.

For Apple-framework policy, deployment targets, permissions, accessibility,
and compatibility work, see [`MACOS_DEVELOPMENT.md`](MACOS_DEVELOPMENT.md).

## Scope

Clawddy adds a native macOS workspace to Ghostty for organizing Claude Code
sessions by project and task. Each agent owns a Ghostty terminal surface, a
stable UUID, and independently derived process and Claude state.

The feature has five boundaries:

1. **Configuration:** projects, tasks, agent identities, and working directories.
2. **Event ingestion:** Claude hooks append minimal lifecycle records; the app
   consumes them in order from persisted byte offsets.
3. **Session metadata:** Claude Code's official status-line payload reports the
   effective model, reasoning effort, context use, and session totals.
4. **Terminal ownership:** each live agent has one Ghostty surface hosted through
   Ghostty's normal terminal view model and focus path.
5. **Presentation:** navigation, the agent list, terminal detail, command palette,
   status item, badge, and notifications render derived state.

Clawddy does not replace Ghostty's terminal renderer, input stack, configuration,
or process model.

## Component Ownership

| Component                         | Responsibility                                                                                                    |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `AgentConfig.swift`               | Versioned JSON model, atomic persistence, migration, and Claude hook installation                                 |
| `AgentEnvironmentResolver.swift`  | Asynchronous login-shell PATH discovery with timeout and deterministic fallback                                   |
| `AgentEventJournal.swift`         | Complete-record parsing across append bursts, partial writes, and journal replacement                             |
| `AgentMetadataRuntime.swift`      | Per-agent Claude settings overlay, status-line forwarding, and atomic metadata publication                        |
| `AgentSessionMetadata.swift`      | Strict decoding and presentation-safe normalization of official Claude status-line fields                         |
| `AgentMetadataViews.swift`        | Compact list summary, persistent detail disclosure, exact inspector, freshness, and accessibility                 |
| `AgentStateReducer.swift`         | Pure process/Claude/unread transition logic and semantic effects                                                  |
| `AgentStateAggregation.swift`     | Deterministic severity-first descendant-state propagation to tasks and projects                                   |
| `AgentTerminalBridge.swift`       | Ordered event ingestion, runtime state, surface lifecycle, notifications, persistence, and aggregate state        |
| `AgentTerminalHost.swift`         | `TerminalViewModel` and `TerminalViewDelegate` adapter for one agent surface tree                                 |
| `AgentDetailViewController.swift` | Creates, retains, switches, focuses, and removes per-agent terminal hosts and surfaces                            |
| `AgentWorkspaceController.swift`  | AppKit three-column split view, toolbar, restoration metadata, and workspace window                               |
| `AgentWorkspaceViews.swift`       | Project/task navigation, filtered agent list, editing, empty states, and accessibility                            |
| `AgentCommandPaletteView.swift`   | Converts agents into stable, semantically searchable shared-palette commands                                      |
| `AgentSearchPanel.swift`          | Floating AppKit panel, compatibility material, positioning, and reduced-motion behavior                           |
| `BridgeMetrics.swift`             | Snapshot-based, low-overhead counters and main-thread stall diagnostics                                           |
| `AppDelegate.swift`               | Composition root, menus, status item, global shortcut, workspace ownership, routing, and Dock badge               |

The composition is deliberately one-way:

```text
AppDelegate
 ├─ AgentConfig ───────────────► agents.json + Claude hook settings
 ├─ AgentEnvironmentResolver ──► per-surface PATH
 ├─ AgentBridge ───────────────► event journal + metadata snapshots + AgentStateReducer
 │    └─ callbacks ────────────► AppDelegate / AgentDetailViewController
 ├─ AgentWorkspaceController
 │    ├─ AgentNavigationView ──► projects, tasks, smart scopes
 │    ├─ AgentListView ────────► agents, search, explicit actions
 │    └─ AgentDetailViewController
 │         └─ AgentTerminalHost ─► Ghostty SurfaceView
 └─ AgentSearchPanel ──────────► AgentCommandPaletteView
```

Views issue user actions through configuration and bridge methods. They do not
read hook files, create Ghostty surfaces directly, or persist derived state.

Agent presentation order is configuration order: project order, then task
order, then agent insertion order. Filtering preserves that relative order.
Runtime state, unread state, metadata, activation, and renaming never change a
row's position; urgency is communicated through status styling and smart scopes.

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
to an `NSTextView` field editor created for a SwiftUI `TextField`. This prevents
terminal key equivalents such as Command-V from bypassing native text editing.
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
}
```

The on-disk configuration lives at:

```text
~/.config/ghostty-agents/agents.json
```

Current encoded shape:

```json
{
  "projects": [
    {
      "id": "B150F75F-55CD-44BE-8994-3B8A840D71B5",
      "name": "ghostty",
      "workingDirectory": "/path/to/ghostty",
      "tasks": [
        {
          "id": "2FCF5403-85C9-4B95-85A9-9978FB1C2F02",
          "name": "display-link",
          "agents": [
            {
              "id": "534A7DB8-4623-4C40-A3C6-DF5914D1302B",
              "name": "implementation"
            }
          ]
        }
      ]
    }
  ]
}
```

The decoder accepts older project/task records without IDs and the original
string-only agent array. It generates UUIDs and writes the migrated form back.
Legacy name-keyed status files are moved to UUID-keyed names when possible.

Configuration writes are atomic and UI mutations are transactional: a failed
replacement restores the previous observable model and surfaces a configuration
error. Project/task deletion is persisted before related runtimes are torn down.
The directory watcher compares raw file data with the last successfully written
or loaded snapshot so it ignores the app's own writes and reloads actual external
edits.

## State Model

Runtime state separates facts owned by Ghostty from facts reported by Claude.

### Process state

`ProcessState` is app-controlled:

| State         | Meaning                                                       |
| ------------- | ------------------------------------------------------------- |
| `inactive`    | No terminal surface exists for the agent                      |
| `launching`   | A surface exists, but no valid Claude hook has arrived        |
| `alive`       | A valid Claude hook confirmed the session                     |
| `unconfirmed` | The terminal is running, but lifecycle status is unavailable |
| `failed`      | The surface or launch script could not be created             |
| `dead`        | The surface was destroyed or its child process exited         |

### Claude state

`ClaudeState` is hook-controlled:

| State        | Hook interpretation                                    |
| ------------ | ------------------------------------------------------ |
| `unknown`    | No usable event                                        |
| `idle`       | Session start/end, stop, or post-compact               |
| `thinking`   | User prompt submitted                                  |
| `working`    | Tool use began or completed                            |
| `permission` | Permission request                                     |
| `error`      | Stop or tool-use failure                               |
| `compacting` | Pre-compact; expires if no matching completion arrives |

### Display and aggregate state

`AgentStateReducer` is the only definition of runtime transitions. It accepts an
immutable snapshot and an event, then returns the next snapshot plus semantic
effects such as completion, waiting for user, failure, or unread change. The
bridge performs side effects only after reducing state.

`DisplayState` is computed from process state, Claude state, and the unread bit;
it is never persisted. For example, `alive + idle + unread` becomes `finished`.

`AggregateState` is then derived across all agents:

- `attention` if any agent is finished, needs permission, or has an error.
- `running(count)` when one or more agents are thinking or working.
- `idle` otherwise.

The status item and Dock badge consume aggregate state. They must not maintain a
second state machine.

## Hook and Event Pipeline

`AgentConfig` installs one POSIX shell hook at:

```text
~/.config/ghostty-agents/hooks/clawddy-hook.sh
```

The hook is registered in `<CLAUDE_CONFIG_DIR>/settings.json` for the Claude
lifecycle and tool events Clawddy observes. When `CLAUDE_CONFIG_DIR` is unset,
Claude's normal `~/.claude` default applies. It has no dependency on `jq`,
Python, or Homebrew.
For each invocation it:

1. Reads the hook payload from standard input.
2. Extracts only `session_id` and `hook_event_name`.
3. Updates the UUID-keyed session file and appends one newline-delimited event
   while holding a bounded macOS `lockf` lock for that agent.

```text
~/.config/ghostty-agents/status/<agent-uuid>.session
~/.config/ghostty-agents/status/<agent-uuid>.events
~/.config/ghostty-agents/status/<agent-uuid>.forkFrom
```

The hook intentionally stores a minimal event instead of the complete tool
payload. Tool results can contain large command output, file contents, or other
sensitive material that the UI does not need.

`AgentBridge` watches the status directory. Filesystem events are throttled into
one nonoverlapping poll per 200-millisecond window. Reads seek directly to the
persisted byte offset and stop at the last complete newline, so cost follows new
events rather than total history and a concurrent partial write is never decoded.
Every complete record is applied sequentially on the main thread and the
resulting offset is persisted. Once an acknowledged prefix reaches one MiB, the
bridge compacts it under the same kernel-managed per-agent lock used by hooks, retains any
concurrent suffix, resets the offset, and immediately repolls. A 30-second
heartbeat checks for process exits that surface notifications missed; it is not
the primary ingestion path.

Legacy `.lastEvent` files are migration inputs only. New hooks never use the
lossy single-value register.

## Session Metadata Pipeline

Claude Code supplies the effective model, reasoning effort, context-window use,
token totals, version, and cost data to a configured `statusLine` command. This
is the authoritative source: Clawddy does not scrape terminal output or infer
these values from requested launch options.

Before starting or resuming an agent, `AgentMetadataRuntime` creates a private,
per-agent settings overlay and passes it with Claude's `--settings` option. The
overlay changes only `statusLine`; lifecycle hooks and all unrelated user,
project, and local settings continue to come from their normal scopes. The
runtime resolves the existing effective status-line object, preserves unknown
presentation fields, and forwards the exact input to the user's original
command. Only that command's output reaches Claude, so an existing status line
continues to render unchanged.

The proxy atomically publishes the same status-line input at Clawddy's explicit
`GHOSTTY_AGENT_STATUS_DIR` (the default path is shown below):

```text
~/.config/ghostty-agents/status/<agent-uuid>.metadata.json
```

Configuration and status directories are mode `0700`; generated settings,
upstream-command files, and snapshots are mode `0600`. A publication failure is
non-fatal and must not prevent the original status-line command from running.
Managed settings or `disableAllHooks` can prevent the overlay from operating;
the UI reports that as metadata unavailable without treating the agent launch as
a failure.

The bridge reads only a changed snapshot on its serial I/O queue and decodes an
allowlist into one `AgentSessionMetadata` value on the main thread. Metadata is
not duplicated into `state.json`; the atomic snapshot is its sole on-disk source
of truth. Claude may report null context usage before the first API response and
immediately after compaction. The UI distinguishes loading, recalculating,
unavailable, and retained last-known values instead of displaying a false zero.

The selected-agent header exposes a persistent summary button with an anchored
inspector. Agent-list rows show a lower-priority scan summary. Both use the same
snapshot, define context consistently as percent used, pair progress with text,
and include complete VoiceOver values. Model and effort are searchable in both
the agent list and command palette. The inspector is also available from the
toolbar Info button and **Agent > Show Agent Details** (`Command-I`), including
while keyboard focus is inside the terminal.

## Concurrency and Observation

`AgentConfig`, `AgentBridge`, `AgentInstance`, and header models use the
Observation framework. UI-visible mutations are performed on the main thread.
The bridge's serial I/O queue is limited to file reads and writes over captured
values; it returns results to the main queue before applying state.

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

1. Set the runtime instance to `launching` and start a one-shot launch timer.
2. Ask `AgentDetailViewController` to show an existing host or create one.
3. For a new host, create `Ghostty.SurfaceView`, wrap it in `SplitTree`, and host
   the normal `TerminalView` through `AgentTerminalHost`.
4. Retain the surface, host, and container by agent UUID.
5. Observe the surface-specific close notification.
6. On explicit activation, move focus through `Ghostty.moveFocus(to:)` and mark
   the agent read.

The terminal is never reparented into an unrelated custom view hierarchy. Using
Ghostty's existing `TerminalView` path preserves focused-value propagation,
responder changes, surface focus reporting, and terminal input behavior.

Switching agents detaches the previous container from the layout while retaining
its live surface and host, then clears its focused surface. Only the selected
terminal presentation is attached to the split view.
Closing or deleting an agent removes the container, host, surface reference,
observer, timer, and associated status files.

If no hook arrives within ten seconds, the reducer moves the instance to
`unconfirmed` and presents a non-fatal **Status Unavailable** state. The live
terminal remains authoritative: missing telemetry is not reported as a failed
launch. A later valid hook recovers the same instance to `alive`.

## Command Construction, Resume, and Fork

Each new terminal starts a unique, mode-0700 temporary login-shell script. It
sets `HOME` to the macOS account home so Claude can resolve the user's login
Keychain, while setting `CLAUDE_CONFIG_DIR` and `GHOSTTY_AGENT_STATUS_DIR`
explicitly for alternate-home installations. Ordinary installations leave
`CLAUDE_CONFIG_DIR` unset and retain Claude's default profile behavior. That
separation lets an isolated installation use the user's normal login Keychain
without reading or writing another installation's Claude configuration, hooks,
session files, or metadata. `GHOSTTY_AGENT_NAME` is set to the agent UUID.
Command selection is ordered:

1. Resume the UUID's recorded session when a valid session file exists.
2. Resume and fork the session recorded in `.forkFrom`.
3. Start a fresh named Claude session.

After Claude exits, the script replaces itself with the user's login shell so
the terminal remains useful. Launch scripts are tracked and removed after a
confirmed hook, surface death, shutdown, or next-start stale cleanup.

Session IDs are accepted only when every character is alphanumeric, a hyphen, or
an underscore. Agent names are shell-escaped before interpolation. PATH discovery
runs away from the launch path, drains stdout and stderr concurrently, has a
bounded timeout, and is injected per surface rather than mutating process-global
environment.

Forking creates a new UUID and configuration entry, then writes the source
session ID to the new UUID's `.forkFrom` file. The marker is removed after the
new agent's first valid hook confirms launch. The source and fork never share an
identity.

Renaming updates the editable label immediately. `/rename` is sent to a terminal
only in a display state that the bridge considers safe for input; otherwise the
rename is persisted and delivered after a safe state arrives.

## Persistence and Recovery

Only state that cannot be reconstructed is persisted in:

```text
~/.config/ghostty-agents/state.json
```

It contains unread agent IDs, pending renames, and per-agent event-journal byte
offsets. Process, Claude, display, surface, and aggregate state are reconstructed
from configuration, ordered hooks, and live surfaces.

Startup order:

1. Ensure config, hook, and status directories exist.
2. Install or update the universal hook without discarding unrelated Claude
   settings; keep a settings backup.
3. Load and migrate configuration.
4. Load persisted unread and pending-rename state.
5. Recreate inactive runtime instances.
6. Start config and status directory watchers and consume unseen complete events.
7. Start the process-exit heartbeat and diagnostics.

Shutdown cancels timers and watchers, removes surface observers, and flushes
persisted state. Temporary `clawddy-<uuid>.sh` launch scripts are cleaned on the
next start.

## Workspace and Focus

The workspace is an `NSSplitViewController` with three native macOS columns:
project/task navigation, a searchable agent list, and an AppKit detail controller
hosting Ghostty's terminal view.

- The workspace window has a stable identifier, an `NSWindowRestoration` class,
  frame autosaving, and split-position autosaving.
- System-standard chrome follows the application appearance; terminal content
  retains the configured terminal appearance.
- Navigation, search, editing, and terminal controls participate in the key-view loop.
- Selection changes detail context but never launches a process or steals focus.
- Double-click, Return, Start/Retry, Focus Terminal, and Command-Return are
  explicit activation paths.
- Window key/resign-key transitions reapply the active host's focus invariant.
- Hidden surfaces must not continue reporting themselves as focused.

The Option-Space shortcut is currently registered through Carbon hot-key APIs.
Treat this as a legacy integration boundary: keep registration and teardown
paired, test conflicts and keyboard layouts, and prefer a supported replacement
if Apple provides equivalent global-shortcut behavior.

The search panel reuses Ghostty's shared command-palette presentation. Agent
search results should remain data adapters; command filtering, keyboard
navigation, reduced-motion behavior, and accessibility stay centralized in the
shared palette. Canceling a global search restores the previously frontmost
application; choosing a result keeps Clawddy active.

## Notifications and Attention

The agent list, status item, and Dock badge are the durable attention mechanisms.
System notifications are supplementary and must degrade cleanly when permission
is denied.

| Transition           | Intended presentation                                              |
| -------------------- | ------------------------------------------------------------------ |
| Active to idle       | Passive completion notification; unread state only when not viewed |
| Permission requested | Time-sensitive notification and attention state                    |
| Error                | Active notification and attention state                            |

Notification authorization is requested only when the feature first needs to
deliver. Denial is normal and never blocks in-app attention state. Critical
sounds are not used.

Notification identifiers begin with `clawddy.` and payloads include the stable
agent UUID. Activation opens the workspace, reveals the target even when it is
outside the current scope, and focuses it when its surface already exists. An
inactive target remains at the explicit Start action instead of launching from a
navigation event. Visible agents do not receive redundant completion banners;
clearing is scoped to the viewed agent rather than global notification history.

## Accessibility and Visual Effects

State must never be encoded by color or animation alone. Agent rows expose a
text label and symbol for each non-inactive state; the status item supplies a
state-specific accessibility description.

All new controls require keyboard operation and accessible names. Command-palette
and workspace changes require an automated accessibility audit plus manual
VoiceOver verification. Animations must honor Reduce Motion.

The search panel may use `NSGlassEffectView` on macOS 26 or newer. Older systems
use the established fallback. Glass is presentation only; contrast, focus, hit
testing, and accessible semantics must not depend on it.

## Security and Privacy Boundaries

- Hook files contain only event and session identifiers, not complete Claude
  prompts or tool results.
- UUIDs, session IDs, and names are validated or escaped before entering shell
  commands and paths.
- Writes that coordinate hook and app state are atomic.
- Hook installation must preserve unrelated entries in Claude settings and keep
  its backup behavior.
- Keychain access uses the account home. Configuration and telemetry isolation
  use `CLAUDE_CONFIG_DIR` and `GHOSTTY_AGENT_STATUS_DIR`; do not copy credentials
  or create a second login Keychain for an alternate-home installation.
- The agent launcher currently passes Claude's
  `--dangerously-skip-permissions` flag. This is an explicit product behavior,
  not a macOS entitlement; changes to it require a product-level security review.
- Notification denial must not prevent in-app state from updating.
- Clawddy does not read the general pasteboard directly. Any future clipboard
  integration must follow the pasteboard privacy policy in the macOS guide.

## Accepted Limitations

### Claude-to-shell transition

Claude may exit while the login shell remains alive. Hooks do not reliably
report every exit path, and the surface process has not exited, so the last
Claude state may remain visible. The terminal content is authoritative.

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

- Fresh agent, resumed agent, and forked agent launch.
- Rename while idle and rename deferred during a blocking state.
- External `agents.json` edit and legacy-schema migration.
- Burst hook traffic, duplicate file events, and malformed event JSON.
- Agent process exit, deletion, app termination, and next-launch cleanup.
- Switching among multiple surfaces without hidden-surface focus or input.
- Option-Space search, keyboard navigation, status item, badge, and notification
  activation.
- Notification authorization allowed and denied.
- VoiceOver and reduced-motion operation across navigation, agent list, detail,
  and command palette.

When behavior changes, update this document at the invariant or ownership level.
Do not paste a new copy of the implementation into the documentation.
