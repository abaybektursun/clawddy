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
2. **Provider adapters:** each provider owns command construction, auth probing,
   hook registration, capabilities, and normalization into shared domain events.
3. **Event ingestion:** provider hooks append minimal, provider-tagged lifecycle
   records; the app consumes them in order from persisted byte offsets.
4. **Session metadata:** the UI presents provider-reported or explicitly
   configured values and labels unavailable capabilities instead of inferring them.
5. **Terminal ownership:** each live agent has one Ghostty surface hosted through
   Ghostty's normal terminal view model and focus path.
6. **Presentation:** navigation, the agent list, terminal detail, command palette,
   status item, badge, and notifications render derived state.

Clawddy does not replace Ghostty's terminal renderer, input stack, configuration,
or process model.

## Component Ownership

| Component                         | Responsibility                                                                                                    |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `AgentConfig.swift`               | Versioned JSON model, atomic persistence, schema migration, and provider-identity recovery                        |
| `AgentProvider.swift`             | Provider protocol, capability matrix, health/auth state, launch records, and provider event vocabulary           |
| `ClaudeCodeProvider.swift`        | Claude Code command construction, hook installation, auth probe, and event normalization                         |
| `CodexProvider.swift`             | Codex command construction, hook installation, auth probe, and event normalization                               |
| `AgentHookRuntime.swift`          | Provider-tagged POSIX hook, safe shell quoting, and provider-exit journaling                                      |
| `AgentSessionStore.swift`         | Validated provider-tagged session and fork persistence plus legacy Claude migration                              |
| `AgentEnvironmentResolver.swift`  | Asynchronous login-shell PATH discovery with timeout and deterministic fallback                                   |
| `AgentEventJournal.swift`         | Complete-record parsing across append bursts, partial writes, and journal replacement                             |
| `AgentMetadataRuntime.swift`      | Per-agent Claude settings overlay, status-line forwarding, and atomic metadata publication                        |
| `AgentSessionMetadata.swift`      | Provider-neutral metadata plus strict decoding and presentation-safe normalization of official telemetry fields   |
| `AgentMetadataViews.swift`        | Compact list summary, persistent detail disclosure, exact inspector, freshness, and accessibility                 |
| `AgentStateReducer.swift`         | Pure surface/process/activity/interaction/telemetry transitions and ordered semantic effects                     |
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
 ├─ AgentConfig ───────────────► agents.json + provider identity migration
 ├─ AgentEnvironmentResolver ──► per-surface PATH
 ├─ AgentBridge ───────────────► adapters + event journal + metadata + AgentStateReducer
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
  "schemaVersion": 4,
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
              "name": "implementation",
              "provider": "codex",
              "launchProfile": {
                "modelID": null,
                "reasoningEffort": "high"
              }
            }
          ]
        }
      ]
    }
  ]
}
```

The decoder accepts older project/task records without IDs and the original
string-only agent array. It generates UUIDs, assigns pre-provider agents to
Claude Code, and writes the migrated form back. Legacy name-keyed status files
are moved to UUID-keyed names when possible. Once a tagged session or pending
fork exists, its provider is authoritative; an external config edit cannot make
another provider consume that identity.

Configuration writes are atomic and UI mutations are transactional: a failed
replacement restores the previous observable model and surfaces a configuration
error. Project/task deletion is persisted before related runtimes are torn down.
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
| Telemetry     | not started, awaiting, live, unavailable with an explanation | lifecycle transport           |

Every launch receives a new generation UUID. Surface callbacks, timeout events,
and hook records carry that generation; the reducer rejects stale events from a
previous process. Provider-specific adapters normalize raw hook names into the
shared domain vocabulary before reduction.

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
generation, and journal event ID. Unread completion is durable attention state:
it remains visible even if the provider or surface exits and clears only after
the user actually exposes that agent's terminal in the key workspace window.

`DisplayState` and parent state are computed rather than stored. `AggregateState`
is then derived across all agents:

- `attention` if any agent has unread work, needs permission, or has an error.
- `running(count)` when one or more agents are reasoning or executing.
- `idle` otherwise.

The status item, task/project icons, smart scopes, and Dock badge consume those
same derived states. They must not maintain a second state machine.

## Hook and Event Pipeline

The selected provider adapter lazily installs one shared POSIX hook when an
agent is first launched:

```text
~/.config/ghostty-agents/hooks/clawddy-provider-hook.sh
```

Claude Code registers it in `<CLAUDE_CONFIG_DIR>/settings.json`; Codex registers
it in `<CODEX_HOME>/hooks.json`. Each adapter removes only older Clawddy-owned
handlers, preserves unrelated groups and settings, writes mode `0600`, and keeps
one backup of the original user file. Integration is not performed at app
startup, so merely opening Clawddy never changes a provider configuration.

Codex hashes non-managed command hooks and will skip a new or changed definition
until the user reviews it with `/hooks`. Clawddy does not bypass that trust flow.
A skipped or disabled hook degrades activity telemetry without turning a working
interactive terminal into a launch failure.

The hook depends only on macOS system tools. For each invocation it:

1. Reads the official hook payload from standard input into a private temporary file.
2. Uses `plutil` to extract only session, event, turn, model, and permission identifiers.
3. Adds a stable event ID plus the provider and launch generation supplied by
   the launcher.
4. Atomically updates the provider-tagged session binding and appends one JSONL
   record while holding a bounded macOS `lockf` lock for that agent.

```text
~/.config/ghostty-agents/status/<agent-uuid>.session.json
~/.config/ghostty-agents/status/<agent-uuid>.events
~/.config/ghostty-agents/status/<agent-uuid>.fork.json
```

Legacy `.session` and `.forkFrom` inputs are accepted only as Claude Code state
and are migrated to tagged records. A session or fork tagged for one provider is
never passed to another provider. The journal intentionally excludes prompts,
tool inputs, tool results, and transcript content.

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

Tagged records must use the supported event schema. Unknown schema versions and
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

Configured and observed values retain their provenance. The inspector labels a
launch-profile value as **Requested model** or **Requested effort** until the
provider independently reports an effective value; configured input is never
presented as observed telemetry.

Claude Code additionally supplies effective reasoning effort, context-window
use, token totals, duration, and cost data to a configured `statusLine` command.
That payload is the authoritative source for Claude telemetry: Clawddy does not
scrape terminal output or read transcript contents.

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
allowlist into one provider-neutral `AgentSessionMetadata` value on the main
actor. Metadata is not duplicated into `state.json`; the atomic snapshot is its
sole on-disk source
of truth. Claude may report null context usage before the first API response and
immediately after compaction. The UI distinguishes loading, recalculating,
unavailable, and retained last-known values instead of displaying a false zero.

Codex's stable interactive hook interface does not currently report context
usage, session cost, or effective reasoning effort. Codex app-server provides a
richer client protocol, but Clawddy does not currently run a second control
channel alongside the real interactive TUI. The inspector labels each missing
field as unavailable or unsupported and explains the integration boundary; it
never substitutes a fabricated value.

The selected-agent header exposes a persistent summary button with an anchored
inspector. Agent-list rows show a lower-priority scan summary. Both use the same
snapshot, define context consistently as percent used, pair progress with text,
and include complete VoiceOver values. Model and effort are searchable in both
the agent list and command palette. The inspector is also available from the
toolbar Info button and **Agent > Show Agent Details** (`Command-I`), including
while keyboard focus is inside the terminal.

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
2. On the serial I/O queue, resolve provider-tagged resume/fork state, validate
   the provider executable and arguments, install the selected adapter's
   integration, and create a mode-0700 launch script.
3. Back on the main actor, reject stale preparation and ask
   `AgentDetailViewController` to show an existing host or create one.
4. For a new host, create `Ghostty.SurfaceView`, wrap it in `SplitTree`, and host
   the normal `TerminalView` through `AgentTerminalHost`.
5. Retain the surface, host, and container by agent UUID.
6. Observe the surface-specific close notification.
7. On explicit activation, move focus through `Ghostty.moveFocus(to:)` and mark
   the agent read.

The terminal is never reparented into an unrelated custom view hierarchy. Using
Ghostty's existing `TerminalView` path preserves focused-value propagation,
responder changes, surface focus reporting, and terminal input behavior.

Switching agents detaches the previous container from the layout while retaining
its live surface and host, then clears its focused surface. Only the selected
terminal presentation is attached to the split view.
Closing or deleting an agent removes the container, host, surface reference,
observer, timer, and associated status files.

If no hook arrives within ten seconds, the reducer marks telemetry unavailable
and presents a non-fatal **Status Unavailable** state. The live terminal remains
authoritative: missing telemetry is not reported as a failed launch. A later
valid hook recovers the same process to running/live without recreating its
surface.

## Command Construction, Resume, and Fork

Each new terminal starts a unique, mode-0700 temporary login-shell script. It
sets `HOME` to the macOS account home so provider authentication uses the user's
normal Keychain and account context. It propagates an explicit
`CLAUDE_CONFIG_DIR` or `CODEX_HOME` only when the caller selected one, and always
sets the isolated status directory, provider ID, agent UUID, and launch
generation. Command selection is ordered:

1. Resume the UUID's provider-matching tagged session when one exists.
2. Fork the provider-matching source recorded in `.fork.json`.
3. Start a fresh interactive provider TUI.

Claude Code uses its interactive `--resume` and `--fork-session` paths plus
optional model, effort, and status-line settings. Codex uses the stable
interactive `resume` and `fork` subcommands plus optional `--model` and
`model_reasoning_effort` configuration. Clawddy does not use Codex's experimental
app-server and does not pass Codex's approval, sandbox, or hook-trust bypass
flags.

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

Forking creates a new UUID and configuration entry, then writes the source
session ID and provider to the new UUID's `.fork.json` file. The marker is
removed after the new agent's first valid hook confirms launch. The source and
fork never share an identity or cross a provider boundary.

Renaming always updates Clawddy's editable label. Both provider TUIs receive
`/rename` only in a display state the bridge considers safe for input; otherwise
the request is persisted and delivered after a safe state arrives.

## Persistence and Recovery

Only state that cannot be reconstructed is persisted in:

```text
~/.config/ghostty-agents/state.json
```

It contains provider-tagged unread and last-applied completion identities,
pending provider renames, and per-agent event-journal byte offsets. The durable
last-applied identity makes replay idempotent even after unread state is
acknowledged. Surface, process, activity,
interaction, telemetry, display, and aggregate state are reconstructed from
configuration, ordered hooks, and live surfaces.

Startup order:

1. Ensure config, hook, and status directories exist.
2. Load and migrate configuration, including legacy Claude identities.
3. Load persisted unread/last-applied completion and pending-rename state.
4. Recreate inactive, provider-specific runtime instances.
5. Start config and status directory watchers and consume unseen complete events.
6. Probe provider installation/auth health away from the main actor.
7. Start the process-exit heartbeat and diagnostics.

Provider hook installation remains a first-launch action, not a startup action.

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
| Sign-in/input needed | Actionable attention state with provider-specific text              |
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

- Hook files contain only event ID, provider, generation, event, session, turn,
  model, and permission identifiers, not prompts, transcript content, or tool
  results.
- UUIDs, session IDs, and names are validated or escaped before entering shell
  commands and paths.
- Writes that coordinate hook and app state are atomic.
- Hook installation must preserve unrelated entries in Claude and Codex settings,
  serialize Clawddy writers, detect concurrent external changes, and keep its
  backup behavior. Codex hook trust is never bypassed.
- Keychain access uses the account home. Configuration and telemetry isolation
  uses `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, and `GHOSTTY_AGENT_STATUS_DIR`; do not
  copy credentials or create a second login Keychain for an alternate-home
  installation.
- The agent launcher currently passes Claude's
  `--dangerously-skip-permissions` flag. This is an explicit product behavior,
  not a macOS entitlement; changes to it require a product-level security review.
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

- Fresh, resumed, and forked launch for each provider, including mixed projects.
- Signed-out first use, Codex hook review, disabled hooks, and late telemetry recovery.
- Rename while idle and rename deferred during a blocking state.
- External `agents.json` edit, provider-identity enforcement, and legacy-schema migration.
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
