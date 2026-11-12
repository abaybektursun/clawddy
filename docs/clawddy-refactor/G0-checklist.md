# Gate G0 checklist

For the owner, with the live Clawddy and Clawddy Dev running side by side. The
five checks are those of `docs/CLAWDDY_REFACTOR_PLAN.md`, Gate G0. About 20
minutes. Run the commands in zsh, in one terminal, in order; they keep their
notes in `$G0`.

## 0. Before launching Clawddy Dev

```sh
cd ~/projects/ghostty
macos/build.nu --identity dev   # P0.8 left a fresh build; rerun only if the source changed
APP=/Volumes/Xcode/GhosttyBuilds/ghostty/macos/dev/products/Release/Ghostty.app
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
/usr/bin/log stream --level info --style compact --predicate 'subsystem == "com.mitchellh.ghostty" AND category == "Clawddy" AND processImagePath CONTAINS "/macos/dev/products/"'
```

Launch Clawddy Dev:

```sh
env -u NO_COLOR open -na /Volumes/Xcode/GhosttyBuilds/ghostty/macos/dev/products/Release/Ghostty.app
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
ls ~/.config/clawddy-dev/status/$ID.fork.json       # gone: removed once the agent was seen alive
cat ~/.config/ghostty-agents/status/$ID.session.json 2>/dev/null || cat ~/.config/ghostty-agents/status/$ID.session
```

Passes when the dev `sessionID` equals the `--session-id` of the ps line and
differs from the live one. If `fork.json` is still there, Clawddy Dev never
saw the agent start (no hook arrived); its next Start forks again under
another new ID. Report that rather than retrying silently.

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
  preflight check). It builds `~/.config/.clawddy-dev-seeding-<uuid>` and
  renames it to `~/.config/clawddy-dev`. Codex agents are not copied, and
  nothing is copied from `cron/`, the journals, `runtime/` or `hooks/`.
- If the seed fails, the app stops at once ("Clawddy Dev quit unexpectedly").
  The reason is in the newest `ghostty-*.ips` in
  `~/Library/Logs/DiagnosticReports/`, after "Could not seed". No dev root is
  left, so the next launch seeds again; delete a leftover
  `~/.config/.clawddy-dev-seeding-*` folder first. The likeliest cause is the
  live app writing a file during the read; relaunching is enough.
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

The next launch seeds again from the live root. Sessions the dev agents
created stay in Claude's own store and do not affect the live agents. The dev
app's window and selection preferences are in their own domain; to reset them
too: `defaults delete com.mitchellh.ghostty.clawddy-dev`.
