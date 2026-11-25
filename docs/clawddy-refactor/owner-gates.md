# Gate G0 checklist

For the owner, with the live Clawddy and Clawddy Dev running side by side. The
five checks are those of `docs/CLAWDDY_REFACTOR_PLAN.md`, Gate G0. About 20
minutes. Run the commands in zsh, in one terminal, in order; they keep their
notes in `$G0`.

## 0. Before launching Clawddy Dev

Clawddy Dev is what `macos/build.nu` builds by default (output under
`/Volumes/Xcode/GhosttyBuilds/ghostty/macos/dev/products/Release/`). The
production app, `--identity production`, is built only at switch-over, with
the live app quit; never build or launch it for G0.

```sh
cd ~/projects/ghostty
# The app under gates/final is a frozen copy of the dev build of the finished engine, so later builds cannot replace it while it runs.
APP=/Volumes/Xcode/GhosttyBuilds/ghostty/gates/final/Ghostty.app
plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist"   # com.mitchellh.ghostty.clawddy-dev
B=~/.config/ghostty-agents-backups/20261112-081548-baseline
G0=/Volumes/Xcode/GhosttyBuilds/ghostty/logs/g0
mkdir -p "$G0"
ls ~/.config/clawddy-dev   # must fail with "No such file or directory": the first launch seeds it
```

Pick one Claude agent that is **not running in the live app** during G0 (its
own live activity would change the files check 3 compares):

```sh
jq -r '.projects[] | .name as $p | .tasks[] | .name as $t | .agents[]
  | select(.provider == "claudeCode") | "\(.id)  \($p) / \($t) / \(.name)"' \
  ~/.config/ghostty-agents/agents.json
ID=<the agent's UUID>
cat ~/.config/ghostty-agents/status/$ID.session.json 2>/dev/null || cat ~/.config/ghostty-agents/status/$ID.session
```

The last line prints the live session ID. Record what checks 3 and 5 compare:

```sh
(cd ~/.config/ghostty-agents/status && stat -f '%m %z %N' $ID.* && shasum $ID.*) > "$G0/agent-before.txt"
find ~/.config/ghostty-agents/cron -exec stat -f '%m %z %N' {} + > "$G0/cron-before.txt"
```

In a second terminal, start the log of Clawddy Dev only. Its "info" lines are
kept in memory, not on disk, so start this before launching. Use the full
path: in zsh, a bare `log` is a different, built-in command.

```sh
/usr/bin/log stream --level info --style compact --predicate 'subsystem == "com.mitchellh.ghostty" AND category == "Clawddy" AND processImagePath CONTAINS "/gates/final/"'
```

Launch Clawddy Dev:

```sh
env -u NO_COLOR open -na /Volumes/Xcode/GhosttyBuilds/ghostty/gates/final/Ghostty.app
```

The log shows, in this order:

```
seeded /Users/<you>/.config/clawddy-dev from /Users/<you>/.config/ghostty-agents: <N> Claude agents, <M> fork markers
data root /Users/<you>/.config/clawddy-dev
```

On the P0.7 rehearsal copy N and M were 66 and 66. The same counts stay on disk:

```sh
jq '{sourceAgents, agents, codexAgents, forkMarkers}' ~/.config/clawddy-dev/migration-seedDevCopy.json
cat ~/.config/clawddy-dev/status/$ID.fork.json   # sourceSessionID is the live session ID printed above
```

## 1. Start, use and stop one seeded agent

In Clawddy Dev, select the agent and press Start. While it runs:

```sh
ps -axww -o pid=,args= | grep -e '--fork-session' | grep -v grep
```

The line contains `claude --resume <live session ID> --fork-session --session-id <new ID> --name <agent name>`.
Send one prompt, wait for the answer, then type `/exit`.

## 2. Global provider files are byte-identical to the P0.2 backup

```sh
cmp ~/.claude/settings.json "$B/claude-settings.json" && cmp ~/.codex/hooks.json "$B/codex-hooks.json" && cmp ~/.codex/config.toml "$B/codex-config.toml" && echo "all three identical"
```

All three were still identical to the backup when P0.8 was committed. If one
differs, `diff` it against the backup to see what changed and whether the live
app, Claude or Codex wrote it.

## 3. No live status file of the seeded agent changed

```sh
(cd ~/.config/ghostty-agents/status && stat -f '%m %z %N' $ID.* && shasum $ID.*) > "$G0/agent-after.txt"
diff "$G0/agent-before.txt" "$G0/agent-after.txt" && echo "unchanged"
```

This covers its `metadata.json`, `events` and bindings.

## 4. The dev agent's session ID differs from the live one

```sh
cat ~/.config/clawddy-dev/status/$ID.session.json   # sessionID is the <new ID> from the ps line
ls ~/.config/clawddy-dev/status/$ID.fork.json       # gone: removed at the agent's first turn
cat ~/.config/ghostty-agents/status/$ID.session.json 2>/dev/null || cat ~/.config/ghostty-agents/status/$ID.session
```

Passes when the dev `sessionID` equals the `--session-id` of the ps line and
differs from the live one. If `fork.json` is still there, Clawddy Dev never
saw the first turn start; its next Start forks again under another new ID.
Report that rather than retrying silently. A fork closed without a prompt
keeps its `fork.json` and has no `session.json` on purpose: Claude does not
save a session before its first message, so the next Start forks again.

## 5. Hot key, notifications, environment, agent-cron

- With both apps running, press Option-Space: the **live** palette opens.
- System Settings, Notifications lists "Clawddy Dev" apart from "Clawddy".
  It appears only after Clawddy Dev has asked for permission (see below).
- In Clawddy Dev, open a plain terminal (File, New Window) and run
  `env | grep -E 'GHOSTTY_AGENT_|CLAWDDY_'`: no output.
- agent-cron's folder:

```sh
find ~/.config/ghostty-agents/cron -exec stat -f '%m %z %N' {} + > "$G0/cron-after.txt"
diff "$G0/cron-before.txt" "$G0/cron-after.txt" && echo "unchanged"
ls ~/.config/clawddy-dev   # no cron folder
```

agent-cron keeps running during G0, so a change from one of its own scheduled
runs is expected; anything else is a failure.

## What Clawddy Dev does on its first launch

- It reads the live root and never writes it: `agents.json`, `state.json`,
  the Claude agents' binding files, and the unread end of each journal (a
  preflight check). Holding the dev root's lock, it writes the fork markers
  and `state.json` into `~/.config/clawddy-dev`, then `agents.json` last.
  Codex agents are not copied, and nothing is copied from `cron/`, the
  journals, `runtime/` or `hooks/`.
- If the seed fails, the app stops at once ("Clawddy Dev quit unexpectedly").
  The reason is in the newest `ghostty-*.ips` in
  `~/Library/Logs/DiagnosticReports/`, after "Could not seed". The dev root
  has no `agents.json` then, so the next launch seeds again over what was
  written, and nothing is left beside it. The likeliest
  cause is the live app writing a file during the read; relaunching is enough.
- A second Clawddy Dev started at the same time says that Clawddy is already
  running and quits; only the first one seeds.
- The workspace window opens with the seeded agents. Nothing starts until you
  press Start.
- macOS asks once whether "Clawddy Dev" may send notifications, the first time
  it updates its Dock badge or posts a notification. Allow it, for check 5.
- The agents use the same project folders as the live ones, which Claude
  already trusts, so no folder trust dialog is expected.
- On the first Start, Clawddy Dev writes its hook scripts to
  `~/.config/clawddy-dev/hooks/` and the agent's settings to
  `~/.config/clawddy-dev/runtime/<ID>/`. It writes nothing under `~/.claude`
  or `~/.codex`. Claude itself writes the forked session's transcript under
  `~/.claude/projects/`, as for any session; the live session's transcript is
  only read.
- `~/.claude/settings.json` still holds the live app's 13 global hook entries.
  They also run inside dev Claude sessions and exit at once without writing,
  because Clawddy Dev gives Claude no `GHOSTTY_AGENT_*` variables.

## Start over with a fresh seed

Quit Clawddy Dev (Cmd-Q in it, or
`osascript -e 'tell application id "com.mitchellh.ghostty.clawddy-dev" to quit'`),
then:

```sh
rm -rf ~/.config/clawddy-dev
```

The next launch seeds again from the live root, as it does whenever the dev
root has no `agents.json`. Sessions the dev agents
created stay in Claude's own store and do not affect the live agents. The dev
app's window and selection preferences are in their own domain; to reset them
too: `defaults delete com.mitchellh.ghostty.clawddy-dev`.

# Gate G3 checklist (status reports reach the app)

Same app, same session as G0. About 15 minutes. In a third terminal, watch the
status reports the dev app receives:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "com.mitchellh.ghostty.clawddy-dev" AND category == "ghostty" AND eventMessage BEGINSWITH "program_status"'
```

1. In Clawddy Dev open a plain terminal (File, New Window) and run
   `printf '\e]7501;?\a'; sleep 1`. The terminal answers (a short burst of
   characters may be echoed at the prompt). No log line is expected for the query.
2. Run `printf '\e]7501;state=working\a'`: one log line `program_status state=working`.
   Run `printf '\ec'`: one log line `program_status state=clear`.
3. Create a dev agent in standard mode (so permission prompts appear), start it,
   and ask for something that needs a permission, for example "create a file
   named g3.txt containing hello". The log shows, in order: `idle`, `working`,
   `blocked kind=permission`, `working` after you allow it, `done`. The agent's
   header shows Working, Waiting for You, then Ready with a completion.
4. Type `/exit`. The log shows `clear`, then one line with `id=clawddy`. The
   header shows Exited at once.
5. No line containing "unknown action" in the dev app's log.

If step 1 or 2 fails, stop and report: the terminal core is not forwarding. If
only step 3 or 4 fails, paste the log lines.

# Acceptance checklist (gate GA, once, after the soak)

Engine behaviour that unit tests cannot prove. Each line is one action and what
must happen.

- Cmd-W on a running agent asks before closing. With `confirm-close-surface = false` in the Ghostty config it does not ask.
- Cmd-Q with running agents asks, and names how many are running; try with only agents running, and with one extra terminal window.
- Esc during a turn: the agent returns to Ready within a second, with no completion and no notification.
- A completion while you are viewing the agent leaves no unread mark. One that arrives after you switched to another agent, or with the app in the background, leaves one.
- `kill` the provider process: the agent shows Exited at once.
- `/clear`, then Restart: the post-clear session is resumed (the pre-clear conversation is not shown).
- After `/exit`, type `claude` by hand in the leftover shell: the agent stays Exited. Restart then asks before closing that shell.
- Rename a running agent: nothing is typed into its terminal. After the next start, `/status` in Claude shows the new name.
- `/compact`: shows Optimizing Context, then Ready, with no completion and no notification.
- A long tool call (for example `sleep 150` allowed to run in the foreground): the agent shows Working throughout, never Status Delayed.
- Open a seeded agent, type nothing, `/exit`, start it again: it forks again from the live conversation and its history is there.
- Quit Clawddy Dev, put the single character `{` into `~/.config/clawddy-dev/preferences.json`, start it: Settings and the New Agent sheet show the error, and the start mode offered is standard. Remove the file afterwards.
- VoiceOver on: a completion, a permission prompt and a failure are each announced once.
- A Codex agent in Clawddy Dev shows the notice that this build does not track Codex status, and its terminal works.

Anything that differs is a bug that blocks switch-over; note what you did and what you saw.

# D1 rollback

From design step D1 on, the first start of a build on a root whose
`agents.json` still has tasks (schema 5) runs `flattenV6` once, on the live
and the dev root alike. It first copies the root, without `cron/`, to
`<root>-backups/<yyyyMMdd-HHmmss>-flattenV6/` beside it (for the live app
`~/.config/ghostty-agents-backups/`, for Clawddy Dev
`~/.config/clawddy-dev-backups/`), stops without writing anything if the data
is not what it expects, and leaves `migration-flattenV6.json` in the root. It
does everything `cleanupV5` does too, so a production build of D1 or later
needs no separate `cleanupV5`.

To roll back, quit the new app and, before the previous app starts, copy
`agents.json` from that backup over the root's; then put the previous app
back and start it. Nothing else needs restoring, because the bindings and
`state.json` that `flattenV6` leaves are ones the previous app reads; agents
created, renamed or moved in the new app since the migration are not in the
restored file, and the next start of a D1 build migrates it again.

```sh
B=$(ls -d ~/.config/ghostty-agents-backups/*-flattenV6 | tail -1)
cp "$B/agents.json" ~/.config/ghostty-agents/agents.json
```

The migration also turns a task scope saved in the workspace preferences into
its project's scope; the previous values are in `$B/workspace-defaults.json`
and need not be restored. The frozen engine build under `gates/final` reads
schema 5 only: on a schema 6 dev root it shows that the configuration could
not be loaded and saves nothing.
