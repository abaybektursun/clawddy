# Clawddy shortcuts

The written authority on keys. Behaviour behind each key is in `flows.md`; the
words on menus and in the keys panel are in `words.md`.

## Rules

1. Inside a terminal, every key without ⌘ goes to the terminal: letters, Option
   and Control chords, Escape, arrows, Return, Tab, function keys.
2. Clawddy never takes a ⌘ chord that types or edits text in a terminal: ⌘⌫
   (delete to line start), ⌘K (clear screen), ⌘←/⌘→ (line start and end),
   ⌘↑/⌘↓ and ⇧⌘↑/⇧⌘↓ (jump to prompt), ⌘C, ⌘V, ⇧⌘V, ⌘A inside a terminal.
3. Clawddy may take Ghostty's tab and split keys: an agent window has neither.
4. System chords are never taken: ⌘Tab, ⌘`, ⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌘Space, ⌘,.
5. Clawddy's chords act only while the agent window is the main window. In that
   window they are claimed before the terminal sees them (some, such as ⌘J and
   ⌘Z, are Ghostty bindings that a focused terminal would otherwise handle
   first). A chord the owner binds in the Ghostty config acts as in Ghostty,
   except the chords in the table below, which are Clawddy's in the agent window.
6. Every key has a menu item with the key shown (Agent menu, Edit, Help), so
   every command is also reachable by the pointer.

## The keys

| Key | Command | Home, tiles | Home, line | Inside a terminal | Palette open |
|---|---|---|---|---|---|
| ⌘J | Next waiting agent | Walk: enters the next agent waiting on you (top bar shows "N of M waiting"); after the last, back where the walk began | Same | Same | Nothing (the palette keeps keys) |
| ⌘[ ⌘] | Previous agent, next agent | Nothing | Nothing | Enters the previous or next agent in the list, wrapping | Nothing |
| ⇧⌘[ ⇧⌘] | Previous project, next project | Switches project, wrapping; home opens with no tile selected (or back to the terminal if left inside) | Same | Same | Nothing |
| ⌘1 … ⌘9 | Agent in that place | Enters the tile in that place, counting settled places; a settled or empty place does nothing. Holding ⌘ for 200 ms shows numbers 1 to 9 over the first nine tiles' marks | Same | Enters the agent in that row of the list | Nothing |
| ⌘N | New agent | Opens the floating new-agent line over the tiles; Escape gives the tiles the keys back, the selection unchanged | Opens the floating new-agent line; Escape gives the line the keys back, its draft unchanged | Opens the floating new-agent line over the terminal | Nothing |
| ⌘P | Find or run a command | Opens the palette (find) | Same | Same | Closes it; focus returns |
| ⌘⎋ | Back to all agents | Nothing | Nothing | Leaves to home, cursor on this agent | Nothing |
| ⌘Z | Undo | Restores the last settled agent(s) or removed project (never cancels a start here) | While holding text: text undo. While empty: cancels the last start (within 6 s), or restores the last settle or project removal | Restores the last settled agent(s) or removed project (never cancels a start here) | Text undo in the field; in an empty new-agent line, cancels the last start (within 6 s) |
| ⌘D | Settle | Settles one selected agent if not working, moving the selection to the next tile (also when a walk began with nothing selected); with several selected, skips working, question and problem agents | Same | During a walk: settles in place, shows Undo in the top bar for 6 s, and advances straight to the next waiting agent. Outside a walk: settles and goes home | Nothing |
| ⌘U | Mark as unread | The cursor tile, if finished | Same | This agent, if finished | Nothing |
| ⌘O | Add a project folder… | Opens the folder panel | Same | Same | Nothing |
| ⌘− | Smaller tiles | One more row of tiles (until a row would be under 132 pt); remembered per project | Same | Ghostty's decrease font size | Nothing |
| ⌘+ (⌘=) | Larger tiles | One fewer row of tiles (down to 1) | Same | Ghostty's increase font size | Nothing |
| ⌘0 | Default tile size | Back to the default rows, max(2, round(height / 290)) | Same | Ghostty's reset font size | Nothing |
| ⌘? (⇧⌘/) | Keys | Shows or hides the keys panel | Same | Same | Nothing |
| ⌘A | Select every agent here | Selects every tile of the project | Selects all text in the line | Ghostty's select all (terminal text) | Selects all text in the field |
| ⌘C | Copy | Copies the selected agents' sentences, one per line, each as "<name>: <sentence>"; status line "Copied" | Copies the selected text | Ghostty's copy (terminal text) | Copies the selected text |
| ⌘↩ | Interrupt them and send | Nothing | With several selected: interrupts the working ones and sends. With one or none: starts the agent (as Return) | Nothing (Ghostty's full screen never fires in the agent window) | Find with no matches: starts an agent with the typed text, landing in the home line (at home) or keeping the floating new-agent line open and empty (inside a terminal); with matches: nothing. New agent: nothing |
| ⌘W | Close window | Closes the agent window; agents keep running | Same | Same (never closes the terminal) | Same |
| F2 | Rename | Renames the cursor tile in place | Nothing (types nothing) | Goes to the terminal (rule 1) | Nothing |

Every chord in this table has a stated outcome in every column; none reaches
a Ghostty binding by omission (`AgentChords`, checked by a test).

Passing through (arrows, ⌘[ ⌘], landing on an agent in the ⌘J walk) never
starts an agent's CLI; a deliberate open (Return, a click, a letter on a tile,
⌘1 to ⌘9) starts it at once (`flows.md` 4.5).

### Keys without ⌘

| Where | Key | Result |
|---|---|---|
| Home, tiles | ← → ↑ ↓ | Move the cursor; settled places are stepped over; no wrap. With no tile selected: Down or Right selects the first tile, Up or Left selects the last |
| Home, tiles | ⇧ + arrow | Range selection from an anchor tile, as in Finder; moving back toward the anchor deselects |
| Home, tiles | Return | Enter the cursor; with several selected, move to the line |
| Home, tiles | Escape | First collapses several selected tiles to the cursor, then clears the selection; with nothing selected does nothing |
| Home, tiles | Hold ⌘ (200 ms) | Shows numbers 1 to 9 over the first nine tiles' marks; releasing hides them |
| Home, tiles | A printable key (not Space, not with Control) | One selected (chip says "Reply to <name>"): enter its terminal and deliver the key there (not to a question menu). None or several selected: move to the line with the key |
| Home, tiles | Space | Nothing |
| Home, tiles | ⌥← ⌥→ | Move the selected tiles one place earlier or later; at either end nothing happens |
| Home, line | ⌥← ⌥→ | Move the caret by a word (text editing) |
| Dragging a tile or row | Escape | Put every tile or row back where it was; no other key acts during a drag |
| Home, line | Return | Start the agent, or with several selected send to all |
| Home, line | ⇧Return | New line |
| Home, line | Escape | Back to the tiles; never deletes text; with several selected and an empty line, also collapses the selection |
| Home, line | ↑ with the caret on the first line | Back to the tiles |
| Inside | everything | The terminal |
| Palette, find | ↑ ↓ | Move the highlight |
| Palette, find | Return | Run the highlighted result |
| Palette, any | Escape | Close; focus returns |
| Palette, new agent | Return | Start the agent; the field empties and stays open |
| Palette, new agent | ⇧Return | New line |
| Name being edited | Return | Keep the name (empty keeps the old) |
| Name being edited | Escape | Restore the old name |
| Name being edited | ⌘ chords | Text editing only; app keys do not act |

### Pointer and trackpad

| Gesture | Result |
|---|---|
| Mouse-down on a tile | Select it at once |
| Click a tile (release without moving) | Enter it |
| Drag a tile (past 4 pt) | Move it; the other tiles make room; release drops it; several selected move together |
| Drag a row in the list | Move it the same way |
| ⇧-click or ⌘-click a tile | Add it to or remove it from the selection |
| Right-click a tile or a list row | Menu: Open, Rename, Mark as unread, Settle |
| Click a list row | Enter it |
| Double-click the name in the header (inside) | Rename |
| Pinch together (inside) | Back to all agents |
| Pinch apart (home, a tile selected) | Enter the cursor |
| Click the waiting count | As ⌘J |
| Drop folders on the window | Add them as projects |

## What each chord does in Ghostty and macOS

Checked against Ghostty's default bindings (`src/config/Config.zig`, the default
key set, macOS branch) and the main menu (`macos/Sources/App/MainMenu.xib`).
"Taken" means the chord is Clawddy's in the agent window; the Ghostty menu item
keeps its name there and shows no key.

| Chord | Ghostty or macOS already | Decision |
|---|---|---|
| ⌘J | `scroll_to_selection` (Edit ▸ Find ▸ Jump to Selection), performable | Taken. It scrolls a view and does not type or edit; the loss is accepted. Must be claimed before the focused terminal. |
| ⌘[ ⌘] | `goto_split:previous` / `:next` | Taken (split keys). |
| ⇧⌘[ ⇧⌘] | `previous_tab` / `next_tab`; the macOS convention for tabs | Taken (tab keys). Same meaning: neighbour of the same kind. |
| ⌘1 … ⌘8, ⌘9 | `goto_tab:1…8`, `last_tab` | Taken (tab keys). |
| ⌘N | `new_window` | Taken in the agent window. |
| ⌘P | Nothing (Ghostty's command palette is ⇧⌘P; no Print item) | Taken. |
| ⌘⎋ | Nothing | Taken. |
| ⌘Z | Ghostty `undo` (undo closing a tab or split), performable | Taken: the agent window has no tabs or splits, and it does not edit terminal text. |
| ⌘D | `new_split:right` | Taken for Settle (split key). |
| ⌘⌫ | Sends `\x15`, delete to line start | Not taken (rule 2). This is why Settle is ⌘D. |
| ⌘U | Nothing | Taken. |
| ⌘O | Nothing | Taken. |
| ⌘? (⇧⌘/) | Help ▸ Clawddy Help | That item becomes "Keys". |
| ⌘A | `select_all` | Ghostty's inside a terminal; at home it selects tiles. |
| ⌘↩ | `toggle_fullscreen` (a terminal binding) | Taken everywhere in the agent window: the line and find use it, and elsewhere it does nothing, so full screen never fires by accident. |
| ⌘W | `close_surface` (would end the agent's CLI) | Taken: closes the window. ⇧⌘W (`close_window`) does the same. |
| F2 | Nothing in Ghostty; a terminal receives it as a key | Home only. |
| ⌘T, ⇧⌘D, ⌥⌘arrows, ⌃⌘arrows, ⌃⌘=, ⇧⌘↩, ⌥⌘W | Tab and split actions | Do nothing in the agent window. |
| ⇧⌘P | Ghostty's command palette | Does nothing in the agent window: Clawddy has one palette. |
| ⌘C | `copy_to_clipboard` | Ghostty's inside a terminal; at home with the tiles in focus it copies the selected agents' sentences. |
| ⌥← ⌥→ | Not a ⌘ chord; inside a terminal it goes to the terminal (rule 1) | Clawddy's only at home with the tiles in focus. |
| ⌘K, ⌘V, ⇧⌘V, ⌘←, ⌘→, ⌘↑, ⌘↓, ⇧⌘↑, ⇧⌘↓, ⌘Home, ⌘End, ⌘PgUp, ⌘PgDn, ⌘F, ⌘G, ⇧⌘G, ⌘E, ⇧⌘F, ⇧⌘J | Terminal editing, scrolling, search, write screen | Ghostty's, unchanged. |
| ⌘=, ⌘+, ⌘−, ⌘0 | Ghostty's increase, decrease and reset font size (View menu) | Taken at home for tile density; inside a terminal Ghostty's, unchanged. They change a view and never type or edit. |
| ⌘Tab, ⌘`, ⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌘Space, ⌘, | System and app conventions | Never taken. |

The CLIs inside: Claude Code and Codex use Control and Option chords, Escape,
Return, Tab, ⇧Tab and arrows, all of which reach the terminal. None of the ⌘
chords above reaches a CLI in Ghostty's default key encoding.
