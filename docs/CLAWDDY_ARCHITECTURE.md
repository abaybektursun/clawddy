# Clawddy Agent State Architecture v3

## Overview

Clawddy manages multiple Claude Code sessions running inside Ghostty terminal surfaces. This document specifies the complete state management architecture — identity, lifecycle, IPC, persistence, crash recovery, and UI integration.

Audited through 3 rounds of mental simulation (22 scenarios). All known edge cases addressed or documented as accepted limitations.

## Design Principles

1. **Single source of truth per concern.** Process lifecycle owned by app. Claude state owned by hooks. Display state derived, never stored.
2. **UUID identity.** Agent identity is a UUID generated once at creation. Never changes. Display name is a label. Rename = label change. Zero rekey.
3. **Script is a dumb launcher.** All decisions made in Swift. Script sets env, runs one command, falls back to shell.
4. **Thread-safe by construction.** All mutable state on @MainActor. Background work reads snapshots of immutable data, posts results back to main.
5. **Crash-recoverable.** Every piece of state that matters across restarts is persisted to disk. In-memory state is reconstructible.
6. **No stuck states.** Process death detected via surface destruction. Launch timeout prevents indefinite `.launching`. Every state has an exit path.
7. **Atomic file operations.** All writes (hook and app) use tmp+rename. No partial reads ever.
8. **Per-row observation.** Each sidebar row observes its own AgentInstance. State changes re-render only the affected row, not the entire sidebar.
9. **Zero external dependencies in hooks.** No jq, no python. Only POSIX sh + sed.
10. **Run-loop coalesced I/O.** File watcher events coalesce within a single run loop turn. Bounded regardless of agent count.
11. **Single instance.** Only one Clawddy-enabled Ghostty should run. Documented constraint.

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
    @Published var launchTime: Date?     // set when processState → .launching

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

When Claude exits and shell takes over, state stays at last known ClaudeState (typically `.idle` from Stop hook). Terminal shows shell prompt — user sees it directly.

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
launching ──[10s timeout, no hook]──► alive (with claudeState = .idle)
alive ──[surface destroyed]──► dead
launching ──[surface destroyed before hook]──► dead
dead ──[activateAgent again]──► launching
```

**Detection mechanisms:**

| Transition | How detected |
|---|---|
| inactive → launching | App calls `activateAgent()`. Sets processState BEFORE creating surface. Sets `launchTime = Date()`. |
| launching → alive | `applyEvents` sees first hook for this agent's UUID. |
| launching → alive (timeout) | Poll cycle checks: `launchTime` > 10s ago AND `lastHookTime == nil`. Claude failed to start; shell is running. Set `claudeState = .idle`. |
| alive/launching → dead | Ghostty surface destruction detected (close callback or `processExited` poll). |
| dead → launching | App calls `activateAgent()` again. Resets `claudeState = .unknown`, `launchTime = Date()`. |

**On activation, always reset:** `processState = .launching`, `claudeState = .unknown`, `launchTime = Date()`. Prevents stale claudeState from previous session leaking.

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

One script, all events. Atomic writes via tmp+mv. **Zero external dependencies** — no jq, only POSIX sh + sed.

```bash
#!/bin/sh
[ -z "$GHOSTTY_AGENT_NAME" ] && cat > /dev/null && exit 0
DIR="$HOME/.config/ghostty-agents/status"
INPUT=$(cat)

# Extract session_id with sed (no jq dependency)
SID=$(echo "$INPUT" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -1)

# Atomic write: session ID (PID-suffixed tmp to avoid concurrent hook race)
if [ -n "$SID" ]; then
    echo "$SID" > "$DIR/$GHOSTTY_AGENT_NAME.session.$$"
    mv "$DIR/$GHOSTTY_AGENT_NAME.session.$$" "$DIR/$GHOSTTY_AGENT_NAME.session"
fi

# Atomic write: full event JSON (PID-suffixed tmp)
echo "$INPUT" > "$DIR/$GHOSTTY_AGENT_NAME.lastEvent.$$"
mv "$DIR/$GHOSTTY_AGENT_NAME.lastEvent.$$" "$DIR/$GHOSTTY_AGENT_NAME.lastEvent"
```

**Why PID-suffixed tmp files:** Two hooks can fire concurrently for the same agent (e.g., PreToolUse immediately followed by PostToolUse). Each runs as a separate process. Without unique tmp names, both write to the same `.tmp` file — race condition. Using `$$` (shell PID) ensures each process has its own tmp. Last `mv` wins (latest event). No data corruption.

**Why sed not jq:** macOS doesn't ship jq. Users who install via Homebrew have it; others don't. sed is guaranteed POSIX. The extraction pattern is simple enough for sed.

**Why atomic (tmp+mv):** POSIX rename is atomic. Reader either sees old file or new file, never partial content. Eliminates flickering from partial reads.

**Why one script:** All logic lives in Swift. Hook records what happened. App interprets.

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

```
SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
PostToolUseFailure, PermissionRequest, Stop, StopFailure,
PreCompact, PostCompact, SubagentStart, SubagentStop, SessionEnd
```

### Known limitation: `.lastEvent` is a register, not a queue

Rapid events overwrite each other. If PostToolUseFailure fires and PreToolUse immediately overwrites it, we miss the error.

**Why acceptable:**
- PermissionRequest blocks Claude — can't be overwritten
- Error → next event usually has a human-noticeable gap (Claude generates response)
- SubagentStart/SubagentStop don't change state (mapped to .unknown)

**Future upgrade:** Append-only event log with read offset tracking.

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

`readLastEvent` is pure: reads a file, returns data. No mutable state.
`applyEvents` runs on main. Mutates agents. Thread safe by construction.

### Sidebar observation pattern

The bridge's `@Published agents` dict publishes ONLY on structural changes (agent added/removed). Individual state changes publish on each `AgentInstance` (@Published properties).

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

When one agent's state changes, only THAT row re-renders. Other rows untouched.

### Sync agent creation (prevents nil lookup flicker)

When adding an agent, BOTH config AND bridge are updated synchronously on main:

```swift
func createAgent(name: String, project: String, task: String) -> AgentEntry {
    let entry = AgentEntry(id: UUID(), name: name)
    config.addAgent(entry, project: project, task: task)  // config @Published fires
    let instance = AgentInstance(id: entry.id, name: entry.name)
    instance.processState = .inactive
    agents[entry.id] = instance  // bridge @Published fires
    return entry
}
```

Both mutations synchronous on main. SwiftUI sees both before first render. No flicker.

---

## File Watchers

### Status directory watcher (for .lastEvent files)

Watches the STATUS DIRECTORY (not individual files). Directory-level kqueue fires on any file creation/rename/delete in the directory — catches atomic writes (tmp+mv) correctly.

**Run-loop coalescing** prevents unbounded I/O with many agents:

```swift
private var pollScheduled = false

let source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: statusDirFd, eventMask: .write, queue: .main
)
source.setEventHandler { [weak self] in
    guard let self, !self.pollScheduled else { return }
    self.pollScheduled = true
    DispatchQueue.main.async {
        self.pollScheduled = false
        self.schedulePoll()
    }
}
```

Multiple file watcher events within one run loop cycle → ONE poll. Zero added latency. At most one poll per run loop turn, regardless of agent count. 50 agents, 100 file writes → one poll reading 50 files.

**Safety net timer:** 3 seconds. Catches anything missed by the watcher (e.g., race during startup).

### Config directory watcher (for agents.json)

Watches the CONFIG DIRECTORY (not the agents.json file directly). This handles:
- Atomic external edits (vim, VS Code) that replace the inode
- Fresh install where agents.json doesn't exist yet (file created later → watcher fires)
- File renames within the directory

```swift
let source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: configDirFd, eventMask: .write, queue: .main
)
source.setEventHandler { [weak self] in
    guard let self, !self.suppressWatch else { return }
    self.load()
}
```

---

## Process Death Detection

### Primary: surface destruction callback

When creating a surface, register for close notification. **Store observer token for cleanup.**

```swift
var surfaceObservers: [UUID: NSObjectProtocol] = [:]

// On surface creation
let token = NotificationCenter.default.addObserver(
    forName: .ghosttyDidCloseSurface,   // verify this exists; fall back to polling if not
    object: surfaceView,
    queue: .main
) { [weak self] _ in
    self?.handleSurfaceDeath(id: agentId)
}
surfaceObservers[agentId] = token

// Fallback: poll processExited in schedulePoll (MUST be on main thread — surface access)
func schedulePoll() {
    guard !isTerminating else { return }
    // Main thread: check process exits
    for (id, surface) in surfaceViews {
        if surface.processExited {
            handleSurfaceDeath(id: id)
        }
    }
    // Background: file I/O
    ...
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
    // Remove observer
    if let token = surfaceObservers.removeValue(forKey: id) {
        NotificationCenter.default.removeObserver(token)
    }
    // Don't delete .session — user may want to resume later
    // If this was the active agent, show placeholder
    if detailVC?.activeKey == id {
        detailVC?.showPlaceholder()
    }
}
```

### Launch timeout

If no hook arrives within 10 seconds of activation, Claude failed to start (e.g., not in PATH, crash). Terminal is alive with shell. Transition to alive + idle:

```swift
// In poll cycle
if agent.processState == .launching,
   agent.lastHookTime == nil,
   let t = agent.launchTime,
   Date().timeIntervalSince(t) > 10 {
    agent.processState = .alive
    agent.claudeState = .idle
}
```

User sees "idle" in sidebar, shell prompt in terminal. Can type `claude` manually. Not stuck.

### What we CAN'T detect

| Scenario | Detectable? | State shown |
|---|---|---|
| User closes workspace window | Surface stays alive (`isReleasedWhenClosed=false`). No death. | Last known state (correct) |
| App force-quit | Everything dies. Reconstructed on restart as `.inactive`. | `.inactive` (correct) |
| Claude exits, `exec zsh` runs | No hooks, processExited=false. | Last known claudeState (typically `.idle`). User sees shell prompt. |
| Terminal surface closed | Surface destroyed → handleSurfaceDeath. | `.dead` (correct) |
| `kill -9 <claude-pid>` | No hooks. Script continues to `exec zsh`. Same as Claude exit. | Last known claudeState |

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
    // Priority 2: fork from source (don't delete .forkFrom here — see lifecycle below)
    if let sourceId = readForkSource(agent.id) {
        return "claude --resume '\(sourceId)' --fork-session --name '\(agent.name)' --permission-mode auto"
    }
    // Priority 3: fresh start
    return "claude --name '\(agent.name)' --permission-mode auto"
}
```

**Script never reads, writes, or deletes any state file.**

### .forkFrom lifecycle

1. App writes `<new-uuid>.forkFrom` on fork request
2. `buildCommand` reads it, builds fork command (**does NOT delete**)
3. When first hook arrives (processState .launching → .alive), app deletes `.forkFrom` — fork confirmed
4. If app crashes before deletion: on restart, `.session` file now exists (SessionStart wrote it), so `buildCommand` uses Priority 1 (resume). `.forkFrom` ignored. Harmless.
5. If fork fails (no hook, surface destroyed): `.forkFrom` persists. Next activation retries. Correct.

---

## Persistence and Crash Recovery

### What's persisted

| Data | Location | Survives crash | Written by |
|---|---|---|---|
| Agent config (UUIDs, names) | `agents.json` | Yes | App (atomic) |
| Session IDs | `<uuid>.session` | Yes | Hook (atomic) |
| Fork sources | `<uuid>.forkFrom` | Yes | App (atomic) |
| Last hook event | `<uuid>.lastEvent` | Yes | Hook (atomic) |
| Unread set + pending renames | `state.json` | Yes | App (periodic flush, atomic) |
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

### Atomic write helper

Handles both first-time writes (file doesn't exist) and subsequent writes:

```swift
func atomicWrite(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(UUID().uuidString + ".tmp")
    try data.write(to: tmp)
    if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItem(
            at: url, withItemAt: tmp, backupItemName: nil, resultingItemURL: nil)
    } else {
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
```

### On app startup (reconstruction)

```swift
func reconstructState() {
    let persisted = loadStateJson()  // unread set + pending renames

    for project in config.projects {
        for task in project.tasks {
            for entry in task.agents {
                let agent = AgentInstance(id: entry.id, name: entry.name)
                agent.processState = .inactive  // no surface exists yet
                agent.claudeState = .unknown    // set on activation, not startup
                agent.isUnread = persisted.unreadAgents.contains(entry.id)
                agents[entry.id] = agent
            }
        }
    }

    self.pendingRenames = persisted.pendingRenames
}
```

**On activation (not startup):** reset `processState = .launching`, `claudeState = .unknown`, `launchTime = Date()`. Prevents stale state leak.

---

## Activation Flow (step by step)

```
 1.  User clicks agent in sidebar                           [main thread]
 2.  activateAgent(id: UUID) called                         [main thread]
 3.  agent.processState = .launching                        [main thread]
 4.  agent.claudeState = .unknown                           [main thread]
 5.  agent.launchTime = Date()                              [main thread]
 6.  command = buildCommand(agent)                           [main thread, reads files]
 7.  script = writeScript(uuid, name, command)              [main thread]
 8.  config = SurfaceConfiguration(command: script, ...)    [main thread]
 9.  surface = Ghostty.SurfaceView(app, baseConfig: config) [main thread]
10.  If surface.error != nil → agent.processState = .dead, return  [main thread]
11.  Register surface close observer                        [main thread]
12.  Add surface to detail VC, store in surfaceViews dict   [main thread]
13.  markRead(agent.id)                                     [main thread]
--- sync boundary ---
14.  [process starts on background thread]
15.  [claude starts → hook fires → writes .lastEvent + .session atomically]
16.  [file watcher fires → pollScheduled flag → run loop coalesces]
17.  [schedulePoll → ioQueue reads files → main applyEvents]
18.  applyEvents: claudeState = .idle, processState = .alive [main thread]
19.  If .forkFrom exists → delete it (fork confirmed)       [main thread]
20.  If pendingRename exists → flush /rename                 [main thread]
21.  AgentInstance @Published fires → only this agent's row re-renders
```

Steps 2-13 are synchronous on main thread. Steps 14-21 are asynchronous.
If step 9 fails (surface error), step 10 catches it immediately. No stuck .launching.

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

**Pending renames survive crash:** persisted in state.json. On restart, loaded and re-queued. Flushed when agent reaches safe state.

---

## Fork Flow

```
1.  User right-clicks agent → "Fork"
2.  sourceSessionId = readSessionFile(source.id)
    - If nil → show error to user, abort
3.  newEntry = createAgent(name: "\(source.name)-fork", ...)  ← sync bridge + config
4.  atomicWrite(<newId>.forkFrom, sourceSessionId)
5.  [User clicks new agent → activateAgent]
6.  buildCommand: sees .forkFrom → "claude --resume <sourceId> --fork-session --name <name>"
7.  Surface starts → claude forks → SessionStart hook writes NEW session ID
8.  applyEvents: processState .launching → .alive
9.  Delete .forkFrom (fork confirmed)
10. Agent is independent. UUID identity = no collision.
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

Notification grouping: `threadIdentifier = uuid.uuidString`.
Notification tap: opens workspace window.
Notification ID prefix: `clawddy.` (for routing in delegate).

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

Liquid Glass: `.glassEffect(.regular.tint(selectionTint.opacity(0.28)))` on macOS 26+.
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
6. Persist state.json (atomic)
```

### On app termination
```
1. Set isTerminating = true (prevents schedulePoll re-entry)
2. Invalidate poll timer
3. Cancel status directory watcher DispatchSource (closes fd)
4. Cancel config directory watcher DispatchSource (closes fd)
5. Remove all surface observers (surfaceObservers.values.forEach removeObserver)
6. Unregister Carbon hotkey via UnregisterEventHotKey(ref)
7. Remove Carbon event handler via RemoveEventHandler(ref)
8. Persist state.json (final flush — unread + pendingRenames)
```

### On app startup
```
1. Clean stale script files from /tmp/clawddy-*.sh
2. Ensure config directory exists (create if needed)
3. Ensure status directory exists
4. Write universal hook script (clawddy-hook.sh)
5. Install/update hooks in ~/.claude/settings.json if needed
6. Load config (migrate if old format)
7. Load state.json (unread set, pending renames)
8. Reconstruct agents from config (all processState = .inactive)
9. Start config directory watcher
10. Start status directory watcher
11. Start poll timer (3s safety net)
12. Register Carbon hotkey + event handler (store refs for cleanup)
```

---

## Migration from v1

### Config format

Old: `"agents": ["alpha", "beta"]`
New: `"agents": [{"id": "...", "name": "alpha"}, ...]`

Detection: attempt decode as `[AgentEntry]`. If fails, decode as `[String]`, generate UUIDs, **save immediately** (persist UUIDs before anything else reads them — otherwise re-decode generates different UUIDs).

**Sessions from v1 are NOT migrated.** Old status files (keyed by sanitized name strings) are orphaned. Agents start fresh. Clean break — documented in release notes.

### Hook migration

Old: 6 separate scripts. New: 1 universal script.

On startup:
1. Remove all old Clawddy hooks from `~/.claude/settings.json` (entries containing `ghostty-agents/hooks/`)
2. Write `clawddy-hook.sh`
3. Install hooks for all 13 events
4. Delete old script files from hooks directory

---

## Constraints

### Single instance

Only one Clawddy-enabled Ghostty should run. Multiple instances share config + status files and will cause undefined behavior (conflicting file watchers, phantom states, config corruption).

Not enforced programmatically. Documented as a constraint.

### One terminal per agent

Each agent has at most one terminal surface. Re-activating an existing agent shows its existing surface, doesn't create a new one.

---

## Accepted Limitations

### 1. Claude → shell transition undetectable
When Claude exits and `exec zsh -l` takes over, no hooks fire and `processExited` never triggers. State stays at last known ClaudeState.

**Impact:** Low. Terminal communicates state directly. Sidebar is secondary indicator.

### 2. `.lastEvent` is a register, not a queue
Rapid events overwrite each other. Transient error states can be missed.

**Impact:** Low. Blocking events (PermissionRequest) can't be overwritten. Errors have readable gaps.

**Upgrade path:** Append-only event log.

### 3. SessionEnd doesn't fire on /exit
Claude Code bug (github.com/anthropics/claude-code/issues/17885).

**Impact:** Low. Same as limitation #1.

### 4. No hooks on SIGTERM/SIGKILL/SIGHUP
Process termination via signals bypasses hooks.

**Impact:** Medium for SIGKILL (state stuck until surface destroyed). Low for others (surface destruction follows).

### 5. Launch timeout is heuristic
10-second timeout assumes Claude should start within 10 seconds. On slow machines or with large context restoration, this could be too short.

**Impact:** Low. False timeout transitions to alive+idle, which is not harmful — user sees the terminal. Can increase timeout if needed.
