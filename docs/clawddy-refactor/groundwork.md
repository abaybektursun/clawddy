# Clawddy refactor groundwork

Everything here was read from code or observed read-only on disk. Items marked *(inferred)* were not observed directly.

## 0. Facts that change the plan

1. **The live app already shares an identity with stock Ghostty.** Two apps are running now with bundle ID `com.mitchellh.ghostty`: `/Applications/Ghostty.app` (stock 1.3.1) and `~/Applications/Clawddy.app` (live, signed with team 94DS9XB3FJ). They share one defaults domain: the `clawddy.*` keys live in `com.mitchellh.ghostty`. They also share one notification identity. Stock Ghostty runs upstream's `removeAllDeliveredNotifications()` when it quits, so it likely wipes Clawddy's notifications too *(inferred)*. Whether production Clawddy keeps `com.mitchellh.ghostty` after acceptance is an **owner decision** (§1.4). The data root can stay `~/.config/ghostty-agents` either way.
2. **Running the tests touches live data.** `macos/build.nu --action test` builds its test host with bundle ID `com.mitchellh.ghostty`. There is no XCTest detection anywhere in `App/`. The host runs `clawddy.setup()` (AppDelegate.swift:349-350). That calls `bridge.start`, which reads the live `state.json` and journals and rewrites `state.json` whenever a poll returns a batch (AgentTerminalBridge.swift:1284, 1290, 1610-1631). It also uses the live defaults domain for `clawddy.workspace.*`, spawns provider probes, adds a status item and tries to register Option-Space.
3. **Two instances double-write each other's events.** Both instances register a global hook. Each install removes only commands containing the substring `"ghostty-agents/hooks/"` (AgentHookRuntime.swift:182), so a dev root keeps its own entries and adds 13 more on every dev launch. The live hook script (old, already installed) acts on any process with `GHOSTTY_AGENT_ID` set and writes to `$GHOSTTY_AGENT_STATUS_DIR`. Every event of an agent run by either instance is therefore written by both scripts, with distinct event IDs, into that agent's journal. Dedupe is by event ID, so both copies apply.
4. **A dev copy of the data would resume live sessions.** Starting a copied agent in dev runs `claude --resume <id>` on a session the live app may be running at that moment. The dev copy must convert bindings into forks (§2.5).
5. **The old app silently destroys v6 data.** Removing tasks (schema v6) is unreadable by the old app, and it fails without an error. `AgentProject` decodes a missing `tasks` key as `[]` (AgentConfig.swift:66), so every agent disappears, and the next save makes that permanent. Rollback must restore the backup **before** the old app is launched.
6. **agent-cron depends only on `<root>/cron/` plus `/tmp/agent-crond-<uid>.sock`.** Its root is `GHOSTTY_AGENT_DATA_DIR` or `~/.config/ghostty-agents` (agent-cron AgentCronStateStore.swift:40-66). It never reads `agents.json`, `state.json` or `status/`. It already passes hooks through a per-run `--settings` overlay (ClaudeSettingsOverlay.swift:45-65), which is a working precedent for per-agent hooks. Therefore the production root must stay `~/.config/ghostty-agents`, and `cron/` must never be moved, copied into dev, or swept.

## 1. Side-by-side dev identity

### 1.1 Inventory of identity-bound resources

| Resource | Where | Collides with a second instance? |
|---|---|---|
| Bundle ID | project.pbxproj:1038 (Release), 582 (ReleaseLocal) = `com.mitchellh.ghostty`; 981 Debug = `.debug`; tests 760/784/807; dock tile 678/707/736 | **Yes.** Defaults, notifications, saved state, TCC, LaunchServices, Sparkle state |
| Display and wrapper names | pbxproj 555/1012 `Clawddy`; `PRODUCT_NAME = Clawddy` 584/1040; `WRAPPER_NAME = Ghostty.app` 588/1044 (TEST_HOST at 768/791/814 depends on it) | Services menu titles (`NSServices` uses `$(INFOPLIST_KEY_CFBundleDisplayName)`), AppleScript-by-name, Dock |
| Entitlements | Ghostty*.entitlements: no app groups, no keychain groups, not sandboxed | No shared keychain. TCC is per bundle ID + team |
| Signing | build.nu:59-62, 124-125 force Apple Development / 94DS9XB3FJ | Same team, so TCC separates only by bundle ID |
| Sparkle | Info.plist `SUEnableAutomaticChecks=false`, `SUPublicEDKey` = Ghostty's key; UpdateDelegate.swift:13-15 points at Ghostty feeds; AppDelegate.swift:244 `startUpdater()`, 861-867 | Not a cross-instance collision. But **Check for Updates would offer stock Ghostty**, and Sparkle settings persist in the shared domain *(inferred)* |
| UserDefaults | `UserDefaults.standard`: ClawddyController.swift:24-26 → AgentWorkspaceViews.swift:49-54 keys `clawddy.workspace.{scope,selectedAgentID,preferredAgents,collapsedProjects}`; NewAgentSheet `clawddy.newAgent.provider` (1223, 1240, 1457). On disk: all 5 keys plus `NSWindow Frame AgentWorkspace` and `NSSplitView Subview Frames ClawddyAgentWorkspaceSplit` | **Yes** if the bundle ID is the same |
| Window autosave and restoration | AgentWorkspaceController.swift:131, 277, 279, 291-294; ClawddyController.swift:97 (status item `autosaveName`) | Per-domain, so same bundle ID means shared |
| Notifications | `UNUserNotificationCenter` per bundle ID; category set at AppDelegate.swift:315-322; Clawddy IDs `clawddy.<uuid>.<kind>` (AgentTerminalBridge.swift:1555) | **Yes** if the bundle ID is the same |
| Dock tile plugin | Plugin ID `com.mitchellh.ghostty-dock-tile`; DockTilePlugin.swift:12-16 hard-codes suite `com.mitchellh.ghostty`; listens on a distributed notification (AppIcon.swift:94) | Cosmetic: a dev Dock icon follows the live/stock icon setting |
| Option-Space hot key | ClawddyController.swift:216-247 (`RegisterEventHotKey` 49 + optionKey, signature `AGNT`) | **Yes.** System-wide exclusive: whichever instance starts first wins and the other logs a warning at 245 *(inferred)* |
| AppleScript | Info.plist `OSAScriptingDefinition` Ghostty.sdef; three bundles named `Ghostty.app` on disk | `tell application "Ghostty"` is ambiguous. Target `application id` or an absolute path |
| URL schemes, document types | No `CFBundleURLTypes`. `CFBundleDocumentTypes` (scripts, folders, unix-executable) and the exported UTI `com.mitchellh.ghosttySurfaceId` are identical in all bundles | A dev build becomes an Open With candidate (low) |
| Single instance | CLAWDDY_ARCHITECTURE.md:650-654 says run one instance; no code enforces it | All shared files below |
| Data root | AgentConfig.swift:196-220 (`GHOSTTY_AGENT_DATA_DIR`, else `~/.config/ghostty-agents`); statics 301-304 | Separate only if the launcher remembers the env var. GUI launches don't carry it |
| Static paths that ignore `AgentConfig(dataDirectory:)` | AgentSessionStore defaults 9, 42, 72, 86, 112, 125, 136; AgentHookRuntime.swift:4-6, 66, 84; AgentMetadataRuntime.swift:11-12, 166; CodexProvider.swift:14-16; AgentPreferences.swift:52-54; bridge 350, 470, 1604, 1624; AgentWorkspaceViews.swift:506-508 | They all follow the env var but not the instance override. That is why tests can't isolate the bridge |
| Hook-script default path | AgentHookRuntime.swift:17 and AgentMetadataRuntime.swift:23 default to `$HOME/.config/ghostty-agents/status`; AgentHookRuntime.swift:11 `GHOSTTY_AGENT_NAME` fallback | Writes to the live root whenever `*_STATUS_DIR` is unset |
| Hook entry matching | AgentHookRuntime.swift:182, substring `"ghostty-agents/hooks/"` | Live never removes dev entries; dev entries pile up; double writes (fact 3) |
| Launch scripts | `FileManager.default.temporaryDirectory/clawddy-<agentUUID>-<UUID>.sh` (AgentTerminalBridge.swift:375-376); startup sweep 1655-1661 deletes **every** `clawddy-*.sh` in the shared per-user `DARWIN_USER_TEMP_DIR` | See 1.2 |
| Global provider files | `~/.claude/settings.json` (ClaudeCodeProvider.swift:150-170), `~/.codex/hooks.json` (CodexProvider.swift:171-191), via `updateJSONFile` (AgentHookRuntime.swift:107-171). Backups exist: `settings.json.clawddy-backup`, `hooks.json.clawddy-backup` (written once; first writer wins). Locks `*.clawddy.lock` are shared and serialize writers, which is fine. Codex marker `<root>/codex-hook-review-required` is per root | Both instances write the same files. Currently 13 live entries in each file, and slashes are escaped (`\/`) |
| Inherited identity env | Launch script exports `GHOSTTY_AGENT_*` (AgentTerminalBridge.swift:350-353); the fallback shell keeps them (373); not in `AgentTerminalEnvironmentPolicy.inheritedAutomationVariables` (AgentTerminalEnvironmentPolicy.swift:11-24) | A process started from one instance's terminal carries that instance's identity |

### 1.2 Can the temp sweep break the live app's running agents?

- **What it matches.** Any file in `FileManager.default.temporaryDirectory` whose name has prefix `clawddy-` and suffix `.sh`. Hook temp files (`clawddy-hook-*.json`) don't match.
- **When the live app has a script in temp.** From the `ioQueue` write (375-383) until `becameAlive` (1229), provider exit (1246), surface death (1495) or shutdown (537). Agents whose hooks never arrive (an untrusted Codex hook, disabled hooks) keep their script for the whole session.
- **Current temp dir:** zero `clawddy-*.sh` files (`getconf DARWIN_USER_TEMP_DIR` listing).
- **Effect on a running agent:** none. zsh holds the script open, and unlinking an open file doesn't affect a reader *(inferred, POSIX semantics)*.
- **Effect on a starting agent: it breaks.** If the second instance starts between the script write and zsh opening the file, the agent fails with "no such file or directory" *(inferred race; window from surface creation to exec)*. This works in both directions: dev startup can break a live launch, and live startup can break a dev launch.

### 1.3 Minimal change set for full independence (mechanical)

**1. Build settings (project.pbxproj, app target only).**
- At project level, add `CLAWDDY_BUNDLE_IDENTIFIER = com.mitchellh.ghostty`, `CLAWDDY_DISPLAY_NAME = Clawddy`, `CLAWDDY_DATA_DIRECTORY_NAME = ghostty-agents`, `CLAWDDY_GLOBAL_HOTKEY = YES`, `CLAWDDY_UPDATER = YES`.
- In the app target's Release (1038) and ReleaseLocal (582) configurations, set `PRODUCT_BUNDLE_IDENTIFIER = $(CLAWDDY_BUNDLE_IDENTIFIER)` and `INFOPLIST_KEY_CFBundleDisplayName = $(CLAWDDY_DISPLAY_NAME)` (1012, 555).
- Leave `WRAPPER_NAME` alone, because TEST_HOST hard-codes `Ghostty.app`.
- Command-line overrides of `CLAWDDY_*` reach only the app target. Overriding `PRODUCT_BUNDLE_IDENTIFIER` itself on the xcodebuild command line would hit every target, including the dock tile and the test bundle. Don't do that.

**2. Info.plist (Ghostty-Info.plist).** Add `ClawddyDataDirectoryName = $(CLAWDDY_DATA_DIRECTORY_NAME)`, `ClawddyGlobalHotKey = $(CLAWDDY_GLOBAL_HOTKEY)`, `ClawddyUpdater = $(CLAWDDY_UPDATER)`.

**3. macos/build.nu.**
- Add `--identity: string = "production"`.
- For `dev`, pass `CLAWDDY_BUNDLE_IDENTIFIER=com.mitchellh.ghostty.clawddy-dev`, `CLAWDDY_DISPLAY_NAME="Clawddy Dev"`, `CLAWDDY_DATA_DIRECTORY_NAME=clawddy-dev`, `CLAWDDY_GLOBAL_HOTKEY=NO`, `CLAWDDY_UPDATER=NO`, and set `action_root = <root>/dev`, so dev has separate products, objects and DerivedData.
- For `--action test`, always pass `CLAWDDY_BUNDLE_IDENTIFIER=com.mitchellh.ghostty.clawddy-tests` and `CLAWDDY_DATA_DIRECTORY_NAME=clawddy-tests`.
- Choose `clawddy-dev` deliberately: it shares no substring with the live matcher (`ghostty-agents/hooks/`) or agent-cron's default.

**4. One data-root resolver.** Add `struct AgentDataRoot { let url: URL }` with derived `agentsFile`, `stateFile`, `preferencesFile`, `statusDir`, `runtimeDir`, `hooksDir`, `launchDir`, resolved once in `ClawddyController.init`:
- **Under XCTest** (`ProcessInfo.environment["XCTestConfigurationFilePath"] != nil`): a unique temp directory.
- **Otherwise:** `~/.config/<ClawddyDataDirectoryName>`. A missing or empty key is a `preconditionFailure` (fail and trace).
- **Guard:** `precondition((bundleID == "com.mitchellh.ghostty") == (dirName == "ghostty-agents"))`.
- **Delete** `GHOSTTY_AGENT_DATA_DIR` handling from the app (AgentConfig.swift:206-220). agent-cron keeps its own copy untouched.
- **Thread the root** through `AgentConfig(dataDirectory:)`, which already exists, then the bridge, `AgentSessionStore`, `AgentHookRuntime`, `AgentMetadataRuntime`, `CodexProvider` marker, `AgentPreferencesStore`, and the view at 506-508. Delete the statics at 196-220 and 301-304.

**5. Launch scripts move into the root.** Write to `<root>/runtime/launch/clawddy-<agent>-<uuid>.sh` (mode 0700 dir) instead of temp (375). Sweep only that directory (1655-1661).

**6. Rename the hook env namespace and scope the hook to its root.**
- The app exports `CLAWDDY_AGENT_ID`, `CLAWDDY_AGENT_PROVIDER`, `CLAWDDY_AGENT_GENERATION`, `CLAWDDY_STATUS_DIR` (350-353).
- Add `GHOSTTY_AGENT_ID`, `GHOSTTY_AGENT_NAME`, `GHOSTTY_AGENT_PROVIDER`, `GHOSTTY_AGENT_LAUNCH_GENERATION`, `GHOSTTY_AGENT_STATUS_DIR` to `inheritedAutomationVariables` (AgentTerminalEnvironmentPolicy.swift:11-24). They are then unset by the prelude and by `env -u`, so the old live script, which only reads `GHOSTTY_AGENT_*`, ignores dev agents.
- The hook command becomes `'<root>/hooks/clawddy-provider-hook.sh' '<root>/status'`.
- The script's first line: `[ -n "$CLAWDDY_STATUS_DIR" ] && [ "$CLAWDDY_STATUS_DIR" = "$1" ] || { cat >/dev/null; exit 0; }`.
- Delete the `GHOSTTY_AGENT_NAME` fallback and the default-directory fallback (AgentHookRuntime.swift:11, 17).
- Pass the status-line proxy its status dir as `$3` instead of env (AgentMetadataRuntime.swift:23, 83-87).

**7. Exact entry matching.** Replace the substring test (AgentHookRuntime.swift:182) with "the first shell word of `command`, unquoted, equals this instance's `scriptURL.path`". The production build's install then replaces the old-format live entry at the same path, and never touches another root's entry.

**8. Gate the hot key and the updater.** In ClawddyController.swift:103, register the hot key only if `ClawddyGlobalHotKey == "YES"`. In AppDelegate.swift:244, call `startUpdater()` and show the Check for Updates item only if `ClawddyUpdater == "YES"`.

**9. Strip inherited identity at startup.** In `ClawddyController.init`, `unsetenv` every `GHOSTTY_AGENT_*` and `CLAWDDY_*` variable. An instance launched from another instance's terminal then can't leak identity into its plain terminals or its probes (AgentProvider.swift:467-482 copies the whole environment).

**10. Isolate the test host.**
- `ClawddyController.setup()` returns immediately under XCTest: no bridge start, status item, hot key, resolver or probes.
- The workspace model gets `defaults: nil` under XCTest.
- Item 3 already gives the host a non-production bundle ID, and item 4 gives it a temp root.

**11. Dev never resumes a live session.** The dev seed (§2.5) writes `fork.json` instead of `session.json`.

### 1.4 Owner decision required

Should production Clawddy keep `com.mitchellh.ghostty`? Keeping it leaves the shared domain and notification identity with stock Ghostty (fact 1). Moving to its own ID (e.g. `com.mitchellh.ghostty.clawddy`) means:
- copying the 5 `clawddy.*` keys and 2 window keys to the new domain;
- one new notification-permission prompt;
- re-granting TCC permissions.

The data root is unaffected in both cases.

### 1.5 "Two instances cannot affect each other": what must hold, and how to observe it

| # | Invariant | Observation |
|---|---|---|
| I1 | Distinct bundle IDs | `plutil -extract CFBundleIdentifier raw <dev>.app/Contents/Info.plist`. After using dev, `defaults read com.mitchellh.ghostty` shows unchanged `clawddy.*` values and `defaults read com.mitchellh.ghostty.clawddy-dev` holds dev's keys. System Settings → Notifications lists "Clawddy Dev" separately |
| I2 | Distinct data roots, and dev never writes the live root | Record `shasum` and `stat -f %m` of `~/.config/ghostty-agents/{agents.json,state.json}` and `ls -l status \| shasum` before and after a dev session that starts, uses, and stops agents. They are identical apart from appends by the live app's own agents |
| I3 | No shared launch-script directory | `grep -n temporaryDirectory macos/Sources/Features/AgentManagement` returns nothing. Starting dev while a live agent is "Starting…" never breaks it |
| I4 | One journal line per hook event, in the launching instance's root only | Dev agent: number of `UserPromptSubmit` lines in `clawddy-dev/status/<id>.events` = number of prompts typed. `grep -c 'clawddy-provider-hook.sh' ~/.claude/settings.json` = 26 (13 live + 13 dev) and stays 26 across dev relaunches. Live journal sizes don't grow for idle live agents while dev agents work |
| I5 | Dev never removes live hook entries, and vice versa | The 13 live entries are still present after dev launches. Unit test `hookInstallerRemovesOnlyItsOwnScriptPath` |
| I6 | Option-Space stays with live | Press Option-Space with both running: the live palette opens |
| I7 | Dev never resumes a live session | `clawddy-dev/status` has `fork.json` files and no copied `session.json`. After the first Start in dev, the new `session.json` ID differs from the live binding |
| I8 | Tests don't touch live state | Run `macos/build.nu --action test` with live running: shasum of live `agents.json`/`state.json`, `defaults export com.mitchellh.ghostty - \| shasum`, and the status listing are unchanged. No second menu-bar icon appears |
| I9 | No inherited identity | In a plain dev terminal, `env \| grep -E 'GHOSTTY_AGENT_\|CLAWDDY_'` is empty |
| I10 | Dev can't self-update into stock Ghostty | The Check for Updates item is absent in dev |
| I11 | agent-cron untouched | `ls ~/.config/ghostty-agents/cron` mtimes are unchanged by dev. There is no `cron/` under `clawddy-dev` |

## 2. Data inventory and migration

### 2.1 Current schemas, from the Codable types and confirmed against real key sets

**agents.json** (`AgentConfigFile` AgentConfig.swift:141-171, `AgentProject` 46-69, `AgentTask` 80-139, `AgentEntry` 10-44, `AgentLaunchProfile` AgentProvider.swift:102-134). Written `.prettyPrinted, .sortedKeys`.

```
{ schemaVersion: Int (absent → 1),
  projects: [ { id: UUID (absent → new), name, workingDirectory?: String,
    tasks: [ { id: UUID (absent → new), name,
      agents: [ String (v1)
              | { id: UUID (absent → new), name,
                  provider: "claudeCode"|"codex" (absent → claudeCode),
                  launchProfile: { modelID?, reasoningEffort?,
                                   startMode: "unrestricted"|"standard" (absent → unrestricted) } } ] } ] } ] }
```

On disk the key paths are exactly `schemaVersion`, `projects[].{id,name,workingDirectory,tasks}`, `tasks[].{id,name,agents}`, `agents[].{id,name,provider,launchProfile}`, `launchProfile.startMode`. schemaVersion is 5.

**state.json** (`PersistedState` AgentTerminalBridge.swift:239-281).
- Keys: `unreadCompletions`, `lastAppliedCompletions`, `pendingRenames`, `eventOffsets`. Legacy input key `unreadAgents: [UUID]`.
- Every `[UUID: X]` is encoded by JSONEncoder as a **flat array `[key, value, key, value, …]`** (confirmed on disk).
- `AgentCompletionID` = `{provider, sessionID?, turnID?, launchGeneration, eventID}`.

**preferences.json** (AgentPreferences.swift:3-49): `{schemaVersion, claudeCodeDefaultStartMode, codexDefaultStartMode}`. **Absent on disk**, so the app uses its unrestricted defaults.

**status/**
- `<id>.events`: JSONL. Hook records are `{schemaVersion:1, eventID, provider, launchGeneration, hookEventName, sessionID, turnID, model, permissionMode}`, all strings, with **empty strings for missing fields**. Launch-script exit records are `{…, hookEventName:"ProviderExited", exitStatus:Int}`. Legacy untagged records are `{hook_event_name, session_id}`.
- `<id>.events.lock`: empty.
- `<id>.session.json`: `{provider, sessionID, launchGeneration?}`.
- `<id>.fork.json`: `{provider, sourceSessionID}`.
- `<id>.metadata.json`: the raw Claude statusLine payload. Keys on disk: session_id, transcript_path, cwd, prompt_id, effort, session_name, model, workspace, version, output_style, cost, context_window, exceeds_200k_tokens, fast_mode, thinking, rate_limits, scratchpad_dir, prompt_cache.
- Legacy: `<id>.session` (bare ID), `<id>.lastEvent` (`{hook_event_name, session_id}`, no reader in code), `<id>.state`, v1 name-keyed files, and hook temp leftovers.

**runtime/<id>/**: `settings.json` = `{statusLine:{type,command}}`; 29 of 42 also carry a legacy `env.CLAUDE_CODE_FORCE_SESSION_PERSISTENCE` from an older build. Plus `upstream-statusline.command`. Both are rewritten on every launch.

**hooks/**: `clawddy-provider-hook.sh`, `clawddy-statusline-proxy.sh`, and legacy `clawddy-hook.sh` (0 registrations in either provider file).

**Root top level:** `cron/` (agent-cron), an `atomicWrite` leftover `<uuid>.tmp`, and `debug.log` and `statusline.sh`, which are referenced by no code and by no provider settings. The user's `~/.claude/settings.json` has no `statusLine` key.

### 2.2 Real-data facts (counts only)

**Config.**
- 4 projects with 1, 2, 4 and 11 tasks; 18 tasks in total, 1 of them empty.
- 69 agents: 66 Claude, 3 Codex. All `unrestricted`; none sets a model or effort.
- No string agents, no missing IDs, no duplicate IDs, no duplicate project names.

**Name collisions after flattening tasks:**
- 1 group of 3 agents in one project. Their names are equal ignoring case but not identical in case.
- Renaming them to "<task> <agent>" leaves 0 collisions.

**state.json.**
- 48 offsets, all configured, all equal to their file sizes, so every journal is fully consumed.
- 44 last-applied completions, 0 unread, 0 pending renames.
- No `unreadAgents` key; 0 `legacy-unread` event IDs.

**Sessions.**
- 45 configured agents have a tagged `session.json`; all generations are valid UUIDs; 0 provider mismatches.
- **24 configured agents rely only on a legacy `.session` file.** All 24 are Claude and all have valid IDs.
- 3 have both a tagged and a legacy file; every one of the 69 has a binding.

**Fork markers:** 0 `.fork.json` files, 0 `.forkFrom` files.

**status/: 592 files, 215 distinct UUIDs, 69 of them configured.**

| Kind | Total | Orphan |
|---|---|---|
| `events` | 90 | 42 (one is 2.9 MB) |
| `events.lock` | 91 | 43 |
| `lastEvent` | 126 | 99 |
| `metadata.json` | 42 | 0 |
| `session` | 131 | 104 |
| `session.json` | 82 | 37 |
| `state` | 8 | 8 |
| temp leftovers | 3 | |
| v1 name-keyed | 19 | |

**Journals: 46,770 records.**
- 87 untagged. 79 of those are in configured journals, all before the persisted offsets; 8 are in orphan journals.
- 1 record has `"provider":""`. It fails to decode and is dropped silently at AgentTerminalBridge.swift:1158-1161.
- Empty-string fields: `turnID=""` in 44,254 records, `model=""` in 44,174, `permissionMode=""` in 548. These decode as `""`, not nil.

**Dry run of the migration's sweep (computed):**
- keep 183 files;
- create 24 `session.json` files;
- delete 409 files: 335 orphan-UUID files, 19 v1 files, 27 configured `.lastEvent`, 27 configured legacy `.session` after conversion, and 1 configured temp leftover.

**Defaults:**
- `clawddy.workspace.scope` is currently a task scope.
- `preferredAgents` has 3 `project:` keys and 8 `task:` keys.

### 2.3 Target schemas

**agents.json v6.** Same file and key style, with tasks removed:

```
{ "schemaVersion": 6,
  "projects": [ { "id", "name", "workingDirectory",
                  "agents": [ { "id", "name", "provider", "launchProfile": { "modelID"?, "reasoningEffort"?, "startMode" } } ] } ] }
```

- Every key is required. The decoder is strict: no `?? default` paths, and `schemaVersion != 6` throws, except inside the migration.
- Agent order = tasks in order, then agents in insertion order. This is today's visible order.
- Agent names are unique within a project, ignoring case.

**state.json.**
- Phase A keeps the current encoding (flat arrays) so the old app can still read it.
- Exactly-once consolidation drops `eventOffsets` and `lastAppliedCompletions`.
- Removing rename-by-keystroke drops `pendingRenames`.
- What remains: `unreadCompletions`.

**status/.** Only `<id>.{events, events.lock, session.json, fork.json, metadata.json}` for configured IDs.

**hooks/.** Only the two current scripts.

**runtime/.** Unchanged; regenerated on every launch.

**Defaults.**
- `scope` of the form `task:<p>:<t>` becomes `project:<p>`.
- `preferredAgents` drops the `task:*` keys.
- Other keys unchanged.

### 2.4 The migration: pure function plus a thin IO wrapper

**Signature.**

```swift
struct AgentDataSnapshot {            // read by the IO layer; small files only
  var agentsJSON: Data; var stateJSON: Data?; var preferencesJSON: Data?
  var statusFileNames: [String]       // names only; journals are never loaded
  var smallStatusFiles: [String: Data] // .session, .session.json, .fork.json
  var hookFileNames: [String]
  var workspaceDefaults: [String: Any] // the five clawddy.* keys
}
enum AgentMigrationMode { case cleanupV5, flattenV6, seedDevCopy }
struct AgentMigrationPlan {
  var agentsJSON: Data; var stateJSON: Data
  var statusWrites: [String: Data]; var deletions: [String]   // paths relative to root
  var defaultsWrites: [String: Any?]; var renames: [UUID: (from: String, to: String)]
  var report: AgentMigrationReport                            // every count, written to the backup folder
}
func planAgentMigration(_ s: AgentDataSnapshot, mode: AgentMigrationMode) throws -> AgentMigrationPlan
```

**Preflight aborts.** The function throws, and the operator must look; nothing is ever guessed:
- schemaVersion is not 5 (or not 6 when a no-op is expected);
- a string agent, or a missing key;
- a legacy `.session` file holding an invalid ID;
- a `session.json` whose provider differs from the config;
- an untagged journal record after its offset.

All of these are zero today.

**Rules.**
1. Convert each configured agent that has only a legacy `.session` (24) into `session.json` `{provider:"claudeCode", sessionID}`. Where a tagged file exists, the tagged file wins. Delete the legacy file afterwards.
2. Delete every status file whose UUID is not in config, all v1 files, all `.lastEvent` files, and temp leftovers. **Unknown kinds are reported, never deleted.**
3. In `state.json`, drop entries for deleted agents. Drop the fields named in §2.3 as the matching engine steps land.
4. Delete `hooks/clawddy-hook.sh`.
5. Never touch `cron/`, `debug.log`, `statusline.sh` or `runtime/`.
6. **`flattenV6` only:**
   - Flatten as in §2.3 and drop empty tasks.
   - Collisions: keep the first occurrence in config order and rename the others to `"<name> (<task name>)"`, adding ` 2`, ` 3` while that still collides. Today that is 2 renames.
   - Rewrite defaults as in §2.3.
7. **`seedDevCopy`:**
   - Replace every binding (45 tagged + 24 legacy) with `fork.json` `{provider, sourceSessionID}`.
   - Copy no journals, metadata, runtime or hooks.
   - Copy unread completions; drop offsets and last-applied entries.

**IO wrapper, in order.**
1. **Precondition** for `inPlace`: the old app is not running. Refuse if another running app with this bundle ID has `CFBundleName == "Clawddy"` and a different bundle URL. Stock Ghostty is excluded by name.
2. **Backup** to `~/.config/ghostty-agents-backups/<yyyyMMdd-HHmmss>-<mode>/`, mode 0700, outside the root so neither the watcher nor agent-cron sees it:
   - `ditto` of the root **excluding `cron/`**;
   - copies of `~/.claude/settings.json` and `~/.codex/hooks.json`;
   - `defaults export com.mitchellh.ghostty <backup>/defaults.plist`;
   - `ditto ~/Applications/Clawddy.app <backup>/Clawddy.app`.

   Then re-decode the backup's `agents.json` to prove the backup is readable.
3. Read the snapshot and plan. On an abort, write the report into the backup folder and stop.
4. Write `statusWrites` (additive).
5. Write `state.json`.
6. Write **`agents.json`. This is the commit point.**
7. Delete the files in `deletions`.
8. Write defaults.
9. Remove the dev identity's hook entries by exact path. If per-agent hooks have landed, also remove the live global Claude entries.
10. Write `<root>/migration-<mode>.json` containing the report.

**Idempotence.** Steps 4 and 7-9 are idempotent. Before step 6 the file is still v5, so a rerun re-plans the same result. After step 6, planning yields an empty plan. Test M2 checks this.

**Dev seed.** No env var, and the copy is never a move. The dev app runs the seed only if its own root doesn't exist and it is the dev identity. It reads `~/.config/ghostty-agents/{agents.json,state.json,preferences.json}` and the configured agents' bindings through read-only opens, plans `seedDevCopy`, and writes only under `~/.config/clawddy-dev`. Delete `~/.config/clawddy-dev` to reseed.

**Expected after acceptance.** Codex detects the changed hook command (it now has an argument) and requires one `/hooks` review for the 3 Codex agents. Until then their activity status is paused (by design).

**Rollback.**
1. Quit the new app.
2. Move the current `status/` to `<backup>/post-migration-status/`.
3. `ditto` the backup's root files back into place. `cron/` is untouched because it isn't in the backup.
4. Restore the 5 `clawddy.*` keys from `defaults.plist`.
5. Restore `Clawddy.app` from the backup.
6. **Only then** launch the old app.

Notes:
- Provider files need no restore. The old app reinstalls its own script and entry before its first launch (`prepareIntegration` runs at AgentTerminalBridge.swift:341, before the surface exists).
- Sessions started after migration are lost on rollback. Those agents resume their pre-migration session.
- `cleanupV5` output is readable by the old app (tagged bindings are read first, and missing `state.json` keys decode as empty), so a Phase A rollback can skip the data restore. A `flattenV6` rollback cannot (fact 5).

### 2.5 Migration test cases

Pure function, against a synthetic fixture with the real shape: 4 projects, 18 tasks including 1 empty, 69 agents, 1 collision group of 3.
- **M1** `flattenPreservesOrderAndRenamesCollisions`: 69 agents, order kept, 2 deterministic renames.
- **M2** `planIsIdempotent`: plan → apply → plan gives an empty plan.
- **M3** `legacySessionOnlyIsConverted`.
- **M4** `taggedBindingWinsOverLegacy`.
- **M5** `orphansV1FilesLastEventAndTempLeftoversAreDeleted`.
- **M6** `unknownStatusKindsAreReportedNotDeleted`.
- **M7** `providerMismatchAborts`.
- **M8** `invalidLegacySessionIDAborts`.
- **M9** `schemaOtherThan5Or6Aborts`; `schema6IsNoOp`.
- **M10** `stringAgentsOrMissingKeysAbort`.
- **M11** `untaggedRecordAfterOffsetAborts` (synthetic; only file names and offsets are needed, which the snapshot provides).
- **M12** `cronAndUnknownTopLevelFilesAreNeverPlanned`.
- **M13** `workspaceDefaultsMapTaskScopeToProject`.
- **M14** `emptyTaskDroppedEmptyProjectKept`.
- **M15** `collisionRenameNeverClobbersAnExistingName`.
- **M16** `unreadForDeletedAgentsDropped`.
- **M17** `seedDevCopyConvertsEveryBindingToFork`.

IO wrapper:
- **M18** `seedNeverWritesSource`: the source copy is chmodded read-only; the seed succeeds.
- **M19** `interruptedApplyResumesCorrectly`: inject a failure after step 4 and after step 5; the rerun produces the same final tree.
- **M20** `backupIsCompleteAndDecodes`.

Opt-in rehearsal (manual, never in CI):
- **M21** `rehearsalOnRealCopy`: `ditto` the live root to a temp dir, then run `cleanupV5` and `flattenV6`. Expect 69 agents, 24 conversions, 409 deletions, 0 aborts.

## 3. The bridge seam and the test harness

### 3.1 The single status seam

```swift
struct AgentStatusObservation: Sendable, Equatable {
  enum Source: Sendable, Equatable { case hookJournal, programStatus }
  let agentID: UUID; let generation: UUID; let provider: AgentProviderID
  let source: Source
  let events: [AgentDomainEvent]        // already normalized
  let facts: AgentObservedFacts         // sessionID?, turnID?, model?, permissionMode?; "" mapped to nil by the source
  let observedAt: Date
}
@MainActor func ingest(_ o: AgentStatusObservation)   // the ONLY way live state enters the reducer
```

**`ingest` algorithm**, which replaces AgentTerminalBridge.swift:1155-1278:
1. Look up the agent. If unknown, record a diagnostic.
2. If `o.generation != runtime.launchGeneration`, return silently: a stale generation is expected.
3. If the provider doesn't match, record a diagnostic.
4. If `o.source != runtime.statusSource`, record a diagnostic. Each launch selects one source per provider through the provider table, so the two sources can never both count.
5. For each event, call `apply(.provider(...))`.
6. Merge facts into metadata.
7. Set `lastStatusAt = observedAt`.
8. Call `perform(effects)`: notifications, rename, script cleanup, fork cleanup, health refresh.

**Exactly-once lives in the transport**, so `ingest` keeps no dedupe set:
- The journal source uses in-memory byte offsets, starts each journal at EOF on launch (no earlier generation can apply), and resets an offset only after its own compaction.
- The program-status source takes in-order delivery from the PTY stream.

**Hook journal source** (`AgentHookJournalSource`). It owns the watcher, the coalescing poll, offsets and compaction (today at 1049-1127, 1302-1308, 1356-1379, 1633-1651). It decodes each record, requires `schemaVersion`, `provider` and `launchGeneration`, normalizes through the provider table, maps `""` to nil, and calls `ingest`.

**Program-status source.** The surface host binds `(agentID, generation, provider)` when it creates a surface. Whatever surface-level signal agents (a) and (b) deliver is mapped to `AgentDomainEvent`s by a table supplied later, then passed to `ingest`. Nothing else in the bridge depends on which source is in use.

**Other reducer inputs stay distinct:**
- user intents: `launch`, `viewed`;
- surface lifecycle from the host: `surfaceOpened(id, generation)`, `surfaceClosed(id, generation, processAlive)`;
- timers from the scheduler.

### 3.2 Injected seams (the smallest set)

| Seam | Replaces |
|---|---|
| S1 `AgentDataRoot` (§1.3 item 4) | All statics, temp scripts (375, 1656), `stateURL` (1604, 1624) |
| S2 `AgentScheduler { var now: Date; func after(_ s: TimeInterval, _ f: @escaping @MainActor () -> Void) -> AgentScheduled }` | `Timer` at 506, 781, 1420; `asyncAfter` at 1057; `Date()` at 733, 1249, 1344, 1398 |
| S3 `AgentIOExecutor { func perform<T>(_ work: @Sendable () -> T, then: @MainActor (T) -> Void) }`. Production: `ioQueue` + main hop. Tests: inline | Pairs at 557-571, 757-776, 1080-1126, 1360-1378; fire-and-forget calls at 1004, 1232, 1325, 1483, 1498, 1629, 1684 |
| S4 `AgentSurfaceHost` (main actor): `present(agent:projectName:launch:) -> .created/.existing/.refused`, `hasSurface`, `removeSurface`, `sendText`, `select`. The host calls back `bridge.surfaceClosed(...)`. `AgentDetailViewController` already has these methods (122, 154, 228, 257, 273, 291) | The `app`/`detailVC` parameters (701, 803-804); the `@unchecked Sendable` wrappers (306-316); the close observer (867-877); the `processExited` heartbeat check (1022); the bridge's own `surfaceViews` |
| S5 `AgentNotifier { post(_:); clear(agentID:) }` | 1535-1599 |
| S6 `AgentProviderTable` with closures `locateExecutable`, `probe`, `prepareIntegration`, `arguments`, `normalize` (real), `statusSource` | `AgentProviderRegistry` (445). Tests never spawn CLIs or write provider files |
| S7 `diagnose(_ AgentDiagnostic)` (production: Logger plus visible error state; tests: an array) | Silent `try?` and `continue` paths |

**Introduction order:** S1, S5, S6, S3, S2, S4. Each seam is a constructor parameter whose production default is today's exact behaviour. The production IO executor keeps the current `ioQueue` + `Task { @MainActor }` hop, so ordering doesn't shift.

### 3.3 The harness

- **Fixture:** a temp root with `agents.json`.
- **Setup:** `AgentConfig(dataDirectory:)` and `AgentBridge(root:, scheduler: ManualScheduler, io: .inline, surfaces: FakeSurfaceHost, notifier: RecordingNotifier, providers: .fake)`.
- **Drive:**
  - `bridge.start`, `bridge.activateAgent`;
  - `journal.append(id, hook:, session:, generation:)`, which writes the exact format the hook script writes, `""` fields included;
  - `scheduler.advance(by:)`;
  - `host.close(id, processAlive:)`;
  - external edits to `agents.json` followed by `config.load()`.
- **Assert:** `displayState` and the runtime fields; `notifier.posted` (identifier, interruption level); `host.calls` and `host.sentText`; `state.json`, `session.json` and `fork.json` contents; `diagnostics`.
- **Keep the format honest:** one integration test runs the real hook script (as AgentHookScriptTests does today) into the harness root.

### 3.4 Characterization tests to write before refactoring

Tests prefixed `knownWrong_` pin today's wrong output on purpose; the fix later flips the assertion.

**Launch and lifecycle**
- `launchShowsStartingAndPresentsOneSurface`
- `secondActivationDuringPreparationStartsNothing`
- `noHookFor10sIsStatusUnavailable`
- `sessionStartIsReadyRemovesScriptWritesBinding`
- `missingExecutableIsCouldntStart`
- `providerExitBeforeSessionStartIsStartFailure`
- `forkLaunchUsesPendingForkAndClearsItOnSessionStart`

**Activity**
- `promptToolPermissionStopSequence`: thinking → working → thinking → permission, with a time-sensitive notification → finished, with a passive notification, unread set, and the unread persisted.
- `stopWhileViewedNoUnreadNoNotification`
- `viewingAcknowledgesPersistsAndClears`
- `stopFailureNeedsAttention`
- `toolFailureKeepsTurn`
- `compactionExpiresAfter30s`
- `silent120sIsDelayedAndRecovers`
- `partialLineWaitsForNewline`
- `journalOver1MiBCompactsAndLaterEventsApply`

**Generations and filters**
- `surfaceDeathIsExitedAndCleansUp`
- `restartNewGenerationIgnoresOldEvents`
- `providerMismatchAndUnknownSchemaAreSkippedAndAcknowledged`
- `replayedEventIDAppliesOnce`
- `eventsPresentAtStartupNeverApply`

**Rename**
- `renameWhileIdleIsTypedImmediately`
- `renameWhileWorkingIsDeferredPersistedThenTyped`

**Config reconcile**
- `externalAddCreatesRuntime`
- `externalDeleteRemovesRuntime`
- `providerChangeOnBoundAgentIsReverted`
- `providerChangeOnNeverLaunchedAgentReplacesRuntime`
- `persistedUnreadSurvivesRestart`

**Known wrong**
- `knownWrong_nestedSessionStartResetsActiveTurnAndRebinds`
- `knownWrong_renameTypedIntoFallbackShellAfterExit`
- `knownWrong_closeWithLiveProcessDestroysWithoutConfirmation`
- `knownWrong_undecodableRecordDroppedSilently`: the `provider:""` case.
- `knownWrong_corruptStateFileStartsEmpty`
- `knownWrong_corruptPreferencesAreUnrestricted`
- `knownWrong_corruptBindingLaunchesFresh`
- `knownWrong_externalDeleteLeavesStatusFiles`
- `knownWrong_aggregateNotPublishedAtStartup`
- `knownWrong_emptyTurnIDKeptAsEmptyString`
- `knownWrong_hostRefusingPresentLeavesAgentLaunching`: the path at 858-862.
- `knownWrong_sweepDeletesForeignClawddyScripts`
- `knownWrong_installerKeepsEntriesForNonDefaultRoot`

The watcher missing pure appends can't be pinned without a real `DispatchSource`. Observe it manually: after a Codex `/exit`, "Exited" appears up to about 10 s late *(inferred)*.

## 4. Verified safe deletions

**BridgeMetrics: 29 call sites plus the file.**
- Delete `BridgeMetrics.swift`.
- Delete the calls at:
  - AppDelegate.swift:834;
  - AgentConfig.swift:756, 764, 767 (at 764 the guard's `else` body becomes `return`);
  - AgentTerminalBridge.swift:514, 539, 612, 619, 650, 659, 691, 865, 872, 942, 994, 997, 1014, 1053, 1062, 1283, 1298, 1401-1408, 1452-1453, 1459, 1517, 1645.
- Delete `updateMetricsSnapshot()` (1458-1462) and its calls at 515, 665, 692, 866, 980, 988, 1485, 1490.
- Update docs: CLAWDDY_ARCHITECTURE.md:63, 535-536 and README.md:58.
- What breaks: nothing. Diagnostics existed only with `GHOSTTY_AGENT_METRICS=1`, and no tests reference it.

**Visual audit.**
- Delete AgentWorkspacePolicies.swift:5-32.
- ClawddyController.swift: delete 118-145 and 428-501; replace 24-26 with `.standard`, or `nil` under XCTest (§1.3); delete the guard at 83-86 and the argument at 352-353.
- AgentWorkspaceViews.swift: delete 828, 999-1004, 1022, 1227, 1361-1370.
- AppDelegate.swift: delete 237-245, then restore an unconditional `updateController.startUpdater()`, gated by §1.3 item 8. Delete 352-354.
- Delete the tests at AgentWorkspacePolicyTests.swift:20-49.
- Optional: `SettingsController.show(activate:)` loses its only `false` caller.
- What breaks: only the env-driven QA mode. It is not referenced in any docs.

**AgentOrdering.**
- Delete `let ranks` at AgentWorkspaceViews.swift:855 and `.sorted{…}` at 879.
- Delete AgentOrdering.swift and AgentOrderingTests.swift.
- Why it's safe: the list is built by the same traversal (projects → tasks → agents) that produces the ranks, so the sort is the identity. 0 duplicate IDs on disk.

**Module-level `atomicWrite`** (AgentConfig.swift:798-802): 0 callers. All callers use `AgentConfig.atomicWrite` or `Self.atomicWrite`.

**`bridge.surfaceView(for:)`** (AgentTerminalBridge.swift:1466): 0 callers. The detail controller's own `surfaceView(for:)` is a different method and stays.

**`launchTime`** (145, 733): written, never read.

**`GHOSTTY_AGENT_NAME`** (AgentHookRuntime.swift:11): set nowhere in the repo. Changing the script string makes each root's installed script be rewritten on its own app's next launch (69-74).

**Unused `AgentSessionMetadata` fields.**
- Delete the properties at 14, 16, 23, 24, 25, 27, 28 and their assignments at 102, 104, 111-115.
- Delete the payload fields at 161/167, 176/184, 194-196/201-203, 214-215/223-224.
- Update AgentMetadataTests.swift:50.
- Optionally drop the `Codable` conformance: nothing ever encodes or decodes the type.
- Removing `transcriptPath` also shrinks the privacy surface.

**Legacy paths with zero users, and the on-disk evidence for each:**

| Path | Code | Evidence of zero users |
|---|---|---|
| `legacyUnreadAgents` | AgentTerminalBridge.swift:246 (`unreadAgents` key), 265-269, 280, 486-496 | No `unreadAgents` key in `state.json`; 0 `legacy-unread` event IDs |
| `.forkFrom` | AgentSessionStore.swift:29, 97-105, 127, 139 | 0 `.forkFrom` and 0 `.fork.json` files |
| snake_case event keys | AgentProvider.swift:336-339, 348-356, 363; AgentTerminalBridge.swift:1169-1174, 1188-1190 | All 79 configured untagged records lie before persisted offsets, and all 48 offsets equal file size. The other 8 are in orphan journals. Untagged lines can only apply during a live generation, i.e. if an old script wrote them, and `clawddy-hook.sh` has 0 registrations. Delete the legacy half of AgentProviderTests.swift:285-306 |
| `PersistedAgent.legacyName` | AgentConfig.swift:94-107, 131-137 | schemaVersion is 5; 0 string agents. Delete AgentConfigDurabilityTests `legacyStringAgentsStillMigrateAndPersistTheirIdentity` (199 ff.) |
| `migrateStatusFiles` | AgentConfig.swift:356, 417-445 | For all 69 agents, 0 v1 files would move. The 19 v1 files on disk are orphans for the sweep |
| Decode defaults (optional; makes decoding strict) | AgentConfig.swift:34, 38-42, 64, 111, 121, 158-169; AgentProvider.swift:125-126 | 0 entries missing any key. Adjust AgentProviderTests.swift:116 ff. and the start-mode default test |

**Not deletable yet:** the legacy `.session` fallback (AgentSessionStore.swift:27-35, 53-65). 24 configured agents depend on it. Delete it only after the migration has run (`cleanupV5` at Phase A acceptance, or the dev seed for dev). The `.lastEvent` name has no reader; delete it together with the sweep.

Every deletion above must be re-proven at acceptance by the migration preflight (M9-M11) against the live data of that day.

**PageList revert.** In src/terminal/PageList.zig:799-800, restore upstream's `log.err("PageList integrity check failed: {}", .{err});` followed by `@panic("PageList integrity check failed");`.
- Check: `git diff upstream -- src/terminal/PageList.zig` is empty.
- Effect: Debug builds panic on a corrupt PageList again. Release builds are unaffected (`slow_runtime_safety` is Debug-only, build_config.zig:65-71).

**AppDelegate restores.**
- **Notifications at quit:** at AppDelegate.swift:449-450, put upstream's comment and `UNUserNotificationCenter.current().removeAllDeliveredNotifications()` before `clawddy.shutdown()`. Agents die at quit anyway, and unread state persists in the app.
- **`open_config`:** upstream bound the Preferences… item (Cmd-,) to `openConfig:` through outlet `menuOpenConfig`, and synced the `open_config` shortcut onto it. The fork repointed that item to Settings (MainMenu.xib hunks at outlet 44 and item 97-99). An exact restore takes four steps:
  1. Revert those xib hunks.
  2. Rename the outlet back at AppDelegate.swift:25 and 1231.
  3. Re-add `syncMenuShortcut(config, action: "open_config", menuItem: self.menuOpenConfig)` after 1275.
  4. Move "Settings…" into the Agent menu built by `ClawddyController.setupMenu` (278-329), and delete the `showSettings` action (1066-1068).

  **Behaviour change the owner must accept:** Cmd-, opens the Ghostty config file again.

## 5. Phase order constraints

The "Depends on" column is the dependency graph: each step can start once the steps it names are done.

| Step | Depends on | Why | Green at every step? | Acceptance |
|---|---|---|---|---|
| **E0** one-time read-only backup of the live root, provider files and defaults | none | Safety before any dev run | n/a | Backup re-decodes |
| **E4b** PageList revert; AppDelegate restores | none | Upstream hygiene | Yes | `git diff upstream` on those lines is empty. Notification Center is empty after quit. Cmd-, per decision |
| **E4a** dead code: metrics, visual audit, ordering, free `atomicWrite`, `surfaceView(for:)`, `launchTime`, `GHOSTTY_AGENT_NAME` fallback, unused metadata fields | none (before E5) | The visual audit writes runtime fields directly, which would block E5 | Yes | Greps return 0; existing tests pass; smoke run |
| **E1** identity and isolation (§1.3) | E0 | Everything else is tested in dev | Yes: production defaults equal today's behaviour | Tests `dataRootFromInfoKey`, `productionBundleRefusesForeignRoot`, `xctestUsesTemporaryRoot`, `launchScriptsUnderRoot`, `hookIgnoresOtherRoot`, `hookInstallerRemovesOnlyItsOwnScriptPath`; manual I1-I11 |
| **E2** seams S2-S7 (S1 comes with E1) | E1 | The harness needs them | Yes, with default parameters. **This is the one stretch that precedes characterization**; mitigated by exact production defaults plus a smoke run after each seam | Existing 134 tests and a smoke run |
| **E3** characterization tests | E2 | Pin behaviour before changing it | Yes | All pass, including the `knownWrong_` ones |
| **E14b** migration pure function, IO wrapper, M1-M21 | E1 | The dev seed and both acceptances need it | Yes (unused until invoked) | M1-M20 pass; M21 rehearsal counts match §2.2 |
| **E4c** legacy decoders (§4 table) | E3, E14b | Preflight must prove zero users. The `.session` fallback goes only after `cleanupV5` | Yes | Preflight test; updated tests |
| **E5** single runtime snapshot (`private(set) var runtime`, plus computed read-only accessors so views compile) | E3, E4a | | Yes | Characterization unchanged; new `applyIsOneObservableMutation` |
| **E6** single surface map (the host owns it) | E2 (S4), E3 | | Yes | `surfaceDeathFromHostRemovesOnlyRecord`; grep `surfaceViews` returns 0 |
| **E12** close confirmation (honor `process_alive`) | E6 | One close entry point | Yes | `knownWrong_closeWithLiveProcess…` flipped; manual Cmd-W shows a confirmation. Quit is probably already covered by libghostty `needsConfirmQuit` (AppDelegate.swift:443) *(inferred; verify manually)* |
| **E7** single viewed-agent owner (the controller computes the policy; the bridge receives an `isViewed` closure; delete `explicitlyViewedAgentID`, `headerModel.agent` and `activeID` duplicates, keeping one stored value) | E3; easier after E6 | | Yes | `AgentActivationIntentTests` pass. Manual: completion while viewing gives no unread; switching away then completing gives unread |
| **E8** status-source seam (§3.1) | E3; E5 helps | | Yes | Characterization unchanged; `ingestDrivesSameTransitionsFromEitherSource` |
| **E9** one exactly-once mechanism (transport offsets in memory, EOF on start; delete `AgentProviderEventLedger`, persisted offsets and last-applied) | E8 | | Yes. The old app still reads the result | `eventsPresentAtStartupNeverApply`; `compactionNeitherReplaysNorLoses`; `state.json` lacks both keys |
| **E10** provider table replaces protocol and registry | E2 (S6), E8 | `normalize` moves into the source | Yes | `providerTableMapsEveryHookEvent`; grep `AgentProviderAdapter` returns 0 |
| **E11** env leak fix (fallback `unset`; foreign-session guard in `ingest`/reducer) | E3, E8 | | Yes | `knownWrong_nestedSessionStart…` flipped; `fallbackShellHasNoAgentIdentity` (run the generated script, `env` shows no `CLAWDDY_`) |
| **E13** fail-loud persistence (`atomicWrite` throws; preferences fail closed; unreadable binding is an explicit failure; diagnostics) | E2 (S7), E3 | | Yes | The four `knownWrong_corrupt…` / undecodable tests flipped |
| **E14a** single removal path deleting `<uuid>.*` | E3 | | Yes | `knownWrong_externalDeleteLeavesStatusFiles` flipped |
| **E15** hooks through per-agent settings for Claude; Codex stays global but scoped | E1, E10, **external research** | | Yes | `claudeLaunchCarriesHookOverlayWithIdentityArgs`. After migration, `grep -c clawddy ~/.claude/settings.json` = 0 and live Claude agents still report state |
| **E16** bridge decomposition by deletion (`DisplayState` to the presentation file, launch-script builder into the provider table) | E5-E15 | | Yes | Characterization unchanged; file size |
| **Phase A acceptance** | E1-E16 | | n/a | Backup, then `cleanupV5`, then install. Rollback by reinstalling the old app, with optional data restore |
| **B1** task removal plus `flattenV6` | Phase A accepted | UI-bearing | **No** | M1-M21 plus the UI work. Rollback requires a data restore |

Steps that can run independently of each other: E4a, E4b, E14b; E5, E6 and E13; E10 and E11 once E8 is done.

**Steps that cannot be made safe in small increments:**
1. **B1 (task removal).** The schema, `AgentConfig`, the workspace model and its scopes, the policies (drop destination, empty-state copy, disclosure), the drag payload, the views, the command palette and the tests all change together. Splitting it would need a temporary synthetic-task shim, which the owner's standard rejects. Do it as one change at the start of Phase B. **Owner decision 3 conflicts with this:** task removal can't happen in Phase A with the UI unchanged.
2. **The production in-place migrations.** They are one-shot and require quitting the live app. Mitigated by the backup, the rehearsal on a real copy (M21), the preflight aborts and the commit-point ordering.
3. **E2.** Seams arrive before the tests that pin behaviour. Keep production defaults identical and run a smoke test after each one.
4. **E15.** Gated on the other agents' findings. The identity-as-arguments design must also hold for Codex, or Codex stays on the scoped global hook from E1.
