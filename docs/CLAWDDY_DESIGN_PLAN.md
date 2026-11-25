# Clawddy design plan

Status: approved by the owner 2026-11-13, all five proposals in section 11 accepted. Built, 2026-11-14: every step, D0 to D9, in the dev identity; D10 replaced D9's scope title with the list of projects, one open at a time (section 13), and the flows steps built `docs/clawddy-design/flows.md` 1, 5 to 11, drag reordering included; `docs/clawddy-design/flows.md` is the authority on behaviour; the production app is not switched over. The words as shipped are `docs/clawddy-design/words.md`, the keys `docs/clawddy-design/shortcuts.md`, the final pictures `/Volumes/Xcode/GhosttyBuilds/ghostty/snapshots/d8/` beside the D0 set in `d0-before/`. It replaces the Phase B outline in `CLAWDDY_REFACTOR_PLAN.md` section 11.

Since the flows 2 step, `AgentInteractionTests` drive the real window off screen, the test host in the background, with real key input through the window's key equivalents and the menus; SwiftUI takes no click or drag off screen, so the pointer's tests are kept but do not run, and the drags have been checked only by `AgentSidebarDragTests` and pictures. What only tests and pictures have checked, never a person at the app, to try first: the keys (⌘N and naming in the row, ⌥⌘N, ⌥⌘J, ⌘[, previous and next agent, ⌃⌘S, ⌘1 to ⌘9, ⌘P, the arrows, Return and type-to-select in the sidebar); a click and an Option-click on a heading, its "…" button and renaming in it; dragging agents and projects; the row and heading menus and "Move to"; the menu bar item's menu and a click on a notification; VoiceOver (each row read as one element with its menu's commands as actions, the groups, a heading as a button with its roll-up and its open or closed value, the announcements); full keyboard access and its Ink focus rings; the Working breath and the headline's fade, and Reduce Motion stopping them; the sidebar size set to Large and Increase Contrast switched while the window is open; the close, restart, quit, remove and clean-up questions.
This plan describes the earlier sidebar interface. The redesign of 24 November
2026 replaced it: home is a grid of tiles and the authority is
`docs/clawddy-design/flows.md` with the prototype
`docs/clawddy-design/prototype.html`; `docs/clawddy-design/handover.md` says
what was built. The round-one mockup this plan pointed at has been removed.

## 1. Who this is for and what the window is for

One person running many coding agents at once. Their scarce resource is
attention. They are almost always doing one of three things:

1. Working inside one agent's terminal.
2. Glancing to learn whether anyone needs them.
3. Moving to the agent that needs them, answering, and moving on.

The window exists to make 2 take no effort and 3 take one keystroke, and to
stay out of the way of 1. Everything that serves none of the three is removed.

## 2. The idea: quiet until you are needed

- **The terminal is the room.** It gets every pixel the sidebar does not need.
  The header and sidebar take their colours from the terminal theme, so the
  window reads as one object in any theme, and there is no dark band above a
  light terminal.
- **One colour, one meaning.** The chrome is monochrome. A single hue appears
  only when an agent is waiting for the user. If nothing in the window is
  coloured, nothing needs you. This is the one bold choice; everything else is
  restraint.
- **A queue, then a shelf.** The sidebar opens with "Waiting for you": the
  agents that need an answer, across all projects, oldest first. Below it, every
  agent at rest under its project.
- **The words say what is being asked.** Not "Waiting for You" but "Wants to
  run a command", "Asked a question", "Needs you to sign in".

What makes it feel expensive is precision, not ornament: one type family, a
4-point grid, no divider lines where spacing already separates, alignment that
is checked at pixel level, selection changes that are instant, and no element
that cannot say what it is for.

## 3. What goes away

| Today | Why it goes |
|---|---|
| The tasks level (already decided) | A third level of hierarchy for a list of about ten things per project. |
| The middle column | Its content becomes the sidebar. The terminal gains its width. |
| Scope filters ("Needs attention", project, task) | The queue at the top of the sidebar is the filter. |
| The metadata strip under the header (Provider, Model, Effort, Context) | Provider is shown twice; effort is a launch setting. Model and context move to one quiet cluster at the right of the header. |
| The inspector popover | What remains worth showing fits in a single hover card on that cluster. |
| The status pill and the Start button side by side | A running agent needs no button. An agent at rest shows one action in the terminal area. |
| The footer bar and the "15 agents" count | The count answers no question the user has. |
| Fifteen display states, seven colours | Six states, one colour (section 5). |
| "Completed" counting as "needs attention" | Done is not a request. It is marked unread, not coloured. |

## 4. The window

```
┌──────────────┬──────────────────────────────────────────────┐
│ ● ● ●        │ soundings       Wants to run a command   ◔42%│  44 pt header
│ Waiting for  ├──────────────────────────────────────────────┤
│  ● soundings │                                              │
│  ● anchor-a… │                                              │
│ ghostty      │              terminal                        │
│  ✓ review    │                                              │
│  • sunrise-… │                                              │
│  ○ docs      │                                              │
│ coral        │                                              │
│  • import-l… │                                              │
│ New agent ⌘N │                                              │
└──────────────┴──────────────────────────────────────────────┘
   236 pt                     the rest
```

- **Sidebar**, 236 points, resizable from 200 to 320, hidden with one shortcut.
  At the 900-point minimum window the terminal is 664 points wide (today's
  three columns leave it far less). When hidden, a waiting agent still shows:
  the header gains a small count in the signal colour.
- **Row**: state mark, name, and at the right a short reason only when there is
  one ("permission", "question", "done 4m", "rate limit"). 28 points tall. No
  provider logo unless the project mixes providers.
- **Header**, 44 points, one line: agent name, the state in words, and at the
  right the model and a small context ring with its percentage. Hovering that
  cluster shows session id, working folder, start mode and effort. Nothing else
  lives in the header.
- **An agent that is not running** shows, centred in the terminal area, its
  last activity in one line, and comes back once it has been selected for
  half a second (`docs/clawddy-design/flows.md` 6). A button appears only
  where the user decides: Resume for an agent the user stopped, while it stays
  selected; for a problem, its reason and the one action that resolves it
  (Start fresh, Sign in, Retry).
- **Materials.** On macOS 26 the sidebar uses the system's sidebar glass,
  tinted toward the terminal background; on macOS 14 and 15 it is the terminal
  background lifted by 4 percent. No custom blur, no gradients, no shadows
  inside the window.

## 5. Six states, one mark each

| State | Mark | Text weight | Covers today's |
|---|---|---|---|
| Waiting for you | filled dot in the signal colour | bold | permission, input, authentication |
| Done | check | bold until opened | finished |
| Working | small dot that breathes slowly | regular | thinking, working, compacting |
| Starting | open ring | quiet | launching, status unavailable (first 10 s) |
| Problem | triangle, with its reason beside it | quiet | error, failed, status unavailable (after 10 s) |
| Not running | hollow circle | quiet | inactive, dead, idle after exit |

An agent that is running and idle at its prompt with nothing unread shows the
Working mark without the breathing: alive, not busy. The marks differ in shape,
so the set reads without colour and under the colour-blindness simulations.
Reduced Motion stops the breathing. Compaction is shown only in the header
text ("Compacting"), not as a seventh mark.

## 6. Tokens

**Colour.** Chrome colours are computed from the terminal theme's background
and foreground, so there are no fixed greys. The example values below are for
one dark theme.

| Name | Example | Rule |
|---|---|---|
| Room | `#171A21` | terminal background, as configured |
| Shelf | `#1D212A` | Room moved 4 percent toward the foreground |
| Ink | `#E9E7E2` | terminal foreground |
| Quiet | `#8B909B` | Ink at 55 percent over Room; must keep 4.5:1 |
| Signal | `#F4B63F` dark, `#B66A00` light | fixed; the only hue; 4.5:1 against Shelf in both |
| Problem | `#E8644F` dark, `#C23B25` light | fixed; only on the triangle and its reason |

Increase Contrast raises Quiet to 7:1 and adds a 1-point outline to the
selected row.

**Type.** The system face (SF Pro) throughout the chrome, because it follows
the user's text-size setting and matches the menus around it. Two sizes only:
13 for names and header, 11 for group titles and reasons. Two weights only:
regular and semibold. Numbers are tabular. The terminal keeps the user's own
font; the chrome never uses a monospace face.

**Space.** A 4-point grid. Row 28, header 44, sidebar inset 8, text inset 16,
corner radius 6 for rows. The header's text baseline lines up with the window
controls.

**Motion.** Three motions exist: the Working breath (2.4 s), a 120 ms fade
when the header's state text changes, and the sidebar sliding when hidden or
shown. Selecting an agent is instant. Nothing else animates.

## 7. Behaviour that respects the user

- **One key to the next agent that needs you.** A shortcut jumps to the oldest
  waiting agent; pressing it again goes to the next. When none is waiting it
  does nothing and says so quietly in the header for a second.
- **No shortcut that the terminal eats.** Today's Cmd-K and Cmd-I collide with
  terminal bindings. Every shortcut is checked against Ghostty's defaults and
  the user's config before it is assigned, and all are listed in the menus.
  Proposed: next waiting, previous and next agent, hide sidebar, new agent,
  find agent. The exact keys are chosen in step D5 after that check.
- **Starting an agent asks nothing.** Cmd-N creates an agent in the current
  project with the saved defaults and starts it, its prompt taking the keys;
  its name is its conversation's title until the user gives one. Provider, model and start mode are on an Option-click or the menu, not
  in a form that must be read every time.
- **Notifications say what is asked.** "soundings wants to run a command"
  and, when the report carries it, the command itself. A click lands in that
  terminal with the prompt focused. A completion for the agent you are looking
  at makes no sound and no banner.
- **The menu bar item is a number.** It shows how many agents are waiting, in
  the signal colour, and nothing when the answer is zero. Its menu is the
  queue.
- **Nothing is lost by accident.** Closing, restarting and quitting ask only
  when something is running, and say what will happen to the session ("It can
  be resumed").
- **Empty and first run.** One sentence and one button: "No agents yet. Start
  one in a folder." with "Choose folder". No illustration, no tour.
- **Problems are sentences.** What happened, and the one thing to do about it.
  Never a code, never an apology.

## 8. Words

Sentence case everywhere. One name per thing, used in the sidebar, header,
menus, notifications and VoiceOver alike.

| Situation | Text |
|---|---|
| Permission prompt | Wants to run a command / Wants to edit a file / Wants permission |
| Question | Asked a question |
| Sign-in | Needs you to sign in |
| Finished, unread | Done |
| In a turn | Working |
| Compaction | Compacting |
| Before the first report | Starting |
| Exited normally | Not running |
| Session gone | Couldn't resume: the conversation no longer exists |
| Quit dialog title | Quit Clawddy? |

The finer permission wording depends on what the status report carries; where
it carries only "permission", the text is "Wants permission".

## 9. Accessibility

- Every state is distinguishable by shape and by its VoiceOver label; colour is
  never the only carrier.
- A row reads as "soundings, waiting for you, permission, ghostty".
- The sidebar is a real outline: arrow keys, type-to-select, and rotor support.
- Text follows the system text size up to the largest setting without
  truncating the state. On macOS the one such setting an app can read is
  the sidebar size (General > Sidebar icon size): the sidebar's 13 and 11
  points and 28-point rows become 15, 13 and 32 at Large (D7).
- Contrast: 4.5:1 for all text, 3:1 for marks, measured in both themes and
  with Increase Contrast.
- State changes are announced once (already in the engine); the wording comes
  from section 8.

## 10. Steps

Each step is one worker and one or more commits, judged on rendered pictures,
not on code. The owner looks at the pictures at the end of each step and says
yes or no. Builds are Release, dev identity, and tests run under the test
identity, as in the engine work.

| Step | Change | The owner sees |
|---|---|---|
| D0 | Snapshot harness as a test target that renders the real views (the sidebar list rendered blank in the earlier attempt; that is fixed first). It writes dark, light, large text and Increase Contrast pictures of every screen to a folder. | A before set of the current UI. |
| D1 | Remove tasks: schema 6, the `flattenV6` migration (already written and rehearsed), model, policies, views and tests in one change, with backup, and rollback rehearsed. | The same UI without the task level. |
| D2 | Two columns: the outline sidebar with the queue on top; the middle column, scope filters and footer deleted. | Sidebar pictures at 900 and 1512 points wide. |
| D3 | Six states and their marks; the colour tokens derived from the terminal theme; Done no longer counts as attention anywhere (badge, menu bar, sort). | The state legend in both themes and under a colour-blindness filter. |
| D4 | Header in one line with the hover card; the resting and problem states of the terminal area; the inspector and metadata strip deleted. | Header and resting-state pictures. |
| D5 | Keyboard: the conflict check, the shortcut set, next-waiting, sidebar toggle, every command in the menus. | A table of shortcuts with what each was checked against. |
| D6 | New agent without a form; rename in place; menu bar item as the queue; notification wording. | A short recording of creating an agent. |
| D7 | Words (section 8) and accessibility (section 9), with a VoiceOver pass by the owner. | The copy table as shipped. |
| D8 | Review at pixel level with the owner: alignment, spacing, truncation, the 900-point minimum, the largest text size. Fixes only. | Final picture set next to the D0 set. |

D1 changes stored data; it follows the same rules as the engine switch-over
(backup first, abort without writing on unexpected data, old app restorable).
Steps D2 to D8 change no stored data except view preferences.

## 11. Decisions for the owner

1. **The signal colour.** Proposed: a fixed amber, so it means the same thing
   on every machine. The alternative is the system accent colour, which
   follows the user but can be red or grey and then collides with Problem.
2. **Queue on top of the sidebar.** A waiting agent appears twice in spirit:
   in the queue and missing from its project group. Proposed: it moves to the
   queue and leaves its group, so each agent has one row. The alternative is
   to keep it in place and only colour it.
3. **Order inside a project.** Proposed: the order the user arranged, never
   re-sorted by state, so rows do not jump while being read.
4. **Cmd-N starts at once.** Proposed as above. The alternative keeps a small
   sheet with provider and start mode.
5. **The name in the quit dialog and menus** becomes "Clawddy" (it says
   "Ghostty" today in places).

## 12. What is not known yet

- Whether status reports carry enough to say what a permission is for. If not,
  the text stays "Wants permission".
- Whether the derived chrome colours hold 4.5:1 for every terminal theme; D3
  measures the bundled themes and clamps where they do not.
- Whether SwiftUI's outline can meet the row and keyboard requirements, or the
  sidebar needs an AppKit outline view. D2 decides, on evidence.
- Codex agents still report through hooks; their "Waiting for you" may be
  slower to appear than Claude's.

## 13. Many agents: the list of projects, one open at a time (added 2026-11-13, redesigned as D10 on 2026-11-14)

The owner has 69 agents in 4 projects (36 in the largest). Section 3 assumed
about ten per project. These ways to keep the sidebar short were weighed:

| Option | Verdict |
|---|---|
| Collapsible projects | Hides noise only after the user tidies by hand, every day. |
| Optional groups inside a project | A second level again, and more filing work. |
| One window per project | Native, but waiting agents scatter across windows and the single workspace would have to be rebuilt. |
| A scope title beside the window controls whose pop-up menu picks one project or "All projects" (built as D9) | Rejected by the owner after a few hours of use: "when I go back to project it doesn't focus on the last window. Can't rearrange the agents. Selecting the project is bad experience, can't see what is happening with the project, can't delete the project." The menu hid the projects behind a click, showed nothing of them but a waiting mark, offered no management (a focused project showed no heading, and Remove project… was only on a heading), and forgot where the user was. |
| **Every project is a heading in the sidebar; one is open at a time, and resting agents fold away** | Chosen (D10). Opening one closes the others, so nothing needs tidying; a closed project still says what is happening in it; the queue stays in one place; each project remembers where the user left off. |

```
● ● ●
Waiting for you
 ● soundings           permission
 ● anchor-alarm          question
tidepool                   ● 2  ✓ 1      <- closed: heading and roll-up
paper-kite                                <- open: heading in Ink
 ✓ review                 done 3m
 • sunrise-tables
 ○ moon-phase-set
 › 17 earlier
field_notes                 ● 1
coral
Add project…

New agent                        ⌘N
```

**The band beside the window controls** is empty, and moves the window.

**Queue.** "Waiting for you" comes first and holds every waiting agent of
every project, oldest request first; a waiting agent has one row there and
leaves its project while it waits. While the waiting agents come from more
than one project, each row's right-hand text is its project's name in Quiet;
while they all come from one, it is the reason (the header says what is
asked).

**Headings.** Every project is listed, in the user's order, as a heading
row (a row's height, 28 points, on the same grid): its name at the text
column, 13-point semibold, in Ink while it is open and in Quiet while it is
closed. A closed project's heading shows at its right a roll-up of what is
not zero: the Working mark and the count of agents in a turn (not those
Ready at their prompt), the Done mark and the count of unread completions,
the Problem mark and the count of problems; marks at 10 points, counts at
11-point tabular Quiet. Waiting agents are not counted there: they are in
the queue. A closed project with nothing going on is only its name. The
open project is told by its Ink name and its rows, with no box and no line.

**One project open at a time.** A click on a closed heading opens it and
closes the others; a click on the open heading closes it, and with none
open the sidebar is the overview of every heading. An Option-click opens or
closes one project and leaves the others as they are, for working across
two. Which projects are open is kept for the next start. Opening and
closing are instant. The only project is always open: a click on it goes
back to its agent.

**Opening a project selects where the user left off**: each project keeps
its last selected agent (a view preference, by agent id). Opening selects
it while the project still has it, else the project's first row as shown,
else its first agent, and gives its terminal the keys when it has one. A
project with no agents selects nothing, and the terminal area says "No
agents in <project> yet." with "New agent". Closing a project changes
neither the selection nor the terminal.

**Selecting an agent from anywhere** (a row, the queue, find, next waiting,
a notification, the menu bar item's menu, previous or next agent, back)
opens its project, alone unless it is open already, and keeps the agent as
that project's last. A click on a row, as every jump, gives the agent's
prompt the keys; the arrow keys and typing a name select in the sidebar,
which keeps the keys. Previous and next agent (⌥⌘↑ and ⌥⌘↓) walk the queue
and the open projects' rows only. A selection kept from the last run is
shown as it was, its project left closed if it was.

**Back to previous agent** (⌘[) returns to the agent selected before the
last selection, kept for the next start, and again comes back, as ⌘-Tab does between two apps: next
waiting goes to the agent that asks, the answer is typed, and ⌘[ goes back.
The key is not ⌃⇥, the one first intended: `docs/clawddy-design/shortcuts.md`
says why.

**An open project shows** its agents as the earlier rule below decides, in
the column the queue's rows have, so the marks line up.

**Managing a project** is on its heading: its right-click, and a "…"
button that takes the roll-up's place while the pointer is over the heading
or the keyboard is on it, give New agent, New project in this folder…,
Rename, Move up, Move down, Reveal folder in Finder and Remove project….
Rename edits the name in the heading, through the same edit the workspace
model owns for agents' names. Remove project… asks in a sentence what
happens, its question what goes and one sentence what stops and stays:
"Remove paper-kite and its 17 agents?" and "2 are running and will be stopped;
their conversations stay on disk with Claude Code and Codex.",
with "Remove project" and Cancel, Cancel the default; it removes each agent
as removing an agent does, terminal and files, and, like removing an agent,
is undone with ⌘Z (flows 10). "Choose folder…" and "New agent with options…" left the
heading's menu: a project's folder is fixed (a new folder is a new
project), and options are on ⌥⌘N and an Option-click on "New agent".

**Add project…** is a quiet row after the last project, scrolling with
them; it asks for a folder, and the new project opens alone. **New agent**
(⌘N) stays at the bottom and creates the agent directly after the selected
agent in its project, else at the end of the first open project, else of
the first project, which opens.

**Keys.** ⌘1 to ⌘9 open the first nine projects, each alone, where the user
left off. ⌘[ goes back. With the sidebar hidden, nothing changes: the
header shows the waiting count.

**VoiceOver.** A heading is a button whose label is the project and its
roll-up, "paper-kite, 2 working, 1 done", whose value is "open" or "closed", and
whose actions are its menu's commands.

**Earlier.** An agent of an open project is shown when it is waiting,
working, starting, ready, unread-done or a problem, when it was active in
the last 24 hours, or when it is selected. Every other agent is "earlier":
behind the "N earlier" line, which opens in place and remembers whether it
is open. Nothing is deleted, and find reaches every agent. Rows do not fold
away while they are read: an agent once shown stays shown until a project
opens or closes or the window becomes key again after another window or app
was, and only then is the 24-hour rule applied again. A change of state
still shows at once: an agent that starts waiting moves to the queue.

**Sub-projects are projects.** Two projects may share a folder. "New project
in this folder…" on a project's menu asks only for a name, places the new
project directly after it and opens it. A row's menu has "Move to ▸"
listing the projects and "New project in this folder…". No multiple
selection. A move always succeeds: an agent moved, or dragged, into a
project that has its name takes the lowest free number ("review 2"). A new
agent's default name, "agent N", is free across all projects.

**Clean-up.** Agent menu: "Remove agents not used in 30 days…" lists them and
asks once; conversations stay on disk with their provider.

### Flows

How each of these behaves from end to end, and where the keyboard is after
it, is `docs/clawddy-design/flows.md`, which is the authority on behaviour
where this plan differs. D10 built its flows 2, 3, 4, 8 (finding an agent
and opening its project), 10 (the removal question's words) and 12, and its
third principle for every action they contain: a click on a heading or a
row, ⌘1 to ⌘9, ⌥⌘J, ⌘[, find, a notification, the menu bar item's menu,
renaming, moving or removing a project all end with the selected agent's
prompt holding the keys, or, where the agent shows no terminal, with Return
pressing the terminal area's one button. The flows step built flows 1
(what ran at quit comes back, the selected agent first, then three at a time;
a turn the quit cut off is marked "interrupted"), 6 (selecting brings an
agent back after half a second; a stop the user chose holds while it stays
selected; "Stop agent"), 7 (an unexpected stop restarts once, "Reconnecting";
a second within a minute is a problem with Retry) and 11 (the quit question
names what comes back and what is interrupted). An agent's terminal is its
provider's only: when the provider exits, the terminal closes. The flows 2
step built 5 (⌘N starts the agent at once, its name the conversation's title
until the user names it), 8's "Continue an earlier conversation…", 9 (a drag
the sidebar owns, in place of system drag and drop) and 10 (Undo of every
removal, "Recently removed"), and a Claude turn now starts with its prompt.
