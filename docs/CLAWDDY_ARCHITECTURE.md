# Clawddy Agent State Architecture v2

## Overview

Clawddy manages multiple Claude Code sessions running inside Ghostty terminal surfaces. This document specifies the complete state management architecture — identity, lifecycle, IPC, persistence, crash recovery, and UI integration.

## Design Principles

1. **Single source of truth per concern.** Process lifecycle owned by app. Claude state owned by hooks. Display state derived, never stored.
2. **UUID identity.** Agent identity is a UUID generated once at creation. Never changes. Display name is a label. Rename = label change. Zero rekey.
3. **Script is a dumb launcher.** All decisions made in Swift. Script sets env, runs one command, falls back to shell.
4. **Thread-safe by construction.** All mutable state on @MainActor. Background work reads snapshots of immutable data, posts results back to main.
5. **Crash-recoverable.** Every piece of state that matters across restarts is persisted to disk. In-memory state is reconstructible.
6. **No stuck states.** Process death is detected via surface destruction. Every state has an exit path.
7. **Atomic file operations.** All writes (hook and app) use tmp+rename. No partial reads ever.
8. **Per-row observation.** Each sidebar row observes its own AgentInstance. State changes re-render only the affected row, not the entire sidebar.

---

## Agent Identity

### AgentEntry (persisted in agents.json)

```swift
struct AgentEntry: Codable, Identifiable {
    let id: UUID          // generated once at creation, NEVER changes
    var name: String      // display label, freely renameable
}
```

Config format:

```json
{
  "projects": [{
    "name": "myproject",
    "workingDirectory": "/path/to/project",
    "tasks": [{
      "name": "feature",
      "agents": [
        {"id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890", "name": "alpha"},
        {"id": "f9e8d7c6-b5a4-3210-fedc-ba0987654321", "name": "beta"}
      ]
    }]
  }]
}
```

**UUID is used for:** env var (`GHOSTTY_AGENT_NAME`), status file names, dict keys, script file names.

**Display name is used for:** sidebar label, terminal title (OSC 2), `claude --name`, `/rename`.

**Rename is:** change `name` in config + send `/rename` to Claude. Zero rekey. Zero file renames.

**Fork is:** generate new UUID. Collision impossible.

---

## State Model

### Two orthogonal axes + one UI overlay

```swift
@MainActor
final class AgentInstance: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var sessionId: String?
    @Published var processState: ProcessState
    @Published var claudeState: ClaudeState
    @Published var isUnread: Bool
    @Published var lastHookTime: Date?

    var displayState: DisplayState { /* derived, never stored */ }
}

enum ProcessState: Codable {
    case inactive       // no terminal surface exists
    case launching      // surface created, waiting for first hook
    case alive          // claude process confirmed running (hook received)
    case dead           // terminal surface destroyed or process killed
}

enum ClaudeState: Codable, Equatable {
    case unknown        // no hook data yet
    case idle           // Stop hook fired (stop_reason: end_turn)
    case thinking       // UserPromptSubmit fired
    case working        // PreToolUse or PostToolUse fired
    case permission     // PermissionRequest fired
    case error          // StopFailure or PostToolUseFailure fired
    case compacting     // PreCompact fired, waiting for PostCompact
}
```

**Removed: `.shellFallback`.** Can't reliably detect Claude→shell transition:
- `/exit` doesn't fire SessionEnd (Claude Code bug)
- SIGINT/SIGTERM don't fire hooks
- `exec zsh` replaces process so `processExited` never fires
- No PTY fd access for `tcgetpgrp()`

When Claude exits and shell takes over, state stays at last known ClaudeState (typically `.idle` from the Stop hook). The terminal shows a shell prompt — the user sees it directly. Attempting to detect this transition causes more bugs (false positives) than it solves.

### DisplayState derivation

```swift
enum DisplayState {
    case inactive
    case launching
    case idle
    case finished       // alive + idle + unread
    case thinking
    case working
    case permission
    case error
    case compacting
    case dead
}

var displayState: DisplayState {
    switch processState {
    case .inactive:  return .inactive
    case .dead:      return .dead
    case .launching: return .launching
    case .alive:
        if isUnread && claudeState == .idle { return .finished }
        switch claudeState {
        case .unknown:    return .launching  // alive but no hook yet
        case .idle:       return .idle
        case .thinking:   return .thinking
        case .working:    return .working
        case .permission: return .permission
        case .error:      return .error
        case .compacting: return .compacting
        }
    }
}
```

Display state is NEVER stored. Always computed. Eliminates desync by construction.

---

## State Transitions

### Process state (app-controlled)

```
inactive ──[activateAgent]──► launching
launching ──[first hook received]──► alive
alive ──[surface destroyed]──► dead
launching ──[surface destroyed before hook]──► dead
dead ──[activateAgent again]──► launching
```

**Detection mechanisms:**

| Transition | How detected |
|---|---|
| inactive → launching | App calls `activateAgent()`. Sets processState BEFORE creating surface. |
| launching → alive | `applyEvents` sees first hook for this agent's UUID. |
| alive/launching → dead | Ghostty `close_surface_cb` fires, or poll detects `processExited == true`. |
| dead → launching | App calls `activateAgent()` again. Resets `claudeState = .unknown`. |

**On activation, always reset:** `processState = .launching`, `claudeState = .unknown`. This prevents stale claudeState from previous session leaking through during launch.

### Claude state (hook-controlled)

```
unknown ──[SessionStart]──► idle
idle ──[UserPromptSubmit]──► thinking
thinking ──[PreToolUse]──► working
thinking ──[Stop]──► idle
working ──[PostToolUse, then more PreToolUse]──► working (stays)
working ──[Stop]──► idle
working ──[PostToolUseFailure]──► error
any ──[PermissionRequest]──► permission
permission ──[PostToolUse]──► working (granted, tool ran)
permission ──[PermissionDenied]──► working (denied, claude continues)
any ──[StopFailure]──► error
error ──[UserPromptSubmit]──► thinking (user retries)
any ──[PreCompact]──► compacting
compacting ──[PostCompact]──► idle
any ──[SessionEnd]──► idle (session ended gracefully)
```

### Unread tracking

```
isUnread = false (default)
Set true:  processState == .alive AND claudeState transitions FROM thinking/working TO idle
           AND agent is NOT currently being viewed (not the active surface in the detail VC)
Set false: user activates this agent (clicks in sidebar)
Set false: claudeState transitions TO thinking/working (agent back to work)
Persisted: YES — survives app restart (stored in state.json)
```

---

## File Layout

All status files keyed by UUID. Atomic writes throughout.

```
~/.config/ghostty-agents/
├── agents.json                          # project/task/agent config (UUIDs + names)
├── state.json                           # persisted bridge state (unread set, pending renames)
├── hooks/
│   └── clawddy-hook.sh                  # single universal hook script
└── status/
    ├── <uuid>.session                   # Claude session ID
    ├── <uuid>.forkFrom                  # source session ID for fork (one-time)
    └── <uuid>.lastEvent                 # last hook event (full JSON)
```

### Universal hook script

One script, all events. Atomic writes via tmp+mv.

```bash
#!/bin/sh
[ -z "$GHOSTTY_AGENT_NAME" ] && cat > /dev/null && exit 0
DIR="$HOME/.config/ghostty-agents/status"
INPUT=$(cat)
SID=$(echo "$INPUT" | /usr/bin/jq -r '.session_id // empty')

# Atomic write: session ID
if [ -n "$SID" ]; then
    echo "$SID" > "$DIR/$GHOSTTY_AGENT_NAME.session.tmp"
    mv "$DIR/$GHOSTTY_AGENT_NAME.session.tmp" "$DIR/$GHOSTTY_AGENT_NAME.session"
fi

# Atomic write: full event JSON
echo "$INPUT" > "$DIR/$GHOSTTY_AGENT_NAME.lastEvent.tmp"
mv "$DIR/$GHOSTTY_AGENT_NAME.lastEvent.tmp" "$DIR/$GHOSTTY_AGENT_NAME.lastEvent"
```

**Why atomic (tmp+mv):** POSIX rename is atomic. Reader either sees old file or new file, never partial content. Eliminates the flickering-state bug from partial reads.

**Why one script:** All logic lives in Swift. Hook just records what happened. App interprets.

### Claude state parsing (Swift)

```swift
func parseClaudeState(from json: [String: Any]) -> ClaudeState {
    guard let event = json["hook_event_name"] as? String else { return .unknown }
    switch event {
    case "SessionStart":          return .idle
    case "UserPromptSubmit":      return .thinking
    case "PreToolUse":            return .working
    case "PostToolUse":           return .working
    case "PostToolUseFailure":    return .error
    case "PermissionRequest":     return .permission
    case "Stop":                  return .idle
    case "StopFailure":           return .error
    case "PreCompact":            return .compacting
    case "PostCompact":           return .idle
    case "SessionEnd":            return .idle
    default:                      return .unknown
    }
}
```

### Hook registration

13 events, one script:

```json
{
  "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
  "PostToolUseFailure", "PermissionRequest", "Stop", "StopFailure",
  "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "SessionEnd"
}
```

### Known limitation: `.lastEvent` is a register, not a queue

Rapid events overwrite each other. If PostToolUseFailure fires and PreToolUse immediately overwrites it, we miss the error.

**Why this is acceptable:**
- PermissionRequest blocks Claude — can't be overwritten
- Error → next event usually has a human-noticeable gap (Claude generates a response)
- SubagentStart/SubagentStop don't change our state (mapped to .unknown)

**Future upgrade path:** Change hook to append to an event log. App tracks read offset. Proper queue semantics. Not needed for v2.

---

## Thread Safety

**Rule: all mutable agent state on @MainActor. No exceptions.**

```swift
@MainActor
final class AgentBridge: ObservableObject {
    // Structural changes (add/remove agents) publish here
    @Published private(set) var agents: [UUID: AgentInstance] = [:]

    // Per-agent state changes publish on each AgentInstance (per-row observation)

    private let ioQueue = DispatchQueue(label: "clawddy.io", qos: .utility)

    func schedulePoll() {
        let ids = Array(agents.keys)  // snapshot on main
        ioQueue.async { [self] in
            // Pure file reads — no mutable state touched
            var events: [UUID: [String: Any]] = [:]
            for id in ids {
                events[id] = self.readLastEvent(for: id)
            }
            DispatchQueue.main.async {
                self.applyEvents(events)
            }
        }
    }
}
```

`readLastEvent` is a pure function: reads a file, returns data. No mutable state.
`applyEvents` runs on main. Mutates agents. Thread safe by construction.

### Sidebar observation pattern

The bridge's `@Published agents` dict publishes ONLY on structural changes (agent added/removed). Individual state changes publish on each `AgentInstance`.

Each sidebar row receives its `AgentInstance` directly:

```swift
struct AgentRow: View {
    @ObservedObject var agent: AgentInstance
    // ...
}

// In sidebar ForEach
ForEach(task.agents, id: \.id) { entry in
    if let agent = bridge.agents[entry.id] {
        AgentRow(agent: agent, ...)
    }
}
```

When one agent's state changes, only THAT row re-renders. Other rows untouched. No full-sidebar re-render on every state poll.

---

## Process Death Detection

### Primary: surface destruction callback

When creating a surface, register for close notification:

```swift
// Option A: NotificationCenter if Ghostty posts surface close notifications
NotificationCenter.default.addObserver(
    forName: .ghosttyDidCloseSurface,  // need to verify this exists
    object: surfaceView,
    queue: .main
) { [weak self] _ in
    self?.handleSurfaceDeath(id: agentId)
}

// Option B: poll processExited on timer (fallback)
// Checked every poll cycle for all .alive/.launching agents
if surfaceView.processExited {
    handleSurfaceDeath(id: agentId)
}
```

### handleSurfaceDeath

```swift
func handleSurfaceDeath(id: UUID) {
    guard let agent = agents[id] else { return }
    agent.processState = .dead
    agent.claudeState = .unknown
    surfaceViews.removeValue(forKey: id)
    surfaceWrappers.removeValue(forKey: id)
    // Don't delete .session — user may want to resume later
}
```

### What we CAN'T detect

| Scenario | Detectable? | State shown |
|---|---|---|
| User closes workspace window | Surface stays alive (isReleasedWhenClosed=false). No death. | Last known state (correct) |
| App force-quit | Everything dies. Reconstructed on restart as .inactive. | .inactive (correct) |
| Claude exits, `exec zsh` runs | No hooks, processExited=false. | Last known claudeState (typically .idle). User sees shell prompt in terminal. |
| Terminal tab/surface closed | Surface destroyed → handleSurfaceDeath. | .dead (correct) |
| `kill -9 <claude-pid>` | No hooks. Script continues to `exec zsh`. Same as Claude exit. | Last known claudeState |

**Accepted limitation:** Claude → shell transition is undetectable without PTY fd access. The terminal prompt is the user's signal. State stays at last known value.

---

## Agent Script

Zero logic. One command. App builds everything.

```bash
#!/bin/zsh -l
export GHOSTTY_AGENT_NAME='<UUID>'
printf '\033]2;%s\007' '<display-name>'
clear
<COMMAND>
exec zsh -l
```

### Command building (Swift)

```swift
func buildCommand(agent: AgentInstance) -> String {
    // Priority 1: resume existing session
    if let sessionId = readSessionFile(agent.id) {
        return "claude --resume '\(sessionId)' --permission-mode auto"
    }
    // Priority 2: fork from source
    if let sourceId = readForkSource(agent.id) {
        // Don't delete .forkFrom here — delete when first hook confirms fork succeeded
        return "claude --resume '\(sourceId)' --fork-session --name '\(agent.name)' --permission-mode auto"
    }
    // Priority 3: fresh start
    return "claude --name '\(agent.name)' --permission-mode auto"
}
```

**Script never reads, writes, or deletes any state file.**

### .forkFrom lifecycle

1. App writes `<new-uuid>.forkFrom` on fork request
2. `buildCommand` reads it, builds fork command (does NOT delete)
3. When first hook arrives (processState .launching → .alive), app deletes `.forkFrom`
4. If app crashes before deletion: on restart, `.session` file now exists (SessionStart hook wrote it), so buildCommand uses Priority 1 (resume). `.forkFrom` is ignored. Harmless.
5. If fork fails (no hook arrives, surface destroyed): `.forkFrom` persists. Next activation retries the fork. Correct.

---

## File Watcher

### No throttle

```swift
let source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: fd, eventMask: .write, queue: .main
)
source.setEventHandler { [weak self] in
    self?.schedulePoll()
}
```

Cost per event: 1 file read per agent (~1ms each). During 50-tool burst: 50 reads = 50ms. The `claudeState` comparison prevents re-renders when state unchanged (most reads during a burst return the same `.working` state).

### File watcher limitations

kqueue watches an inode. If an external process atomically replaces a file (write tmp + rename), the old inode is replaced. The watcher stops seeing changes.

**Our hook uses atomic write (tmp + mv).** So the watcher is watching the STATUS DIRECTORY, not individual files. Directory-level kqueue fires on any file creation/rename/delete in the directory. This catches atomic writes correctly.

---

## Persistence and Crash Recovery

### What's persisted

| Data | Location | Survives crash | Written by |
|---|---|---|---|
| Agent config (UUIDs, names) | `agents.json` | Yes | App (atomic) |
| Session IDs | `<uuid>.session` | Yes | Hook (atomic) |
| Fork sources | `<uuid>.forkFrom` | Yes | App (atomic) |
| Last hook event | `<uuid>.lastEvent` | Yes | Hook (atomic) |
| Unread set + pending renames | `state.json` | Yes | App (periodic atomic flush) |
| Process state | Memory only | No — reconstructed as `.inactive` | App |
| Claude state | Reconstructed from `.lastEvent` | Yes | Hook |

### state.json format

```json
{
    "unreadAgents": ["uuid-1", "uuid-2"],
    "pendingRenames": {
        "uuid-3": "new-display-name"
    }
}
```

Flushed every 5 seconds and on app termination. Atomic write.

### On app startup (reconstruction)

```swift
func reconstructState() {
    let persisted = loadStateJson()  // unread set + pending renames

    for project in config.projects {
        for task in project.tasks {
            for entry in task.agents {
                let agent = AgentInstance(id: entry.id, name: entry.name)
                agent.processState = .inactive  // no surface exists yet
                agent.claudeState = .unknown    // will be set when activated
                agent.isUnread = persisted.unreadAgents.contains(entry.id)
                agents[entry.id] = agent
            }
        }
    }

    self.pendingRenames = persisted.pendingRenames
}
```

**On activation (not startup):** when user clicks an agent:
1. `processState = .launching`
2. `claudeState = .unknown` (reset — prevents stale state from previous session leaking)
3. Surface created, script runs
4. First hook arrives → `processState = .alive`, `claudeState` updated from event
5. If pending rename exists → flush when safe state reached

### Atomic writes (Swift)

```swift
func atomicWrite(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
    try data.write(to: tmp)
    _ = try FileManager.default.replaceItem(at: url, withItemAt: tmp, backupItemName: nil, resultingItemURL: nil)
}
```

---

## Activation Flow (step by step)

```
1.  User clicks agent in sidebar
2.  activateAgent(id: UUID) called on main thread
3.  agent.processState = .launching
4.  agent.claudeState = .unknown        ← prevents stale state leak
5.  command = buildCommand(agent)       ← reads .session / .forkFrom on main
6.  script = writeScript(uuid, name, command)
7.  config = SurfaceConfiguration(command: script, ...)
8.  surface = Ghostty.SurfaceView(app, baseConfig: config)
9.  Register surface close observer (for process death detection)
10. Add surface to detail VC
11. markRead(agent.id)                  ← clear unread if viewing this agent
12. [process starts on background thread]
13. [claude starts → SessionStart hook fires → writes .lastEvent + .session]
14. [file watcher fires → schedulePoll → ioQueue reads → main applyEvents]
15. applyEvents: claudeState = .idle, processState = .alive
16. If .forkFrom exists → delete it (fork confirmed)
17. If pendingRename exists for this agent → flush /rename
18. SwiftUI: AgentInstance publishes → only this agent's row re-renders
```

Steps 2-11 are synchronous on main thread. Steps 12-18 are asynchronous.

---

## Rename Flow

```
1.  User double-taps agent name
2.  User types new name, presses Enter
3.  agent.name = newName                        ← @Published, row re-renders
4.  config.save()                               ← atomic write
5.  Check claudeState:
    a. Safe (idle/thinking/working) → send "/rename newName\n" to pty
    b. Unsafe (permission/error/unknown) → pendingRenames[uuid] = newName
6.  persistState()                              ← flush pendingRenames to state.json
7.  On next transition to safe state → flush pending rename automatically
8.  ZERO rekey. ZERO file renames. UUID unchanged.
```

---

## Fork Flow

```
1.  User right-clicks agent → "Fork"
2.  sourceSessionId = readSessionFile(source.id)
    - If nil → show error to user, abort
3.  newId = UUID()
4.  Write <newId>.forkFrom = sourceSessionId        ← atomic
5.  Add AgentEntry(id: newId, name: "\(source.name)-fork") to config
6.  config.save()                                   ← atomic
7.  [User clicks new agent → activateAgent]
8.  buildCommand: sees .forkFrom → "claude --resume <sourceId> --fork-session --name <name>"
9.  Surface starts → claude forks → SessionStart hook writes NEW session ID to <newId>.session
10. applyEvents: processState .launching → .alive, delete .forkFrom (fork confirmed)
11. Agent is independent. No collision possible (UUID identity).
```

---

## Notification Design

| Event | Level | Sound | Badge | When |
|---|---|---|---|---|
| Finished (unread) | `.passive` | none | +1 | claudeState: thinking/working → idle, agent not being viewed |
| Permission needed | `.timeSensitive` | `.defaultCritical` | +1 | claudeState → permission |
| Error | `.active` | `.default` | +1 | claudeState → error |
| Compacting | none | none | none | Sidebar-only indicator |

Badge count = agents where `displayState ∈ {.finished, .permission, .error}`.
Badge clears per-agent when user views the agent.

Notification grouping: `threadIdentifier = uuid.uuidString` (per-agent stacking).
Notification tap: opens workspace window.
Notification ID prefix: `clawddy.` (for routing in UNUserNotificationCenterDelegate).

---

## Display Properties

| DisplayState | Color | Icon | Label | Selection tint | Animation |
|---|---|---|---|---|---|
| `.inactive` | `.secondary.opacity(0.3)` | `circle` | "" | `.accentColor` | none |
| `.launching` | `.secondary` | `circle.dotted` | "launching" | `.accentColor` | `.pulse` |
| `.idle` | `.secondary` | `moon.fill` | "idle" | `.accentColor` | none |
| `.finished` | `.yellow` | `bell.badge.fill` | "finished" | `.yellow` | `.variableColor` |
| `.thinking` | `.blue` | `brain` | "thinking" | `.blue` | `.pulse` |
| `.working` | `.green` | `bolt.fill` | "working" | `.green` | `.variableColor` |
| `.permission` | `.orange` | `exclamationmark.circle.fill` | "permission" | `.orange` | `.variableColor` |
| `.error` | `.red` | `xmark.circle.fill` | "error" | `.red` | `.bounce` (once) |
| `.compacting` | `.purple` | `arrow.triangle.2.circlepath` | "compacting" | `.purple` | `.pulse` |
| `.dead` | `.secondary.opacity(0.3)` | `xmark` | "exited" | `.accentColor` | none |

Liquid Glass: selected row uses `.glassEffect(.regular.tint(selectionTint.opacity(0.28)))` on macOS 26+.
Symbol effects: `.symbolEffect` gated to macOS 14+.

---

## Cleanup

### On agent delete
```
1. Destroy surface (remove from detail VC, remove close observer)
2. Remove AgentInstance from bridge.agents dict
3. Delete: <uuid>.session, <uuid>.forkFrom, <uuid>.lastEvent (on ioQueue)
4. Remove from config, save (atomic)
5. Remove from unreadAgents, remove from pendingRenames
6. Persist state.json
```

### On app termination
```
1. Invalidate poll timer
2. Cancel file watcher DispatchSource (closes fd via cancelHandler)
3. Unregister Carbon hotkey via UnregisterEventHotKey(ref)
4. Remove Carbon event handler via RemoveEventHandler(ref)
5. Persist state.json (final flush — unread + pendingRenames)
```

### On app startup
```
1. Clean stale script files from /tmp/clawddy-*.sh
2. Load config (migrate if old format detected)
3. Load state.json (unread set, pending renames)
4. Reconstruct agents from config (all processState = .inactive)
5. Start poll timer (3s safety net)
6. Start file watcher on status directory (no throttle)
7. Register Carbon hotkey + event handler (store refs for cleanup)
8. Install/update hooks if needed
```

---

## Migration from v1

### Config format

Old: `"agents": ["alpha", "beta"]`
New: `"agents": [{"id": "...", "name": "alpha"}, ...]`

Detection: try to decode as `[AgentEntry]`. If that fails, decode as `[String]`, generate UUIDs, save new format.

**Sessions from v1 are not migrated.** Old status files (keyed by sanitized name strings) are orphaned. Agents start fresh after migration. This is a clean break — documented in release notes.

### Hook migration

Old: 6 separate scripts (on-session-start.sh, on-tool.sh, etc.)
New: 1 universal script (clawddy-hook.sh)

On startup:
1. Remove all old Clawddy hooks from `~/.claude/settings.json` (entries containing `ghostty-agents/hooks/`)
2. Write new `clawddy-hook.sh`
3. Install new hooks for all 13 events
4. Delete old script files from hooks directory

---

## Accepted Limitations

### 1. Claude → shell transition undetectable
When Claude exits and `exec zsh -l` takes over, no hooks fire and `processExited` never triggers (process replaced, not exited). State stays at last known ClaudeState. The user sees the shell prompt in the terminal directly.

**Impact:** Low. The terminal itself communicates state. The sidebar label is a secondary indicator.

### 2. `.lastEvent` is a register, not a queue
Rapid events overwrite each other. A transient error state (PostToolUseFailure) could be overwritten by the next event before we read it.

**Impact:** Low. PermissionRequest (the most critical) blocks Claude and can't be overwritten. Errors are typically followed by Claude's response text, creating a readable gap.

**Future upgrade:** Append-only event log with read offset tracking.

### 3. SessionEnd doesn't fire on /exit
Claude Code bug (github.com/anthropics/claude-code/issues/17885). `/exit` terminates the session without firing SessionEnd. Only Ctrl+D fires it.

**Impact:** Low. Same as limitation #1 — Claude exits, shell takes over, undetectable.

### 4. No hooks on SIGTERM/SIGKILL/SIGHUP
Process termination via signals bypasses hooks entirely. State stays at last known value until surface destruction is detected.

**Impact:** Medium for SIGKILL (state stuck until surface destroyed). Low for SIGTERM/SIGHUP (surface destruction usually follows quickly).
