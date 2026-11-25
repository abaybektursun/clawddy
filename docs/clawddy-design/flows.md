# Clawddy flows

The written authority on how Clawddy behaves. Engineers build to it and testers
test against it. Its source is the browser prototype
(`docs/clawddy-design/prototype.html`, pictures in `prototype-shots/`); where
this file and the prototype differ, this file wins, because it also decides what
the prototype fakes or leaves open. Keys are in `shortcuts.md`, every word the
app shows is in `words.md`.

Dark theme only. No sounds. Clawddy never draws a chat view: an agent's terminal
is the real Ghostty terminal running the CLI.

## Terms

- **Agent**: a lasting stored record of one Claude Code, Codex or Antigravity
  (the `agy` program) conversation in
  one project folder: its name, state, last sentence, first instruction, the
  prompts sent to it, its last message, the CLI it runs, the CLI's session id and
  the saved text of its terminal. The CLI process under it
  is replaceable; the record is not.
- **Project**: a folder the person added. Every agent belongs to one project.
- **Home**: every agent of the current project, each a tile in a fixed place,
  with the line at the bottom.
- **Tile**: one agent at home: mark, name, age, sentence, and its screen (the
  last lines of its terminal as plain text).
- **Inside**: one agent's terminal, full size, with the list of the project's
  agents on its left.
- **The line**: the text field at the bottom of home. It starts a new agent, or,
  with two or more tiles selected, sends one instruction to all of them.
- **The palette**: the floating panel for finding agents and running commands
  (find mode), and for starting agents from inside a terminal (new-agent mode).
- **Waiting on you**: an agent that has a question, stopped with a problem, or
  finished and was not read since. Amber means only this.
- **Settle**: take an agent that is not working off home. It stays findable
  and comes back when opened.
- **The status line**: one short sentence in the middle of the top bar that
  confirms what just happened and fades. Removing a project and settling during
  a walk add an Undo button to it.

## 1. The window

### Top bar (44 pt, every view)

From left: the window's own buttons; the projects; the status line (centred);
then at the right the waiting count, Find, New agent and Keys buttons.

- **Projects**: each project's name as text, in the projects' order (added at
  the end; the person can move them, 3.5). The current one is primary text,
  semibold; the others tertiary. A project with agents waiting on you shows
  their number after its name, small, in secondary grey (never amber). Its
  tooltip and accessibility label give the total agent count as well as the
  waiting count. Click: switch to that project (6.10). Right-click or
  Control-click: the project menu (6.2). Drag along the bar: move it (3.5).
  Right-click on the bar's empty part: "Add a project folder…" (⌘O).
- **Waiting count**: an amber dot and "N waiting on you" in amber, counting every
  project; with none, a grey dot and "No one is waiting" in grey. While walking
  (6.6), it shows the position: "2 of 6 waiting". Hidden when there are no
  projects. Click: the same as ⌘J (6.6).
- **Find** (magnifier): opens the palette in find mode (hidden when there are no
  projects). **New agent** (plus): the same as ⌘N, everywhere: the floating
  new-agent line (6.3). **Keys** (question mark): toggles the keys panel.
- Projects that do not fit go into a last item "N more", a menu listing them with
  their counts. The current project is always visible, in the place of the last
  one that fits. Each entry has a submenu: "Go to <project>", then the
  project menu (6.2).
- Every control answers a click with something visible near where the person
  looks, within one frame; a control that can do nothing in some state is drawn
  disabled in that state or does not exist.

### Home

- Tiles in a grid inside 24 pt side margins, 12 pt gaps. Columns: as many as fit
  at a minimum width of 300 pt; they divide the width equally. Columns depend on
  the window width and nothing else.
- Tile size comes from the window size and the person's chosen density only,
  never from how many agents there are.
- Density is the number of rows of tiles that fit the grid's visible height H.
  The default is max(2, round(W / 290)), W the window's height below the top
  bar (section 9). At home, ⌘− shows one more row (smaller
  tiles), ⌘+ (⌘=) one fewer (larger tiles), ⌘0 returns to the default. The
  choice is remembered per project, as a number of rows more or fewer than the
  default, so a window resize recomputes the default and keeps the choice. Rows
  range from 1 to as many as keep a row at least 132 pt tall; at either end the
  key does nothing. Inside a terminal these three keys keep Ghostty's meaning
  (font size).
- Row height = floor((H − 12 × (rows − 1)) / rows) pt. Rows of tiles beyond
  those that fit scroll. Adding, settling or removing agents never changes a
  tile's size; it changes only how far the grid scrolls (6.7 says when a settled
  place closes).
- Agents scrolled out of view are still reached: the top bar's waiting count and
  the ⌘J walk include them, and moving the selection scrolls the cursor into
  view. When waiting agents are scrolled above or below the visible area at
  home, a small opaque pill at that edge says "N waiting above" or "N waiting
  below"; clicking it scrolls the nearest one into view.
- Holding ⌘ for 200 ms at home shows the numbers 1 to 9 over the first nine
  tiles' marks; releasing ⌘ (or pressing another key) hides them.
- Tiles are in the person's order. A new agent takes the next place at the end;
  a tile keeps its place unless the person moves it (3.5). The order is per
  project, is saved, and is also the order of the list beside a terminal and of
  ⌘1 to ⌘9.
- The line sits under the grid, centred, at most 960 pt wide (at least 24 pt
  from each side) and 18 pt from the bottom.

### A tile

- Row 1: the state mark (14 pt), the name (semibold, one line, ends in "…" if
  long), the age at the right (11 pt, tabular digits).
- Row 2: the sentence, starting at the tile's left inset (x = 12, aligned with
  the screen below it, 5 pt below row 1): up to 2 lines (1 line when the row
  height is under 200 pt), up to 4 when the agent is waiting on you, ending in
  "…" when cut. A tile's height is set by the grid alone: the sentence takes the
  lines that fit and the screen keeps at least 30 pt. A state change never
  changes a tile's height.
- Row 3: the screen, a rounded rectangle filling the rest of the tile (at least
  30 pt tall): the last lines of the agent's terminal, monospace 11 pt, one
  colour, newest at the bottom, each line cut at the right edge with "…". Only
  the text fades at the top (never the screen's background), scaled to the
  screen height H as clear 0 to min(6, H × 0.10) pt, opaque from
  min(24, H × 0.35) pt, and turned off when H is under 64 pt.
- The screen is **off** (one step above the tile, text at 20 % opacity, 30 % while
  working) unless the agent is waiting on you. Then it is **on**: the terminal
  theme's own background, its older lines at 62 %, its newest three lines at
  100 %.
- A question adds a 2 pt amber line along the tile's top edge, following the
  corner radius; a problem adds the same line in red. A finished, unread agent
  has no top line: its amber tick and lit screen are enough.
- The age is the time since the turn started while working, otherwise the time
  since its state last changed (how long it has waited on a waiting tile): "now"
  under 45 s, then "4m", "3h", "2d". On a waiting tile it uses the second text
  tone; on other tiles the third.
- Selected: the tile takes the raised surface and an outset ring drawn 2 pt
  outside the tile (radius 14): 1.5 pt at 55 % ink for the cursor tile while the
  tiles have the keyboard, 1 pt at 30 % ink for other selected tiles. A selected
  tile that is waiting on you keeps its own background so its lit screen keeps
  its edge. A selected tile's off screen shows its text at 50 %. With two or
  more tiles selected and the line focused, unselected tiles drop to 55 %
  opacity.
- App-written sentences are italic (section 4.2).

### Inside

- Left, 252 pt wide, fixed: the back row with a left chevron, "All of <project>"
  and its key (⌘⎋) at the right, separated by a 1 pt hairline under it; then one
  row per agent of the project that is not settled, in tile order: mark, name
  (one line), sentence (one line, 12 pt). The row of the agent shown has the
  raised background. Names of the agent shown and of agents waiting on you are
  primary text, semibold; others secondary, medium; sentences of agents waiting
  on you are primary, the current row's sentence is secondary, others tertiary.
  The list scrolls; it keeps the shown agent's row in view. Rows keep their
  order and one height.
- Right: a 42 pt header (mark, name, sentence in secondary grey, and at the right
  either the change count "+38 −9" and the time, or the news pill, 6.11), then
  the terminal, radius 10, filling the rest. Under 760 pt of pane width, the
  header hides the current sentence while news is showing.
- The terminal's size is the same for every agent of the window, so moving
  between agents never resizes a terminal. Only a window resize does.
- Agent terminals do not show Ghostty's progress bar.

### The line

- A raised slab (radius 12, centred, at most 960 pt wide, a 1 pt line of light
  on its top edge). Inside, left to right: a chip, the text, and the end
  controls. The chip (radius 6) sits on the first text baseline.
- Chip: always names where typed text will go, and is the only thing that
  decides it:
  - no tile selected (or the line has focus with one or no tile selected): "New
    agent in <project>"; when the line is set to a CLI that is not the default,
    it names that CLI: "New Codex agent in <project>", "New Claude Code agent
    in <project>" or "New Antigravity agent in <project>".
  - exactly one tile selected and the tiles have focus: "Reply to <agent name>".
  - two or more tiles selected: "To N agents", brighter.
- Text: 14 pt, one line tall, growing a line at a time to 6 lines, then
  scrolling. Placeholder: "Describe the task", "Type to reply, or ⌘N for a new
  agent" (when one tile is selected and the tiles have focus), or "One
  instruction for all N". It grows upward over the grid's bottom margin; tiles
  do not resize while the person types.
- End controls, while empty: "N settled" (when the project has settled agents;
  opens the palette listing them) and the key hint ⌘N. While it holds text: the
  send button (a light disk with an up arrow); with several selected, also
  "⌘↩ interrupt them and send" before it.
- While the line has the keyboard its edge brightens (1 pt at 32 % ink, top
  light at 10 %, and a soft shadow underneath).
- The line keeps one draft per project. Each project's draft survives switching
  projects, entering terminals and quitting. Only sending empties it.

### The palette

- Floats over everything, its top at 13 % of the window's content height, width
  640 pt (at most 88 % of the window), radius 12, an opaque raised surface with
  a 1 pt rim of light and a shadow. No blur or translucency. Behind it the
  window is dimmed.
- Find mode: a 17 pt field "Find an agent or run a command", and under it the
  results in groups "Agents", "Settled", "Commands" (6.8).
- New-agent mode (the floating new-agent line, at home and inside a terminal):
  the chip "New agent in <project>" (naming the CLI when it is not the default,
  as on the line, aligned to the first text baseline), the field "Describe the
  task", and under it "↩ Start another" and "⎋ Back to terminal" (at home "⎋
  Close").

### The keys panel

A 370 pt opaque panel under the Keys button, listing the keys grouped under
Move, Agents and Grid (with the three density keys on separate rows; see
`words.md`). It scrolls when taller than the window. It never takes the
keyboard. It closes on a click anywhere outside it, on the Keys button again, or
on ⌘?.

## 2. Agent states

### 2.1 The states

| State | Means | Mark | Tile | Row beside a terminal | Counts as waiting |
|---|---|---|---|---|---|
| Working | The CLI is in a turn. | Three-quarter arc, secondary grey, turning once every 1.2 s (linear); stops when the window is not visible, static under Reduce Motion. | Sentence: its current activity, else its last instruction (4.2), secondary grey, then "You sent: <text>" in tertiary while a message it was sent is queued. Screen off, text at 30 %. Age: time in this turn. | Name secondary; sentence as on the tile. | No |
| Has a question | The CLI asked a question or a permission and is showing its menu. | Filled disk, amber. | Amber top line; screen on; sentence = the question, primary. | Name primary, semibold; question primary. | Yes |
| Stopped with a problem | The turn or the CLI failed: an error, login expired, the CLI exited unexpectedly, the conversation is missing or open elsewhere, cut off by too many restarts. | Filled triangle, red. | Red top line; screen on; sentence = the CLI's error, or an app-written sentence saying what to do. | As a question, with the triangle. | Yes |
| Finished, unread | The turn ended and the person has not opened the agent since. | Tick, amber. | Screen on; sentence = the agent's last message, primary. | As a question, with the tick. | Yes |
| Finished | The turn ended and the person has opened the agent since. It stays so until the person replies or settles it. | Tick, tertiary grey. | Screen off; sentence secondary. | Name secondary; sentence tertiary. | No |
| Paused at its usage limit | The CLI reported a usage limit. | Two bars, tertiary grey. | Screen off; sentence = the CLI's own limit message with its reset time, or the app's sentence (4.2). | Name secondary. | No |
| Usage limit reset | The reset time the CLI gave has passed. | Two bars, amber. | Screen on, no top line; app sentence "Usage limit reset. Open it to continue." | As a question, with the bars. | Yes |
| Settled | The person settled it. | (not shown at home) | Not on home, not in the list; findable under "Settled". | Not shown. | No |

"Waiting on you" is exactly: not settled, and Has a question, Stopped with a
problem, Finished unread, or Usage limit reset.

The top bar's count is the number of agents waiting on you across all projects;
each project's number is the same count for that project. The Dock icon shows
the same total as a badge (none at zero).

### 2.2 What moves an agent between states

| Event | From | To | Notes |
|---|---|---|---|
| A turn starts (the person sends in its terminal, a message from the line, the first instruction, a continuation after restart) | any but Settled | Working | Clears any question, problem or unread mark. |
| The CLI asks a question or permission | Working | Has a question | |
| The question is answered in the terminal | Has a question | Working | |
| The turn ends | Working | Finished unread | Unless the agent is the one shown inside, in the key window: then Finished. If a queued message exists, the CLI starts it: Working again. |
| The person interrupts (Escape in its terminal) | Working | Finished | Sentence: "You interrupted it." (app-written). |
| The person opens it (enter by any means, 3.3) | Finished unread | Finished | Opening never clears a question, a problem or a reset limit. |
| Mark as unread (⌘U) | Finished | Finished unread | Only finished agents. |
| Settle (⌘D) | any but Working (when several are selected, skips Working, Has a question, and Stopped with a problem) | Settled | The CLI process ends 60 s after settling (6.7), not at once, so Undo is instant. Undo after 60 s still restores the agent; its CLI resumes when next opened. |
| Undo of a settle (⌘Z) | Settled | the state before | Same place (selected if at home in that project). Never lost by navigating. |
| Remove project | any, Working included | Settled | Every agent of the project at once (6.2); undo restores each exactly. |
| Opening a settled agent (from find) | Settled | the state before settling | It returns to home at its original place in creation order. |
| The CLI reports a usage limit | Working | Paused at its usage limit | No continuation is promised. |
| The reset time passes | Paused | Usage limit reset | Only when the CLI gave a reset time. |
| Login expired (the CLI reports an authentication failure) | any | Stopped with a problem | The app's sentence "Login expired. Open it and run /login." (Antigravity: "Login expired. Open it and sign in again."); the CLI's message stays in the terminal. Cleared by the next turn (after the person runs /login). agy reports "sign in required" for a moment at some starts even when signed in, so for agy the report counts only once it has stood 2 s, and its next report clears it. |
| The turn fails with an error | Working | Stopped with a problem | The CLI's own message. |
| The CLI process exits with status 0 (the person typed /exit, Ctrl-D), or the person stops it or closes its terminal | Working | Finished | Sentence: "You interrupted it." The terminal shows its last screen; the agent has no process (4.5). |
| The same, in any other state | any | unchanged | |
| The CLI process exits otherwise (non-zero, signal) while Clawddy runs | any | Stopped with a problem | App sentence with the status. Not continued automatically. |
| Clawddy quits, crashes, or the Mac restarts while the agent is Working | Working | Working, continued (6.14) | Its turn was cut off. |
| Clawddy quits or crashes while the agent is in any other state | any | unchanged | Comes back as it was, without a process. A question stays amber with its text; opening the agent resumes its CLI and the person answers in words. |
| What the CLI reported could not be read or recorded | any | Stopped with a problem | App sentence; cleared by the next turn. |
| A continuation would be the fourth in a row without a finished turn | Working | Stopped with a problem | "Cut off by three restarts. Open it to continue." |
| Start cancelled (⌘Z within 6 s, 6.3) | Working | (deleted) | The record is removed; the CLI process ends. |

## 3. Moving around (rules every flow uses)

### 3.1 Selection at home

- Home starts with no tile selected when the app launches and when switching to
  a project whose view is home. A tile is selected only because the person moved
  onto it, clicked it, just came back from its terminal, or settled an agent at
  home (which moves the selection to the next tile, also when a walk began with
  nothing selected).
- One tile is the cursor; the selection is the cursor plus any tiles added to it.
- Arrows move the cursor one tile left, right, up or down in the grid, stepping
  over a settled place. At an edge nothing happens (no wrap). With no tile
  selected, Down or Right selects the first tile; Up or Left selects the last.
- Shift-arrow selects a range from an anchor tile, as in Finder: moving back
  toward the anchor deselects tiles. Shift-click or ⌘-click a tile toggles it in
  the selection; removing the cursor makes the first remaining selected tile the
  cursor (or clears the selection if none remain).
- ⌘A while the tiles have the keyboard selects every tile of the project (and
  sets the cursor to the first tile if none was selected).
- Escape on the tiles first collapses several selected tiles to the cursor, then
  clears the selection. With nothing selected, Escape does nothing.
- Moving the selection is instant, never animated, and never starts, stops or
  types into anything. The grid scrolls the minimum needed to keep the cursor in
  view.

### 3.2 The two places at home that take keys

The tiles and the line. Exactly one has the keyboard (section 5). The chip at
the left of the line always names where typed text will go. From the tiles:
Return opens the cursor (or, with several selected, moves to the line); a
printable key opens the cursor's terminal with that key when one tile is
selected (4.4), or moves to the line with that key when none or several are
selected. From the line: Escape, or Up while the caret is on the first line,
moves back to the tiles; Escape with several selected and an empty line also
collapses the selection. Escape never deletes text.

### 3.3 Entering and leaving a terminal

- **Enter** an agent by: Return or a click on its tile, a printable key on its
  tile, a row in the list, ⌘1 to ⌘9, ⌘[ and ⌘], ⌘J, the news in the header, a
  result in find, or pinching apart on a selected tile. Entering makes the
  agent's project current, shows its terminal inside, gives the terminal the
  keyboard, selects the agent, and marks a Finished unread agent Finished.
- **Read** means seen: an agent counts as read only while its terminal, or its
  saved lines when its CLI is not running, is shown in a window that is key,
  visible and not covered (its occlusion state visible), with Clawddy the
  active app and the session unlocked. Entering an agent whose CLI is not
  running marks it read too.
- **Leave** with ⌘⎋, a click on "All of <project>", or pinching together: home of
  the same project, the cursor on the agent just left, scrolled into view, the
  tiles having the keyboard.
- A deliberate enter starts the agent's CLI if it is not running; passing
  through does not (4.5).
- Each project remembers whether it was left at home or inside a given agent.
  Switching back restores that terminal if left inside, or home with no tile
  selected if left at home.

### 3.4 Undo

- **Settle and remove project**: never lost by navigating. ⌘Z restores the last
  settled agent(s) or removed project to its place from anywhere (home, inside a
  terminal, another project), for as long as it is the last undoable action in
  the session. The empty settled place at home still closes when the person
  leaves home.
- **Cancelling a start**: ⌘Z never cancels a start except where starts happen:
  in the home line or the floating new-agent line, when that field is empty and
  the start was the last action, within 6 s while the agent is still working.
  Inside a terminal and on the tiles, ⌘Z only restores a settle or project
  removal.
- **Text fields**: in any field holding text (the line, the palette, a rename
  field), ⌘Z is text undo only. In find, ⌘Z is only ever text undo.
- **One list.** Settles, project removals and starts are one list of undoable
  actions, newest last; ⌘Z undoes the newest that still applies (agents
  brought back by opening them, or a project back in the bar, no longer
  apply). A start stops being undoable as soon as anything else happens:
  another action, a project switch, an edit in the line or the floating
  new-agent line, or the agent going. While a start can still be cancelled
  it is the last action, so ⌘Z away from where starts happen says "Nothing to
  undo" rather than reaching an older settle. Edit ▸ Undo names and does
  exactly what ⌘Z would do where the keys are.
- **Per session.** Undo does not survive a relaunch: Clawddy starts with
  nothing to undo.

### 3.5 Moving tiles

- **By the pointer.** Mouse-down on a tile selects it at once (the pressed state
  shows; a tile already in a selection of several keeps that selection).
  Releasing without moving enters it. Moving more than 4 pt picks it up: it
  lifts (raised surface, the selection ring, a soft shadow) and follows the
  pointer; the place under the pointer becomes the gap and the other tiles move
  to make room as it passes. Several selected tiles move together: the one
  under the pointer leads, the others stack behind it 6 pt apart, and they land
  side by side in their order. Release drops them in the gap. Escape during the
  drag puts every tile back where it was. Near the grid's top or bottom edge the
  grid scrolls. A settled place counts as a place and can be passed.
- **By the keyboard.** At home with the tiles in focus, ⌥← and ⌥→ move the
  selected tiles one place earlier or later (several move together); at either
  end nothing happens. The cursor stays on the same agent and is kept in view.
- **In the list beside a terminal.** Dragging a row reorders the same way
  (vertically); a click without moving enters the agent. The agent shown does
  not change.
- **Projects in the top bar.** A project's name dragged along the bar moves the
  project: past 4 pt it lifts (raised surface, shadow) and follows the pointer
  along the bar; the other names glide to make room; release drops it in the
  gap; Escape during the drag puts every name back. A press that moves less
  than 4 pt is a click (switch project). "Move left" and "Move right" in the
  project menu move it one place (disabled at the ends); a project in "N more"
  moves with them too. The projects' order is saved at once in `agents.json`
  and is the one order everything uses: the bar, "N more", the walk (6.6),
  find's "Go to" commands, and ⇧⌘[ ⇧⌘].
- The new order is saved at once, per project, as the order of the project's
  agents in `agents.json`. Moving is
  not undone by ⌘Z (it is undone by moving back) and does not clear the record
  of undoable actions: an undone settle returns the agent to its place in the
  order as it is now.
- Starting to drag a tile commits a name being edited first (its mouse-down
  is a click outside the field, 6.9).

## 4. What the app does for real

The prototype fakes these; the app must do them.

### 4.1 The screen on a tile is the terminal's own text

- The screen shows the last lines of the agent's terminal as plain text read from
  the terminal itself (`ghostty_surface_read_text`), the lines above the CLI's
  own input box and footer (those are cut off), blank lines left out, so a
  small tile shows more of the work.
  One colour, monospace, no scaling of a picture.
- Refreshed at most 4 times a second while the tile is visible; tiles off screen,
  in other projects, or in a hidden or covered window are not refreshed.
- Terminals not on screen stay attached to the window, hidden, with drawing
  stopped (occluded), never removed and rebuilt.
- An agent without a CLI process shows the text saved from its terminal when its
  process last ended (saved on every exit and at quit).
- The line of the terminal that repeats the sentence word for word is left out
  of the screen when the agent is not working.

### 4.2 The sentence

- Finished: the agent's own last message, from the CLI's hook (Claude Code's Stop
  hook `last_assistant_message`; Codex's turn-complete payload; agy's Stop hook,
  which reads the whole reply from its transcript, since its `done` report
  carries only the reply's first line, cut at 200 characters, shown until the
  hook's arrives). Its first paragraph, Markdown marks removed, whitespace
  collapsed.
- Has a question: the question text from the CLI's hook, at once (agy: from its
  status report, which cuts a question at 180 characters).
- Stopped with a problem: the CLI's own error message when it gives one, except
  for a login that expired: then the app's sentence ("Login expired. Open it and
  run /login."; for Antigravity, which has no /login, "Login expired. Open it
  and sign in again."); the CLI's raw text stays in its terminal.
- Working: the step the CLI reports now (Claude Code's status report names it,
  e.g. "Creating empty marker file"; agy reports no step, and the title its
  report carries on a resumed conversation is not one); else the last instruction it was given, as
  written, in the CLI-words style (not italic); "Working" only when neither
  exists. Followed by "You sent: <text>" while a message is queued.
- App-written sentences (used when the CLI gives no sentence, and always for an
  expired login; the list is in `words.md`) are set in italic, so the person can
  always tell the app's words from the agent's. On a tile waiting on you they
  are primary text; otherwise tertiary.
- Each sentence is stored in the agent's record and survives restarts.

### 4.3 The name

- The CLI's own session title when it has one (Claude Code titles a conversation
  about a second after the first instruction).
- Until then, or for a CLI with no titles: the first instruction's first five
  words, the first letter capitalised, trailing punctuation removed, at most 60
  characters.
- A name the person gives is never replaced. A title that arrives while the
  person is renaming waits and is dropped if they commit a name.
- Two agents may have the same name.

### 4.4 Typing on a selected tile

A printable key on a selected tile opens its terminal (with the enter motion)
and the key arrives in the CLI's input, with every key typed after it, in order,
nothing lost, nothing doubled. If the CLI process is not running, the key starts
it (4.5) and the keys are held and delivered when the CLI's input is ready. If
the agent has a question, the terminal opens with its menu and the key is not
delivered: a stray key must never choose an option.

### 4.5 When a CLI process starts

- An agent whose CLI is not running (after Clawddy restarts, or after its CLI
  exited) shows its saved last lines, on its tile and in its terminal area.
- **A deliberate open starts its CLI at once**: Return on its tile, a click on
  its tile or its row in the list, a letter typed on its selected tile, ⌘1 to
  ⌘9, a result chosen in find, the news in the header, pinching apart on its
  tile. So does anything sent to it: a message from the line, a new agent's
  first instruction, a continuation after restart.
- **Passing through starts nothing**: moving the selection with arrows, stepping
  with ⌘[ and ⌘], and landing on an agent during the ⌘J walk. An agent reached
  this way shows its saved lines with the quiet line "Type to continue this
  conversation." under them, and its CLI starts when the person types the first
  key into that terminal.
- While a CLI starts, the terminal area shows the saved lines with one quiet
  line of status under them: "Starting <CLI>…".
- At most three CLIs start at once (a burst of new agents, a restart's
  continuations and opens together). A start beyond that waits its turn, never
  runs out of time while waiting, and its tile and terminal area say "Waiting
  to start. 3 agents start at a time."; an agent the person opens goes first.
  The check that a conversation is not open elsewhere lists the running
  conversations once for such a burst.
- Starting resumes the agent's own conversation (the CLI's resume by session id).
  Keys and pastes typed while a CLI starts are type-ahead: held in order from
  the start until the CLI's first status report, then delivered, none lost and
  none delivered twice. Held keys never outlive the start they belong to. They
  are thrown away, never delivered, and the status line says so ("What you
  typed while it was starting was not sent.") when the launch fails or reaches
  30 s (the agent becomes Stopped with a problem, "<CLI> did not start in 30 s.
  Type here to try again."), when the CLI asks something, when the person
  leaves that agent, and when the terminal has drawn a screen but no report came
  within 3 s (about twice the slowest normal start): the CLI is showing
  something that needs the person, such as a trust or update dialog, and from
  then on keys go straight to its terminal. The app's own sends wait for the
  CLI to read its input, always.
- Before resuming, the app checks the conversation is not live in another
  terminal; if it is, the agent becomes Stopped with a problem
  ("Open in another terminal. Close it there to continue."). For Claude Code
  the check is its own list of running sessions; Codex lists none, so the sign
  is a running Codex given that conversation's id (a Codex started fresh in
  another terminal is not seen); agy holds a lock file for each conversation it
  has open (`presence/<id>.lock` in its data folder), so the sign is that lock
  held, by any agy. agy itself does not refuse a conversation open elsewhere.
- Before resuming an agy conversation the app also checks it still exists (its
  `conversations/<id>.db`): agy would take an id it does not know as a new
  conversation without a word. A conversation that is gone, for any CLI, makes
  the agent Stopped with a problem ("<CLI> cannot find this conversation. Type
  to start fresh.").
- agy's folder trust dialog, shown at start in a folder nobody trusted, is
  reported as a permission request: the agent waits on the person (its tile
  lights and says "Trust this folder?"), it has started (the 30 s limit no
  longer applies), and keys held for it are not sent into the dialog.
  Answering it in the terminal leaves a new agent as it was ("No output yet").
  agy runs a first instruction's turn behind the dialog without waiting for
  the answer (agy 1.5.17), so its reply can already be recorded.

### 4.6 Sending text into a CLI

The app types the text into the CLI's input as a paste and presses Return. A
working CLI queues it itself, visibly, in its own terminal; Clawddy keeps no
queue of its own. Before typing, the app reads the CLI's input line: if it holds
text the person typed, or the CLI is showing a menu, the agent is skipped and
told (6.5).

## 5. Focus

At every moment exactly one thing has the keyboard.

| View | Owner of the keyboard | How the person can tell |
|---|---|---|
| Home, tiles | The grid (the cursor tile, or none selected) | Cursor ring 1.5 pt at 55 % ink outside the tile; the line shows only its placeholder, no caret. |
| Home, line | The line | Caret; the line's edge brightens (1 pt at 32 % ink with a soft shadow); tile rings drop to 1 pt at 30 % ink, and with two or more selected, unselected tiles dim to 55 %. |
| Inside | The agent's terminal (every key without ⌘ goes to it) | The terminal's cursor is solid. The list is never keyboard-focusable; it is clicked. |
| Palette open | The palette's field | Caret in the field; the window behind is dimmed. |
| Name being edited | That name field | The name sits on a lighter fill with a 4 pt halo; caret; text selected at first. |
| Folder panel, quit alert | The system panel | System. |

Where the keyboard goes when something closes:

| Closes | Keyboard returns to |
|---|---|
| Palette, by Escape, ⌘P or a click outside | What had it before: the line, the tiles, or the terminal. |
| Palette, by running a result | Where the result lands: a terminal (an agent), the line ("Select every working agent here"), the name field (Rename), the tiles (Settle, Go to a project shown at home). |
| Palette, starting from find (⌘↩) | At home: the home line (selection collapsed to the cursor). Inside a terminal: the floating new-agent line stays open, empty. |
| New-agent palette, by Escape | The terminal it was opened from. |
| Name field, by Return, Escape or a click elsewhere | The tiles (home) or the terminal (inside). |
| Leaving a terminal | The tiles, cursor on the agent left. |
| The walk ending | Where it began: the terminal or the tiles, as they were. |
| Switching project | That project's tiles (with no tile selected), or its terminal if it was left inside. |
| Sending from the line to several | The tiles, selection collapsed to the cursor. |
| Starting an agent from the line | The line stays, empty, ready for the next. |
| The window becoming key again | What had it when the window lost key. |
| Launch | Home with no tile selected (or the terminal if left inside). |

Nothing takes the keyboard without the person's action: news, a finishing
agent, a CLI title arriving or a status line never move focus.

## 6. Flows

### 6.1 First launch, no projects

1. The window opens at the screen's visible size up to 1440 × 900 pt, centred.
   The top bar shows no projects, New agent and Keys. The waiting count and Find
   are hidden while there is no project.
2. The middle of the window shows a framed dashed drop area containing "Add a
   project to start. Drop its folder on this window, or choose one." and one
   solid primary button "Choose a folder…" (⌘O). The line is hidden: there is no
   project to start an agent in.
3. The person drops a folder, or chooses one: 6.2. The project becomes
   current; home shows its empty state; the line appears and has the keyboard.
4. Typing a task and Return starts the first agent (6.3).
5. ⌘N or the New agent button opens the folder panel, since there is no project
   to start an agent in. Only ⌘O, ⌘N, ⌘P, ⌘? and ⌘Z act. A right-click on the
   bar's empty part offers "Add a project folder…".
6. The same screen shows after the last project is removed (6.2); ⌘Z or the
   status line's Undo brings the project back.

### 6.2 Adding a project

There is no add-project row or button in the layout once a project exists.

By command:
1. ⌘O, or "Add a project folder…" in the palette or the Agent menu, opens the
   system folder panel (button "Add project").
2. Choosing a folder adds it at the end of the projects and makes it current:
   home, empty, the line has the keyboard. Status line: "Added <project>".
3. Cancelling the panel changes nothing.

By dropping:
1. Dragging one or more folders over the window shows a 2 pt light outline
   inside the window edge and, centred, "Add <folder> as a project" (or "Add N
   folders as projects").
2. Dropping adds each, in the dropped order; the last becomes current, as above.
3. A folder that is already a project is not added twice; it becomes current.
   Status line: "<project> is already here". A folder whose project was
   removed brings that project back to the end of the bar, its agents still
   settled ("Added <project>").
4. Dragging only files (no folder) shows the not-allowed pointer, no outline, and
   drops nothing; after a drop attempt, status line "Drop a folder, not a file".

The project's name is its folder's name. A second folder with the same name is
shown as "<name> (<parent folder>)".

The project menu (right-click or Control-click on a project's name in the
bar, or the submenu of its entry in "N more"): "New agent in <project>"
(switches to it and opens the floating new-agent line); "Move left"; "Move
right" (disabled at the ends, 3.5); "Show in Finder"; "Remove project"; and,
after a separator, "Add a project folder…" (⌘O). VoiceOver reaches each of
these as an action of the project's button, and "show menu" opens it.

Removing: "Remove project" (the project menu acts on its project; the palette
and the Agent menu act on the current one) always works, in one step, with no
confirmation:
1. Every agent of the project is settled, working ones included, and the
   project leaves the top bar. When it was current, the view goes to the next
   project in the bar (the previous one if it was last; the first-launch screen
   if it was the only one); otherwise the view stays where it is.
2. The status line says, for 6 s, "Removed <project> and settled its N agents."
   (or "Removed <project>." when it had none) with an Undo button (⌘Z).
3. ⌘Z or Undo brings back the project in its place in the bar and every agent
   exactly as it was: state, place, sentence, running CLI, and the project's view
   (current again if it was current). Status line "Brought back <project>". This undo survives navigating anywhere,
   for as long as it is the last undoable action in the session (3.4).
4. Each settled agent's CLI process ends 60 s after settling; undo after that
   still restores the project and its agents, whose CLIs resume when next opened.
5. Nothing on disk is deleted. The settled agents stay findable under "Settled";
   opening one brings the project back to the bar.

### 6.3 Starting an agent

⌘N or the plus button, everywhere (home included):
1. The floating new-agent line opens: at home over the tiles, inside over the
   terminal, its field with the keyboard. The selection does not change.
2. Return starts the agent in the current project (as below) and the field
   empties and stays open for the next: a burst of starts needs no click.
3. Escape closes it; the keyboard is back where it was (the tiles, the home
   line or the terminal), the selection and the line's draft unchanged. Pressed
   while it is already open, the plus button gives its field the keyboard and
   keeps its text.

At home, from the line:
1. Typing on a home with no tiles, or with no tile selected, lands in the line;
   the line also takes the keyboard by a click on it.
2. The chip says "New agent in <project>". The person types the task in plain
   words (Shift-Return for a new line).
3. Return or the send button: a new agent exists at once, Working, at the next
   place at the end of the grid, scrolled into view, appearing with the new-tile
   motion (section 7). Its name is the first five words until the CLI's title
   arrives (4.3). Its CLI starts with the task as the first instruction, using
   the default CLI and start mode set in the Agent menu ("New agents use",
   "Start new agents"), unless the line was opened for another CLI (below).
4. The line empties and keeps the keyboard. The selection does not move to the
   new agent. Status line for 6 s: "Started <name>. ⌘Z cancels it."
5. With one tile selected, text in the line always starts a new agent; it never
   goes to the selected agent (replying happens in the agent's terminal).

From inside a terminal, the floating new-agent line works as above: the new
agent appears at the end of the list, the agent shown does not change, and
Escape gives the terminal the keyboard back.

From find: with no match, ⌘↩ starts an agent with the typed text as its task and
behaves like a start from the line: at home the palette closes and the keyboard
lands in the empty home line (selection collapsed to the cursor); inside a
terminal the floating new-agent line stays open with an empty field. So ⌘Z
cancels it there, and a burst can continue. A draft already in the home line
stays as it was; ⌘Z there is then text undo (3.4).

Choosing the CLI: a new agent uses the default CLI set in the Agent menu. The
palette (and the Agent menu) has "New Claude Code agent", "New Codex agent" and
"New Antigravity agent", one per CLI: each opens the floating new-agent line for that CLI, and the chip names the CLI
when it is not the default ("New Codex agent in tidepool"). It stays set to that
CLI, for as many starts as the person types, until it closes; then it returns to
the default.

Several in a row: type, Return, type, Return. Each starts its own agent, each
confirmed. Nothing in between needs a click.

Cancelling a start:
1. ⌘Z in the empty home line or the empty floating new-agent line, within 6 s of
   the start, while the new agent is still working and the start was the last
   action: the agent is deleted, its CLI process ends, its tile (or row)
   disappears. Status line: "Cancelled <name>". ⌘Z never cancels a start on the
   tiles, inside a terminal, or in a field holding text (3.4).
2. Later than 6 s, or after it finished: status line "Too late to cancel. Settle
   it instead." for 3 s; nothing changes.

### 6.4 Replying to one agent

1. At home, select its tile (arrows, ⌘J, or a click with nothing else). Start
   typing: its terminal opens and the first key is already in the CLI's input
   (4.4). Or press Return or click to open it, then type.
2. Inside, the person types and presses Return in the CLI as in any terminal. A
   working CLI queues the message itself.
3. Answering a question: the CLI's own menu is on screen; its keys (digits,
   arrows, Return) choose. The agent becomes Working.
4. ⌘⎋ goes home; the tile shows the new turn.

### 6.5 Sending to several

1. At home select two or more tiles (Shift-arrows, Shift- or ⌘-click, ⌘A, or
   "Select every working agent here" in the palette, which also puts the
   keyboard in the line).
2. Typing (or Return) moves to the line. The chip says "To N agents"; the
   placeholder "One instruction for all N".
3. Return or the send button sends without interrupting:
   - an agent waiting at its prompt starts a turn with the text;
   - a working agent receives the text into its CLI, which queues it until its
     turn ends; its tile shows "You sent: <text>" after what it is doing until
     the CLI takes it up;
   - an agent with no CLI process is started (4.5), then receives it once its
     input is ready.
4. ⌘↩ sends with interrupting: each working agent is interrupted first (Escape
   into its CLI, waiting until its input is ready), then receives the text, which
   starts a turn at once. Agents not working receive it as in step 3. agy puts
   the messages queued during the turn back into its input when interrupted;
   they are the person's, so that agent is then skipped as in step 5 ("its
   terminal holds text you typed") and its queued messages stay in its input,
   not recorded as sent.
5. Agents whose terminal already holds text the person typed, or that have a
   question or another menu open, are skipped: the app never types on top of
   half-written words or into a menu.
6. After sending: the line empties, the selection collapses to the cursor, the
   tiles have the keyboard. Status line: "Sent to N agents" (1.8 s); with
   skipped agents, "Sent to N. Skipped <names>: <reason>." (6 s). If every agent
   was skipped: "Nothing sent. Skipped <names>: <reason>." (6 s), and the text stays in
   the line.

### 6.6 Walking through agents waiting on you (⌘J)

1. The first press fixes the walk's order: every agent waiting on you, except the
   one shown inside; agents of the current project first, then other projects in
   bar order; within a project questions, then problems, then finished unread
   and reset limits; within those, the longest waiting first. It also remembers
   where the walk began (project, home or inside, cursor, agent).
2. Each press enters the next agent in that order that is still waiting on you
   (skipping any that stopped waiting meanwhile), switching project when needed.
   While walking, the top bar shows the position: "2 of 6 waiting". Landing on
   an agent in the walk starts no CLI by itself (4.5); keys typed are held until
   it is ready.
3. Each agent is visited once for each time it starts waiting. The person
   may reply, answer, settle or simply pass on the way; an agent passed
   without an answer is not visited again in this walk. An agent that stops
   waiting while the person is on it stays theirs until they press again;
   one ahead that stopped waiting is passed over and no longer counted.
   Agents that start waiting after the walk began join its end, in the same
   order; so does an agent that stopped waiting and then started waiting
   again after the walk passed it (it was answered and asked again), as a
   new arrival does. The agent on screen never joins while it is on screen.
   Undoing a settle during the walk makes that agent the next stop.
   Pressing ⌘D during a walk settles the agent in place, shows "Settled
   <name>" with an Undo button in the top bar for 6 s, and moves straight to
   the next waiting agent without visiting home.
   The count is "k of N waiting": N is the number of stops in this walk
   (those visited, counted while they still wait, the one on screen, and
   those still to come); k is the place of the one on screen. Moving forward
   never lowers either number; they drop only when an agent is settled or
   stops waiting, and N grows when one joins the end ("4 of 7").
4. The press after the last stop (or ⌘D on the last) returns to where the
   walk began, exactly (inside the same agent, or home with the same
   cursor), with the status line "That was everyone. Back where you
   started." (2.6 s; when ended by ⌘D, the status line keeps "Settled
   <name>" with Undo for 6 s), even when agents passed without an answer
   still wait. If that place is gone (its agent settled), it ends at the
   current project's home, the cursor on the agent left, with "That was
   everyone." The next press starts a new walk.
5. If no one was waiting at the first press: status line "No one else is
   waiting"; nothing moves.
6. Entering any agent another way, going home with ⌘⎋, or switching project ends
   the walk where the person is; the projects it passed through keep the view
   they had before it. Removing a project ends a walk. Landing on agents
   changes no project's remembered view: a relaunch mid-walk shows every
   project as it was before the walk, except the one the person was in. Escape inside a terminal is the terminal's key and does
   not end it. Settling inside a terminal does not end it.
7. The waiting count in the top bar does the same as ⌘J when clicked.

### 6.7 Settle and undo

1. At home, ⌘D settles one selected agent if it is not working (settling one
   agent with a question or problem on its own is allowed). When two or more
   tiles are selected, ⌘D skips agents that are working, have a question, or
   stopped with a problem. Inside a terminal during a walk, ⌘D settles in place,
   shows "Settled <name>" with Undo in the top bar for 6 s, and advances
   straight to the next waiting agent without visiting home (6.6). Outside a
   walk, ⌘D inside a terminal settles the agent shown and goes home (with the
   leave motion) so the settled place and its Undo are in view; the cursor moves
   to the next agent.
2. Each settled tile at home becomes, in its own place, a vertically stacked
   card ("Settled", the name, and an Undo button ⌘Z on the latest settle).
   Nothing else moves. The cursor moves to the next tile after the last settled
   one that is not settled (or the first, if none after), also when a walk began
   with nothing selected.
3. The project's "N settled" count in the line goes up.
4. ⌘Z or the Undo button brings back every agent of the latest settle, in their
   places, in their earlier states (selecting the first if at home in that
   project). Status line "Brought back <name>" (or "Brought back N agents").
   Undo survives moving around (3.4).
5. Working agents are never settled. If every selected agent is working: status
   line "Still working. Open it and press ⎋ to interrupt." (several: "Still
   working. Open each and press ⎋ to interrupt."; inside: "Still working. Press
   ⎋ to interrupt it first."). When settling several skips working, question or
   problem agents: "Settled N. Skipped M that are working or need you." (or
   "None settled. All are working or need you." if none could be settled).
6. With nothing selected: "Select an agent first".
7. The empty settled places at home stay until the person leaves home (enters a
   terminal or switches project); then they close and later tiles take their
   places. Each settled agent's CLI process ends 60 s after settling. Undo after
   60 s still restores the agent; its CLI resumes when it is next opened.
   Settled agents remain findable with find (6.8).

### 6.8 Finding

1. ⌘P or the magnifier opens the palette in find mode, the field empty.
2. Empty field: up to 5 agents (waiting on you first, then the rest, then most
   recently changed) and up to 5 commands.
3. Typing filters as each key is typed (results within 100 ms). An agent matches
   when the text appears, ignoring case, in its stored record only: its name, its
   first instruction, the prompts sent to it, or its last message, in any project,
   settled or not. The terminal's output and the rest of the conversation are not
   searched. Its row shows the mark, the name, and under it the text that matched
   (for a name match, its last message), with the match in
   semibold; at the right its project and age. Up to 8 agents, ordered: waiting
   on you, then not settled, then settled, then most recent; then up to 4
   matching commands.
4. Text starting with "settled" lists only the current project's settled
   agents (the rest of the text filters them) and no commands, so it matches
   the line's count. The "N settled" control on the line opens the palette
   with "settled " already typed. Settled agents of every project are found
   by any other text, under "Settled".
5. Up and Down move the highlight; a hover highlights too; Return or a click runs
   it. An agent opens inside (a settled agent comes back to home at its original
   place, then opens and its CLI starts, 4.5). A command runs.
6. No match: "Nothing matches." and "⌘↩ start an agent with this text"; ⌘↩ starts
   a new agent in the current project with the text as its task and behaves like
   a start from the line (6.3: at home the keyboard lands in the home line;
   inside a terminal the floating new-agent line stays open, empty). When there
   are matches, ⌘↩ does nothing.
7. Escape, ⌘P again, or a click outside closes it; focus returns (section 5).
   While the palette is open no other app key acts.

Commands in the palette: New agent; New Claude Code agent; New Codex agent;
New Antigravity agent; Add a project folder…; Settle; Mark as
unread; Rename; Select every working agent here; Remove project; Smaller
tiles; Larger tiles; Default tile size; Keys; Go to <project> for each
project. Each shows its key at the right, and each is listed only where it
acts (where the keys were when the palette opened). Running one closes the
palette first, so it acts where the keys were.

### 6.9 Renaming

1. Home: F2 on the cursor tile. Inside: double-click the name in the header. Or
   "Rename" in the palette or a tile's or row's menu (right-click).
2. The name becomes editable in place, all of it selected. Nothing else changes
   size.
3. Typing edits it. Other agents finishing, this agent changing state, its CLI
   title arriving, news, and the status line never close, replace or move the
   field, and never commit it.
4. Return keeps the new name (an empty name keeps the old one). A click anywhere
   outside the field keeps it too; on a control, the control then does its
   action; on empty space nothing else happens. If the tile or row being
   renamed is settled, goes, or leaves the screen, the edit is cancelled and
   the keyboard goes where it belongs (tiles or terminal). Escape restores the old name. App keys do not act while the
   name is being edited. A name is one line of at most 60 characters: line breaks of every kind
   and tabs pasted become spaces, zero-width characters are dropped, the
   name is trimmed, and typing stops at 60. The field uses the
   name's own font and line, so the name does not move when editing begins.
   A title its CLI gave meanwhile is taken only if no new name was kept and
   the name was still the app's.
5. The given name is the agent's for good (4.3).

### 6.10 Switching projects

1. Click a project, use ⇧⌘[ / ⇧⌘] (previous / next, wrapping), "Go to <project>"
   in the palette, or enter an agent of another project.
2. The project comes back as it was left: inside the same agent if it was left
   inside and that agent still exists; otherwise home with no tile selected.
3. Any empty settled places at home close and any walk ends; undo of settle and
   project removal is kept (3.4). Each project keeps its own draft in the line;
   the chip names the new project.

### 6.11 News while inside a terminal

1. While the person works inside a terminal, another agent (any project) becomes
   waiting on you.
2. The top bar count and that project's number go up. If it is in this project,
   its row in the list turns primary with its amber or red mark.
3. The header's right side shows, for 6 s, a clickable pill with a resting fill,
   holding the agent's mark, its name and its sentence, replacing the change
   count and time. Under 760 pt of pane width, the current agent's sentence
   hides while news is showing. A newer arrival replaces it. Clicking it enters
   that agent.
4. Nothing covers the terminal, no sound plays, the keyboard stays in the
   terminal, and the terminal does not move.
5. An agent that finishes while it is the one shown, in the key window, becomes
   Finished, not unread.
6. When Clawddy is not the active app, the Dock badge updates. If "Notify when an
   agent is waiting" is on in the Agent menu (off by default; the system asks for
   permission when it is first turned on), a notification shows the name, the
   project and the sentence; clicking it opens that agent.

### 6.12 Mark as unread

⌘U on the cursor tile (home) or the agent shown (inside), if it is Finished: it
becomes Finished unread, its screen lights, it counts as waiting. Status line
"Marked unread". On any other state: "Only a finished agent can be marked
unread". Inside, it stays unread until the person enters it again: looking
at it does not read it.

### 6.13 Quitting and closing the window

- ⌘W closes the window. Agents keep running. A click on the Dock icon, or any
  agent command, opens it again exactly as it was. With the window closed, the
  Agent menu's Show agents, New agent (and the CLI variants), Add a project
  folder…, Find or run a command…, Next waiting agent and Help ▸ Keys act from
  the pointer and open the window first; the rest wait for it. Their keys act
  only in the agent window. At launch the app shows the agent window (the
  first-launch screen with no project), never a plain terminal window;
  Ghostty's terminal windows open only by Ghostty's own commands (File ▸ New
  Window).
- Nothing asks the system for a permission at launch. The Dock badge asks for
  none; where macOS shows no badge without permission, there is none until the
  person turns notifications on.
- ⌘Q with no agent working quits at once. With agents working, it asks once:
  "Quit Clawddy? N agents are working. They stop now and continue by themselves
  when Clawddy opens again." Quit (default) and Cancel.

### 6.14 After Clawddy restarts

1. The window comes back with its size and place, the current project, each
   project's view (home with no tile selected, or inside an agent), each
   project's line draft and every agent's record: name, state, sentence, saved
   terminal text.
2. Agents that were Working when Clawddy quit, crashed or the Mac restarted were
   cut off. Each is resumed, at most 3 starting at a time: its CLI is started on
   its own conversation, a dim line "── Clawddy restarted and resumed this
   conversation ──" is printed in its terminal before the CLI starts, and the app
   sends: "[Sent by Clawddy after a restart, not typed by you] Continue where you
   left off. Your last turn was cut short." Its tile's sentence is
   "Continuing after a restart (1 of 3)" (app-written) until that turn ends.
   An agent cut off before its CLI had a conversation to resume (Codex binds one
   at the end of its first turn) starts fresh instead, and the app sends its
   recorded first instruction, labelled: "[Sent by Clawddy after a restart, not
   typed by you] <first instruction>". A continuation is recorded when its CLI
   is started with it, not before. A settled agent is never continued: its turn
   ended, interrupted, when its CLI was ended.
3. The count grows with each restart that cuts off the same turn: (2 of 3),
   (3 of 3), fresh starts included. A fourth is not sent; the agent becomes
   Stopped with a problem. A finished turn resets the count.
4. Agents in any other state come back as they were, without a process,
   showing their saved last lines; their CLI starts on a deliberate open, on the
   first key typed into their terminal, or when something is sent to them (4.5).
5. Status line for 7 s: "Restarted. Resuming N interrupted agents." (one:
   "Restarted. Resuming 1 interrupted agent."). Nothing is said when none were
   cut off.
6. Unsent text that was in a CLI's input at quit is lost with the process; the
   saved terminal text still shows it.

## 7. Motion

Every change the person causes is shown by motion of 200 ms or less, can be
interrupted at any frame, and never delays or drops a key: the state changes at
the key press and the motion only shows it. The one large gesture is entering a
tile. Nothing moves by itself to decorate. The one thing in the app that moves
on its own is the working mark (a three-quarter arc turning once every 1.2 s,
linear), because it carries information: this agent is alive. It stops when the
window is not visible, and it is static under Reduce Motion.

The system is one curve and five durations:

- Curve "out": cubic-bezier(.32, .72, 0, 1), in AppKit
  `CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)`. Every motion and
  fade uses it. A 60 Hz frame after a key already shows about 20 % of the
  change, so the result is visible at once, and the tail settles softly.
- 200 ms: fades that end something without a key (the status line and the news
  going away, a screen powering down, a top line).
- 160 ms: entering and leaving a terminal (including settling inside outside a
  walk).
- 150 ms: in-place changes the person causes (settle, undo, a new tile, density,
  the palette opening, the line growing, a project switch, the status line and
  news appearing) and the end of a hover.
- 100 ms: things going away because of a key (palette, keys panel, menu, a
  cancelled tile, hold-⌘ tile numbers) and every fade under Reduce Motion.
- 400 ms: a screen lighting. No key causes it, so it may be slower; it is the
  only change over 200 ms. (A new tile's lighter background returning to normal
  takes 1.4 s; it is a colour, not a movement.)

Rules every row follows:

- **Retarget, never queue.** A key during a motion changes the state at once;
  the motion then runs from the value on screen (in AppKit, from the
  `presentationLayer`) to the new target, with the row's duration and the same
  curve. No motion waits for another; at any moment each layer has at most one.
- **Selection and focus never animate.** Rings, the line's bright edge and the
  current row in the list change in the frame of the key.
- **Two layers never sit on top of each other.** When one layer fades out as
  another fades in, the leaving one reaches 0 at half-way progress and the
  arriving one starts at a quarter (key times on the curve's progress; in AppKit
  a `CAKeyframeAnimation` with `keyTimes` [0, .5, 1] or [0, .25, 1] and the
  animation's `timingFunction` set to "out"). A retarget drops the key times.
- **Scrolling caused by a key is instant** (the cursor kept in view, a new tile
  revealed). Only the person's own trackpad scrolls smoothly.
- **Reduce Motion**: nothing translates, scales or resizes, and the working mark
  is static. Each row's Reduce Motion column says what replaces it; it is always
  an opacity change of 100 ms or none.

| Trigger | What moves | Duration | Another key mid-way | Reduce Motion |
|---|---|---|---|---|
| Enter a tile from home, the tile on screen (any means) | The terminal grows from the tile's outer rectangle to its full rectangle in 160 ms on the one curve, clipped by a wrapper with square clipping (no animated mask). There is no text line-up and no flying name. The tile's own content (mark, name, age, sentence, text and top edge) is hidden from the first frame, and a snapshot of the tile cross-fades out over the first 50 ms (also covering any stale terminal frame); the list and header fade in in place after 50 ms; the grid and the line fade out by half-way. The terminal is scaled, never resized: column count and font are fixed throughout. | 160 ms | The terminal has the keyboard from the first frame; typed keys go into it, in order. Leaving mid-way runs back from the frame on screen. Entering another agent from inside (⌘J, ⌘[ ⌘], ⌘1–9, the list, news) swaps the terminal's content in the next frame and lets the motion finish; nothing restarts. | 100 ms cross-fade of the two views |
| Enter from home, no tile on screen (another project, a tile scrolled out of view) | The two views cross-fade. | 150 ms | As above. | 100 ms cross-fade |
| Enter from inside (list, ⌘[ ⌘], ⌘1–9, ⌘J, news) | Nothing moves: the other terminal is shown in the next frame. If the project changes (the walk crossing projects), the list fades from 40 % to 100 %. | 0; list 150 ms | — | List: 100 ms fade |
| Leave to home | The exact reverse: the terminal shrinks from its full rectangle into the tile's outer rectangle in 160 ms; the list and header fade out in place over the first 50 ms; the grid and line fade in after 50 ms; the tile's snapshot fades in over the last 50 ms for a seamless hand-over. If that agent has no tile on screen at the home shown (the walk ending in another project), the views cross-fade (150 ms). | 160 ms | Arrows move the selection at once. Entering the same agent mid-way runs forward from the frame on screen; entering another agent starts from that agent's tile. | 100 ms cross-fade |
| Settle inside (⌘D, outside a walk) | The terminal shrinks into the agent's place and reaches opacity 0 by half-way (80 ms); the settled card ("Settled", name, Undo) stays at opacity 0 until 80 ms and fades in over the second half, so terminal text never ghosts over it. (During a walk, ⌘D settles in place and switches straight to the next waiting agent without visiting home.) | 160 ms | ⌘Z brings it back at once. | 100 ms cross-fade |
| A tile's screen lights (the agent becomes waiting on you) | Screen background to the theme colour; the lines already there go to their lit opacity (new lines arrive lit). The top line (question, problem) fades in. | Screen 400 ms; top line 200 ms | Not affected by keys. | 100 ms fades |
| A screen powers down (read, or the agent starts working) | Back to off; the top line fades out in its last colour. | 200 ms | — | 100 ms fade |
| A new tile appears (a start) | The tile fades in at its place; its background starts at the popover surface (#2f323a, two steps up, so it is not read as selected) and returns to the tile's own. | Fade 150 ms; background 1.4 s | Keys are not affected; the line keeps the keyboard. | Fade 100 ms; lighter background kept |
| Settle | The settled place (canvas fill, hairline, "Settled <name>", Undo) fades in over the tile in the same rectangle. No other tile moves; the cursor ring moves in the frame of the key. | 150 ms | ⌘Z mid-way runs back from the frame on screen. | 100 ms fade |
| Undo of a settle | The settled place fades out, showing the tile. | 150 ms | — | 100 ms fade |
| A start cancelled (⌘Z within 6 s) | The tile fades out where it was. | 100 ms | — | 100 ms fade |
| A settled place closes (the person looked away) | Happens while home is not on screen; no motion. | — | — | — |
| Selection moves | Nothing animates; rings change in the frame of the key. | 0 | — | — |
| Focus moves between the tiles and the line | Nothing animates: the cursor ring and the line's edge swap in the same frame. | 0 | — | — |
| Palette or new-agent palette opens | Dim reaches full opacity in 75 ms; the opaque palette fades in and scales from 98 % to 100 % about its top centre. | 150 ms (dim 75 ms) | The field has the keyboard from the first frame. | 100 ms fade, no scale |
| Palette closes | Dim and palette fade out. | 100 ms | Keys go to the returning owner at once; reopening mid-way runs back from the frame on screen. | 100 ms fade |
| The line grows a line | Its top edge rises one line; the text stays where it is (the new line appears at the caret, the lines above are revealed by the rising edge). | 150 ms | Typing continues. | Instant |
| Status line shows | Fades in, holds (1.8 s by default, longer where words.md says), fades out. A new line replaces the current one at once, without a fade. | 150 ms in, 200 ms out | — | 100 ms fades |
| News in the header | Fades in over the change count; the count fades back after 6 s. | 150 ms in, 200 ms back | — | 100 ms fades |
| Keys panel, tile and row menu | Fade in; fade out. | 150 ms in, 100 ms out | Any key closes the menu (Escape only closes it). | 100 ms fades |
| Drag of a folder over the window | Outline and words fade in. | 150 ms | — | 100 ms fade |
| Density change (⌘− ⌘+ ⌘0 at home) | Row height animates to the new value; columns and widths never change; the cursor is kept in view on every frame. The sentence line clamp updates once the row height finishes animating, never snapping on frame 0. | 150 ms | The next key acts at once; a second density key retargets from the frame on screen. | Instant |
| Project switch at home | The new project's tiles fade from 40 % to 100 % (no blank frame). | 150 ms | — | 100 ms fade |
| A tile or row is picked up (a drag passes 4 pt) | Its shadow fades in; it follows the pointer exactly (no lag, no easing). Other selected tiles glide to a stack behind it. | Shadow 150 ms; the stack follows over 150 ms | Escape puts everything back (as below). No other key acts during a drag. | No shadow fade, no glide |
| Other tiles make room as the drag passes | Each tile whose place changes glides to its new place from wherever it is on screen; a tile already gliding retargets. | 150 ms | — | Instant |
| Drop (release) | The lifted tiles glide from under the pointer into the gap; the shadow fades out. | 150 ms | Keys act at once. | Instant |
| Escape during a drag | Every tile glides back to its place from wherever it is. | 150 ms | — | Instant |
| ⌥← ⌥→ (move the selected tiles) | The moved tiles and the tiles they pass swap places by gliding. | 150 ms | A second press retargets from the frame on screen. | Instant |
| Window resize | Tiles reflow to the new columns and row height. | No animation | — | — |

### Hover and pressed states

The pointer is an arrow everywhere except over editable text and the terminal:
the I-beam over the line's text, the palette's field, a name being edited and the
terminal's text. No control shows a pointing hand. Colour changes are instant
when the pointer enters or presses and take 150 ms (out) when it leaves or
releases. Hover never changes selection or focus.

Tiles: mouse-down selects the tile at once; release without moving enters it; a
press that moves more than 4 pt picks it up to move it (3.5) and does not enter;
the second click of a double-click does nothing (the first already entered).
⇧-click and ⌘-click toggle selection without entering. A right-click makes the
tile the cursor (it keeps a selection that already contains it) and opens its
menu. Tile text is not selectable; ⌘C with the tiles in focus copies the
selected agents' sentences, one per line, each preceded by the agent's name
("<name>: <sentence>"), and the status line says "Copied".
The terminal's text is selectable as in any terminal. A click anywhere on the
line's slab puts the caret in it.

| Thing | Hover | Pressed |
|---|---|---|
| Project name | Secondary text, 4 % white fill | 8 % fill |
| Waiting count | 5 % fill | 10 % fill |
| Find, New agent, Keys buttons | 5 % fill | 10 % fill |
| Tile | One surface step lighter (white at 1.6 % over the tile) | Selected at once, raised surface (white at 3.6 %); enters on release without moving; a drag past 4 pt lifts it (raised surface, ring, shadow 0 14 34 black 45 % and 0 2 6 black 30 %) |
| A settled place | Nothing (only its Undo responds) | — |
| Undo on a settled place, Undo in the status line | (filled 7 %) 10 % | 13 % |
| "All of <project>" | Secondary text | 8 % fill |
| Row in the list | 4 % fill | 8 % fill; enters on release without moving; a drag past 4 pt lifts it as a tile lifts |
| News pill in the header | (filled 6 %, rim 28 %) 10 % fill | 14 % fill |
| "N settled" on the line | Secondary text, 5 % fill | 10 % fill |
| The line's slab | — | Puts the caret in the line |
| Send button | — | Scales to 92 % at once, back in 100 ms (Reduce Motion: 80 % opacity instead) |
| Palette result | Becomes the highlighted row (8 % fill), only when the pointer moves, so a resting pointer never takes the highlight from the arrow keys | Runs on release |
| Tile and row menu item | 8 % fill (disabled items: none, text at the fourth grey) | 12 % fill; runs on release |
| Keys panel's links | 10 % fill (rest 6 %) | 14 % |
| "Choose a folder…" (first launch) | Solid ink button: lighter fill | Slightly dimmer fill |

## 8. Feel requirements (testable)

1. **100 ms.** Every key press and click shows its result within 100 ms, and at
   least 95 % within 50 ms (measured from the event to the first frame showing
   it, by signpost): selection, enter, leave, palette open, status line, settle,
   undo, switching project. Find results update within 100 ms of a key with 200
   agents.
2. **No key lost.** Keys typed during any transition (enter, leave, palette
   opening or closing, switching project, a CLI starting) arrive in order where
   the keyboard lands, none dropped, none doubled. Test: select a tile whose CLI
   is not running and type `echo hello` then Return within 200 ms; the whole line
   arrives in its CLI. The single exception is 4.4's question menu.
3. **Passing through starts nothing.** Arrow through 20 tiles, step through 20
   agents with ⌘], and walk with ⌘J past agents whose CLI is not running, typing
   nothing, then wait 5 s: no new CLI process exists. A deliberate open (Return,
   a click, ⌘1 to ⌘9) of such an agent starts its CLI at once.
4. **No field replaced under the hand.** While the person types in the line, the
   palette or a name field, nothing replaces, clears, moves or commits that
   field. Test: rename an agent while a script finishes three agents, changes its
   state and delivers its CLI title; the field stays and the typed name is saved.
   Each project's line draft survives entering a terminal, switching project and
   a relaunch.
5. **Tiles keep place and size.** No tile changes position or size because any
   agent changed state, finished, asked, failed, got a title, or produced output.
   Test: record the frames of all tiles while 17 agents change state for a
   minute; every rectangle is identical. Sizes change only with the window size
   or the person's density keys: test at 1440 × 900 by starting 30 agents; the
   first tile's rectangle never changes. Positions change only by the person's
   own adding, settling, removing or moving (3.5) (a settled place closes only
   after the person looked away), a density change or a window resize.
6. **Escape never deletes text.**
7. **Smooth.** Enter and leave motions hold the display's frame rate (no hitch in
   an Instruments trace) with 17 tiles refreshing.

## 9. Limits

- **0 projects**: 6.1.
- **0 agents in a project**: the grid shows, centred, "No active agents in
  <project>. Describe a task below." and the line has the keyboard. Inside is
  not reachable. ⌘J still walks other projects.
- **1 agent**: one tile, one column wide and one row tall at the project's
  density (at 1440 × 900 pt and the default 3 rows, about 250 pt); the rest of the
  grid is empty canvas.
- **Rows at the default density** are chosen from the window's height below
  the top bar alone, the line's room included: max(2, round((window height −
  44) / 290)). So 846, 900 and 800 pt tall windows show 3 rows and a 560 pt
  window 2; the room the line takes never removes a row by a point of
  rounding. The rows then share the grid's visible height.
- **17 agents in one project**: at 1440 × 900 pt the grid is about 776 pt tall,
  the default is 3 rows of about 250 pt and there are 4 columns: 12 tiles are in
  view and the last 5 (rows 4 and 5) scroll (with an edge pill when waiting
  agents sit below or above). ⌘− twice gives 5 rows of about 145 pt and all 17
  in view; non-waiting sentences take 1 line (under 200 pt row height) and the
  screens turn off their top fade below 64 pt. 5 rows is the most at this height
  (a row must stay at least 132 pt).
- **40 agents**: at the default, 12 in view and 28 scrolled; at the densest
  (5 rows), 20 in view. The cursor is kept in view; the waiting count, ⌘J and find
  reach every agent. ⌘1 to ⌘9 reach the first nine places. The list inside
  scrolls and keeps the shown agent in view.
- **Window 900 pt wide** (the minimum width; minimum height 560 pt): 2 columns;
  inside, the terminal is about 630 pt wide (under 760 pt pane width, so the
  header hides the current sentence while news shows). Projects that do not fit
  go into "N more". The status line shortens with "…" to fit between the
  projects and the waiting count.
- **Window 3,000 pt wide**: 9 columns of about 320 pt. The palette stays 640 pt.
  The line stays centred at 960 pt max width.
- **Very long names**: one line with "…" on tiles, rows, the header (at most 36 %
  of the header) and find rows; the whole name in the tooltip and to VoiceOver.
  The name field scrolls while editing.
- **Very long sentences**: cut with "…" at the tile's lines, one line in rows and
  the header; the whole sentence to VoiceOver and in the tooltip on hover.
- **A project name longer than 24 characters**: cut with "…" in the bar.
- **A terminal with no output yet**: the screen is empty but keeps its space;
  the sentence is the app's "Starting <CLI>" while the CLI starts and "No output
  yet" after.
- **A CLI that is not installed**: the agent is created and becomes Stopped with
  a problem: "<CLI> is not installed. Install it, then type to start."
- **A project folder that is gone**: its agents become Stopped with a problem
  when something is sent to them: "Folder missing. Put it back, or settle this
  agent."

## 10. Not in this build

Missions, scheduled jobs, worktrees, diffs, plan limits, a light theme, sounds.
