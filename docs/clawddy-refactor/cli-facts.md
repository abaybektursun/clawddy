# Clawddy refactor: observed CLI facts (Claude Code 2.1.322, Codex CLI 0.166.0)

Captured 2026-11-11 on the owner's machine by a PTY spike. Everything in sections 1–4 is the experiment report verbatim, except for these redactions:

- `<CLAUDE_CONFIG>` is the Claude Code user config directory, `<CODEX_HOME>` the Codex home directory, `<CLAWDDY_CONFIG>` the Clawddy config directory (all three are under the owner's home).
- `<sid-…>` / `<uuid-N>` replace session ids; `<live-agent-N>` / `<live-sid-N>` replace live agent ids and their session ids.
- Typed prompt text is replaced by a description in angle brackets.
- `<SPIKE>` is the scratch directory `/private/tmp/claude-501/-Users-abaybektursun-projects-ghostty/ecee68dc-7e24-4e70-a0d9-554f08565b6d/scratchpad/spike` (captures stay there and were not copied).

The harness scripts are in `spike-harness/` next to this file (see Appendix E).

---

I ran 10 CLI sessions (7 Claude, 3 Codex) in a PTY harness that answers terminal queries like Ghostty 1.3.2-dev. Everything below is from captured bytes or JSON unless marked NOT OBSERVED. Nothing touched live agent state.

**Safety baseline:** this shell is not inside a Clawddy agent. Its ancestry is `/Applications/Ghostty.app → login → zsh → claude (26380) → zsh`, and no `GHOSTTY_AGENT_*` variable is set anywhere in it. With no inherited `.events` file to watch, I snapshotted the whole `<CLAWDDY_CONFIG>/status/` directory instead, and stripped `GHOSTTY_AGENT_*`, `CLAUDE*` and `CODEX_*` from every launch.

## 1. Facts

### A1 — OSC 7501 format in the fork (read from source)
- **Format:** `ESC ] 7501 ; key=value:key=value… ST`, where ST is BEL or `ESC \`. `state` is required: `idle`, `working`, `done`, `blocked`, `error` or `clear`.
- **Optional keys:**
  - `id`: names made of `[A-Za-z0-9_.+-]` joined by `/`, at most 128 bytes, 8 levels, 32 bytes per part.
  - `kind`: `permission`, `question` or `auth`; only read when blocked.
  - `progress`: 0–100; only read when working or blocked.
  - `app`: at most 32 bytes.
  - `title`: base64, at most 192 bytes decoded.
  - `msg`: base64, at most 2048 bytes decoded.
- **Rules:** each report replaces the record for its id. `clear` removes that record and everything under it, or every record if there is no id. Unknown keys are skipped. A bad state, a value over its limit, a bad id or bad base64 discards the whole report.
- **Query:** body `?`. The reply is `ESC]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth`, ended with the same terminator the query used.
- **In the fork:** libghostty-vt (`stream_terminal.zig:983`) replies only when a `program_status` callback is installed. The macOS app path (`src/termio/stream_handler.zig:388`) lists `.program_status` as unimplemented and does nothing. **Today Clawddy neither answers the query nor shows the reports.**

### A2 — Claude: OBSERVED
- **Startup query:** `ESC]7501;?BEL` 0.2–0.5 s after launch, before the trust dialog.
  - With my reply, the debug log says `programStatus=yes (probe: OSC 7501 reply)`.
  - With no reply (exp5): `programStatus=no (probe: no reply to OSC 7501 ; ?)` and zero reports. Claude falls back to status glyphs in the title (`OSC 0 "◐ Claude Code"`, then `"✳ Single word reply"`).
- **TERM does not matter (exp6):** with `TERM=xterm-256color` and no `TERM_PROGRAM`, Claude still queries and still emits. Only OSC `9;4` progress disappears.

Lifecycle, all terminated with BEL, all `app=claude-code` (msg shown decoded):

| Event | Bytes / timing |
|---|---|
| Trust accepted, or resume | `state=idle` |
| Prompt submitted | `state=working`, 34–50 ms after Enter |
| Tool running | `state=working:msg=` "Creating empty marker file" |
| Permission prompt | `state=blocked:kind=permission:msg=` "approve Bash: touch spike_marker.txt", in the same frame as the dialog (24.020 vs 24.025 s). OSC `777;notify;Claude Code;Claude needs your permission` follows 6 s later |
| AskUserQuestion | `state=blocked:kind=question:msg=` "answer: Which do you choose: A or B? (A · B)" |
| Turn finished | `state=done`, about 60 ms after the answer renders, once Stop hooks finish. A second report 1.5–2.5 s later adds a summary, e.g. `msg=` "replied with the single word ok as requested" |
| Esc on the permission prompt | `state=idle`; the screen says "Interrupted · What should Claude do instead?" |
| Esc mid-turn | `state=idle` 46 ms later, and the prompt text is put back in the input box |
| `/clear` | `working`, then `idle` within 50 ms |
| `/exit` | `working`, then `state=clear` three times, then `OSC 0 ""` |
| Trust declined | `9;4;0;`, then `7501;state=clear`, then exit code 1 |
| Focus in or out (exp10) | No effect. `done` is sent focused or not, and stays until the next prompt |
| `error` | NOT OBSERVED |

### A3 — Codex: OBSERVED in part
- Codex never queries. It emits on its own, terminated with `ESC \`, even with a generic TERM (exp9).
- During startup, before any prompt: `state=idle:app=codex`, then `working` for about 0.5 s, then `idle`.
- A prompt gives `working`, then about 1 s later `state=error:app=codex`. The screen shows: "The 'gpt-6-astra' model is not supported when using Codex with a ChatGPT account."
- Esc after the error gives `state=idle`. `/quit` gives `OSC 0 ""` and `ESC]7501;state=clear ESC\`.
- **NOT OBSERVED for Codex:** `blocked`, `done`, and a real mid-turn interrupt. Every turn fails with the user's configured default model, and I was told not to pass a model.

### A4 — Is OSC 7501 enough on its own?
- **Claude gives:** working vs idle, blocked permission vs blocked question, and done vs idle.
- **Codex gives:** `error`.
- **It cannot tell apart:** an interrupt, a denied permission (Esc) and `/clear` — all three end in `idle`.
- **Compared with hooks it lacks:** session id, prompt id, model, permission mode, effort, cwd, transcript path, end reason, and tool name (only free text in `msg`).

### B — Claude hooks through `--settings`
- **B1 — they fire, merge, and carry arguments: OBSERVED.**
  - My `--settings` hooks ran. The user's global hooks ran in the same session too (`clawddy-provider-hook.sh`, `context_gate.py` printing "context staging: 25 pending", and `now.py`, which wrote `<CLAUDE_CONFIG>/hooks/.last/<sid-C>`). They merge; nothing is replaced.
  - Command-line arguments arrive intact: argv was `["agent-A2","gen-7",…]`.
  - **Hooks don't run until workspace trust is accepted.** The debug log says: "Skipping SessionEnd:other hook execution - workspace trust not accepted".
- **B2 — payload fields: OBSERVED.** Fields present on every event: `session_id`, `cwd`, `transcript_path`, `scratchpad_dir`, `hook_event_name`.

| Event | Extra fields |
|---|---|
| SessionStart (startup) | `source`, `model` |
| SessionStart (clear) | `source`, `session_title`; no `model` |
| UserPromptSubmit | `prompt`, `prompt_id`, `permission_mode`, `session_title` |
| Stop | `prompt_id`, `effort {level}`, `permission_mode`, `last_assistant_message`, `stop_hook_active`, `background_tasks`, `session_crons` |
| PreToolUse | `tool_name`, `tool_input`, `tool_use_id`, `prompt_id`, `effort`, `permission_mode` |
| PermissionRequest | `tool_name`, `tool_input`, `permission_suggestions`, `prompt_id`, `effort`, `permission_mode` |
| Notification | `notification_type: "permission_prompt"`, `message`, `prompt_id` |
| SessionEnd | `reason`, `prompt_id` |

  - **Never present:** `turn_id`. `model` appears only on SessionStart at startup.
  - **SessionEnd reason:** `"clear"` on `/clear`, `"prompt_input_exit"` on `/exit`.
  - **`/clear` changes the session id:** `<sid-A>` ended, then a new SessionStart with `source:"clear"` and id `<sid-B>`.
  - **Stop does not fire** for an interrupted turn or an Esc-denied permission.
  - **AskUserQuestion also fires PermissionRequest.**
  - **A stray SubagentStop** (`agent_type: ""`) fires after completed turns, with no matching SubagentStart.
- **B3 — `sessionTitle` renames the session: OBSERVED.**
  - A SessionStart hook printing `{"hookSpecificOutput":{"hookEventName":"SessionStart","sessionTitle":"…"}}` led to:
    - `OSC 0` set to that title;
    - transcript entries `{"type":"custom-title","customTitle":…}` and `{"type":"agent-name",…}`;
    - statusLine `session_name` and UserPromptSubmit `session_title` carrying it.
  - The title carried over across `/clear`. The same output from UserPromptSubmit also works.
  - The CLI flag `--name spikeNameB` alone does the same: title `"✳ spikeNameB"` then `"spikeNameB"`, plus both transcript entries, including on `--resume`.
- **B4 — `--session-id`: OBSERVED.**
  - It is listed in `claude --help`, and the chosen uuid `<sid-A>` came back as `session_id`.
  - `--resume <sid-A>` from the same cwd gave SessionStart with `source:"resume"` and the same id.
- **B5 — statusLine from the same `--settings`: OBSERVED.** It ran and received:
  - `session_id`, `session_name`, `prompt_id`, `transcript_path`, `cwd`, `scratchpad_dir`
  - `model{id, display_name}`, `effort.level`, `workspace{…}`, `version`, `output_style`
  - `cost{…}`, `context_window{…}`, `exceeds_200k_tokens`, `prompt_cache{…}`, `fast_mode`, `thinking`, `rate_limits{…}`
  - **Frequency:** it is driven by events, not a timer. It runs about 0.1–0.3 s after SessionStart and after each Stop, plus after tool completion and Notifications. It never runs mid-turn or on an interrupt.

### C — Codex
- **C1 — per-launch hooks: OBSERVED, and the trust review blocks them.**
  - `-c 'hooks.SessionStart=[{hooks=[{type="command",command="…",timeout=10}]}]'` is accepted, one flag per event. All 8 were counted ("8 hooks are new or changed"), `SessionEnd` and `Interrupt` included.
  - A blocking dialog follows: "Hooks need review … 1. Review hooks / 2. Trust all and continue / 3. Continue without trusting (hooks won't run)". Ctrl-C does not close it.
  - With option 3, my hooks never ran.
  - Trust is stored in `<CODEX_HOME>/config.toml` as `[hooks.state."<file>:<event>:<i>:<j>"] trusted_hash`.
  - **Not tried, because the rules forbid them:**
    - "Trust all", which writes to the user's config.
    - `--dangerously-bypass-hook-trust`, or its config form `-c bypass_hook_trust=true`.
    - A scratch `CODEX_HOME`, which would need the credentials file copied.
    - Supplying `-c hooks.state…trusted_hash=`: the hash is codex's own versioned TOML digest, and I did not reproduce it.
- **C2 — hook events and payloads: NOT OBSERVED** (no hook ever ran).
- **C3 — choosing or learning the session id:** there is no `--session-id` in `codex --help` or `codex resume --help`. You can learn the id afterwards:
  - from the exit message "codex resume <sid>" (ids are UUIDv7);
  - from the rollout file `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<timestamp>-<sid>.jsonl`, whose first line (`session_meta`) has `id`, `session_id` and `cwd`.

### D — Do nested processes inherit env vars?
- **Partly observed:** this Bash shell, a tool child of claude pid 26380, carries the `GHOSTTY_*` vars that `ps` shows in that claude's environment. My test sessions' hooks also inherited the harness's environment.
- `--help` documents no scrub. The binary contains `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` (tied to a subprocess sandbox) and `CLAUDE_CODE_DONT_INHERIT_ENV`; what they do is NOT VERIFIED. I did not run a nested `claude`.

## 2. Verdicts on the four design moves
- **(i) Live state from OSC 7501: GO-WITH-LIMITS.**
  - The fork must first answer `OSC 7501;?` with the same terminator. Without that, Claude emits nothing. Codex emits either way.
  - Keep hooks or statusLine for identity.
  - Interrupt, Esc-deny and `/clear` all collapse to `idle`, and `done` stays until the next prompt.
  - There are brief false `working` reports on `/clear`, `/exit` and Codex startup.
  - Claude `error` and all Codex states except idle, working, error and clear are unproven.
- **(ii) Claude hooks per agent via `--settings`, identity as arguments: GO-WITH-LIMITS.**
  - They merge with the global hooks, so the global Clawddy hooks must be removed or they fire twice.
  - Nothing runs until the folder is trusted.
  - Don't expect Stop on interrupt or `turn_id`; PermissionRequest also covers AskUserQuestion.
  - **Codex: NO-GO** within these rules (trust review).
- **(iii) Stop typing `/rename`: GO for Claude.** Use `--name <x>` at launch (it works with `--resume`), or a SessionStart `sessionTitle`. Codex was not tested.
- **(iv) Deterministic session id: GO-WITH-LIMITS for Claude.** `--session-id` and `--resume` work, but `/clear` switches to a new random id. You still need SessionEnd `reason=clear` / SessionStart `source=clear`, or statusLine `session_id`. **Codex: NO-GO** for choosing the id; it can only be learned from the rollout file.

## 3. Surprises and hazards
- **An interrupt puts the prompt back in the input box.** My typed `/clear` was appended and sent as `"<interrupted prompt text>/clear"`. Typing `/rename` after an interrupt would do the same.
- **The trust dialog defaults to "❯ No, exit"**, so a bare Enter quits Claude.
- **Once 7501 is confirmed, Claude stops putting status glyphs in the title, and a custom title stops the AI title.** Any code that reads the title will change behaviour when the fork starts replying.
- **Every Codex turn fails with the user's default model on 0.166.0.** Clawddy launches codex with only `--dangerously-bypass-approvals-and-sandbox` (`AgentProvider.swift:60`) and no model, so live Codex agents would likely fail the same way.
- **Codex dialogs swallow keystrokes:** an update dialog (→0.167.2) appears first, then the hook review. My typed prompt moved the hook-review selection, and Enter confirmed option 3. I verified `<CODEX_HOME>/config.toml` is byte-identical before and after.
- **Codex starts a background daemon by default** (`daemon_auto_start=true`). I passed `--no-daemon --disable daemon_auto_start` on every launch.
- **The current Clawddy hook reads `turn_id`, which Claude never sends.** Live events files show `"turnID":""`.
- **Side effects that come from just running the CLIs:**
  - Claude recorded trust and project entries for the scratch folders and wrote transcripts under `<CLAUDE_CONFIG>/projects/*spike*`.
  - Each Claude session also connected a remote-control bridge, because of the user's `remoteControlAtStartup` setting.
  - `now.py` wrote stamp files under `<CLAUDE_CONFIG>/hooks/.last/`.
  - Codex wrote 2 rollouts and its usual history/state files.

## 4. Cleanup
- **PIDs started:** 671 (shell self-test); 2661, 3541, 5742, 8027, 8890, 9552, 15380 (claude); 10768, 12214, 14852 (codex). **All confirmed gone.**
- **Signals:** the harness sent SIGHUP only to its own children — exp1 and exp5 had already exited, and exp7's codex was stuck at the hook dialog. No other process was signalled.
- **Status directory:** only two live agents' files changed during my runs (`<live-agent-1>`, session `<live-sid-1>`, and `<live-agent-2>`, session `<live-sid-2>`). None of my 7 session ids appears in any status file, and no new files appeared.

Scratch files are left in place under `/private/tmp/claude-501/-Users-abaybektursun-projects-ghostty/ecee68dc-7e24-4e70-a0d9-554f08565b6d/scratchpad/spike/`:
- **Harness:** `/private/tmp/claude-501/-Users-abaybektursun-projects-ghostty/ecee68dc-7e24-4e70-a0d9-554f08565b6d/scratchpad/spike/bin/harness.py`
- **Helpers in `spike/bin`:** `run.sh`, `decode.py`, `hook.py`, `statusline.py`, `mk_settings.py`, `clean-env`.
- **Per-experiment folders `spike/exp0`–`spike/exp10`:** `steps.json` and `settings.json` plus captures in `cap/` (`log.jsonl`, `out.bin`, `hooks.jsonl`, `statusline.jsonl`, `claude-debug.log`).
- **Rerun one experiment (Claude, exp2):**
  ```
  spike/bin/run.sh spike/exp2 spike/exp2/steps.json reply -- claude --settings spike/exp2/settings.json --permission-mode manual --debug-file spike/exp2/cap/claude-debug.log
  python3 spike/bin/decode.py spike/exp2/cap
  ```

---

## Appendix A. Command lines per experiment

Every child ran as `spike/bin/run.sh EXPDIR EXPDIR/steps.json <reply|none> [--env K=V ...] -- <cmd>`, which runs `clean-env python3 -I harness.py --out EXPDIR/cap --cwd EXPDIR/work ...`. The harness sets `TERM=xterm-ghostty TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION=1.3.2-dev COLORTERM=truecolor TERMINFO=/Applications/Ghostty.app/Contents/Resources/terminfo`, window 120x40, unless `--env` overrides. `<SPIKE>` = `/private/tmp/claude-501/-Users-abaybektursun-projects-ghostty/ecee68dc-7e24-4e70-a0d9-554f08565b6d/scratchpad/spike`.

- **exp1** (Claude, OSC 7501 query answered, trust dialog declined by Enter); harness OSC 7501 mode `reply`
  ```
  claude --settings <SPIKE>/exp1/settings.json --permission-mode manual --debug-file <SPIKE>/exp1/cap/claude-debug.log
  ```
- **exp2** (Claude, query answered, --settings hooks, manual permission mode: prompt, permission deny, interrupt, (accidental) prompt+/clear, /exit); harness OSC 7501 mode `reply`
  ```
  claude --settings <SPIKE>/exp2/settings.json --permission-mode manual --debug-file <SPIKE>/exp2/cap/claude-debug.log
  ```
- **exp3** (Claude, query answered, --session-id, AskUserQuestion, /clear, /exit); harness OSC 7501 mode `reply`
  ```
  claude --session-id <uuid-1> --settings <SPIKE>/exp3/settings.json --debug-file <SPIKE>/exp3/cap/claude-debug.log
  ```
- **exp4** (Claude, --resume <chosen id> --name, same cwd as exp3); harness OSC 7501 mode `reply`
  ```
  claude --resume <uuid-1> --name spikeNameB --settings <SPIKE>/exp4/settings.json --debug-file <SPIKE>/exp4/cap/claude-debug.log
  ```
- **exp5** (Claude, query NOT answered); harness OSC 7501 mode `none`; osc7501=none (harness does not answer the query)
  ```
  claude --debug-file <SPIKE>/exp5/cap/claude-debug.log
  ```
- **exp6** (Claude, query answered, TERM=xterm-256color, TERM_PROGRAM and TERM_PROGRAM_VERSION unset); harness OSC 7501 mode `reply`; --env TERM=xterm-256color --env TERM_PROGRAM= --env TERM_PROGRAM_VERSION=
  ```
  claude --debug-file <SPIKE>/exp6/cap/claude-debug.log
  ```
- **exp10** (Claude, query answered, focus-in/focus-out events); harness OSC 7501 mode `reply`
  ```
  claude --debug-file <SPIKE>/exp10/cap/claude-debug.log
  ```
- **exp7** (Codex, -c hooks, startup only (hook review dialog), ended by harness SIGHUP); harness OSC 7501 mode `reply`
  ```
  codex --no-daemon --disable daemon_auto_start -c 'notify=[]' -c 'projects."<SPIKE>/exp7/work".trust_level="trusted"' -c 'hooks.SessionStart=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp7/cap/hooks.jsonl codex-A7 gen-1",timeout=10}]}]' -c 'hooks.UserPromptSubmit=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp7/cap/hooks.jsonl codex-A7 gen-1",timeout=10}]}]' -c 'hooks.Stop=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp7/cap/hooks.jsonl codex-A7 gen-1",timeout=10}]}]' -c 'hooks.PreToolUse=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp7/cap/hooks.jsonl codex-A7 gen-1",timeout=10}]}]' -c 'hooks.PermissionRequest=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp7/cap/hooks.jsonl codex-A7 gen-1",timeout=10}]}]' -c 'hooks.PostToolUse=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp7/cap/hooks.jsonl codex-A7 gen-1",timeout=10}]}]' -c 'hooks.SessionEnd=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp7/cap/hooks.jsonl codex-A7 gen-1",timeout=10}]}]' -c 'hooks.Interrupt=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp7/cap/hooks.jsonl codex-A7 gen-1",timeout=10}]}]'
  ```
- **exp8** (Codex, -c hooks skipped, -s read-only -a on-request, prompts end in model error); harness OSC 7501 mode `reply`
  ```
  codex --no-daemon --disable daemon_auto_start -c 'notify=[]' -c 'projects."<SPIKE>/exp8/work".trust_level="trusted"' -s read-only -a on-request -c 'hooks.SessionStart=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp8/cap/hooks.jsonl codex-A8 gen-1",timeout=10}]}]' -c 'hooks.UserPromptSubmit=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp8/cap/hooks.jsonl codex-A8 gen-1",timeout=10}]}]' -c 'hooks.Stop=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp8/cap/hooks.jsonl codex-A8 gen-1",timeout=10}]}]' -c 'hooks.PreToolUse=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp8/cap/hooks.jsonl codex-A8 gen-1",timeout=10}]}]' -c 'hooks.PermissionRequest=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp8/cap/hooks.jsonl codex-A8 gen-1",timeout=10}]}]' -c 'hooks.PostToolUse=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp8/cap/hooks.jsonl codex-A8 gen-1",timeout=10}]}]' -c 'hooks.SessionEnd=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp8/cap/hooks.jsonl codex-A8 gen-1",timeout=10}]}]' -c 'hooks.Interrupt=[{hooks=[{type="command",command="/opt/homebrew/bin/python3 -I <SPIKE>/bin/hook.py <SPIKE>/exp8/cap/hooks.jsonl codex-A8 gen-1",timeout=10}]}]'
  ```
- **exp9** (Codex, TERM=xterm-256color, TERM_PROGRAM and TERM_PROGRAM_VERSION unset); harness OSC 7501 mode `reply`; --env TERM=xterm-256color --env TERM_PROGRAM= --env TERM_PROGRAM_VERSION=
  ```
  codex --no-daemon --disable daemon_auto_start -c 'notify=[]' -c 'projects."<SPIKE>/exp9/work".trust_level="trusted"'
  ```

Settings files (exp2, exp3, exp4) were generated by `mk_settings.py`: one command hook per event (SessionStart, UserPromptSubmit, Stop, StopFailure, SessionEnd, Notification, PermissionRequest, PermissionDenied, PreToolUse, PostToolUse, PostToolUseFailure, SubagentStart, SubagentStop, PreCompact, PostCompact), each `python3 -I <SPIKE>/bin/hook.py <SPIKE>/expN/cap/hooks.jsonl <agent-arg> <gen-arg> [--title T [--title-on EVENTS]]`, timeout 10, plus `statusLine: {type: command, command: python3 -I <SPIKE>/bin/statusline.py <SPIKE>/expN/cap/statusline.jsonl}`. exp2 title on SessionStart and UserPromptSubmit; exp3 title on SessionStart only; exp4 no title. Codex hook flags (exp7, exp8): one `-c 'hooks.<Event>=[{hooks=[{type="command",command="python3 -I <SPIKE>/bin/hook.py <SPIKE>/expN/cap/hooks.jsonl codex-AN gen-1",timeout=10}]}]'` per event for SessionStart, UserPromptSubmit, Stop, PreToolUse, PermissionRequest, PostToolUse, SessionEnd, Interrupt.

## Appendix B. Captured OSC 7501 sequences (and related OSC) per experiment

Times are seconds since spawn. `MARK` rows are harness steps (labels only, prompt text omitted). `IN` rows are bytes the harness sent. `REPLY` rows are the harness answer to the 7501 query. Raw bytes are Python repr of the exact sequence; base64 `msg` decoded in brackets. OSC 0 (title), 9;4 (progress) and 777 (notify) rows are included where they bear on the lifecycle.

### exp1: Claude, OSC 7501 query answered, trust dialog declined by Enter
```
   0.497 OSC   '\x1b]7501;?\x07'
   0.497 REPLY '\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x07'
   2.218 MARK  trust-answer
   2.272 KEY   enter
   2.283 OSC   '\x1b]9;4;0;\x07'
   2.283 OSC   '\x1b]7501;state=clear\x07'
   2.283 OSC   '\x1b]0;\x07'
   2.555 EXIT  {"exit_status_after_signal": 256}
```

### exp2: Claude, query answered, --settings hooks, manual permission mode: prompt, permission deny, interrupt, (accidental) prompt+/clear, /exit
```
   0.308 OSC   '\x1b]7501;?\x07'
   0.308 REPLY '\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x07'
   2.016 MARK  trust-answer
   2.068 KEY   down
   2.683 KEY   enter
   3.047 OSC   '\x1b]7501;state=idle:app=claude-code\x07'
   3.047 OSC   '\x1b]0;Claude Code\x07'
   3.048 OSC   '\x1b]9;4;0;\x07'
   3.238 OSC   '\x1b]0;spikeTitleA-SessionStart\x07'
   8.794 MARK  prompt1
  10.101 KEY   enter
  10.135 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  10.137 OSC   '\x1b]9;4;3;\x07'
  10.268 OSC   '\x1b]0;spikeTitleA-UserPromptSubmit\x07'
  12.908 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  12.908 OSC   '\x1b]9;4;0;\x07'
  14.911 OSC   '\x1b]7501;state=done:app=claude-code:msg=cmVwbGllZCB3aXRoIHRoZSBzaW5nbGUgd29yZCBvayBhcyByZXF1ZXN0ZWQ=\x07'  [msg='replied with the single word ok as requested']
  19.111 MARK  permission
  21.060 KEY   enter
  21.103 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  21.103 OSC   '\x1b]9;4;3;\x07'
  23.922 OSC   '\x1b]7501;state=working:app=claude-code:msg=Q3JlYXRpbmcgZW1wdHkgbWFya2VyIGZpbGU=\x07'  [msg='Creating empty marker file']
  24.020 OSC   '\x1b]7501;state=blocked:app=claude-code:kind=permission:msg=YXBwcm92ZSBCYXNoOiB0b3VjaCBzcGlrZV9tYXJrZXIudHh0\x07'  [msg='approve Bash: touch spike_marker.txt']
  30.080 OSC   '\x1b]777;notify;Claude Code;Claude needs your permission\x07'
  34.278 MARK  deny-esc
  34.328 KEY   esc
  34.394 OSC   '\x1b]7501;state=idle:app=claude-code\x07'
  34.394 OSC   '\x1b]9;4;0;\x07'
  42.443 MARK  interrupt-prompt
  44.349 KEY   enter
  44.527 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  44.527 OSC   '\x1b]9;4;3;\x07'
  47.727 MARK  interrupt-esc
  47.778 KEY   esc
  47.824 OSC   '\x1b]7501;state=idle:app=claude-code\x07'
  47.824 OSC   '\x1b]9;4;0;\x07'
  51.886 MARK  clear
  52.894 KEY   enter
  52.905 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  52.905 OSC   '\x1b]9;4;3;\x07'
  60.676 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  60.676 OSC   '\x1b]9;4;0;\x07'
  62.882 OSC   '\x1b]7501;state=done:app=claude-code:msg=Y291bnRlZCAxIHRvIDQwMCwgb25lIG51bWJlciBwZXIgbGluZQ==\x07'  [msg='counted 1 to 400, one number per line']
  69.011 MARK  exit
  69.988 KEY   enter
  70.026 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  70.026 OSC   '\x1b]9;4;3;\x07'
  70.035 OSC   '\x1b]9;4;0;\x07'
  70.035 OSC   '\x1b]7501;state=clear\x07'
  70.041 OSC   '\x1b]7501;state=clear\x07'
  70.041 OSC   '\x1b]9;4;0;\x07'
  70.042 OSC   '\x1b]9;4;0;\x07'
  70.042 OSC   '\x1b]7501;state=clear\x07'
  70.042 OSC   '\x1b]0;\x07'
  71.143 EXIT  {"exit_status": 0}
```

### exp3: Claude, query answered, --session-id, AskUserQuestion, /clear, /exit
```
   0.241 OSC   '\x1b]7501;?\x07'
   0.241 REPLY '\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x07'
   2.019 MARK  trust-answer
   2.071 KEY   down
   2.682 KEY   enter
   2.850 OSC   '\x1b]7501;state=idle:app=claude-code\x07'
   2.850 OSC   '\x1b]0;Claude Code\x07'
   2.850 OSC   '\x1b]9;4;0;\x07'
   2.987 OSC   '\x1b]0;spikeStartTitle-SessionStart\x07'
   8.794 MARK  prompt1
  10.114 KEY   enter
  10.152 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  10.154 OSC   '\x1b]9;4;3;\x07'
  12.446 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  12.446 OSC   '\x1b]9;4;0;\x07'
  14.310 OSC   '\x1b]7501;state=done:app=claude-code:msg=cmVwbGllZCB3aXRoIHRoZSBzaW5nbGUgd29yZCAnb2snIGFzIGFza2Vk\x07'  [msg="replied with the single word 'ok' as asked"]
  18.718 MARK  question
  22.102 KEY   enter
  22.125 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  22.125 OSC   '\x1b]9;4;3;\x07'
  25.498 OSC   '\x1b]7501;state=blocked:app=claude-code:kind=question:msg=YW5zd2VyOiBXaGljaCBkbyB5b3UgY2hvb3NlOiBBIG9yIEI/IChBIMK3IEIp\x07'  [msg='answer: Which do you choose: A or B? (A · B)']
  28.709 MARK  answer-enter
  28.762 KEY   enter
  28.803 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  30.396 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  30.396 OSC   '\x1b]9;4;0;\x07'
  32.672 OSC   '\x1b]7501;state=done:app=claude-code:msg=YW5zd2VyZWQgQS9CIHF1ZXN0aW9uIHdpdGggbGV0dGVyIEE=\x07'  [msg='answered A/B question with letter A']
  36.547 MARK  clear
  37.551 KEY   enter
  37.578 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  37.578 OSC   '\x1b]9;4;3;\x07'
  37.629 OSC   '\x1b]7501;state=idle:app=claude-code\x07'
  37.629 OSC   '\x1b]9;4;0;\x07'
  45.661 MARK  prompt2
  47.029 KEY   enter
  47.068 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  47.069 OSC   '\x1b]9;4;3;\x07'
  49.749 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  49.749 OSC   '\x1b]9;4;0;\x07'
  51.093 OSC   '\x1b]7501;state=done:app=claude-code:msg=cmVwbGllZCBvayBhcyByZXF1ZXN0ZWQ=\x07'  [msg='replied ok as requested']
  56.039 MARK  exit
  57.021 KEY   enter
  57.044 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  57.044 OSC   '\x1b]9;4;3;\x07'
  57.057 OSC   '\x1b]9;4;0;\x07'
  57.057 OSC   '\x1b]7501;state=clear\x07'
  57.062 OSC   '\x1b]7501;state=clear\x07'
  57.062 OSC   '\x1b]9;4;0;\x07'
  57.063 OSC   '\x1b]9;4;0;\x07'
  57.063 OSC   '\x1b]7501;state=clear\x07'
  57.063 OSC   '\x1b]0;\x07'
  57.740 EXIT  {"exit_status": 0}
```

### exp4: Claude, --resume <chosen id> --name, same cwd as exp3
```
   0.314 OSC   '\x1b]0;✳ spikeNameB\x07'
   0.315 OSC   '\x1b]9;4;0;\x07'
   0.448 OSC   '\x1b]7501;?\x07'
   0.448 REPLY '\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x07'
   0.468 OSC   '\x1b]7501;state=idle:app=claude-code\x07'
   0.468 OSC   '\x1b]0;spikeNameB\x07'
   8.061 MARK  prompt1
   9.392 KEY   enter
   9.444 OSC   '\x1b]7501;state=working:app=claude-code\x07'
   9.446 OSC   '\x1b]9;4;3;\x07'
  11.543 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  11.543 OSC   '\x1b]9;4;0;\x07'
  14.717 OSC   '\x1b]7501;state=done:app=claude-code:msg=cmVwbGllZCAnb2snIGFzIHJlcXVlc3RlZA==\x07'  [msg="replied 'ok' as requested"]
  17.798 MARK  exit
  18.780 KEY   enter
  18.811 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  18.811 OSC   '\x1b]9;4;3;\x07'
  18.819 OSC   '\x1b]9;4;0;\x07'
  18.819 OSC   '\x1b]7501;state=clear\x07'
  18.823 OSC   '\x1b]7501;state=clear\x07'
  18.824 OSC   '\x1b]9;4;0;\x07'
  18.824 OSC   '\x1b]9;4;0;\x07'
  18.824 OSC   '\x1b]7501;state=clear\x07'
  18.824 OSC   '\x1b]0;\x07'
  19.801 EXIT  {"exit_status": 0}
```

### exp5: Claude, query NOT answered
```
   0.214 OSC   '\x1b]7501;?\x07'
   2.023 MARK  trust-answer
   2.076 KEY   down
   2.684 KEY   enter
   2.840 OSC   '\x1b]0;✳ Claude Code\x07'
   2.840 OSC   '\x1b]9;4;0;\x07'
  10.796 MARK  prompt1
  12.153 KEY   enter
  12.205 OSC   '\x1b]0;◐ Claude Code\x07'
  12.207 OSC   '\x1b]9;4;3;\x07'
  13.166 OSC   '\x1b]0;◑ Claude Code\x07'
  14.127 OSC   '\x1b]0;◐ Claude Code\x07'
  14.431 OSC   '\x1b]0;◐ Single word reply\x07'
  14.634 OSC   '\x1b]0;✳ Single word reply\x07'
  14.634 OSC   '\x1b]9;4;0;\x07'
  24.319 MARK  exit
  25.302 KEY   enter
  25.323 OSC   '\x1b]0;◐ Single word reply\x07'
  25.323 OSC   '\x1b]9;4;3;\x07'
  25.337 OSC   '\x1b]9;4;0;\x07'
  25.340 OSC   '\x1b]9;4;0;\x07'
  25.340 OSC   '\x1b]9;4;0;\x07'
  25.340 OSC   '\x1b]0;\x07'
  26.153 EXIT  {"exit_status_after_signal": 0}
```

### exp6: Claude, query answered, TERM=xterm-256color, TERM_PROGRAM and TERM_PROGRAM_VERSION unset
```
   0.191 OSC   '\x1b]7501;?\x07'
   0.191 REPLY '\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x07'
   1.809 MARK  trust-answer
   1.863 KEY   down
   2.472 KEY   enter
   2.618 OSC   '\x1b]7501;state=idle:app=claude-code\x07'
   2.618 OSC   '\x1b]0;Claude Code\x07'
  10.584 MARK  exit
  11.569 KEY   enter
  11.587 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  11.596 OSC   '\x1b]7501;state=clear\x07'
  11.598 OSC   '\x1b]7501;state=clear\x07'
  11.599 OSC   '\x1b]7501;state=clear\x07'
  11.599 OSC   '\x1b]0;\x07'
  12.435 EXIT  {"exit_status": 0}
```

### exp10: Claude, query answered, focus-in/focus-out events
```
   0.292 OSC   '\x1b]7501;?\x07'
   0.292 REPLY '\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x07'
   2.018 MARK  trust-answer
   2.072 KEY   down
   2.686 KEY   enter
   2.834 OSC   '\x1b]7501;state=idle:app=claude-code\x07'
   2.834 OSC   '\x1b]0;Claude Code\x07'
   2.835 OSC   '\x1b]9;4;0;\x07'
   8.802 MARK  focus-in-before-turn
   8.854 KEY   focus-in
   8.855 IN    '\x1b[I'
  10.965 MARK  prompt-focused
  12.294 KEY   enter
  12.335 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  12.337 OSC   '\x1b]9;4;3;\x07'
  13.507 OSC   '\x1b]0;Single word reply\x07'
  14.712 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  14.712 OSC   '\x1b]9;4;0;\x07'
  16.558 OSC   '\x1b]7501;state=done:app=claude-code:msg=cmVwbGllZCAnb2snIGFzIHJlcXVlc3RlZA==\x07'  [msg="replied 'ok' as requested"]
  22.885 MARK  focus-out
  22.941 KEY   focus-out
  22.941 IN    '\x1b[O'
  25.053 MARK  prompt-unfocused
  26.386 KEY   enter
  26.418 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  26.418 OSC   '\x1b]9;4;3;\x07'
  30.618 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  30.618 OSC   '\x1b]9;4;0;\x07'
  32.075 OSC   '\x1b]7501;state=done:app=claude-code:msg=cmVwbGllZCAnb2snIGFzIHJlcXVlc3RlZA==\x07'  [msg="replied 'ok' as requested"]
  38.830 MARK  focus-in-after-done
  38.885 KEY   focus-in
  38.885 IN    '\x1b[I'
  41.989 MARK  exit
  42.974 KEY   enter
  43.000 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  43.000 OSC   '\x1b]9;4;3;\x07'
  43.009 OSC   '\x1b]9;4;0;\x07'
  43.009 OSC   '\x1b]7501;state=clear\x07'
  43.012 OSC   '\x1b]7501;state=clear\x07'
  43.012 OSC   '\x1b]9;4;0;\x07'
  43.013 OSC   '\x1b]9;4;0;\x07'
  43.013 OSC   '\x1b]7501;state=clear\x07'
  43.013 OSC   '\x1b]0;\x07'
  43.686 EXIT  {"exit_status": 0}
```

### exp7: Codex, -c hooks, startup only (hook review dialog), ended by harness SIGHUP
```
  10.068 MARK  snapshot
  11.182 KEY   ctrl-c
  12.294 KEY   ctrl-c
  18.421 EXIT  {"exit_status_after_signal": 1}
```

### exp8: Codex, -c hooks skipped, -s read-only -a on-request, prompts end in model error
```
  31.811 MARK  skip-hook-review-esc
  31.864 KEY   esc
  37.992 MARK  prompt1
  39.436 KEY   enter
  39.474 OSC   '\x1b]0;work\x07'
  39.481 OSC   '\x1b]7501;state=idle:app=codex\x1b\\'
  39.608 OSC   '\x1b]0;⠙ work\x07'
  39.617 OSC   '\x1b]7501;state=working:app=codex\x1b\\'
  39.747 OSC   '\x1b]0;⠹ work\x07'
  39.867 OSC   '\x1b]0;⠸ work\x07'
  39.927 OSC   '\x1b]0;⠼ work\x07'
  40.002 OSC   '\x1b]0;⠴ work\x07'
  40.040 OSC   '\x1b]0;work\x07'
  40.041 OSC   '\x1b]7501;state=idle:app=codex\x1b\\'
  62.636 MARK  permission
  64.603 KEY   enter
  64.608 OSC   '\x1b]7501;state=working:app=codex\x1b\\'
  64.758 OSC   '\x1b]0;⠹ work\x07'
  64.794 OSC   '\x1b]0;⠸ work\x07'
  64.900 OSC   '\x1b]0;⠼ work\x07'
  64.993 OSC   '\x1b]0;⠴ work\x07'
  65.097 OSC   '\x1b]0;⠦ work\x07'
  65.200 OSC   '\x1b]0;⠧ work\x07'
  65.302 OSC   '\x1b]0;⠇ work\x07'
  65.374 OSC   '\x1b]0;⠏ work\x07'
  65.410 OSC   '\x1b]0;work\x07'
  65.417 OSC   '\x1b]7501;state=error:app=codex\x1b\\'
  67.367 OSC   '\x1b]0;Create spike marker | work\x07'
 156.902 MARK  deny-esc
 156.960 KEY   esc
 156.969 OSC   '\x1b]7501;state=idle:app=codex\x1b\\'
 161.076 MARK  interrupt-prompt
 161.132 KEY   ctrl-u
 163.051 KEY   enter
 163.053 OSC   '\x1b]7501;state=working:app=codex\x1b\\'
 163.099 OSC   '\x1b]0;⠦ Create spike marker | work\x07'
 163.187 OSC   '\x1b]0;⠧ Create spike marker | work\x07'
 163.288 OSC   '\x1b]0;⠇ Create spike marker | work\x07'
 163.391 OSC   '\x1b]0;⠏ Create spike marker | work\x07'
 163.493 OSC   '\x1b]0;⠋ Create spike marker | work\x07'
 163.598 OSC   '\x1b]0;⠙ Create spike marker | work\x07'
 163.618 OSC   '\x1b]0;Create spike marker | work\x07'
 163.619 OSC   '\x1b]7501;state=error:app=codex\x1b\\'
 167.157 MARK  interrupt-esc
 167.212 KEY   esc
 167.215 OSC   '\x1b]7501;state=idle:app=codex\x1b\\'
 171.322 MARK  exit
 171.374 KEY   ctrl-u
 172.711 KEY   enter
 172.747 OSC   '\x1b]0;\x07'
 172.750 OSC   '\x1b]7501;state=clear\x1b\\'
 172.846 EXIT  {"exit_status": 0}
```

### exp9: Codex, TERM=xterm-256color, TERM_PROGRAM and TERM_PROGRAM_VERSION unset
```
   2.023 MARK  skip-update-esc
   2.076 KEY   esc
   2.458 OSC   '\x1b]0;work\x07'
   2.463 OSC   '\x1b]7501;state=idle:app=codex\x1b\\'
   2.582 OSC   '\x1b]0;⠙ work\x07'
   2.599 OSC   '\x1b]7501;state=working:app=codex\x1b\\'
   2.726 OSC   '\x1b]0;⠹ work\x07'
   2.788 OSC   '\x1b]0;⠸ work\x07'
   2.863 OSC   '\x1b]0;⠼ work\x07'
   2.966 OSC   '\x1b]0;⠴ work\x07'
   3.063 OSC   '\x1b]0;⠦ work\x07'
   3.063 OSC   '\x1b]0;work\x07'
   3.063 OSC   '\x1b]7501;state=idle:app=codex\x1b\\'
  23.209 MARK  prompt1
  24.514 KEY   enter
  24.518 OSC   '\x1b]7501;state=working:app=codex\x1b\\'
  24.715 OSC   '\x1b]0;⠹ work\x07'
  24.785 OSC   '\x1b]0;⠸ work\x07'
  24.887 OSC   '\x1b]0;⠼ work\x07'
  24.977 OSC   '\x1b]0;⠴ work\x07'
  25.077 OSC   '\x1b]0;⠦ work\x07'
  25.178 OSC   '\x1b]0;⠧ work\x07'
  25.281 OSC   '\x1b]0;⠇ work\x07'
  25.381 OSC   '\x1b]0;⠏ work\x07'
  25.483 OSC   '\x1b]0;⠋ work\x07'
  25.556 OSC   '\x1b]0;work\x07'
  25.560 OSC   '\x1b]7501;state=error:app=codex\x1b\\'
  26.716 OSC   '\x1b]0;Reply ok | work\x07'
  32.676 MARK  esc
  32.731 KEY   esc
  32.733 OSC   '\x1b]7501;state=idle:app=codex\x1b\\'
  34.838 MARK  exit
  34.893 KEY   ctrl-u
  36.221 KEY   enter
  36.270 OSC   '\x1b]0;\x07'
  36.272 OSC   '\x1b]7501;state=clear\x1b\\'
  36.521 EXIT  {"exit_status": 0}
```

## Appendix C. Claude hook payload top-level keys per event (exact, sorted)

- `SessionStart (source=startup)` [exp2]: `["cwd", "hook_event_name", "model", "scratchpad_dir", "session_id", "source", "transcript_path"]`
- `UserPromptSubmit` [exp2]: `["cwd", "hook_event_name", "permission_mode", "prompt", "prompt_id", "scratchpad_dir", "session_id", "session_title", "transcript_path"]`
- `Stop` [exp2]: `["background_tasks", "cwd", "effort", "hook_event_name", "last_assistant_message", "permission_mode", "prompt_id", "scratchpad_dir", "session_crons", "session_id", "stop_hook_active", "transcript_path"]`
- `PreToolUse` [exp2]: `["cwd", "effort", "hook_event_name", "permission_mode", "prompt_id", "scratchpad_dir", "session_id", "tool_input", "tool_name", "tool_use_id", "transcript_path"]`
- `PreToolUse.tool_input[Bash]` [exp2]: `["command", "description"]`
- `PermissionRequest` [exp2]: `["cwd", "effort", "hook_event_name", "permission_mode", "permission_suggestions", "prompt_id", "scratchpad_dir", "session_id", "tool_input", "tool_name", "transcript_path"]`
- `PermissionRequest.tool_input[Bash]` [exp2]: `["command", "description"]`
- `Notification` [exp2]: `["cwd", "hook_event_name", "message", "notification_type", "prompt_id", "scratchpad_dir", "session_id", "transcript_path"]`
- `Notification values` [exp2]: `["notification_type='permission_prompt'", "message='Claude needs your permission'"]`
- `SubagentStop` [exp2]: `["agent_id", "agent_transcript_path", "agent_type", "background_tasks", "cwd", "effort", "hook_event_name", "permission_mode", "prompt_id", "scratchpad_dir", "session_crons", "session_id", "stop_hook_active", "transcript_path"]`
- `SessionEnd` [exp2]: `["cwd", "hook_event_name", "prompt_id", "reason", "scratchpad_dir", "session_id", "transcript_path"]`
- `SessionEnd reason=prompt_input_exit` [exp2]: `["(value observed)"]`
- `PreToolUse.tool_input[AskUserQuestion]` [exp3]: `["questions"]`
- `PermissionRequest.tool_input[AskUserQuestion]` [exp3]: `["questions"]`
- `PostToolUse` [exp3]: `["cwd", "duration_ms", "effort", "hook_event_name", "permission_mode", "prompt_id", "scratchpad_dir", "session_id", "tool_input", "tool_name", "tool_response", "tool_use_id", "transcript_path"]`
- `PostToolUse.tool_input[AskUserQuestion]` [exp3]: `["annotations", "answers", "questions"]`
- `SessionEnd reason=clear` [exp3]: `["(value observed)"]`
- `SessionStart (source=clear)` [exp3]: `["cwd", "hook_event_name", "scratchpad_dir", "session_id", "session_title", "source", "transcript_path"]`
- `SessionStart (source=resume)` [exp4]: `["context_tokens", "cwd", "estimated_cache_write_usd", "hook_event_name", "prompt_cache_likely_expired", "scratchpad_dir", "seconds_since_last_response", "session_id", "session_title", "source", "transcript_path"]`

Environment variable NAMES visible to hook processes (values not recorded): `["CLAUDECODE", "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_SESSION_ID", "CLAUDE_EFFORT", "CLAUDE_ENV_FILE", "CLAUDE_PID", "CLAUDE_PROJECT_DIR", "GHOSTTY_BIN_DIR", "GHOSTTY_RESOURCES_DIR", "GHOSTTY_SHELL_FEATURES", "TERM", "TERMINFO", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"]`. No `GHOSTTY_AGENT_*` names were present. The `CLAUDE_*` names are set by the Claude process for its hooks (they were stripped from the launch environment).

statusLine payload keys (exp2, last call, exact): `["session_id", "transcript_path", "cwd", "scratchpad_dir", "prompt_id", "effort", "effort.level", "session_name", "model", "model.id", "model.display_name", "workspace", "workspace.current_dir", "workspace.project_dir", "workspace.added_dirs", "version", "output_style", "output_style.name", "cost", "cost.total_cost_usd", "cost.total_duration_ms", "cost.total_api_duration_ms", "cost.total_lines_added", "cost.total_lines_removed", "context_window", "context_window.total_input_tokens", "context_window.total_output_tokens", "context_window.context_window_size", "context_window.current_usage", "context_window.current_usage.input_tokens", "context_window.current_usage.output_tokens", "context_window.current_usage.cache_creation_input_tokens", "context_window.current_usage.cache_read_input_tokens", "context_window.used_percentage", "context_window.remaining_percentage", "exceeds_200k_tokens", "prompt_cache", "prompt_cache.warm", "prompt_cache.caching_observed", "prompt_cache.ttl", "prompt_cache.expires_at", "prompt_cache.requests", "prompt_cache.misses", "prompt_cache.expected_rebuilds", "prompt_cache.hit_ratio", "prompt_cache.cache_write_tokens", "prompt_cache.miss_recache_tokens", "prompt_cache.last_miss_at", "prompt_cache.last_miss_cause", "prompt_cache.miss_causes", "prompt_cache.recache_tokens_if_cold", "fast_mode", "thinking", "thinking.enabled", "rate_limits", "rate_limits.seven_day", "rate_limits.seven_day.used_percentage", "rate_limits.seven_day.resets_at"]`

## Appendix D. Hook and statusLine event order (seconds since first hook)
```
exp2:
    0.00  SessionStart(source=startup)             session_id=<uuid-2>
    0.17  STATUSLINE                               session_id=<uuid-2>
    7.16  UserPromptSubmit                         session_id=<uuid-2>
    9.89  Stop                                     session_id=<uuid-2>
   10.20  STATUSLINE                               session_id=<uuid-2>
   18.12  UserPromptSubmit                         session_id=<uuid-2>
   20.96  PreToolUse                               session_id=<uuid-2>
   21.04  PermissionRequest                        session_id=<uuid-2>
   27.08  Notification                             session_id=<uuid-2>
   31.44  STATUSLINE                               session_id=<uuid-2>
   41.58  UserPromptSubmit                         session_id=<uuid-2>
   49.93  UserPromptSubmit                         session_id=<uuid-2>
   57.67  Stop                                     session_id=<uuid-2>
   58.00  STATUSLINE                               session_id=<uuid-2>
   60.92  SubagentStop                             session_id=<uuid-2>
   67.80  SessionEnd(reason=prompt_input_exit)     session_id=<uuid-2>
exp3:
    0.00  SessionStart(source=startup)             session_id=<uuid-1>
    0.14  STATUSLINE                               session_id=<uuid-1>
    7.35  UserPromptSubmit                         session_id=<uuid-1>
    9.62  Stop                                     session_id=<uuid-1>
    9.92  STATUSLINE                               session_id=<uuid-1>
   19.33  UserPromptSubmit                         session_id=<uuid-1>
   22.67  PreToolUse                               session_id=<uuid-1>
   22.70  PermissionRequest                        session_id=<uuid-1>
   26.01  PostToolUse                              session_id=<uuid-1>
   26.02  STATUSLINE                               session_id=<uuid-1>
   27.57  Stop                                     session_id=<uuid-1>
   27.88  STATUSLINE                               session_id=<uuid-1>
   30.66  SubagentStop                             session_id=<uuid-1>
   34.78  SessionEnd(reason=clear)                 session_id=<uuid-1>
   34.83  SessionStart(source=clear)               session_id=<uuid-3>
   35.14  STATUSLINE                               session_id=<uuid-3>
   44.28  UserPromptSubmit                         session_id=<uuid-3>
   46.92  Stop                                     session_id=<uuid-3>
   47.24  STATUSLINE                               session_id=<uuid-3>
   54.73  SessionEnd(reason=prompt_input_exit)     session_id=<uuid-3>
exp4:
    0.00  SessionStart(source=resume)              session_id=<uuid-1>
    0.12  STATUSLINE                               session_id=<uuid-1>
    9.17  UserPromptSubmit                         session_id=<uuid-1>
   11.24  Stop                                     session_id=<uuid-1>
   11.57  STATUSLINE                               session_id=<uuid-1>
   14.79  SubagentStop                             session_id=<uuid-1>
   18.99  SessionEnd(reason=prompt_input_exit)     session_id=<uuid-1>
```

## Appendix E. Using the copied harness (`spike-harness/`)

- `clean-env CMD...` runs CMD with every `GHOSTTY_AGENT_*`, `CLAUDE*` and `CODEX_*` variable removed, so the global Clawddy hooks exit early and no live agent state is touched.
- `harness.py --out DIR --cwd DIR --steps steps.json [--osc7501 reply|none] [--env K=V ...] -- CMD...` runs CMD in a 120x40 PTY with Ghostty-like TERM variables. It answers DA1/DA2, CPR, XTVERSION, kitty keyboard query, DECRQM, OSC 10/11/4 colour queries, window size queries and (with `reply`) the OSC 7501 query with the same terminator. It types scripted steps (`wait`, `wait_raw`, `quiet`, `sleep`, `type`, `key`, `mark`) and logs every byte with timestamps to `DIR/log.jsonl` and `DIR/out.bin`. When the steps end it sends SIGHUP/SIGTERM/SIGKILL only to its own child, and only if the child is still alive.
- `run.sh EXPDIR STEPS.json reply|none [--env K=V ...] -- CMD...` needs `SPIKE_DIR` set to a scratch directory. It wraps the harness in `clean-env`, snapshots `$HOME/.config/ghostty-agents/status` before and after, and prints leftover processes in the child's process group.
- `mk_settings.py OUT.json CAPDIR AGENT GEN [TITLE [TITLE_ON_EVENTS]]` writes a Claude `--settings` file with logging hooks (`hook.py`) and a logging statusLine (`statusline.py`).
- `decode.py CAPDIR [--all-osc] [--text]` prints the timeline of steps, replies and OSC sequences, with base64 `msg`/`title` decoded.
- Rerun example (exp2 shape, new scratch directory):
  ```
  export SPIKE_DIR=/path/to/scratch/spike
  H=docs/clawddy-refactor/spike-harness
  python3 $H/mk_settings.py $SPIKE_DIR/exp2/settings.json $SPIKE_DIR/exp2/cap agent-A2 gen-7 spikeTitleA
  $H/run.sh $SPIKE_DIR/exp2 $SPIKE_DIR/exp2/steps.json reply -- claude --settings $SPIKE_DIR/exp2/settings.json --permission-mode manual --debug-file $SPIKE_DIR/exp2/cap/claude-debug.log
  python3 $H/decode.py $SPIKE_DIR/exp2/cap
  ```
  The `mkdir -p $SPIKE_DIR/exp2/cap` must happen before `mk_settings.py`. Steps files are JSON lists, as described in the `harness.py` docstring. A new working directory brings up Claude's trust dialog, whose default is "No, exit", so steps must send `down` then `enter`.
