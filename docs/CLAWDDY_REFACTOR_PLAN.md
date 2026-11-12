# Clawddy refactor plan

Status: revision 2, 2026-11-11, approved and in execution since 2026-11-12. Phase 0, Phase 2 and P3.5a are committed; gates G0 and G3 await the owner.
Revision 2 incorporates an adversarial review of revision 1 against the code; the
review found four defects that would have disturbed the live app or lost sessions,
and all of its findings are folded in below (section 14 lists what changed).

## 1. What this plan does

It replaces the way Clawddy learns what an agent is doing, removes the state that
is stored in more than one place, makes failures visible, and makes it impossible
for a development build or a test run to touch the live app's data. The UI stays
as it is until that engine is accepted (Phase A). The UI redesign, including the
removal of tasks, follows as Phase B.

"Will work" means: every step has an acceptance check that is an automated test
or a precise observation, the build is green after every step, and every step
that touches user data has a backup and a rehearsed rollback. Where a fact is not
yet proven, the plan has a gate with a stated fallback. Section 13 lists what is
still unproven.

## 2. Facts the plan is built on

Observed on this machine on 2026-11-11 (Claude Code 2.1.322, Codex 0.166.0). The
captures and the harness to rerun them are in `docs/clawddy-refactor/`.

| # | Fact | Consequence |
|---|---|---|
| F1 | Claude sends `OSC 7501;?` at startup. With the documented reply it reports `idle`, `working`, `blocked kind=permission`, `blocked kind=question`, `done`, and `clear` on exit. With no reply it reports nothing. Nothing is reported before the folder trust dialog is accepted. | The fork must answer the query. Then Claude's turn activity needs no hooks. |
| F2 | Interrupt, Esc on a permission prompt, and `/clear` all end in `idle`. `done` stays until the next prompt, and a second `done` carrying a summary follows 1.5 to 2.5 s after the first. `/clear` and `/exit` produce a `working` blip of about 50 ms. Claude `error` was never seen. | Interrupted turns stop being stuck. A repeated `done` must not count as a second completion. Failures still need a hook. |
| F3 | Codex sends OSC 7501 without a query: `idle`, `working`, `error`, `clear` were seen, plus a `working` of about 0.5 s during startup. `blocked` and `done` were not seen, because every turn failed with the configured default model. | Codex stays on today's hook source until gate G4. |
| F4 | Claude hooks given through `--settings` run, merge with global hooks, and receive command-line arguments intact. They do not run until the folder is trusted. A `claude` started by an agent's tools does not receive the parent's `--settings`. | Agent identity can travel as hook arguments. With no identity in the environment, a nested session cannot report as its parent. |
| F5 | `claude --session-id <uuid>` works; `--resume <uuid>` resumes it; `--session-id` may be combined with `--resume` only together with `--fork-session`. `/clear` switches to a new random id, reported by `SessionStart` with `source: "clear"`. | The app chooses the id for new sessions and forks, and follows `/clear` through the `SessionStart` hook. |
| F6 | `claude --name <x>` names the session, also with `--resume`. Codex has no equivalent. | Rename no longer types into the terminal. |
| F7 | Claude never sends `turn_id` (the field is `prompt_id`). `Stop` does not fire on interrupt. `SessionEnd` fires with `reason: "clear"` while the process keeps running. | Three assumptions in today's code are wrong. |
| F8 | Codex per-launch hooks hit a blocking trust dialog, and any change to the order or content of `~/.codex/hooks.json` re-triggers that dialog for every Codex session on the machine. Codex has no `--session-id`. | Only the production app may write that file, and as rarely as possible. |
| F9 | Upstream Ghostty parses OSC 7501 and drops it in the GUI (`src/termio/stream_handler.zig:388`); there is nothing upstream to merge. The fork has not modified any of the nine upstream files the forwarding change touches. | We write the forwarding, following the progress-report path hop by hop. |
| F10 | `macos/build.nu --action test` launches a host with the live bundle ID that runs the full Clawddy setup: it reads the live event files, rewrites the live `state.json`, and rewrites the `clawddy.workspace.*` preferences. An unfiltered `./build.nu test` runs the same Xcode tests. | No test may run until the test host is inert. |
| F11 | Two instances both rewrite the global hook files, and each agent event is then recorded twice. The status-line proxy and the hook script both fall back to the live status folder when their variable is unset. A second instance's startup sweep can delete the first one's launch script during a launch. | A dev build needs its own data root, no fallback paths, and no writes to global provider files. |
| F12 | Live data, re-derived by the reviewer: 69 agents (66 Claude, 3 Codex), 18 tasks in 4 projects, 24 agents bound only by the old `.session` file, 409 dead status files, one name collision group of 3 once tasks are flattened. These numbers drift as the live app is used. | Sizes the two migrations; counts are re-derived on the day. |
| F13 | The old app decodes a tasks-free `agents.json` as "no agents", drops unread state at once, and saves the empty list on its next change. | After the Phase B migration, rollback must restore the backup before the old app starts. |

## 3. Decisions

Made by the owner: remove tasks; leave `agent-cron` untouched; engine first, UI
second; run the refactored build side by side under a separate identity.

Defaults this plan assumes until the owner says otherwise:

- **D1.** Production Clawddy keeps bundle ID `com.mitchellh.ghostty` through
  Phase A, as today. Giving it its own ID is a separate step at the end of Phase B
  (B7), because it also changes the Dock tile plugin's preference suite, saved
  window state, notification history and permissions, and should not be mixed into
  the engine switch-over.
- **D2.** Cmd-, keeps opening Clawddy settings.
- **D3.** Task removal is the first change of Phase B, in one step.
- **D4.** Rename changes the Clawddy label at once. Claude receives it as `--name`
  at the next launch. Codex sessions are not renamed. Nothing is typed into a
  running terminal.
- **D5.** These Claude signals are dropped in Phase A because nothing reports them
  once hooks stop carrying turn activity: the separate "thinking" state (it shows
  as "working") and the permission-mode readout. Compaction and turn failure are
  kept, through hooks.
- **D6.** Answering the status query on every surface means Claude Code, in any
  Clawddy terminal, stops writing its spinner glyph into the tab title. Accepted.

## 4. Target design

- **Each fact has one source.** A provider table says, per provider, which source
  reports turn activity and which hook events are subscribed. The two sets never
  overlap. Every observation enters through one function,
  `AgentBridge.ingest(_:)`, which drops observations from another generation and
  events the table does not allow from that source.
- **Claude.** Turn activity (idle, working, waiting for permission, waiting for an
  answer, done) comes from the surface's program status. Hooks are carried only in
  the per-agent `--settings` file, with the agent id, generation and status folder
  as command arguments: `SessionStart` (session binding, also after `/clear`),
  `StopFailure` (turn failed), `PreCompact` and `PostCompact`. No agent variables
  are exported for Claude, and nothing is written to `~/.claude/settings.json`.
- **Codex.** Unchanged in behaviour until G4: hook events through the event file,
  identity in `CLAWDDY_*` variables, one entry set in `~/.codex/hooks.json`
  written by the production app only and only when its content would change.
- **Exit.** After the provider returns, the launch script prints one OSC 7501
  report with id `clawddy` carrying the exit status, unsets any agent variables,
  and starts the login shell. That report is handled as an event: it ends the
  generation, and every later report from that surface is ignored until the next
  launch. A provider's own `clear` only resets activity. Surface death also ends
  the generation.
- **Event file.** It stays, for hook events only, read by a file-level watcher
  that sees appends. Offsets live in memory and start at end of file.
- **State.** `AgentInstance` holds one `private(set) var runtime:
  AgentRuntimeSnapshot`, assigned only from the reducer's result.
- **Surfaces.** `AgentDetailViewController` is the only owner of live surfaces. It
  observes its surfaces and forwards close and status events to the bridge.
- **Viewed agent.** One stored value in the workspace model.
- **Persistence.** One `AgentDataRoot`, resolved once from the bundle, passed to
  everything, with no fallback path anywhere. Writes throw. A file that cannot be
  read is an error the user sees.

Deleted in Phase A: `BridgeMetrics`; the visual-audit mode; `AgentOrdering`;
`AgentProviderEventLedger` and the persisted offsets and last-applied
completions; the bridge's surface map; the runtime-field mirror; the global Claude
hook installer; the keystroke rename and its persisted queue; temp-dir launch
scripts; the provider protocol, registry and capability matrix; the legacy
decoders; the `PageList.zig` change.

## 5. Ground rules for execution

1. **No test runs before step P0.3 is merged**, neither `macos/build.nu --action
   test` nor an unfiltered `./build.nu test`. Steps P0.1 and P0.2 are verified by
   building only.
2. **One step, one commit, one worker.** Each step is done by one Opus subagent
   whose brief is the step's row plus the sections of `docs/clawddy-refactor/` it
   names. Steps never build in parallel: there is one external build root.
3. **Every step from P0.3 on ends with** `swiftlint lint --strict`, the Clawddy
   tests through `macos/build.nu --action test`, and a Release build with
   `--identity dev`. A step whose check fails is reverted, not patched forward.
4. **Workers never touch the live app.** They do not launch any app, do not write
   to `~/.config/ghostty-agents`, `~/.claude`, `~/.codex`, or the
   `com.mitchellh.ghostty` preferences, and quit nothing they did not start.
   Workers may run tiny CLI sessions in the spike harness when a step says so.
5. **Manual checks are done by the owner**, at the gates G0, G3, G4 and GA only.
   Each gate is a short checklist. No step depends on a manual check between
   gates.
6. **The reviewer is not the author.** The orchestrating session reads each diff
   against the step's acceptance check before the next step starts.
7. Project rules apply: no `try?` to hide errors, no assumed model names, builds
   only through the wrappers, Release only.

## 6. Phase 0: make development safe

| Step | Change | Acceptance |
|---|---|---|
| P0.1 | Add `agent-cron/` and `clawddy-review-shots/` to `.git/info/exclude`. Commit the current working tree (30 modified, 1 deleted, the untracked Clawddy sources and tests, and the plan documents) by file name on branch `clawddy/refactor`. Delete untracked `macos/macos/` (539 MB stray framework copy) and `prototype-workspace-b/` after the owner confirms. | Release build succeeds; `git status --short` is empty. Needs the owner's go-ahead to commit. |
| P0.2 | Read-only backup of `~/.config/ghostty-agents` (without `cron/`), `~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.codex/config.toml`, and an export of the `com.mitchellh.ghostty` preferences, to `~/.config/ghostty-agents-backups/<timestamp>-baseline/`. | The backup's `agents.json` decodes to the same agent count as the live file. |
| P0.3 | One commit, in this order inside it: (a) under XCTest, `ClawddyController.setup()` returns at once, before `reconcile`, and the workspace model gets no preferences store; (b) `--action test` always builds bundle ID `com.mitchellh.ghostty.clawddy-tests` into `<build root>/tests`, whatever other flags are given; (c) `AgentDataRoot`, resolved once from an Info.plist key set by build settings, a unique temp folder under XCTest, threaded through `AgentConfig`, the bridge, `AgentSessionStore`, `AgentHookRuntime`, `AgentMetadataRuntime`, `CodexProvider`, `AgentPreferencesStore` and the config-error view; the static paths and the app's own `GHOSTTY_AGENT_DATA_DIR` handling are deleted; a precondition (skipped under XCTest) fails the launch if the production bundle ID is paired with a foreign root or the reverse; a lock file in the root makes a second instance on the same root fail with a clear message. | Tests `testHostDoesNotStartClawddy`, `dataRootFromInfoKey`, `productionBundleRefusesForeignRoot`, `xctestUsesTemporaryRoot`, `secondInstanceOnSameRootRefuses`. First test run of the project happens here, with the live app running; afterwards the four `clawddy.workspace.*` values and the modification time of the live `agents.json` are unchanged and no second menu-bar icon appeared. |
| P0.4 | `macos/build.nu --identity dev`: bundle ID `com.mitchellh.ghostty.clawddy-dev`, name "Clawddy Dev", root `~/.config/clawddy-dev`, products under `<build root>/dev`, global hotkey off, updater off. | `plutil -extract CFBundleIdentifier raw` on the product; the production product is untouched. |
| P0.5 | No fallback paths and no shared folders: the hook script and the status-line proxy take their status folder as an argument and have no default; launch scripts live in `<root>/runtime/launch/` and the startup sweep covers only that folder; at app start the variables `GHOSTTY_AGENT_ID`, `GHOSTTY_AGENT_NAME`, `GHOSTTY_AGENT_PROVIDER`, `GHOSTTY_AGENT_LAUNCH_GENERATION`, `GHOSTTY_AGENT_STATUS_DIR` and the four `CLAWDDY_*` names are removed from the app's environment by name (the `GHOSTTY_AGENT_CRON_*` names belong to `agent-cron` and are left alone). | Tests `hookScriptRequiresStatusDirArgument`, `statuslineProxyRequiresStatusDirArgument`, `launchScriptsUnderRoot`; no `temporaryDirectory` reference left in `AgentManagement`. |
| P0.6 | Claude hooks move into the per-agent `--settings` file, all events that are hooked today, with agent id, generation and status folder as arguments; nothing is exported for Claude; the Claude global installer is no longer called. Codex keeps `CLAWDDY_AGENT_ID`, `CLAWDDY_AGENT_PROVIDER`, `CLAWDDY_AGENT_GENERATION`, `CLAWDDY_STATUS_DIR` and its global entry, matched by exact script path, rewritten only when its content would change, and only by the production identity: the dev identity never writes `~/.codex/hooks.json`. | Tests `claudeLaunchCarriesHooksInSettingsOverlay`, `claudeLaunchExportsNoAgentIdentity`, `devIdentityNeverInstallsGlobalHooks`, `codexInstallerIsNoOpWhenUnchanged`, `hookInstallerRemovesOnlyItsOwnScriptPath`; `knownWrong` behaviour "nested session rebinds its parent" is covered by `nestedClaudeCannotReportAsParent` (runs the real hook script without arguments). |
| P0.7 | Migration as a pure function `planAgentMigration(snapshot, mode)` with modes `cleanupV5`, `flattenV6`, `seedDevCopy`, and a thin IO wrapper (backup, apply in commit-point order, report). Preflight throws on anything unexpected; files of unknown kind are reported and kept; `cron/` is never planned. | Tests M1 to M20 (`groundwork.md` section 2.5). Rehearsal M21 on a copy of the live root: zero aborts, and counts equal to those re-derived the same day by `review_inventory.py`. |
| P0.8 | Dev seed, run before `AgentConfig` creates the root: if the dev root does not exist, read the live `agents.json` and the Claude agents' bindings through read-only opens and write a dev root containing the Claude agents only, each with a fork marker in place of its binding. A fork launches as `--resume <source> --fork-session --session-id <new uuid>`, so the new binding is known before the process starts. Codex agents are not seeded. | Tests `seedNeverWritesSource` (source copy is read-only), `seedContainsNoCodexAgents`, `forkLaunchAnnouncesItsNewSessionID`. |

**Gate G0** (owner, about 20 minutes, live and dev both running; checklist in
`groundwork.md` section 1.5, amended):

1. Start, use and stop one seeded agent in Clawddy Dev.
2. `~/.codex/hooks.json`, `~/.codex/config.toml` and `~/.claude/settings.json` are
   byte-identical to the P0.2 backup.
3. In the live status folder, no file belonging to the seeded agent's id changed
   (including its `metadata.json`).
4. The dev agent's new session id differs from the live agent's.
5. Option-Space opens the live palette; "Clawddy Dev" appears separately in
   System Settings, Notifications; a plain dev terminal has no `CLAWDDY_` or
   `GHOSTTY_AGENT_` variables; `~/.config/ghostty-agents/cron` is unchanged.

Nothing after G0 starts until all five hold.

## 7. Phase 1: pin behaviour, then remove dead weight

| Step | Change | Acceptance |
|---|---|---|
| P1.1 | Seams with today's behaviour as the default, one per commit: scheduler (clock, timers, delayed calls); IO executor (keeps today's queue-then-main hop exactly, including the one place that uses `DispatchQueue.main.async`); notifier; provider table closures; diagnostics sink. The surface host is not a constructor parameter: `activateAgent` already receives the detail controller per call, so its parameter type becomes a protocol that the controller already satisfies, and the bridge's heartbeat asks the host for exited processes. | Existing tests pass after each commit. |
| P1.2 | Test harness (temp root, manual scheduler, inline IO, fake surface host, recording notifier, fake providers) and the characterization tests of `groundwork.md` section 3.4, minus the two that Phase 0 already fixed (`…sweepDeletesForeignClawddyScripts`, `…installerKeepsEntriesForNonDefaultRoot`). One integration test feeds the harness from the real hook script. | All pass on the engine as it is after Phase 0. |
| P1.3 | Deletions with no behaviour change: `BridgeMetrics` and its 29 call sites; the visual-audit mode; `AgentOrdering`; the unused free `atomicWrite`; `bridge.surfaceView(for:)`; the `launchTime` property; the `GHOSTTY_AGENT_NAME` fallback; seven unused `AgentSessionMetadata` fields; the mentions of these in `README.md` and `docs/CLAWDDY_ARCHITECTURE.md`. | P1.2 tests unchanged; each symbol has no remaining reference in `macos/`. |
| P1.4 | Two deliberate behaviour changes, each its own commit: revert `src/terminal/PageList.zig` to upstream (integrity failures panic again in builds with slow runtime safety); restore upstream's clearing of delivered notifications at quit. | `git diff upstream -- src/terminal/PageList.zig` is empty; library builds. |
| P1.5 | Delete the legacy decoders the migration preflight proves unused: `legacyUnreadAgents`, `.forkFrom`, snake_case event keys, `PersistedAgent.legacyName`, `migrateStatusFiles`, decode defaults. The `.session` fallback stays until switch-over. | P1.2 tests unchanged; preflight test. |

## 8. Phase 2: deliver program status from Ghostty to Swift

The change list with code is `docs/clawddy-refactor/program-status-forwarding.md`.
Summary: an apprt action `program_status` whose payload is one pointer to a
decoded report; the matching C declarations; a surface message carrying the state
and a copy of the validated body; in the stream handler, forwarding of reports, a
reply to the query built from the parser's `query_reply` with the query's own
terminator, and one `clear` on full reset; decoding on the main thread in
`Surface.zig`; a no-op arm in the GTK apprt; in Swift, a value type, its
conversion, and a notification posted synchronously on the main thread with the
surface as its object, plus one debug log line per report.

Amendments to that document: the observer belongs in `AgentDetailViewController`,
not in the bridge (its section 10 is superseded by P3.2); and the handler must
never free a surface while it runs, because it executes inside the app tick.

Three commits: core and header; Swift delivery; nothing Clawddy-specific.

**Gate G2** (worker, automated). With `GHOSTTY_ZIG` set to Zig 0.17: Zig tests
pass with `-Dtest-filter="program status" -Dtest-filter="ghostty.h"`; the library
builds; the regenerated framework header contains `GHOSTTY_ACTION_PROGRAM_STATUS`;
the dev app builds; the Swift conversion test passes. The design has not been
compiled; if it does not compile as written, the worker corrects it against
neighbouring code and reruns G2.

**Gate G3** (owner, dev app, about 15 minutes). In a plain dev terminal:
`printf '\e]7501;?\a'` is answered; a hand-written report and `printf '\ec'` each
produce one log line. In a dev agent created in standard mode (so that permission
prompts appear): a real Claude session logs `idle`, `working`, `blocked` with a
permission prompt, `done`, and `clear` on `/exit`, with no "unknown action"
warnings.

Fallback if G3 fails for a reason that cannot be fixed in the fork: Phase 3 runs
without P3.5 and without the in-band half of P3.7; Claude's activity events are
added back to its per-agent hook list, and the product is still better in every
other respect.

## 9. Phase 3: the engine

Each step keeps the P1.2 tests green except the `knownWrong_` tests it names.

| Step | Change | Acceptance |
|---|---|---|
| P3.1 | Single runtime snapshot: `private(set) var runtime`; views read computed accessors; every write outside the reducer is removed. The aggregate state is published at startup. | Tests `applyIsOneObservableMutation`; `knownWrong_aggregateNotPublishedAtStartup` flipped. |
| P3.2 | Single surface owner: the bridge's surface map and its `@unchecked Sendable` wrappers are deleted; the host observes close and status notifications and calls `bridge.surfaceClosed(id, generation, processAlive)` and `bridge.programStatus(id, generation, report)`. A host that refuses to present leaves the agent in a failed-to-start state. | Tests `surfaceDeathFromHostRemovesOnlyRecord`; `knownWrong_hostRefusingPresentLeavesAgentLaunching` flipped. |
| P3.3 | Close and quit confirmation: closing an agent surface whose process is alive asks first; quit counts running agents and says "N agents are running. Their sessions can be resumed." | `knownWrong_closeWithLiveProcessDestroysWithoutConfirmation` flipped; test `quitWithRunningAgentsAsks`. |
| P3.4 | Status seam: `AgentStatusObservation` and `ingest` replace the inline ingestion; the event file reader becomes `AgentHookJournalSource` with a file-level watcher (FSEvents with file events on the status folder) that sees appends, in-memory offsets that start at end of file, and compaction. The 10-second polling heartbeat, `AgentProviderEventLedger`, and the persisted offsets and last-applied completions are deleted. | Tests `ingestDrivesSameTransitionsFromEitherSource`, `eventsPresentAtStartupNeverApply`, `compactionNeitherReplaysNorLoses`, `appendIsSeenWithoutPolling` (real watcher, temp folder). |
| P3.5a | Evidence before code. With the spike harness, capture and add to `cli-facts.md`: a prompt submitted within 2 s of `done` (does the late summary `done` still arrive, and where); a failing turn (does `StopFailure` fire, is `error` reported); a compaction; Ctrl-Z and an external editor; a turn longer than 120 s. | The captures exist; any that contradict the mapping below change P3.5 before it is written. |
| P3.5 | Program-status source for Claude, root record only: `working` starts or continues a turn; `blocked` with `permission`, `question`, `auth` gives the three waiting states; `done` completes the active turn, and a `done` with no active turn only updates the summary text; `idle` ends an active turn as interrupted, with no completion; `clear` resets activity; `error` fails the turn. Records with any other id are ignored except `clawddy` (P3.7). A `working` that is followed by `idle` or `clear` within 250 ms raises no effects. The first report marks the provider alive; with none within 10 s the agent shows today's "status unavailable" state (this includes the untrusted-folder dialog, as today). The 120-second "status delayed" rule does not apply to this source. Notifications: `done` and `blocked`, once per state change, plus the failure notification from the `StopFailure` hook; each also posts an accessibility announcement. Claude's hook list shrinks to `SessionStart`, `StopFailure`, `PreCompact`, `PostCompact`. The handler never destroys a surface synchronously. | Harness tests written from the captured byte sequences, one per row of F1, F2 and P3.5a, including `secondDoneIsNotASecondCompletion` and `reportsAfterExitAreIgnored`. |
| P3.5 amendments | From the P3.5a captures (`cli-facts.md`, last section), these override the row above where they differ: (1) a `working` that follows a `PreCompact` hook with `trigger: "manual"` is compaction, and its closing `done` is not a completion and raises no notification; `PostCompact` is not used for this because it can arrive after the `done`. (2) The 250 ms rule also covers `working` followed by `done` (the `/exit` confirmation dialog), but never `error`, which can arrive after 106 ms. (3) A `done` that carries `msg` never completes a turn; it only updates the summary. (4) Claude does report `error`, 15 to 27 ms before `StopFailure`; the failure notification fires once per failed turn, whichever arrives first. (5) Suspend and the external editor report nothing; the last state stays. (6) `SessionStart` sources to accept in P3.6: `startup`, `resume`, `clear`, `compact`, `fork`. | One harness test per amendment, from the captured bytes. |
| P3.6 | Claude launch and identity: `--session-id <new uuid>` for a new session, `--resume <id>` after, `--resume <source> --fork-session --session-id <new>` for a fork, `--name <label>` always. The `SessionStart` hook rewrites `<id>.session.json` on every start, including `source: "clear"`. A resume that fails because the session no longer exists becomes an explicit failed state offering "Start fresh". The keystroke rename and its persisted queue are deleted. | Tests `claudeNewLaunchChoosesSessionID`, `claudeForkAnnouncesNewSessionID`, `sessionStartHookRebindsAfterClear`, `missingSessionIsExplicitFailure`; `knownWrong_renameTypedIntoFallbackShellAfterExit` removed with the feature. |
| P3.7 | Exit and identity: after the provider returns, the launch script prints the `clawddy` exit report, unsets the Codex agent variables, then starts the login shell. The exit report ends the generation; later reports from that surface are ignored. The file record `ProviderExited` is deleted for Claude and kept for Codex until G4. | Tests `exitReportEndsGeneration`, `manualClaudeInFallbackShellDoesNotReviveAgent`, `fallbackShellHasNoAgentIdentity` (runs the generated script and inspects `env`). |
| P3.8 | Provider table replaces `AgentProviderAdapter`, `AgentProviderRegistry` and `AgentProviderCapabilities`; one event table per provider, also inside the hook script; `prompt_id` replaces `turn_id`; `SessionEnd` no longer means process exit. | Tests `providerTableMapsEveryHookEvent`, `sessionEndWithReasonClearKeepsAgentAlive`. |
| P3.9 | Fail loud: `atomicWrite` throws and syncs the temp file before the rename; a corrupt `preferences.json` falls back to standard mode and shows the error; an unreadable binding is an explicit failed state; an undecodable record is logged with its offset; the hook script appends its own failures to `status/hook-errors.log`. | The `knownWrong_corrupt…` tests, `knownWrong_undecodableRecordDroppedSilently` and `knownWrong_emptyTurnIDKeptAsEmptyString` flipped. |
| P3.10 | One removal path that deletes `<uuid>.*` for a removed agent, used by every removal route. | `knownWrong_externalDeleteLeavesStatusFiles` flipped. |
| P3.11 | Single viewed-agent owner: one stored value; the bridge receives an `isViewed` closure; the other four copies are deleted. | Activation tests pass; test `completionWhileViewedLeavesNoUnread`. |
| P3.12 | Move what does not belong in the bridge: display-state presentation to the view side, launch-script construction to the provider table. No new types. | P1.2 tests unchanged; `AgentTerminalBridge.swift` is under 1,000 lines. |

**Gate G4** (owner, Codex). With a Codex model that works on the owner's account:
capture a full session in the spike harness and in the production app after
switch-over. If `blocked` and `done` arrive and the startup `working` can be told
apart from a real turn, Codex moves to the program-status source in a follow-up
step and keeps hooks only for its session id. If not, Codex stays as it is. Phase A
is complete either way.

## 10. Gate GA: acceptance and switch-over

1. **Soak.** The owner uses Clawddy Dev for real work for at least three working
   days, next to the live app. Dev agents are forks of live sessions; work done in
   them stays in Claude's own session store and can be resumed by id, but the dev
   agent list is not merged into production. Any wrong state seen is a bug that
   blocks acceptance and gets a test.
2. **Manual checklist** (owner, once, on the final dev build): Cmd-W on a running
   agent asks; Cmd-Q with running agents asks; an interrupted turn returns to
   idle; a completion while viewing leaves no unread mark and one after switching
   away does; killing the provider shows "Exited" at once; `/clear` then Restart
   resumes the post-clear session; a `claude` typed by hand in the shell after
   exit does not revive the agent.
3. **Review.** The diff against `upstream` outside
   `macos/Sources/Features/AgentManagement` is read line by line.
4. **Switch-over**, with the live app quit: fresh backup as P0.2 plus a copy of
   `~/Applications/Clawddy.app`; rerun the rehearsal on a copy of the live root and
   note its counts; run `cleanupV5` on the live root and compare (zero aborts, same
   counts); archive `~/.config/clawddy-dev` into the backup folder; install and
   start the production build. Its first Claude launch removes the old global
   Claude hook entries by exact path; its first Codex launch rewrites the Codex
   entry once, and Codex asks for one hook review.
5. **Rollback.** Quit the new app, put the backed-up `Clawddy.app` back, start it.
   The old app reads the cleaned data and reinstalls its own hook entries at its
   first agent launch (checked against the code). Sessions started under the new
   app after `/clear` are bound by the new binding files, which the old app also
   reads.
6. The `.session` fallback, the last legacy path, is deleted in the next commit.

## 11. Phase B: the product

Detailed only after Phase A is accepted, against the engine that exists then.

| Step | Change | Gate |
|---|---|---|
| B0 | Snapshot harness as a test target, with the `List` rendering problem solved, so later steps are judged on pixels. | Sidebar and agent list render in the snapshots. |
| B1 | Remove tasks: schema v6, `flattenV6`, model, policies, drag payload, views, palette and tests in one change. | M1 to M21; rehearsal on a copy of the live root; rollback restores the backup before the old app starts (F13). |
| B2 | Two columns: a sidebar outline of projects and agents; the terminal gets the rest. | Terminal width at the 900-point minimum window is at least 640 points. |
| B3 | Six states (not running, starting, working, waiting for you, done, problem with a reason), one glyph per state, "done" out of the attention badge and the orange icon, "Resume" where it is a resume, header and placeholder no longer repeating each other. | The state legend stays distinguishable under the deuteranopia simulation. |
| B4 | Keyboard: no shortcut the terminal consumes first; a configurable, visible global hotkey; focus-list and next-waiting shortcuts. | Each shortcut works while the terminal has focus. |
| B5 | Contrast, text scaling, VoiceOver wording, copy pass. | VoiceOver walk-through of the core flows. |
| B6 | One architecture document that matches the code; one build instruction. | Every file and type it names exists. |
| B7 | Own bundle ID for production (D1), as its own switch-over with its own backup. | Preferences, window state and Dock tile settings carried over; one permission prompt. |

## 12. Risks

| Risk | How it is caught | Response |
|---|---|---|
| A test run or dev build touches live state. | Rule 1; P0.3's first test run is itself checked against live state; G0. | Stop; fix isolation before anything else. |
| The Zig change does not compile as designed. | G2, before any Swift depends on it. | Correct against neighbouring code; rerun G2. |
| Claude's reports differ from the captures in a case not yet captured. | P3.5a captures the open cases before P3.5 is written. | The mapping follows the captures. |
| Claude changes its OSC 7501 behaviour in an update. | The harness reruns in minutes; P3.5 tests are written from captured bytes. | The event-file source remains in the product; adding Claude's activity events back to its hook list is a table change. |
| An agent shows "working" forever. | Tests `exitReportEndsGeneration` and surface-death tests; GA checklist. | The exit report and surface death both end the generation. |
| A step silently changes behaviour. | P1.2 tests after every step. | Revert the step. |
| The migration meets data it does not expect. | Preflight throws; rehearsal on a copy the same day. | Nothing is written before the commit point. |
| Codex's trust dialog is triggered for all Codex sessions. | Test `codexInstallerIsNoOpWhenUnchanged`; G0 item 2. | Only production writes the file, once. |
| Upstream ships its own program-status action. | The next upstream merge conflicts on the same lines. | Take upstream's core; rewrite the Swift conversion and the action case. |

## 13. What is still unproven

- That the Phase 2 Zig and Swift compile as designed (G2).
- That reports from a real Claude reach an agent surface in the built app (G3).
- Claude's behaviour for: a prompt within 2 s of `done`, a failing turn,
  compaction, suspend, an external editor, long turns (P3.5a).
- Codex `blocked` and `done`, and whether Codex hooks receive the environment in
  every sandbox mode (G4).
- That hosted test runs set `XCTestConfigurationFilePath`; P0.3's own test fails
  if they do not.
- The size of the upstream merge conflict; upstream was not fetched.

## 14. What the adversarial review changed

Test isolation now lands as one commit before any test may run. The status-line
proxy lost its fallback path. The dev build writes no global provider file, and
Claude's hooks moved into per-agent settings in Phase 0, which also closes the
nested-session bug structurally. Forks announce their session id. The switch-over
archives the dev root. Failure and compaction keep their hooks. A second `done`
is not a second completion. Only the launch script's exit report ends a
generation. The event file keeps a real watcher. Manual checks moved to four
owner gates. The bundle ID change moved out of the engine switch-over.

## 15. Supporting documents

In `docs/clawddy-refactor/`:

- `groundwork.md`: identity and isolation, data inventory and migration (tests M1
  to M21), bridge seams and the characterization test list, verified deletions
  with call sites, step ordering. Where it and this plan differ, this plan wins.
- `program-status-forwarding.md`: the Phase 2 change list with code, threading,
  edge semantics, tests, commands and merge cost.
- `cli-facts.md`: what Claude Code and Codex were observed to do, with captured
  byte sequences and hook payload fields.
- `spike-harness/`: the PTY harness that reruns those observations.

Screenshots from the UX review are in `clawddy-review-shots/`.

Out of scope: `agent-cron` (it keeps running and its folder is never touched),
the deployment target, and any change to the terminal core other than Phase 2 and
the `PageList.zig` revert.
