# Adding agy (the Antigravity CLI) to Clawddy

Written 2026-11-25 against agy 1.5.17. Not built yet; this is the plan.

## What this plan does

Clawddy runs Claude Code and Codex agents today. This plan adds agy as a third
CLI an agent can run: same tiles, same typing line, same waiting, settling,
resuming and restart behaviour. An agy agent is the real `agy` program in a
real terminal, like the other two.

"Incorporate" was read that way. Other things agy offers (its editor protocol,
remote control, remote agents, its Python SDK) are listed at the end as later
options and are not part of this plan.

## The short version

agy fits the existing design better than Codex does, because it already
reports its own state to the terminal in the format Clawddy reads.

- **State (working, asks, needs permission, done, failed) comes from the
  terminal.** agy sends the same status report Claude Code sends (OSC 7501),
  after asking the terminal whether it understands it. The fork already
  answers that question. Nothing to build for this.
- **Identity and text come from agy's hooks**, loaded from a folder Clawddy
  owns and adds to the launch with `--add-dir`. Nothing of the owner's is
  written: not their project, not `~/.gemini/config`, not their agy settings.
- **Three rules in Clawddy's state logic are wrong for agy** and would show
  false states if agy were added as a plain copy of the Claude provider.
  They are listed under "Traps" and each needs a test.

Size: one new provider file about the size of the Codex one, a stand-in CLI
for tests, a screen reader for agy's input box, and small edits in about ten
files that branch on the CLI.

## What was read

- Every `agy` subcommand's help and the full changelog (1.5.10 to 1.5.17).
- The docs shipped inside the CLI (`~/.gemini/antigravity-cli/builtin/skills/`):
  hooks, JSON config files, plugins, the conversations API, the CLI and SDK
  references.
- 33 pages from `antigravity.google/docs` (CLI reference, settings, hooks,
  headless mode, status line, terminal title, conversations, resume, modes,
  permissions, sandbox, plugins, the editor protocol, remote control, remote
  agents, models, projects, SDK, swarm).
- The strings inside the `agy` binary, for what the docs leave out (the
  status-report switches, the input box hints).
- Seven live probes of the real CLI in a terminal of its own, in throwaway
  folders. Five cost one short model turn each; two cost none.

Copies of the docs, the probe script and its captures are in
`/Volumes/Xcode/GhosttyBuilds/ghostty/redesign-notes/agy/` (outside the
repository; the captures show real paths and are never committed).

## What a provider must supply, and where agy gives it

"Probed" means seen on the real CLI on 2026-11-25. "Docs" means documented
but not exercised.

| Need | agy mechanism | Source |
| --- | --- | --- |
| Start with a first prompt | `--prompt-interactive=<text>` as one argument; a prompt starting with `-` is taken as text | Probed |
| Start unrestricted | `--dangerously-skip-permissions` | Probed |
| Model and effort, when the person chose them | `--model <id>`, `--effort low\|medium\|high\|xhigh\|max`; ids come from `agy models`, never from code | Docs |
| Working, idle, done | OSC 7501 `state=working`, `idle`, `done` with `app=antigravity` | Probed |
| Asks a question | `state=blocked:kind=question`, message = the question | Probed |
| Needs permission | `state=blocked:kind=permission`, message such as "Approve Bash: echo chosen"; the folder trust dialog reports the same kind with "Trust this folder?" | Probed |
| Needs sign-in | `state=blocked:kind=auth` | Probed (start-up only, see Traps) |
| Failed | `state=error`; the Stop hook carries `terminationReason` and `error` | Docs; not seen live |
| Conversation id | `conversationId` in every hook record; a conversation exists only after the first prompt | Probed |
| The prompt, at the turn's start | PreInvocation hook, `lastUserInput`, when `invocationNum` is 0 | Probed |
| The last reply, in full | Last `PLANNER_RESPONSE` line of the file named by the hook's `transcriptPath`, read at the Stop hook | File format probed; timing at Stop not yet |
| Resume | `--conversation <id>` | Probed |
| Same conversation open elsewhere | `~/.gemini/antigravity-cli/presence/<id>.lock` is held while a process has the conversation open and free after it exits | Probed |
| Interrupt a turn | Escape once: the turn ends, state goes to `idle` | Probed |
| Empty the input line | Escape twice, 0.1 s apart | Probed |
| Submit | Return; a pasted block (bracketed paste) lands in the input box as typed | Probed |
| Message sent while working | Queued by default and sent when the turn ends | Probed |

## Decisions

**1. Hooks come from a folder of Clawddy's, added with `--add-dir`.**
agy loads hooks from three places only: the project's `.agents/hooks.json`,
`~/.gemini/config/hooks.json`, and installed plugins. All three are the
owner's. The probe showed a fourth way: a folder passed with `--add-dir` has
its `.agents/hooks.json` loaded, with no trust question for that folder. So
each agent gets `<Clawddy data>/agy/<agent id>/.agents/hooks.json`, written at
launch, whose commands are the existing hook script with the agent's identity
as arguments. This is the same shape as Claude's per-agent settings file.

Where the folder lives matters (the hook-place probes): agy lists its workspace
folders **sorted by path**, whatever the argument order, and the model takes
the first as its own folder and default command folder. A hook folder inside
the data folder (`~/.config/<app>/runtime/…`, or the harness's `root/runtime`)
sorts before most projects: in 3 of 3 runs of "Read notes.txt and summarize it
in one sentence." the model first read `notes.txt` in the hook folder, and asked
what it saw, it named the hook folder its default command folder. So the folder
is `<per-user cache folder>/<app data folder name>/<agent id>/agy`, the cache
folder being macOS's `/var/folders/…/C/` (`DARWIN_USER_CACHE_DIR`), which sorts
after every project under `/Users` or `/Volumes`; there 0 of 3 runs touched it
and the model names the project first and as its default. The hook folder
would still sort before a project under `/var` itself; none is expected. No
shipped build used the folder's former place, so no conversation lists it.

Rejected: writing into the project (shows up in the owner's git status and in
their own agy sessions); a global hook (changes every agy session on the
machine); a plugin (installing one edits the owner's config).

Cost of this choice: the folder is part of the agent's workspace, so the
agent can see it, second in its list. It holds one small file. No other way
loads hooks without writing the owner's files: `--settings` hooks are not
loaded (docs), the global and plugin places are under `~/.gemini/config`, and
the binary reads no variable that moves that folder.

**2. `--settings` is not used.**
It works per session and is not saved (probed), but a key passed there
replaces the owner's value for that key. Passing a trusted-folder list made a
folder the owner had already trusted ask for trust again. The plan needs no
settings, so none are passed.

**3. No hook that gates a tool.**
A PreToolUse hook must print a decision; one that prints `{}` denies the tool
call (probed: it blocked the agent's own question). A bug in Clawddy's script
would then stop agents from working. The question text comes from the
terminal report instead. Clawddy subscribes to SessionStart, PreInvocation
and Stop only, and its script prints `{}` for each.

**4. The same send recipe as the other two.**
Input line empty, paste, Return. Interrupt-and-send is Escape, wait for
`idle`, empty the line if the interrupt gave text back, paste, Return. agy has
its own key for "send this one now" (Alt+M), but what it does depends on a
setting of the owner's, so it is not used.

**5. Control-C is never sent to agy.**
With a turn running it interrupts. With none, the first press arms "press
ctrl+c again to exit" and the second ends the program, typed text and all
(probed). Escape does both jobs safely.

**6. The name shown is "Antigravity"; the stored value is `antigravity`.**
The program calls itself Antigravity CLI. The command stays `agy`.

## Traps: where agy differs and Clawddy's rules are wrong today

Each of these is a rule in `AgentStateReducer.swift` or the screen readers
that holds for Claude Code and is false for agy.

1. **Every `done` from agy carries a message.** Today a `done` with a message
   is treated as "something other than a turn ended" (true for Claude, where
   it marks a compaction) and completes nothing. For agy it is the normal end
   of a turn. Without a change, no agy turn would ever be reported as
   finished. The rule becomes a value in the provider table.
2. **agy reports "sign in required" at every start, for about 30 ms, even
   when signed in.** Today that report fails the agent at once with "login
   expired". For agy it must stand for a short time before it counts, the way
   a `working` must stand before it starts a turn. Also a value in the
   provider table.
3. **The message in a report is cut at 200 characters** and a multi-paragraph
   reply is cut to its first line. So the last reply has to come from the
   transcript, and a long question is shown cut. The 200 limit was seen on a
   reply; a question that long has not been tried.
4. **agy's input box looks like its echo of your prompt.** The box is the
   rows between the last two full-width rules, first row starting with `>`.
   Each submitted prompt is echoed above as a shorter rule followed by
   `> text`. The reader must require both rules to span the terminal, or it
   reads the echo as typed text.
5. **An empty box shows a hint that reads like text**, and the hint changes
   with the mode: "Auto mode: edits & safe commands auto-approved (shift+tab
   to cycle)", "Plan mode: …", "Accept-edits mode: …". All end with
   "(shift+tab to cycle)". After the line is emptied by hand the box shows a
   bare `>`.
6. **An interrupt gives queued text back.** A message queued while agy worked
   returns to the input box when the turn is interrupted. The existing rule
   (never wipe what the person typed; refuse the send and say why) covers it,
   but it needs its own test.
7. **agy does not refuse a conversation that is already open.** A second
   process given the same `--conversation` id answered in it. Clawddy's own
   check on the presence lock is the only guard.
8. **The path in the status-line payload is wrong in 1.5.17.** Its
   `transcript_path` names `~/.gemini/antigravity/…`; the file is under
   `~/.gemini/antigravity-cli/…`. The hook's `transcriptPath` is right. Use
   the hook's.
9. **agy updates itself often** (1.5.16 became 1.5.17 during this work). The
   facts above are written down with the version; the stand-in and its tests
   are built from captured bytes so a change shows up as a failing test
   against a new capture, not as a guess.

## Corrections after stage 1

Stage 1 ran thirteen more starts of the real CLI. The full facts are in
`docs/clawddy-refactor/cli-facts.md`; where they differ from the text above,
they win:

- The sign-in report does not come at every start, and it stood for half a
  second in two starts. It counts only once it has stood for 2 seconds.
- Default mode shows no hint in an empty input box, and no mode shows one
  after anything was typed. The box is empty when the text after `>` is empty
  or ends with "(shift+tab to cycle)".
- The one live failure ran no hook. Failures come from the terminal report.
- SessionStart does not fire on a resume, `/clear` starts a new conversation
  id, and an unknown `--conversation` id silently becomes a new conversation.
  Every hook record binds the id it carries, and a resume first checks that
  the conversation still exists.
- No Stop hook fires after an interrupt.
- Questions in a report are cut at 180 characters, replies at 200.
- The transcript already holds the full reply when the Stop hook fires.
- On a resumed conversation the `working` report carries the conversation's
  title, which is not an activity.

## Work, in order

One engineer, one stage at a time, each stage ending with the tests passing
and a review, as in the redesign.

### Stage 1. Facts and the stand-in

- Add an "agy" section to `docs/clawddy-refactor/cli-facts.md` from the
  captures: the status reports with their timing, the hook records, the
  screens, the keys.
- Close the open facts with the probe script (each is seconds of work):
  whether the transcript already holds the last reply when Stop fires; what a
  question longer than 200 characters looks like in the report; what the Stop
  record says after an interrupt; the hint in default mode; whether
  SessionStart fires when a conversation is resumed in the terminal.
- Write `macos/Tests/AgentManagement/StandIns/agy`: takes the flags above,
  draws agy's input box, sends the captured status reports, and runs the
  hooks from the added folder with records shaped like the real ones.

Done when `check.py` runs the stand-in through start, prompt, question,
permission, interrupt, resume and exit.

### Stage 2. The provider

- `AgentProvider.swift`: a third case in `AgentProviderID` (name, `agy`,
  symbol, start-mode titles and arguments); a third entry in the provider
  table; two new values per entry: whether a `done` with a message completes
  a turn, and how long a sign-in report must stand.
- `AntigravityProvider.swift`, modelled on `CodexProvider.swift`:
  - event table: SessionStart binds the conversation; PreInvocation with
    `invocationNum` 0 reports the prompt; Stop reports the last reply, and a
    failure when `terminationReason` is `ERROR`;
  - `prepareLaunch`: find `agy`, write the agent's hook folder, refuse when
    the presence lock is held, build the arguments;
  - `probe`: installed and its version. agy has no command that reports
    sign-in, so the terminal's own report is what tells the person;
  - `cleanup`: remove the agent's hook folder.
- `AgentHookRuntime.swift`: agy names its fields differently
  (`hookEventName`, `conversationId`), wants `{}` printed, and its last reply
  is read from the transcript. The script's per-CLI table grows by one entry.

Done when the provider's unit tests pass against the stand-in, including: a
first prompt starting with `-`; a resume refused while the lock is held; a
launch whose hook folder cannot be written failing loudly.

### Stage 3. State and screen rules

- `AgentStateReducer.swift`: the two table values from stage 2 replace the
  two fixed rules (traps 1 and 2). Claude's and Codex's behaviour is
  unchanged and their tests still pass untouched.
- `AgentTerminalInput.swift` and `AgentTail.swift`: readers for agy's input
  box, written against the captured screens (traps 4 and 5), including the
  question menu, the permission menu and the trust dialog, which must read as
  "a menu is showing".
- `AgentTerminalBridge.swift`: emptying the line is Escape twice for agy.

Done when each trap above has a test that fails without its fix.

### Stage 4. The parts of the app that name a CLI

- `AgentCommands.swift`, the Agent menu, the palette: "New Antigravity
  agent".
- `AgentPreferences.swift`: the default start mode is two named fields today;
  make it one value per CLI so a third does not add a third pair.
- The typing line's chip, the tile's sentence, "Starting Antigravity…", the
  settings window.
- `words.md`, `flows.md` and `shortcuts.md` where they list the CLIs.

Done when a scene with all three CLIs side by side matches the pictures: the
only visible difference between agents is the name on the chip.

### Stage 5. Proof with the real CLI

- A harness run with `--real`: start with a first prompt, answer a question,
  approve a command, interrupt, send while working, quit the app and reopen
  (the conversation resumes), try to open the same conversation twice (it is
  refused and says why).
- The existing soaks with agy agents in the mix: no lost keys, no window
  taking focus, idle main thread unchanged.
- An independent review of the diff before it is handed over.

## Not proven, and how each gets proven

| Open | How |
| --- | --- |
| What agy reports when the usage limit is reached | Half proven (stage 7, a local gateway answering 429): after its retries agy writes a Stop with `terminationReason` "ERROR" and an `error` that matches agy's own quota rule; the app shows that as paused at the usage limit, with the `error` report's words, no reset time. Not seen: the `error` report and screen of a quota failure (agy's first-run setup stays over the turn with a gateway set, and finishing it means accepting its terms), and a limit from Google's servers themselves. The same gap is open for Claude and Codex. |
| The trust dialog's "Yes" with the real agy | Still open: no variable moves agy's settings (stage 7: `ANTIGRAVITY_EXECUTABLE_DATA_DIR` is its sidecars' folder), and "Yes" writes the owner's trusted folders. Proven against the stand-in only. |
| What a signed-out agy reports after start-up | Proven at start (stage 6, a throwaway `HOME`): `blocked kind=auth` stands, the login method menu shows, the tile shows the login problem after 2 s. A sign-in completed afterwards: not done. |
| `state=error` on a live failure | Proven (stage 6): before a turn, and during one after agy's retries (a Stop with `terminationReason` "ERROR", then `error`). |
| Whether a hook folder inside the workspace changes what the agent does | Measured (stage 6, 14 turns): no file went there, but with the folder sorting first the model read there once and took it for its default command folder. Cause and fix (the hook-place probes): agy sorts the folders by path; the folder moved to the per-user cache folder, which sorts after the project: 0 of 3 runs touched it against 3 of 3 before (decision 1). |

## Later options, not in this plan

- **Quota on the tile.** agy passes a JSON status to a `title` or
  `statusLine` command at each state change: the remaining share of each
  quota with its reset time, tokens used, the conversation title, whether a
  confirmation is pending. A `title` command passed with `--settings` works
  per launch (probed). It would let a tile say when the limit resets. It
  replaces the owner's own title command for that session, which is why it is
  left out of the first build.
- **agy's own title as the agent's name**, from the same payload.
- **The conversations API** (create, list, read state, rename, delete over
  local HTTP), reachable only from inside an agent's shell. Useful if Clawddy
  ever lists agy conversations it did not start.
- **`agy acp`**, the editor protocol over stdin and stdout. It would replace
  the terminal with Clawddy's own drawing of the conversation, which is the
  opposite of what Clawddy is.
- **Remote control and remote agents.** Flags exist (`--remote-control`,
  `--remote-agent`); nothing in Clawddy needs them.
- **agy's subagents and swarm.** They run inside one agy and show in its
  terminal. The status payload lists them if tiles should ever count them.
