# Clawddy Agent State Architecture

## Overview

Clawddy manages multiple Claude Code sessions running inside Ghostty terminal surfaces. This document specifies the complete state management architecture — identity, lifecycle, IPC, persistence, crash recovery, and UI integration.

## Design Principles

1. **Single source of truth per concern.** Process lifecycle owned by app. Claude state owned by hooks. Display state derived, never stored.
2. **UUID identity.** Agent identity is a UUID generated once at creation. Never changes. Display name is a label. Rename = label change. Zero rekey.
3. **Script is a dumb launcher.** All decisions made in Swift. Script sets env, runs one command, falls back to shell.
4. **Thread-safe by construction.** All mutable state on main actor. Background work reads snapshots, writes results back to main.
5. **Crash-recoverable.** Every piece of state that matters across restarts is persisted. In-memory state is reconstructible from disk.
6. **No stuck states.** Process death is always detected. Every state has an exit path.

---

## Agent Identity

### AgentEntry (persisted in agents.json)

```swift
struct AgentEntry: Codable, Identifiable {
    let id: UUID          // generated once at creation, NEVER changes
    var name: String      // display label, freely renameable
}
```

Config format changes from `"agents": ["alpha", "beta"]` to:

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

**UUID is used for:**
- `GHOSTTY_AGENT_NAME` environment variable (hooks identify the agent)
- Status file names: `<uuid>.state`, `<uuid>.session`, `<uuid>.forkFrom`
- Dict keys in bridge, detail VC, sidebar
- Script file names: `/tmp/clawddy-<uuid>.sh`

**Display name is used for:**
- Sidebar label
- Terminal title (OSC 2)
- `claude --name` flag
- `/rename` command

**Rename is:** change `name` field in config + send `/rename` to Claude. Zero dict updates. Zero file renames.

**Fork is:** generate new UUID. No collision possible.

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

    var displayState: DisplayState { /* derived */ }
}

enum ProcessState {
    case inactive       // no terminal surface exists
    case launching      // surface created, waiting for first hook
    case alive          // claude process confirmed running (hook received)
    case shellFallback  // claude exited, zsh took over (detected via absence of hooks + process alive)
    case dead           // terminal surface destroyed or process killed
}

enum ClaudeState {
    case unknown        // no hook data yet
    case idle           // Stop hook fired (stop_reason: end_turn)
    case thinking       // UserPromptSubmit fired
    case working        // PreToolUse or PostToolUse fired
    case permission     // PermissionRequest fired
    case error          // StopFailure or PostToolUseFailure fired
    case compacting     // PreCompact fired, waiting for PostCompact
}

enum DisplayState {
    case inactive
    case launching
    case idle
    case finished       // processState == .alive && claudeState == .idle && isUnread
    case thinking
    case working
    case permission
    case error
    case compacting
    case shell          // process alive but claude not running
    case dead
}
```

### Derivation logic

```swift
var displayState: DisplayState {
    switch processState {
    case .inactive:      return .inactive
    case .dead:          return .dead
    case .launching:     return .launching
    case .shellFallback: return .shell
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
inactive ──[user activates]──► launching
launching ──[first hook received]──► alive
alive ──[claude exits, shell takes over]──► shellFallback
alive ──[surface destroyed / process killed]──► dead
shellFallback ──[surface destroyed]──► dead
dead ──[user re-activates]──► launching
launching ──[surface destroyed before hook]──► dead
```

**How transitions are detected:**

| Transition | Detection mechanism |
|---|---|
| inactive → launching | App calls `activateAgent()` |
| launching → alive | First hook event received for this UUID |
| alive → shellFallback | Heartbeat timeout (no hook in N seconds while process still alive) |
| alive → dead | Ghostty `close_surface_cb` or `processExited` observation |
| shellFallback → dead | Same as above |
| dead → launching | App calls `activateAgent()` again |

### Claude state (hook-controlled)

```
unknown ──[SessionStart]──► idle
idle ──[UserPromptSubmit]──► thinking
thinking ──[PreToolUse]──► working
thinking ──[Stop]──► idle
working ──[PostToolUse then PreToolUse]──► working (stays)
working ──[Stop]──► idle
working ──[PostToolUseFailure]──► error
any ──[PermissionRequest]──► permission
permission ──[PostToolUse]──► working (permission granted, tool ran)
permission ──[PermissionDenied]──► working (denied, claude continues)
any ──[StopFailure]──► error
error ──[UserPromptSubmit]──► thinking (user retries)
any ──[PreCompact]──► compacting
compacting ──[PostCompact]──► idle (or back to previous)
```

### Unread tracking

```
isUnread = false (default)
Set true: when processState == .alive AND claudeState transitions FROM .thinking/.working TO .idle
Set false: when user activates this agent (clicks in sidebar)
Set false: when claudeState transitions TO .thinking/.working (agent active again)
Persisted: yes (survives app restart)
```

---

## File Layout

All files keyed by UUID.

```
~/.config/ghostty-agents/
├── agents.json                          # project/task/agent config (with UUIDs)
├── hooks/                               # hook scripts (shared, not per-agent)
│   └── clawddy-hook.sh                  # SINGLE universal hook script
├── status/
│   ├── <uuid>.session                   # Claude session ID (written by hook)
│   ├── <uuid>.forkFrom                  # Source session ID for fork (written by app)
│   └── <uuid>.lastEvent                 # Last hook event JSON (written by hook)
└── state.json                           # Persisted bridge state (unread set, etc.)
```

### Key change: single universal hook script

Instead of 6 separate scripts, ONE script handles all events:

```bash
#!/bin/sh
[ -z "$GHOSTTY_AGENT_NAME" ] && cat > /dev/null && exit 0
DIR="$HOME/.config/ghostty-agents/status"
INPUT=$(cat)
EVENT=$(echo "$INPUT" | /usr/bin/jq -r '.hook_event_name // empty')
SID=$(echo "$INPUT" | /usr/bin/jq -r '.session_id // empty')

# Always capture session ID
[ -n "$SID" ] && echo "$SID" > "$DIR/$GHOSTTY_AGENT_NAME.session"

# Write full event JSON for the app to parse
echo "$INPUT" > "$DIR/$GHOSTTY_AGENT_NAME.lastEvent"
```

**Why:** The app reads the full event JSON and decides what state means. No state keywords in files. No mapping logic in bash. The hook just records what happened. The app interprets.

The `.lastEvent` file contains the raw JSON from the most recent hook. The app reads `hook_event_name` and derives ClaudeState:

```swift
func parseClaudeState(from event: [String: Any]) -> ClaudeState {
    guard let name = event["hook_event_name"] as? String else { return .unknown }
    switch name {
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
    default:                      return .unknown // SubagentStart, etc. — don't change state
    }
}
```

### Hook registration (all events, one script)

```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}],
    "PostToolUseFailure": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}],
    "PermissionRequest": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}],
    "StopFailure": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}],
    "PreCompact": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}],
    "PostCompact": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}],
    "SubagentStart": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}],
    "SubagentStop": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "~/.config/ghostty-agents/hooks/clawddy-hook.sh", "timeout": 5}]}]
  }
}
```

---

## Thread Safety

**Rule: all mutable agent state lives on `@MainActor`.**

```swift
@MainActor
final class AgentBridge: ObservableObject {
    @Published private(set) var agents: [UUID: AgentInstance] = [:]

    // File I/O on background queue
    private let ioQueue = DispatchQueue(label: "clawddy.io", qos: .utility)

    func schedulePoll() {
        let ids = Array(agents.keys)  // snapshot on main
        ioQueue.async {
            var events: [UUID: [String: Any]] = [:]
            for id in ids {
                events[id] = self.readLastEvent(for: id)  // pure file read, no mutable state
            }
            DispatchQueue.main.async {
                self.applyEvents(events)  // mutate on main only
            }
        }
    }
}
```

**No mutable state on the I/O queue.** Background reads pure files, returns pure data. Main thread applies mutations. Thread safety by construction, not by locks.

---

## Process Death Detection

### Mechanism: observe Ghostty's surface lifecycle

When creating a surface for an agent, register for the surface's close notification:

```swift
func activateAgent(id: UUID, ...) {
    let surfaceView = Ghostty.SurfaceView(app, baseConfig: config)

    // Observe process exit
    NotificationCenter.default.addObserver(
        forName: Ghostty.Notification.didCloseSurface,
        object: surfaceView,
        queue: .main
    ) { [weak self] _ in
        self?.handleSurfaceDeath(id: id)
    }
}

func handleSurfaceDeath(id: UUID) {
    guard let agent = agents[id] else { return }
    agent.processState = .dead
    agent.claudeState = .unknown
    surfaceViews.removeValue(forKey: id)
    surfaceWrappers.removeValue(forKey: id)
}
```

If Ghostty doesn't provide a close notification for embedded surfaces, fall back to polling `surfaceView.processExited` on the timer.

### Shell fallback detection

When `processState == .alive` and no hook fires for 30 seconds while the PTY is still open:
- Claude probably exited and `exec zsh -l` took over
- Transition to `.shellFallback`
- Track via `lastHookTime` per agent

```swift
// In poll cycle
if agent.processState == .alive,
   let lastHook = agent.lastHookTime,
   Date().timeIntervalSince(lastHook) > 30,
   surfaceViews[id] != nil {
    agent.processState = .shellFallback
}
```

---

## Agent Script

Minimal. One command. No logic.

```bash
#!/bin/zsh -l
export GHOSTTY_AGENT_NAME='<UUID>'
printf '\033]2;%s\007' '<display-name>'
clear
<COMMAND>
exec zsh -l
```

`<COMMAND>` is built by Swift at activation time:

```swift
func buildCommand(agent: AgentInstance) -> String {
    // Priority 1: resume existing session
    if let sessionId = readSessionFile(agent.id) {
        return "claude --resume '\(sessionId)' --permission-mode auto"
    }
    // Priority 2: fork from source
    if let sourceId = readForkSource(agent.id) {
        deleteForkSource(agent.id)
        return "claude --resume '\(sourceId)' --fork-session --name '\(agent.name)' --permission-mode auto"
    }
    // Priority 3: fresh start
    return "claude --name '\(agent.name)' --permission-mode auto"
}
```

**Script never reads, writes, or deletes any state file.** App does all file management in Swift.

---

## File Watcher

### Remove throttle entirely

The `DispatchSource` fires synchronously on kqueue event. Cost per event: 1 file read (~1ms). Even 50 rapid PostToolUse events = 50ms. The `agents[id].claudeState` comparison prevents unnecessary SwiftUI re-renders.

```swift
source.setEventHandler { [weak self] in
    self?.schedulePoll()  // no throttle
}
```

### Watch `.lastEvent` files, not `.state` files

The watcher monitors the status directory. When any file changes, it polls all agents. Since we read `.lastEvent` (full JSON), we get richer data per poll.

---

## Persistence and Crash Recovery

### What's persisted

| Data | Location | Survives crash | Written by |
|---|---|---|---|
| Agent config (UUIDs, names) | `agents.json` | Yes | App (atomic write) |
| Session IDs | `<uuid>.session` | Yes | Hook script |
| Fork sources | `<uuid>.forkFrom` | Yes | App |
| Last hook event | `<uuid>.lastEvent` | Yes | Hook script |
| Unread set | `state.json` | Yes | App (periodic flush) |
| Process state | Memory only | No (reconstructed) | App |
| Claude state | Reconstructed from `.lastEvent` | Yes | Hook script |

### On app startup (reconstruction)

```swift
func reconstructState() {
    for project in config.projects {
        for task in project.tasks {
            for entry in task.agents {
                let agent = AgentInstance(id: entry.id, name: entry.name)
                agent.processState = .inactive
                // Restore claude state from last event file
                if let event = readLastEvent(for: entry.id) {
                    agent.claudeState = parseClaudeState(from: event)
                    agent.sessionId = event["session_id"] as? String
                }
                // Restore unread from persisted state
                agent.isUnread = persistedUnreadSet.contains(entry.id)
                agents[entry.id] = agent
            }
        }
    }
}
```

### Atomic writes

All file writes use atomic rename pattern:

```swift
func atomicWrite(_ data: Data, to url: URL) throws {
    let tmp = url.appendingPathExtension("tmp")
    try data.write(to: tmp)
    try FileManager.default.replaceItem(at: url, withItemAt: tmp, backupItemName: nil, resultingItemURL: nil)
}
```

---

## Rename Flow

```
1. User double-taps agent name in sidebar
2. User types new name, presses Enter
3. App updates config: agents[uuid].name = newName
4. App saves config (atomic write)
5. App checks claude state:
   a. Safe (idle/finished/thinking/working) → send /rename immediately
   b. Unsafe (permission/error) → store in pendingRenames[uuid]
6. On next state transition to safe → flush pending rename
7. No rekey. No file renames. No dict updates. UUID unchanged.
```

---

## Fork Flow

```
1. User right-clicks agent → "Fork"
2. App generates new UUID
3. App reads source agent's session ID from <source-uuid>.session
   - If no session → show error, abort
4. App writes <new-uuid>.forkFrom with source session ID
5. App adds new AgentEntry to config (new UUID, name = "{source}-fork")
6. App saves config (atomic write)
7. User clicks new agent → activateAgent
8. buildCommand sees .forkFrom → generates: claude --resume <sourceId> --fork-session --name <name>
9. App deletes .forkFrom (consumed)
10. Surface starts → claude forks → SessionStart hook fires with NEW session ID
11. Hook writes new session ID to <new-uuid>.session
12. Agent is now independent
```

---

## Notification Design

| Event | Level | Sound | Badge | When |
|---|---|---|---|---|
| Agent finished (unread) | `.passive` | none | +1 | `claudeState: .thinking/.working → .idle` AND agent not currently viewed |
| Permission needed | `.timeSensitive` | `.defaultCritical` | +1 | `claudeState → .permission` |
| Error | `.active` | `.default` | +1 | `claudeState → .error` |
| Context compacting | none | none | none | Informational only, shown in sidebar |

Badge count = number of agents where `displayState ∈ {.finished, .permission, .error}`.
Badge clears per-agent when user views the agent (clicks in sidebar).

---

## Display Properties

| DisplayState | Color | Icon | Label | Selection tint | Animated |
|---|---|---|---|---|---|
| `.inactive` | `.secondary.opacity(0.3)` | none | "" | `.accentColor` | no |
| `.launching` | `.secondary` | `circle.dotted` | "launching" | `.accentColor` | `.pulse` |
| `.idle` | `.secondary` | `moon.fill` | "idle" | `.accentColor` | no |
| `.finished` | `.yellow` | `bell.badge.fill` | "finished" | `.yellow` | `.variableColor` |
| `.thinking` | `.blue` | `brain` | "thinking" | `.blue` | `.pulse` |
| `.working` | `.green` | `bolt.fill` | "working" | `.green` | `.variableColor` |
| `.permission` | `.orange` | `exclamationmark.circle.fill` | "permission" | `.orange` | `.variableColor` |
| `.error` | `.red` | `xmark.circle.fill` | "error" | `.red` | `.bounce` (once) |
| `.compacting` | `.purple` | `arrow.triangle.2.circlepath` | "compacting" | `.purple` | `.pulse` |
| `.shell` | `.secondary.opacity(0.5)` | `terminal` | "shell" | `.accentColor` | no |
| `.dead` | `.secondary.opacity(0.3)` | `xmark` | "exited" | `.accentColor` | no |

---

## Cleanup

### On agent delete
```
1. Remove surface from detail VC
2. Remove agent from bridge.agents dict
3. Delete: <uuid>.session, <uuid>.forkFrom, <uuid>.lastEvent
4. Remove from config
5. Save config (atomic)
6. Remove from persisted unread set
```

### On app termination
```
1. Invalidate poll timer
2. Cancel file watcher DispatchSource
3. Unregister Carbon hotkey
4. Persist unread set to state.json
5. Surfaces are owned by Ghostty — they clean up with the window
```

### On app startup
```
1. Clean stale script files from /tmp
2. Reconstruct agent state from disk (see Persistence section)
3. Start poll timer
4. Start file watcher
5. Register hotkey
6. Install/update hooks if needed
```

---

## Migration from current architecture

### Config migration

On first load with new format, detect old format (`"agents": ["name", ...]`) and migrate:

```swift
func migrateIfNeeded() {
    // If agents array contains strings instead of objects, migrate
    for i in projects.indices {
        for j in projects[i].tasks.indices {
            // Old format: agents is [String]
            // New format: agents is [AgentEntry]
            // Detect and convert, generating UUIDs
        }
    }
}
```

### Status file migration

Old files keyed by sanitized name string. New files keyed by UUID. On migration:
1. For each agent with old-style files, rename files to UUID-keyed names
2. Delete old files

### Hook migration

Old: 6 separate scripts. New: 1 universal script. On migration:
1. Write new universal script
2. Remove old Clawddy hooks from Claude settings
3. Install new hooks for all 13 events
4. Delete old script files

---

## Open Questions

1. **Ghostty surface close callback**: Need to verify if `Ghostty.Notification.didCloseSurface` is available for embedded surfaces, or if we need to observe via `close_surface_cb` in the runtime config. If neither works, fall back to polling `processExited`.

2. **Shell fallback detection**: The 30-second timeout for detecting "claude exited, shell took over" is heuristic. If Claude is genuinely idle for 30 seconds (user not typing), we'd incorrectly transition to `.shellFallback`. Consider: only transition if the PTY's foreground process group changed (from claude to zsh). This requires checking the process group via `tcgetpgrp()`.

3. **Concurrent Claude sessions**: If two agents share the same working directory, their sessions could interfere in Claude's session storage. Each agent should get `--name` to distinguish them, but `--continue` (without `--resume`) would pick up the wrong session. Solution: always use `--resume <id>`, never `--continue`.
