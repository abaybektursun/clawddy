# Clawddy words

Every string the agent window shows, by where it appears. The written authority
for words: code uses these exactly. Behaviour is in `flows.md`, keys in
`shortcuts.md`. Filled-in parts are in angle brackets: `<name>` (an agent's
name), `<project>`, `<CLI>` ("Claude Code", "Codex" or "Antigravity"; the program
Antigravity runs is `agy`), `<N>`, `<M>`, `<time>`
(the system's short time format, as "3:00 pm"), `<text>`.

## The standard

- Plain words, sentence case, no exclamation marks, no "please", no apology, no
  code or file names unless the person must act on them.
- A label says what happens: "Settle", not "Done"; "Add project", not "OK".
- An action keeps one name everywhere, and its result uses the same word:
  Settle → "Settled", Start → "Started", Cancel → "Cancelled", Send → "Sent",
  Mark as unread → "Marked unread".
- An error says what went wrong and what to do next, in one or two sentences.
- An empty screen invites the next action.
- Singular and plural are both written out; never "agent(s)".
- Numbers as digits.
- App-written sentences on tiles and in rows are set in italic, so they are
  never mistaken for the agent's own words.

## One name per thing

| Thing | Its name everywhere | Never |
|---|---|---|
| One CLI conversation with its record | agent | session, thread, chat |
| A folder the person added | project (the folder itself: folder) | workspace, repo, directory |
| Taking a finished agent off home | Settle, Settled | archive, close, remove, done |
| Agents that need the person | waiting on you | needs attention, inbox, queue |
| Starting a new agent | Start, Started; the command is New agent | create, spawn, launch |
| Undoing a start | Cancel, Cancelled | delete, kill |
| Undoing a settle | Undo, Brought back | restore, unarchive |
| Text sent into agents from the line | Send, Sent | dispatch, broadcast |
| Stopping a turn now | interrupt | stop, abort, kill |
| The find and command panel | Find (its commands are commands) | search, launcher, omnibox |
| The list of keys | Keys | shortcuts, cheat sheet, help |

## Agent states

| State | Mark's VoiceOver label | Age phrase (VoiceOver) |
|---|---|---|
| Working | Working | working for <N> minutes |
| Has a question | Has a question | asked <N> minutes ago |
| Stopped with a problem | Stopped with a problem | stopped <N> minutes ago |
| Finished, unread | Finished, unread | finished <N> minutes ago |
| Finished | Finished | finished <N> minutes ago |
| Paused at its usage limit | Paused at its usage limit | paused <N> minutes ago |
| Usage limit reset | Usage limit reset | reset <N> minutes ago |

"Minutes" becomes "hours" or "days" as the age grows; under 45 s, "just now".

## Top bar

| Where | Text |
|---|---|
| Project | <project>, then the number waiting on you when not zero; cut with "…" after 24 characters |
| Project, tooltip | <project>, <N> agents (or 1 agent), and ", <M> waiting" when not zero |
| Projects that do not fit | <N> more; each entry "<project>  <M>" (the number waiting when not zero) with a submenu: Go to <project>; —; the project menu |
| Project menu (right-click or Control-click on a project) | New agent in <project>; Move left; Move right (disabled at the ends); Show in Finder; Remove project; —; Add a project folder… ⌘O |
| Bar's empty part, right-click | Add a project folder… ⌘O |
| Project, VoiceOver | button "<project>", value "current" for the current one, "<N> agents" (or "1 agent"), and "<M> waiting" when not zero; actions: the project menu's enabled items, by their titles; "show menu" opens the project menu |
| Waiting count | <N> waiting on you / No one is waiting (hidden when there are no projects) |
| Waiting count, while walking | <N> of <M> waiting |
| Waiting count, tooltip | Go to the next agent waiting on you (⌘J) |
| Waiting count, VoiceOver | "<N> waiting on you" or "No one is waiting", hint "Goes to the next agent waiting on you" |
| Find button | tooltip "Find an agent or run a command (⌘P)"; VoiceOver "Find" |
| New agent button | tooltip "New agent (⌘N)"; VoiceOver "New agent" |
| Keys button | tooltip "Keys (⌘?)"; VoiceOver "Keys" |
| Dock badge | <N> (none at zero) |

## Home

| Where | Text |
|---|---|
| A project with no agents | No active agents in <project>. Describe a task below. |
| Scrolled-away waiting pill | <N> waiting above / <N> waiting below |
| Tile age | now, <N>m, <N>h, <N>d |
| Tile sentence while a sent message is queued | <what it is doing> You sent: <text> |
| Tile, VoiceOver | label "<name>"; value "<state>, <age phrase>. <sentence>"; hint "Press Return to open its terminal, or type to reply." |
| Tile screen, VoiceOver | "Last lines of its terminal", value: those lines |
| Tile tooltip | <name> on the first line, the whole sentence under it |
| Settled place | Stacked vertically: "Settled", "<name>", and the button "Undo ⌘Z" on the places of the latest settle |
| Settled place, VoiceOver | "Settled <name>"; button "Undo", hint "Brings it back" |
| Tile and row menu (right-click) | Open; Rename; Mark as unread; Settle |

## The line

| Where | Text |
|---|---|
| Chip | New agent in <project> / New <CLI> agent in <project> (only when the line was opened for a CLI that is not the default: New Claude Code agent, New Codex agent, New Antigravity agent) / Reply to <name> (one tile selected and tiles have focus) / To <N> agents |
| Placeholder | Describe the task / Type to reply, or ⌘N for a new agent (one tile selected and tiles have focus) / One instruction for all <N> |
| Settled count | <N> settled |
| Key hint while empty | ⌘N |
| With several selected and text typed | ⌘↩ interrupt them and send |
| Send button, VoiceOver | Start / Send to <N> agents |
| Line, VoiceOver | Task for a new agent in <project> (or "for a new <CLI> agent" when not the default) / Reply to <name> / Instruction for <N> agents |

## Inside a terminal

| Where | Text |
|---|---|
| Back row | Left chevron and All of <project>, key ⌘⎋ at the right; VoiceOver hint "Back to all agents" |
| List row, VoiceOver | "<name>, <state>. <sentence>" |
| Header, right | +<N> −<M> (lines added and removed, when the CLI reports them), then: working <N>m / just now / <N>m ago (and h, d) |
| News in the header | <name>  <sentence>, with the agent's mark; VoiceOver "<name> is waiting on you: <sentence>", hint "Opens it" |
| Under the saved lines of an agent reached by passing through (no CLI running) | Type to continue this conversation. |
| Under the saved lines while its start waits its turn | Waiting to start. 3 agents start at a time. |
| Under the saved lines while its CLI starts | Starting <CLI>… |
| Printed in a terminal before a restart's continuation | ── Clawddy restarted and resumed this conversation ── |
| The continuation message the app sends | [Sent by Clawddy after a restart, not typed by you] Continue where you left off. Your last turn was cut short. |
| What the app sends to an agent cut off before it had a conversation | [Sent by Clawddy after a restart, not typed by you] <its first instruction> |

## The palette

| Where | Text |
|---|---|
| Find field placeholder | Find an agent or run a command |
| Group headings | Agents / Settled / Commands |
| Agent result | <name>, under it the matching line; at the right <project> and the age |
| Nothing found | Nothing matches. and ⌘↩ start an agent with this text |
| Result, VoiceOver | "<name>, <state>, <project>. <matching line>"; hint "Press Return to open it." |
| New-agent chip | New agent in <project>, or New <CLI> agent in <project> when not the default |
| New-agent placeholder | Describe the task |
| New-agent hints | ↩ Start another / ⎋ Back to terminal (inside a terminal) or ⎋ Close (at home) |

### Commands (palette rows, with their keys)

Show agents; —; New agent ⌘N; New Claude Code agent; New Codex agent; New Antigravity agent;
Add a project folder… ⌘O; Settle ⌘D; Mark as unread ⌘U; Rename
F2; Select every working agent here; Remove project; Smaller tiles ⌘−;
Larger tiles ⌘+; Default tile size ⌘0; Keys ⌘?; Go to <project> (one per
project).

## Status line (one-line confirmations)

Shown in the middle of the top bar; 1.8 s unless a time is given. VoiceOver
announces each.

| When | Text | Time |
|---|---|---|
| An agent started | Started <name>. ⌘Z cancels it. | 6 s |
| A start cancelled | Cancelled <name> | |
| Undo after the 6 s or after it finished | Too late to cancel. Settle it instead. | 3 s |
| Undo of a settle | Brought back <name> / Brought back <N> agents | |
| Nothing to undo | Nothing to undo | |
| Settle with nothing selected | Select an agent first | |
| Settle during a walk (⌘D inside a walk) | Settled <name> (with the button "Undo ⌘Z") | 6 s |
| Settle, every selected agent working (home) | Still working. Open it and press ⎋ to interrupt. / Still working. Open each and press ⎋ to interrupt. | 3 s |
| Settle, the agent shown is working (inside) | Still working. Press ⎋ to interrupt it first. | 3 s |
| Settle several, some skipped (working, question or problem) | Settled <N>. Skipped <M> that are working or need you. (one: Skipped 1 that is working or needs you.) | 3 s |
| Settle several, all skipped (working, question or problem) | None settled. All are working or need you. | 3 s |
| Sent to all | Sent to <N> agents / Sent to 1 agent | |
| Sent, some skipped | Sent to <N>. Skipped <names>: <reason>. (one sentence per reason) | 6 s |
| Every agent skipped | Nothing sent. Skipped <names>: <reason>. | 6 s |
| Skip reason, terminal holds typed text | its terminal holds text you typed / their terminals hold text you typed | |
| Skip reason, question or menu open | it is asking a question / they are asking questions; for another menu: its terminal is showing a menu / their terminals are showing a menu | |
| Skip reason, its CLI could not take the text (its start failed, or it did not come back ready after an interrupt) | it was not ready / they were not ready | |
| Marked unread | Marked unread | |
| Sentences copied (⌘C on the tiles) | Copied | |
| Mark as unread on another state | Only a finished agent can be marked unread | |
| Walk with no one waiting | No one else is waiting | |
| Walk finished | That was everyone. Back where you started. | 2.6 s |
| Walk finished where it began is gone | That was everyone. | 2.6 s |
| After a restart, some cut off | Restarted. Resuming <N> interrupted agents. (one: Restarted. Resuming 1 interrupted agent.) | 7 s |
| Project added | Added <project> | |
| Project already added | <project> is already here | |
| Files dropped | Drop a folder, not a file | 3 s |
| Project removed | Removed <project> and settled its <N> agents. (one: and settled its agent; none: Removed <project>.) With the button "Undo ⌘Z" | 6 s |
| Project removal undone | Brought back <project> | |
| Keys typed while a CLI started, thrown away (failed or slow start, a question, a dialog, the person left it) | What you typed while it was starting was not sent. | 6 s |
| A change could not be saved (agents.json, a record or a last screen); stays until a write succeeds | Could not save your changes. Check the disk; they are kept while Clawddy is open. | until saved |
| At launch, the older build's state file could not be read (moved to the backups folder; its path is in the log) | The older Clawddy's state file could not be read. It was moved to the backups folder. | 12 s |

## Sentences the app writes on a tile

Used only when the CLI gave no sentence of its own, and always for an expired
login (the CLI's raw text stays in its terminal). Italic. A working agent's
sentence is the step its CLI reports, else the last instruction it was given, in
the CLI-words style, not italic; "Working" only when neither exists.

| Situation | Sentence |
|---|---|
| Working, the CLI reports no step and was given no instruction | Working |
| Its start waits its turn (3 CLIs start at a time) | Waiting to start. 3 agents start at a time. |
| The CLI is starting | Starting <CLI> |
| Started, no output yet | No output yet |
| The person interrupted the turn | You interrupted it. |
| The CLI exited unexpectedly | <CLI> stopped (status <N>). Type here to continue. (a signal: "stopped (signal <N>)") |
| Login expired | Login expired. Open it and run /login. (Antigravity, which has no /login: Login expired. Open it and sign in again.) |
| The turn failed, no message | Stopped with an error. Open it to see why. |
| Usage limit, reset time known | Paused at the usage limit, which resets at <time>. |
| Usage limit, no reset time | Paused at the usage limit. <CLI> gave no reset time. |
| The reset time passed | Usage limit reset. Open it to continue. |
| Continuing after a restart | Continuing after a restart (<N> of 3) |
| Cut off too often | Cut off by three restarts. Open it to continue. |
| Conversation open elsewhere | Open in another terminal. Close it there to continue. |
| Conversation missing | <CLI> cannot find this conversation. Type to start fresh. |
| CLI not installed | <CLI> is not installed. Install it, then type to start. |
| CLI did not start in time | <CLI> did not start in 30 s. Type here to try again. |
| Project folder gone | Folder missing. Put it back, or settle this agent. |
| What the CLI reported was lost | Could not read <CLI> status. Open it to check. |

When the CLI gave its own message (a limit message, or an error other than an
expired login), that message is shown as it is, not in italic, with the reset
time added if the CLI gave one and its message lacks it: "<message> Resets at
<time>."

## First launch and adding projects

| Where | Text |
|---|---|
| No projects | Add a project to start. Drop its folder on this window, or choose one. |
| Its button | Choose a folder… |
| Dragging folders over the window | Add <folder> as a project / Add <N> folders as projects |
| Folder panel | message "Choose a folder to add as a project"; button "Add project" |
| Two projects with one folder name | <name> (<parent folder>) |

## Menus

### Agent menu

New agent ⌘N; New Claude Code agent; New Codex agent; New Antigravity agent; Add a
project folder… ⌘O; —; Smaller tiles ⌘−; Larger tiles ⌘+; Default tile size ⌘0 (these three at home
only; inside a terminal the keys are Ghostty's font size items); —; Find or run
a command… ⌘P; Move earlier ⌥←; Move later ⌥→ (these two at home only); Next
waiting agent ⌘J; Back to all agents ⌘⎋; Previous agent ⌘[; Next agent ⌘];
Previous project ⇧⌘[; Next project ⇧⌘]; Open agent ▸ (the first nine places of
the current view by name, ⌘1 … ⌘9); —; Settle ⌘D; Mark as unread ⌘U; Rename;
Select every working agent here; —; Remove project; —; New agents use ▸
(Claude Code, Codex, Antigravity, one checked); Start new agents ▸ (Without
permission checks, With permission checks, one checked; sets it for every CLI);
Notify when an agent is waiting (checked or not).

"New <CLI> agent" is one item per CLI, in this order. Find matches them by
their titles, so "antigravity" finds "New Antigravity agent" ("agy", the
program's name, does not).

### Other menus

| Where | Text |
|---|---|
| Edit ▸ Undo | Undo settle / Undo start / Undo remove project; "Undo" greyed when nothing can be undone |
| Edit ▸ Copy | Copy (at home with the tiles in focus it copies the selected agents' sentences as "<name>: <sentence>", one per line) |
| Help | Keys ⌘? |
| Window | Ghostty's items; ⌘W closes the agent window |

### Settings window (⌘,)

One row per CLI, in the order above: its name, what its start mode does, and
the mode chosen.

| CLI | Unrestricted mode: title / what it does | Standard mode: title / what it does |
|---|---|---|
| Claude Code | Dangerously skip permissions / Bypasses all Claude Code permission checks. | Standard permissions / Uses the provider’s normal approval and sandbox behavior. |
| Codex | YOLO / Runs without approval prompts or the Codex sandbox. | as above |
| Antigravity | Dangerously skip permissions / Approves every Antigravity tool request without asking. (Its flag `--dangerously-skip-permissions`: "Auto-approve all tool permission requests without prompting.") | as above |

## Alerts and notifications

| Where | Text |
|---|---|
| Quit while agents work or wait their turn to start (asked whatever Ghostty's settings say, and instead of Ghostty's own question) | Quit Clawddy? / <N> agents are working. They stop now and continue by themselves when Clawddy opens again. (one: 1 agent is working. It stops now and continues by itself when Clawddy opens again.) Then, when some wait their turn: <N> agents waiting their turn to start do not start. (one: 1 agent waiting its turn to start does not start.) / Quit, Cancel |
| Notification (when turned on) | title <name>; subtitle <project>; body the sentence |

## Keys panel

Three groups, scrolling when taller than the window:

**Move**

| Key | Text |
|---|---|
| ← ↑ → ↓ | Move between tiles. Shift selects a range |
| ⌘J | Walk everyone waiting on you, one press each, then return |
| ⌘⎋ | Back to all agents. Pinching together does the same |
| ⌘1 … 9 | Open the agent in that place. Hold ⌘ to see numbers |
| ⌘[ ⌘] | Previous and next agent |
| ⇧⌘[ ⇧⌘] | Previous and next project |
| ⌘P | Find an agent or run a command |

**Agents**

| Key | Text |
|---|---|
| type | On one selected tile: replies in its terminal. With none: starts a new agent |
| ↩ | On a tile: open its terminal. In the line: start or send |
| ⌘N | New agent: a floating line, at home and inside a terminal |
| ⌘D | Settle. During a walk, settles and moves to the next |
| ⌘Z | Undo settle or project removal. In an empty line, cancels a start |
| ⌘U | Mark as unread |
| F2 | Rename |
| ⌘C | Copy the selected agents' sentences |
| ⌘O | Add a project folder |

**Grid**

| Key | Text |
|---|---|
| ⌘− | Smaller tiles |
| ⌘+ | Larger tiles |
| ⌘0 | Default tile size |
| ⌥← ⌥→ | Move the selected tile earlier or later. Dragging does the same |

Under the list: "Inside a terminal, every key without ⌘ goes to the terminal.
With several tiles selected, typing writes one instruction for all of them."
