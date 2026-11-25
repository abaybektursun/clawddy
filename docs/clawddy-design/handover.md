# Clawddy redesign: hand-over notes

## After the owner's first run (25 November)

The build to run is a stable copy that later builds do not replace:

```sh
env -u NO_COLOR open -na /Volumes/Xcode/GhosttyBuilds/ghostty/handover/Ghostty.app
```

Builds now go to a separate root so a running copy is never replaced under the person:
`macos/build.nu --configuration Release --action build --build-root /Volumes/Xcode/GhosttyBuilds/ghostty/macos-next`
(products in `macos-next/dev/products/Release/`), and `nu macos/harness.nu start --app <path>` picks the app a
harness run uses. A harness run keeps its window frame and preferences in `<harness dir>/preferences.plist`,
never in the Dev app's own preferences.

Commits after the notes below were written:
- fc03f337b the window owns its opening frame (a normal launch opened it 1 point wide)
- 048ded65e the plus button and ⌘N open the floating new-agent line everywhere, home included
- 3db293f5a projects are managed in the top bar: right-click menu, drag to reorder, "N more" submenus
- f458086e1 one owner of the keys after a terminal stops
- 489f59ee3 a dragged item is held where it was pressed

The working notes referred to below as `scratchpad/build/...` are kept in
`/Volumes/Xcode/GhosttyBuilds/ghostty/redesign-notes/`.

Branch `clawddy-redesign`. The last commits of this pass:
- b1cdde80c fixes from the whole-product review (final-review-rulings.md 1–17)
- afaf2979f review fixes to motion and the terminal stack (neon/review-s10.md)
- 450dda27a the last frames over budget
- 4bc0406e0 what the hand-over checks found: tile drawing and the refresh clock stop while the window cannot be seen

The last narrow pass (Claude Opus 5.5):
- ebc26d5e2 fixes from the last review (saving, quitting, settled agents, keys): `neon/review-final.md`, rulings in the "Last review" section below
- 01aff72e4 the walk visits an agent once for each time it starts waiting (flows.md 6.6 rewritten)
- adde8b855 tiles that grow show their new screen lines before the density change ends
- a0c2f0801 entering a terminal: the frame of the key holds only what it shows
- 1383fdb56 nothing of home shows inside a terminal: home's edge pills go and come with home; the header is hidden at
  home; `AgentWindowView.setRegions` is the one place that says what shows (cause below)

## agy, the Antigravity CLI, as a third CLI (branch `clawddy-agy`)

What was added: an agent can run `agy` (shown as "Antigravity") beside Claude Code and Codex, with the same tiles,
typing line, waiting, settling, resuming and restart behaviour. The plan is `agy-plan.md`; the facts about agy
1.5.17 it is built on are in `docs/clawddy-refactor/cli-facts.md`, "agy".
- `AntigravityProvider.swift`: hooks from a per-agent folder added with `--add-dir` (nothing of the owner's is
  written: not the project, not `~/.gemini`), the presence-lock check before a resume, the check that a resumed
  conversation still exists, no `--settings`, never Control-C.
- `AgentReportRules` in `AgentProvider.swift`: the per-CLI values where agy's status reports differ (a `done`
  with a message ends its turn; its sign-in report counts after 2 s; its `working` carries no step; and so on).
- Screen readers for agy's input box and menus (`AgentTail.swift`, `AgentTerminalInput.swift`).
- Everywhere a CLI is chosen, seen or searched for: "New Antigravity agent" in the Agent menu and find (one
  command per CLI, generated from `AgentProviderID.allCases`), "New agents use", the line's chip, "Starting
  Antigravity…", the settings window (one row per CLI), the start mode's words ("Dangerously skip permissions",
  agy's own flag), and every sentence that names the CLI. agy has no `/login`, so its expired login says "Open it
  and sign in again."
- `preferences.json` keeps one start mode per CLI in `defaultStartModes` (schema 2); a file of the older shape
  (`claudeCodeDefaultStartMode`, `codexDefaultStartMode`) loads with its values and is rewritten in the new shape
  at the next save.
- The stand-in `macos/Tests/AgentManagement/StandIns/agy`, built from captured bytes; `check.py agy agy_screens`.

How it was proven: unit tests (`AgentAntigravityTests.swift` and the per-CLI tests named in the stage notes), the
stand-in checks, and a harness scene with one agent of each CLI in one project taken through working, a question
and done, pictured at home and inside (`/Volumes/Xcode/GhosttyBuilds/ghostty/harness/agy-stage4/shots/`).

Not proven yet: the real `agy` under the app (stage 5 of the plan).

## Build

From the repository root:

```sh
export GHOSTTY_ZIG=/Volumes/Xcode/GhosttyBuilds/ghostty/tools/zig-0.17.0/zig
macos/build.nu --configuration Release --action build
```

This builds Clawddy Dev (bundle ID `com.mitchellh.ghostty.clawddy-dev`), optimized Release, never Debug.
The Zig library only needs rebuilding (`./build.nu -Demit-macos-app=false`) when code outside `macos/` changes;
nothing outside `macos/` changed in this pass.

- App: `/Volumes/Xcode/GhosttyBuilds/ghostty/macos/dev/products/Release/Ghostty.app` (shows as "Clawddy Dev")
- Library check: `macos/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a` is 303,967,360 bytes
  (optimized; a debug library is over 430 MB). `macos/GhosttyKit.xcframework` is a symlink to
  `/Volumes/Xcode/GhosttyBuilds/ghostty/xcframework/GhosttyKit.xcframework`.
- Unit tests: `macos/build.nu --action test` (about 4.5 minutes). On 1383fdb56 (the same code as the last full run): 771 test functions passed, 1 skipped, 0 failed
  (on a0c2f0801: 770 passed, 908 "passed on" lines in the log, because each argument of a parameterized test prints its own line, 138).
  Earlier stages counted those lines (871 at S9, 881 at S10); the last pass counted functions (754 passed + 1
  skipped = 755). Count functions with `grep -oE "Test case '[^']+' passed" <log> | sort -u | wc -l`.

## Launch it normally (not under the harness)

```sh
env -u NO_COLOR open -na "/Volumes/Xcode/GhosttyBuilds/ghostty/macos/dev/products/Release/Ghostty.app"
```

It runs beside the live app. Its data lives in `~/.config/clawddy-dev` (`agents.json`, `preferences.json`,
`status/<agent>.record.json`, `.session.json`, `.screen.txt`, the event journals). The production identity
(`--identity production`, data in `~/.config/ghostty-agents`) is built only at switch-over, with the live app
quit; see `macos/AGENTS.md`. Nothing was built or launched as production in this pass (its products folder was
last written on 14 November).

## Run the harness on a scene

```sh
nu macos/harness.nu start macos/Tests/AgentManagement/Scenes/prototype.json /Volumes/Xcode/GhosttyBuilds/ghostty/harness/<run>
nu macos/harness.nu send '{"state":true}'            # or {"key":"cmd+j"}, {"type":"text"}, {"reopen":true} ...
nu macos/harness.nu shot /Volumes/Xcode/GhosttyBuilds/ghostty/harness/<run>/shots/x.png
nu macos/harness.nu stop
```

`nu macos/harness.nu --help` documents the scene format and every request. `--real` runs the real CLIs from
the login-shell PATH. Scenes used here: the prototype scene; 40 agents as in S10
(`scratchpad/build/s10/home-40.json`), the same split into two projects (`scratchpad/build/final/scene-40.json`),
all 40 finished and idle (`final/scene-40-idle.json`), and an empty data folder (`final/empty-scene.json`).
New harness requests this pass: `reopen` (AppKit's Dock-click entry point, `applicationShouldHandleReopen`);
`state` reports `windowClosed`, `terminalWindows` and `permissionRequests`; `timed` also reports `work`
(the key's handling plus the commit of what it changed).

## Pictures and strips worth looking at

This pass (`/Volumes/Xcode/GhosttyBuilds/ghostty/harness/`):
- `final-empty/shots/launch.png`, `final-empty/shots/reopened.png`: first launch on an empty data folder, and
  after ⌘W and a Dock reopen.
- `final-reopen/shots/reopened-inside.png`: reopened inside the agent it was closed on.
- `final-strips/`: every frame (1/120 s of animation time) of `settle-home`, `undo`,
  `interrupt-settle-then-undo-at-30ms`, `density`, `density-twice`, `reorder-key`,
  `interrupt-enter-then-leave-at-60ms`, `leave-then-project-switch-at-60ms`, `settle-inside`, `screen-lights`,
  `cancel-start`, `line-grows`.
- `probes/work/scratch/final-real/shots/1-working.png` … `5-continued.png`: the real Claude Code run.
Earlier stages: `s10-strips/` (enter, leave, palette, new tile, project switch, Reduce Motion), `s9-pics/shots/`
(walk, rename, find), `s8/shots/review`, `s7-shots/`, `s5/shots/s6/` (home at every density, wide, minimum).

## Known differences from the design

- Names: line breaks and tabs become spaces rather than vanish (the ruling says "removed"; deleting them would
  join words; flows.md 6.9 says spaces). Zero-width characters are removed.
- A launch past 30 s closes its terminal only when it is stuck with nothing on screen; a terminal showing a
  dialog (Claude's trust question, Codex's update question) keeps its terminal so the person can answer it.
- With the agent window closed, the window-opening Agent menu items act from the open menu; their keys act only
  in the agent window (shortcuts.md rule 5), so ⌘N from a plain Ghostty window opens a Ghostty window.
- ⌃⌘F (the system's full screen) is not claimed in the agent window; Ghostty's other unnamed default chords are.
- From S9, still open: find over 500 stored agents has a p95 near 9.5 ms.
- The settings window (⌘,) still sets a start mode per CLI while the Agent menu sets one for all of them: a
  known inconsistency, left as it is (last review ruling 10).
- Ghostty's own menu commands for plain terminals (New Tab, Quick Terminal, Close All Windows) and its Dock menu
  are unchanged (last review ruling 10).
- Undoing a settle during the walk makes that agent the next stop (final review ruling 5), as flows.md 6.6 says.

## Home and inside: what shows (fixed after the coordinator found it in the enter strip)

Home's "N waiting below/above" pill stayed on screen inside a terminal, over the input line, until the waiting
count or home's scroll next changed. Cause: the pill's visibility was computed only in `updatePills` (on a waiting
change or a scroll), from home being hidden at that moment; entering hides home at the motion's end, and nothing
asked again. This predates a0c2f0801 (that commit did not touch the pills or `setRegions`); a scene where the
waiting count keeps changing hid it a moment later, which is why a picture one second after entering looked clean.
Now `setRegions` decides every region (home, the line, the pills; the list, the header, the screen), the pills
fade out and back with home in the motion, and the header is hidden at home. Test:
`AgentInteractionTests.MotionReview.nothingOfHomeShowsInsideAndNothingOfInsideAtHome` (Return, leave, open on
purpose, find inside, a project whose view is home and back, the walk, settle inside, close and reopen; a click
where the pill was reaches the terminal). Harness: `state.interface.regions`; pictures one second after each way in
and out on the 40-agent two-project scene in `/Volumes/Xcode/GhosttyBuilds/ghostty/harness/last-regions/shots/`
(`regions.json`, `bottoms.png`); 200 enter/leave/switch keys in 27 quick bursts (gaps 0–60 ms, `last/burst.py`):
what shows always equalled the model, list and header filled for the agent shown, 0 failures. The movement soak
now fires such bursts too. Strips (40 agents and the 7-agent walk scene, with first, 50 ms and last frames at full
size): `/Volumes/Xcode/GhosttyBuilds/ghostty/harness/last-strips-40/` and `last-strips-7/`. Leaving, frames up to
50 ms show the shrinking terminal over bare canvas (home comes in after 50 ms, as flows.md 7 says).

## Last review (`neon/review-final.md`), one line per ruling; every finding was verified in the code and held

1. Saving: memory is the truth; `lastConfigData` changes only after a write succeeded; a failed write of
   agents.json, a record or a last screen is retried with the next change and at quit, and the top bar keeps
   "Could not save your changes. Check the disk; they are kept while Clawddy is open." until one succeeds; the
   watcher reads an outside edit only when our writes are done and nothing is unsaved. Tests:
   `AgentLastReviewTests` (two config tests, the top-bar notice).
2. Older data: an unreadable `state.json` is moved to the backups and the app launches and says so; an unreadable
   record stops only its agent (a problem naming the file; nothing launches or sends to it); fork markers deleted.
3. Quitting: Clawddy's question whenever an agent works or waits its turn to start, whatever Ghostty's settings and
   with or without a window, asked alone. Harness: `{"quitQuestion":true}` reports it (the harness's own `quit`
   does not ask). Driven: five cut-off agents continuing → asks "5 agents are working…"; nothing working → asks
   nothing.
4. The agent window shows at launch whatever `initial-window` says; a folder opened with the app is added as a
   project, as a drop; files keep Ghostty's behaviour. (Not driven: a real `open -a` would start a second app
   instance beside the harness.)
5. Settled means stopped: one check (`AgentBridge.reaches`) on every launch and send path; settling takes the agent
   off the start queue, continuations, interrupt-and-sends and held sends. Driven: settled while queued after a
   restart → never launched, no prompt recorded, a send refused; the other four continued.
6. A held ⌘V delivers the clipboard text of its key press (test with a private pasteboard).
7. No bell and no command-finished notice from an agent's terminal; plain Ghostty terminals keep both (test).
8. Full screen: the agent window answers Window ▸ Toggle Full Screen / ⌃⌘F and Ghostty's own full-screen key from
   its terminal (test with the window's toggle replaced; not driven in the harness, which would put a window into
   full screen on the owner's display). Ghostty's search field over a terminal keeps its keys (⌘G, ⇧⌘G, ⇧⌘F).
9. Motion: settle inside then undo within the shrink ends the motion at once; a reorder during a density change
   ends the clamp; a list drag ends when its row goes. All three are in the movement soak (`last/soak.py`).
10. Unchanged, as ruled: Ghostty's plain-terminal menu commands and Dock menu; the settings window's per-CLI start
    modes (known inconsistency above).

## Not proven

- Real Codex turns: no Codex turn can complete on this machine (the owner's default model is refused; no model is
  ever named). Codex is proven against the stand-in only.
- The Dock badge without notification permission on this macOS version: the harness has no Dock; the code sets
  the badge label and asks nothing.
- Turning notifications on (it would ask the system for permission, which is not allowed here); their banner,
  and that no sound plays, are proven only by the code path.
- A real Dock click and AppKit's first activation (the harness app never becomes active): the harness calls the
  same `applicationShouldHandleReopen` and the same `showWorkspace`.
- The real window close button and the system's occlusion change on close (the harness stands in by clearing
  `forcesTerminalsVisible`).
- The secure-input mark's picture (its focus is tested; the mark itself was not pictured).
- Real usage-limit and login-expired payloads (stand-in only).
- The zero-size scale division the motion review named (`SurfaceView.viewDidChangeBackingProperties`): judged not
  reachable through the stack (the window's minimum gives a 460 pt screen and terminals are added after an IO
  round trip, after the first layout), so not guarded.
- 120 Hz on an external display, Intel hardware, Increase Contrast, other themes (no colour code changed here).

## What the redesign removed or changed (read before switching the production app)

- The sidebar interface is gone: home is a grid of tiles per project; inside shows one terminal with the project's
  list. Tiles show terminal text, not live terminals.
- The menu bar status item (waiting count and queue) is removed; the top bar and the Dock badge carry the count.
- Notifications are off by default ("Notify when an agent is waiting" in the Agent menu asks for permission when
  turned on); none makes a sound; an agent's terminal posts no desktop notification of its own (Claude Code's own
  terminal notifications from agent terminals are dropped).
- At launch and on a Dock click the app shows the agent window, never a plain Ghostty window; a plain terminal is
  File ▸ New Window (⌘N works for that only outside the agent window).
- Removed commands: Fork (pending fork markers on disk are ignored), Stop agent, Remove agents not used in 30
  days, Continue an earlier conversation, Go to project; "Show agents" is back as the Agent menu's first item.
- In the agent window ⌘D is Settle (Ghostty's split right elsewhere), ⌘J walks waiting agents, ⌘W closes the
  window (agents keep running), and Ghostty's tab, split, redo and inspector keys do nothing. An agent terminal's
  context menu offers only Copy, Paste, Reset Terminal and Read-only.
- Settle replaces delete: settled agents stay findable (find "settled …"); removing a project settles its agents
  and keeps them on disk, with undo.
- At first launch of the redesign, saved agents that are neither running nor unread start settled (the old
  `state.json` is folded and moved to `<data root>-backups/<date>-state-json/`).
- Old `<agent id>.fork.json` markers (forks never opened) are deleted at start by the state fold; nothing reads them.
- An unreadable `state.json` of an older build no longer stops the launch: it is moved to
  `<data root>-backups/<date>-state-json/state.json`, the top bar says so for 12 s and the log names the folder.
- Codex: the global `~/.codex/hooks.json` writer is gone; each Codex launch passes its own notify program, which
  also runs a `notify` already set in the owner's Codex config. Production still removes old Clawddy entries from
  Claude's global settings at start, as before.
- After a restart, agents cut off mid-turn continue by themselves (at most three starting at once), with the
  message labelled "[Sent by Clawddy after a restart, not typed by you]"; a fourth cut-off in a row stops.
- The Option-Space hot key (production only) is unchanged.
- `agents.json` is now written off the main thread in order; quitting waits for the writes. A write that fails
  shows an error and keeps the change in memory (it used to undo the change).

## Measurements (40-agent scene, 32 stand-ins printing; `final/perf.py`, 30 rounds, two runs each)

`work` = the key's handling plus the commit of what it changed (median / p95 ms). Files: `last/perf-*.json`,
`last/ab.out`, samples `last/sample-*.txt`. The machine was loaded during this pass (load average 9 at the start,
20–39 later, from Spotlight and other apps); settle and undo, whose code item 1 does not touch, are the control.

| key | start of pass, run 1 / run 2 (load 9) | without item 1 (load 30–39) | final, run 1 / run 2 (load 21–27) |
|---|---|---|---|
| enter | 10.08 / 18.55, 12.26 / 17.83 | 15.12 / 25.80, 16.60 / 18.94 | 3.12 / 5.91, 2.93 / 5.71 |
| leave | 10.26 / 11.80, 11.60 / 15.29 | 17.42 / 20.01, 17.43 / 20.62 | 3.46 / 5.84, 3.40 / 6.77 |
| switch | 7.17 / 10.80, 9.46 / 12.31 | 11.57 / 13.70, 11.60 / 13.52 | 3.82 / 7.85, 4.03 / 7.10 |
| settle | 4.50 / 5.09, 5.16 / 6.99 | 8.02 / 8.78, 7.47 / 8.59 | 4.40 / 4.79, 8.39 / 9.16 |
| undo | 5.06 / 5.61, 6.17 / 7.43 | 8.97 / 10.91, 5.91 / 12.75 | 5.17 / 5.60, 9.33 / 10.19 |

What made the difference (item 1, sampled before and after): no SwiftUI host while the shown terminal has nothing
to overlay (its layout and per-terminal rebuild were about 17 % of the key's work); the list, header, line, the
tiles' focus look and the left tile's screen filled after the key's frame is committed (they show only after
50 ms); the window view no longer asks for a layout on every show, so the key's frame often has no window layout
pass at all, and with it no walk of the view tree for an Auto Layout engine. Not done: moving hidden terminals
under a container AppKit would skip (it would take terminals out of their superview, against the stack's
invariant), so the walk still costs about 1 ms whenever a layout pass runs. Still over budget: settle and undo
at p95 in the second final run (9.2 / 10.2 ms, during a load spike; 4.8 / 5.6 in the first).

Soaks on the final build (1383fdb56): stack soak (prototype scene) 200 switches, 2,350 keys, 0 failures,
0 activations (`last/stacksoak.json`); movement soak with project switches (two-project 40-agent scene) 1,000
steps including the three last-review sequences and 52 bursts of enter/leave/switch (425 keys, what shows checked
against the model after each), 0 failures, 0 leftovers, 0 activations (`last/soak40.json`). In 49 of the 66
list-drag steps the harness's held drag had not taken the row within 1.5 s and the step only checked the rest; an
earlier run failed twice in that step because the drag took the row after it had been settled and brought back
(the button was still held, so the drag was the person's): the step now waits for the row to be held. Strips retaken (every 1/120 s of animation time):
`/Volumes/Xcode/GhosttyBuilds/ghostty/harness/last-strips/` enter, leave, density-grow.

From the previous pass, not retaken: idle (all 40 agents at their prompts, two minutes, window open) main thread
0.16 %, CPU 0.1 %, 93 MB resident, 560 MB footprint; with 32 of 40 printing main thread 9.1 %, CPU 14.5 %;
window closed with 32 printing main thread 4.4 %. Late frames per movement: 0–2 under load
(`final/movements-after1.txt`).
