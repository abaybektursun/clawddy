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

---

## P3.5a captures (2026-11-12)

Plan step P3.5a: the open cases captured before P3.5 is written. Same machine, same Claude Code (2.1.322), same harness, run from this shell (not inside a Clawddy agent). Nine Claude sessions, all with one-line prompts and one-word answers.

**Harness additions** (in `spike-harness/`):
- `harness.py`: keys `ctrl-z` and `ctrl-g`, sent as CSI u (`ESC[122;5u`, `ESC[103;5u`) while kitty flag 1 is on, the same as Esc and Ctrl-C (Claude pushes flags 5). The kitty pop `ESC[<u` is now tracked; the old pattern never matched it, so after a suspend the harness still thought the flags were pushed. The spawn record now carries the wall-clock time.
- `decode.py`: if `hooks.jsonl` sits next to the log, hook records are shown as `HOOK` rows on the same timeline. The time is when the hook process wrote its record, a few ms after Claude started it.
- `run.sh`: `WORK_DIR` overrides the working folder, so two runs can share one project folder (needed for resume and fork).
- `clean-env` also removes `CLAWDDY_*`; `hook.py` also records `CLAWDDY*` variable names.
- `editor.sh`: a stand-in `$EDITOR` that logs its file argument and exits at once without touching the file.

**Safety:**
- Before the first session, `env` run as the harness child showed no `GHOSTTY_AGENT_*`, `CLAWDDY_*`, `CLAUDE*` or `CODEX_*` names.
- None of the 59 hook records (10 session ids) lists a `GHOSTTY_AGENT_*` or `CLAWDDY*` name.
- `run.sh` saw status-folder changes only in two live agents' files, from the owner's own sessions running at the time. None of my 10 session ids appears anywhere in that folder.
- No global configuration was touched. Per-session differences came only from command-line flags and variables set for the child process: `ANTHROPIC_MODEL` (a name that does not exist), `HTTPS_PROXY`/`HTTP_PROXY` (a closed local port), `CLAUDE_CODE_MAX_RETRIES=0`, `BASH_DEFAULT_TIMEOUT_MS=300000`, `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`, `EDITOR`/`VISUAL`. Every session other than the first case 2 run used the user's configured model.

**Where things are:**
- Captures: `/Volumes/Xcode/GhosttyBuilds/ghostty/tmp/p35a/<run>/`, holding `steps.json`, `settings.json` and `cap/` (`log.jsonl`, `out.bin`, `hooks.jsonl`, `statusline.jsonl`, `claude-debug.log`).
- Transcripts: under `<CLAUDE_CONFIG>/projects/-Volumes-Xcode-GhosttyBuilds-ghostty-tmp-p35a-*`.

**Timeline format:**
- Times are seconds since spawn.
- `MARK` is a harness step label. `KEY enter` is the Enter that submits.
- `HOOK` is a record from the `--settings` hooks.
- Only OSC 7501 is shown (no `9;4` progress and no titles), with `msg` decoded in brackets.
- Session ids are replaced by `<sid-…>` / `<uuid-…>`.

### Case 1: a prompt submitted within 2 s of `done`

Three points, in three sessions:

| Run | First `done` | Next Enter | Gap | Summary `done` of the first turn |
|---|---|---|---|---|
| c3 | 12.617 | 12.916 | 0.30 s | never arrived |
| c1 | 13.841 | 14.880 | 1.04 s | never arrived |
| c4 | 15.137 | 16.860 | 1.72 s | never arrived |
| c1, turn 2 (control) | 17.060 | 19.234 | 2.17 s | arrived at 18.775, 1.72 s after `done`, while the next prompt was still being typed, so it came before the new `working` |

When no prompt followed, the summary came 1.45 to 2.0 s after the first `done` (eight turns).

c1 (follow-ups at 1.04 s and 2.17 s, then `/clear`, which is case 7):
```
   8.796 MARK  prompt1
  10.130 KEY   enter
  10.224 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  10.535 HOOK  UserPromptSubmit sid=<sid-c1>
  13.826 HOOK  Stop sid=<sid-c1>
  13.841 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  14.096 MARK  prompt2-at-once-after-done
  14.880 KEY   enter
  14.912 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  14.933 HOOK  UserPromptSubmit sid=<sid-c1>
  17.049 HOOK  Stop sid=<sid-c1>
  17.060 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  18.475 MARK  prompt3-1.2s-after-done
  18.775 OSC   '\x1b]7501;state=done:app=claude-code:msg=cmVwbGllZCAneWVzJyBhcyByZXF1ZXN0ZWQ=\x07'  [msg="replied 'yes' as requested"]
  19.234 KEY   enter
  19.277 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  19.300 HOOK  UserPromptSubmit sid=<sid-c1>
  21.172 HOOK  Stop sid=<sid-c1>
  21.189 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  22.852 OSC   '\x1b]7501;state=done:app=claude-code:msg=cmVwbGllZCAnbm8nIGFzIHJlcXVlc3RlZA==\x07'  [msg="replied 'no' as requested"]
  23.926 HOOK  SubagentStop sid=<sid-c1>
```
c3 (follow-up at 0.30 s; the rest of c3 is case 3):
```
   9.921 KEY   enter
   9.970 OSC   '\x1b]7501;state=working:app=claude-code\x07'
   9.992 HOOK  UserPromptSubmit sid=<sid-c3>
  12.604 HOOK  Stop sid=<sid-c3>
  12.617 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  12.672 MARK  prompt2-at-once-short
  12.916 KEY   enter
  12.931 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  12.951 HOOK  UserPromptSubmit sid=<sid-c3>
  15.207 HOOK  Stop sid=<sid-c3>
  15.220 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  16.665 OSC   '\x1b]7501;state=done:app=claude-code:msg=Z3JlZXRlZCB1c2VyOyBubyB0YXNrIHBlbmRpbmc=\x07'  [msg='greeted user; no task pending']
```
c4 (follow-up at 1.72 s; the step label says 1.45 s, but typing took longer than planned):
```
  12.807 KEY   enter
  12.838 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  12.856 HOOK  UserPromptSubmit sid=<sid-c4>
  15.125 HOOK  Stop sid=<sid-c4>
  15.137 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  16.614 MARK  prompt2-1.45s-after-done
  16.860 KEY   enter
  16.887 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  16.908 HOOK  UserPromptSubmit sid=<sid-c4>
  19.559 HOOK  Stop sid=<sid-c4>
  19.569 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  21.166 OSC   '\x1b]7501;state=done:app=claude-code:msg=Z3JlZXRlZCB0aGUgdXNlcjsgbm90aGluZyBwZW5kaW5n\x07'  [msg='greeted the user; nothing pending']
```
**Conclusion:** submitting a prompt before the summary arrives cancels it. It arrived neither before nor after the new `working`. A summary that is ready while the user is still typing comes before the new `working`. No summary `done` ever landed inside the next turn, and each turn's completing `done` had no `msg`.

### Case 2: a failing turn

Two ways, both with zero tokens spent:
- **c2:** a model name that does not exist, given through the harness's `--env` mechanism (`ANTHROPIC_MODEL=p35a-invalid-model`, for that child only).
- **c2b:** no route to the API, using `HTTPS_PROXY=http://127.0.0.1:9` and `HTTP_PROXY` for that child only, plus `CLAUDE_CODE_MAX_RETRIES=0`.

c2:
```
   9.935 KEY   enter
   9.987 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  10.011 HOOK  UserPromptSubmit sid=<sid-c2>
  10.426 OSC   '\x1b]7501;state=error:app=claude-code:msg=VGhlcmUncyBhbiBpc3N1ZSB3aXRoIHRoZSBzZWxlY3RlZCBtb2RlbCAocDM1YS1pbnZhbGlkLW1vZGVsKS4gSXQgbWF5IG5vdCBleGlzdCBvciB5b3UgbWF5IG5vdCBoYXZlIGFjY2VzcyB0byBpdC4gUnVuIC9tb2RlbCB0byBwaWNrIGEgZGlmZmVyZW50IG1vZGVsLg==\x07'  [msg="There's an issue with the selected model (p35a-invalid-model). It may not exist or you may not have access to it. Run /model to pick a different model."]
  10.441 HOOK  StopFailure sid=<sid-c2> error=model_not_found
  16.708 MARK  prompt2
  18.059 KEY   enter
  18.093 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  18.120 HOOK  UserPromptSubmit sid=<sid-c2>
  18.487 OSC   '\x1b]7501;state=error:app=claude-code:msg=<same as above>\x07'
  18.509 HOOK  StopFailure sid=<sid-c2> error=model_not_found
  24.629 MARK  exit
  25.605 KEY   enter
  25.631 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  25.641 OSC   '\x1b]7501;state=clear\x07'   (three times)
  26.162 HOOK  SessionEnd sid=<sid-c2> reason=prompt_input_exit
```
c2b (no trust dialog: same folder as c2):
```
   0.243 HOOK  SessionStart sid=<sid-c2b> source=startup
   0.415 OSC   '\x1b]7501;state=idle:app=claude-code\x07'
   7.393 KEY   enter
   7.445 OSC   '\x1b]7501;state=working:app=claude-code\x07'
   7.464 HOOK  UserPromptSubmit sid=<sid-c2b>
   7.551 OSC   '\x1b]7501;state=error:app=claude-code:msg=QVBJIEVycm9yOiBDb25uZWN0aW9uIHJlZnVzZWQg4oCUIGEgZmlyZXdhbGwgb3IgcHJveHkgbWF5IGJlIGJsb2NraW5nIGl0IChFQ09OTlJFRlVTRUQp\x07'  [msg='API Error: Connection refused — a firewall or proxy may be blocking it (ECONNREFUSED)']
   7.578 HOOK  StopFailure sid=<sid-c2b> error=server_error
```
- **StopFailure payload keys:** `cwd`, `effort`, `error`, `hook_event_name`, `last_assistant_message` (the on-screen error text), `prompt_id`, `scratchpad_dir`, `session_id`, `transcript_path`.
- **No `Stop` and no `done`** in any failed turn.
- **`error` stays** until the next prompt, which starts with `working` as usual.
- **Timing:** `error` came 106 ms (no network) and 394–439 ms (bad model) after `working`. The `StopFailure` record was written 15–27 ms after the in-band `error`.
- **Read in the binary, not captured:** the mapping inside Claude sends `error` for a failed last turn unless the error kind is an auth kind. For an auth kind it sends `blocked kind=auth`, or `idle` if the user has signed in since.

**Conclusion:** yes, `StopFailure` fires, and `error` is reported over OSC 7501 with the error text in `msg`. The `error` arrives first, by 15–27 ms, and can come as soon as 106 ms after `working`.

### Case 3: compaction (`/compact` on a short session)

c3, continued after case 1:
```
  15.220 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  16.665 OSC   '\x1b]7501;state=done:app=claude-code:msg=Z3JlZXRlZCB1c2VyOyBubyB0YXNrIHBlbmRpbmc=\x07'  [msg='greeted user; no task pending']
  21.508 MARK  compact
  22.562 KEY   enter
  22.627 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  22.653 HOOK  PreCompact sid=<sid-c3> trigger=manual
  35.734 HOOK  SubagentStop sid=<sid-c3>
  35.787 HOOK  SessionStart sid=<sid-c3> source=compact
  35.819 HOOK  PostCompact sid=<sid-c3> trigger=manual
  35.840 OSC   '\x1b]7501;state=done:app=claude-code:msg=Z3JlZXRlZCB1c2VyOyBubyB0YXNrIHBlbmRpbmc=\x07'  [msg='greeted user; no task pending']
  44.132 MARK  exit
```
- **`/compact` is reported as one long `working`** (13.2 s here), ended by a `done` whose bytes match the previous summary report exactly.
- **What is missing:** no bare `done`, no `Stop`, no `UserPromptSubmit`.
- **Hooks:**
  - `PreCompact` ran 26 ms after `working`.
  - The compaction runs as a subagent: a `SubagentStop` with `agent_type: ""`, whose `last_assistant_message` is the compaction summary.
  - `SessionStart` with `source: "compact"` keeps the same session id.
  - `PostCompact` ran 21 ms before the `done`.
- **Payload keys:**
  - `PreCompact`: `custom_instructions`, `trigger`, `prompt_id`, plus the common fields.
  - `PostCompact`: `compact_summary`, `trigger`, `prompt_id`, plus the common fields.
  - `SessionStart (compact)`: `model`, `prompt_id`, `source`, plus the common fields.

**Conclusion:** over OSC 7501 a manual compaction looks like a 13-second turn that ends in `done` with the old summary. Only the hooks show it was a compaction. Automatic compaction was not captured.

### Case 4: Ctrl-Z then `fg`, and the external editor

c4 ran Claude from an interactive `zsh -f -i` inside the PTY, through a one-line `exec claude …` script. That gives Ctrl-Z a job-control parent: Claude suspends by sending `SIGTSTP` to its own process group, which the kernel ignores for an orphaned group such as a PTY session leader. `EDITOR` and `VISUAL` pointed at `editor.sh`. The editor binding in 2.1.322 is `ctrl+g` (also `ctrl+x ctrl+e`).
```
  21.166 OSC   '\x1b]7501;state=done:app=claude-code:msg=Z3JlZXRlZCB0aGUgdXNlcjsgbm90aGluZyBwZW5kaW5n\x07'  [msg='greeted the user; nothing pending']
  25.869 MARK  type-draft
  26.765 MARK  ctrl-g
  26.820 IN    '\x1b[103;5u'          screen: "Save and close editor to continue..."; editor.log: one call with /tmp/claude-501/claude-prompt-<uuid>.md
  30.935 MARK  clear-input
  30.989 IN    '\x1b[117;5u'
  32.100 MARK  ctrl-z
  32.154 IN    '\x1b[122;5u'          screen: "Claude Code has been suspended. Run `fg` to bring Claude Code back." then "zsh: suspended"
  35.320 MARK  fg
  35.478 KEY   enter                  screen: Claude redraws
  39.588 MARK  prompt3-after-fg
  40.930 KEY   enter
  40.952 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  40.971 HOOK  UserPromptSubmit sid=<sid-c4>
  43.164 HOOK  Stop sid=<sid-c4>
  43.176 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  44.764 OSC   '\x1b]7501;state=done:app=claude-code:msg=cmVwbGllZCAnb2snIGFzIHJlcXVlc3RlZA==\x07'  [msg="replied 'ok' as requested"]
```
- **Raw scan from 21.2 to 40.9 s:** no `7501` bytes at all. The only mode traffic is the kitty pop and push around the editor (`ESC[<u`, `ESC[>5u`) and around the suspend and resume.
- **Hooks:** none in that window.
- **After `fg`:** the next turn reports normally.
- **Not captured:** Ctrl-Z during a turn.

**Conclusion:** neither suspend/`fg` nor the external editor reports anything. The last report (`done` with its summary) stays in force throughout.

### Case 5: a turn longer than 120 s

**Attempt 1 (c5): user defaults, `--allowedTools 'Bash(sleep:*)'`, child-only `BASH_DEFAULT_TIMEOUT_MS=300000`.** The prompt asked for `sleep 130` in the foreground. Claude ran it in the background anyway, and the turn ended after 12 s:
```
  12.381 KEY   enter
  12.434 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  12.459 HOOK  UserPromptSubmit sid=<sid-c5>
  16.216 OSC   '\x1b]7501;state=working:app=claude-code:msg=V2FpdGluZyAxMzAgc2Vjb25kcw==\x07'  [msg='Waiting 130 seconds']
  22.600 HOOK  PreToolUse sid=<sid-c5> tool_name=Bash
  22.651 OSC   '\x1b]7501;state=working:app=claude-code:msg=V2FpdGluZyAxMzAgc2Vjb25kcyBpbiB0aGUgYmFja2dyb3VuZA==\x07'  [msg='Waiting 130 seconds in the background']
  22.695 HOOK  PostToolUse sid=<sid-c5> tool_name=Bash
  24.733 HOOK  Stop sid=<sid-c5>
  24.746 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  26.355 OSC   '\x1b]7501;state=done:app=claude-code:msg=c2xlZXAgMTMwIHJ1bm5pbmcgaW4gYmFja2dyb3VuZDsgd2lsbCByZXBseSB3aGVuIGRvbmU=\x07'  [msg='sleep 130 running in background; will reply when done']
  30.946 MARK  exit
  31.929 KEY   enter
  31.952 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  31.966 OSC   '\x1b]7501;state=done:app=claude-code:msg=<same summary as 26.355>\x07'
                                        screen: "Background work is running · The following will stop when you exit: shell · sleep …"
  39.040 STEP  {"signal": 1, "pid": …}     (the harness ends its own child with SIGHUP)
  39.048 OSC   '\x1b]7501;state=clear\x07'   (three times)
  39.681 HOOK  SessionEnd sid=<sid-c5> reason=other
```
Side finding: `/exit` while background work runs shows a confirmation dialog. It is reported as `working` and then, 14 ms later, a `done` that repeats the previous summary. It is not reported as `blocked`. Ending the session by SIGHUP gives `SessionEnd` with `reason: "other"`. No `sleep 130` process was left afterwards.

**Attempt 2 (c5b): as attempt 1, plus child-only `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`, so the command had to run in the foreground.** Same folder, no trust dialog:
```
   9.700 KEY   enter
   9.762 OSC   '\x1b]7501;state=working:app=claude-code\x07'
   9.783 HOOK  UserPromptSubmit sid=<sid-c5b>
  13.295 HOOK  PreToolUse sid=<sid-c5b> tool_name=Bash
  13.737 OSC   '\x1b]7501;state=working:app=claude-code:msg=V2FpdGluZyBmb3IgMTMwIHNlY29uZHM=\x07'  [msg='Waiting for 130 seconds']
 143.472 HOOK  PostToolUse sid=<sid-c5b> tool_name=Bash
 145.043 HOOK  Stop sid=<sid-c5b>
 145.060 OSC   '\x1b]7501;state=done:app=claude-code\x07'
 146.749 OSC   '\x1b]7501;state=done:app=claude-code:msg=cmFuIHNsZWVwIDEzMCBpbiBmb3JlZ3JvdW5kOyByZXBsaWVkIGZpbmlzaGVk\x07'  [msg='ran sleep 130 in foreground; replied finished']
 152.329 KEY   enter      (/exit)
 152.366 OSC   '\x1b]7501;state=working:app=claude-code\x07'
 152.375 OSC   '\x1b]7501;state=clear\x07'   (three times)
 152.878 HOOK  SessionEnd sid=<sid-c5b> reason=prompt_input_exit
```
- **Raw scan from 13.8 to 145.0 s:** no OSC sequence of any kind. No 7501, no title, no `9;4` progress.
- **Screen redraws continued**, with no gap longer than 0.24 s (1420 output chunks), so silence in the program-status channel does not mean the process is quiet.
- **Hooks:** none fired between `PreToolUse` and `PostToolUse`.

**Conclusion:** there are no periodic reports. After one `working` with `msg` at the start of the tool call, the channel was silent for 131 s until `done`. Also, with default settings Claude may move a long command to the background by itself and end the turn with `done` while the work goes on. What happens when that background task later finishes was not captured.

### Case 6: fork binding

- **Session A (c6a):** `claude --session-id <uuid-A>`, one prompt, `/exit`.
- **Then the fork (c6b), in the same folder:** `claude --resume <uuid-A> --fork-session --session-id <uuid-B> --settings <c6b settings>`, one prompt, `/exit`.
- **A's transcript, before the fork and after the fork exited:** identical (sha256 `11322e3b…d32b`, 381216 bytes, same mtime). A new file `<uuid-B>.jsonl` appeared next to it.
```
c6a
   2.615 HOOK  SessionStart sid=<uuid-A> source=startup
   2.635 OSC   '\x1b]7501;state=idle:app=claude-code\x07'
   9.986 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  10.003 HOOK  UserPromptSubmit sid=<uuid-A>
  12.328 HOOK  Stop sid=<uuid-A>
  12.342 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  14.138 OSC   '\x1b]7501;state=done:app=claude-code:msg=cmVwbGllZCAib2siIGFzIHJlcXVlc3RlZA==\x07'  [msg='replied "ok" as requested']
  18.087 HOOK  SessionEnd sid=<uuid-A> reason=prompt_input_exit
c6b
   0.284 HOOK  SessionStart sid=<uuid-B> source=fork
   0.471 OSC   '\x1b]7501;state=idle:app=claude-code\x07'
   9.407 KEY   enter
   9.430 OSC   '\x1b]7501;state=working:app=claude-code\x07'
   9.447 HOOK  UserPromptSubmit sid=<uuid-B>
  13.528 HOOK  Stop sid=<uuid-B>
  13.540 OSC   '\x1b]7501;state=done:app=claude-code\x07'
  15.534 OSC   '\x1b]7501;state=done:app=claude-code:msg=cmVwbGllZCAnb2snIGFzIHJlcXVlc3RlZA==\x07'  [msg="replied 'ok' as requested"]
  19.404 HOOK  SessionEnd sid=<uuid-B> reason=prompt_input_exit
```
- **SessionStart (fork) payload keys:** `context_tokens`, `cwd`, `estimated_cache_write_usd`, `hook_event_name`, `prompt_cache_likely_expired`, `scratchpad_dir`, `seconds_since_last_response`, `session_id` (= `<uuid-B>`), `source` (= `"fork"`), `transcript_path` (= `…/<uuid-B>.jsonl`).
- **No hook payload in the fork mentions `<uuid-A>`.** All 4 fork hook records carry `<uuid-B>`.
- **Inside `<uuid-B>.jsonl`:**
  - Every entry's `sessionId` is `<uuid-B>`.
  - `<uuid-A>` survives only inside the copied history: in a secondary `session_id` field of copied attachment, assistant and system entries, and in copied text.

**Conclusion:** the fork's `SessionStart` carries the new id `<uuid-B>` with `source: "fork"`, and session A's transcript is not modified. A forked agent binds to its own new id, never to its source session.

### Case 7: `/clear` in a session started with `--session-id`

Re-confirmed in c1:
```
  28.423 KEY   enter      (/clear)
  28.470 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  28.504 HOOK  SessionEnd sid=<sid-c1> reason=clear
  28.533 OSC   '\x1b]7501;state=idle:app=claude-code\x07'
  28.548 HOOK  SessionStart sid=<sid-c1-after-clear> source=clear
  37.517 KEY   enter      (/exit)
  37.584 OSC   '\x1b]7501;state=working:app=claude-code\x07'
  37.595 OSC   '\x1b]7501;state=clear\x07'   (three times)
  38.176 HOOK  SessionEnd sid=<sid-c1-after-clear> reason=prompt_input_exit
```
**Conclusion:** `SessionStart` with `source: "clear"` carries a new random id, not the one given by `--session-id`. Later hooks use the new id. The `working` blip lasted 63 ms.

### Against the P3.5 mapping

The mapping under review (plan row P3.5):
- `working` starts or continues a turn.
- `done` completes the active turn; a `done` with no active turn only updates the summary.
- `idle` ends an active turn as interrupted.
- `clear` resets.
- `error` fails the turn.
- A `working` followed by `idle` or `clear` within 250 ms raises no effects.

Each point below is either a contradiction or a refinement.

1. **Refinement (late summary): the mapping holds, and one more guard is available.**
   - A summary `done` never landed inside a following turn (case 1). Submitting before it arrives cancels it, and a summary that is ready first comes before the new `working`. `secondDoneIsNotASecondCompletion` is right as written.
   - In all 12 completed turns captured here (and all 8 in the first spike), the `done` that completed the turn had no `msg`. Every `done` with `msg` was either a summary or the end of something that was not a turn (points 2 and 3).
   - So "a `done` carrying `msg` never completes a turn" is a cheap second guard.

2. **Contradiction (`/compact`).**
   - What happens: `/compact` is reported as `working` for the whole compaction (13.2 s), then a `done` repeating the previous summary. There is no `Stop` and no `UserPromptSubmit` (case 3).
   - Under the mapping as written, that is a turn that completes: a false completion and a false "done" notification. The 250 ms rule does not cover it.
   - Proposed fix: a `PreCompact` with `trigger: "manual"` (the hook is already in the reduced hook list) marks the current `working` as a compaction. The `done` that ends it completes nothing.
   - Use `PreCompact`, not `PostCompact`. `PreCompact` was written 26 ms after `working` and 13 s before `done`. `PostCompact` was written only 21 ms before the in-band `done`, so it can lose the race through the file watcher.
   - The `msg` guard from point 1 also covers this capture. It would not cover a compaction run when the previous turn has no summary; going by the code, Claude would then send a bare `done`. That case was not captured.
   - Automatic compaction (`trigger: "auto"`) was not captured. It happens inside a real turn, so it must not suppress that turn's completion.

3. **Contradiction (a `working` blip ending in `done`).**
   - What happens: `/exit` while background work runs opens a "Background work is running" confirmation. It is reported as `working`, then 14 ms later a `done` repeating the old summary (case 5, attempt 1).
   - The 250 ms rule names only `idle` and `clear`, so as written this is a turn that completes.
   - Proposed fix: the rule should read "a `working` followed by `idle`, `clear` or `done` within 250 ms raises no effects". It must not cover `error`: a real failure arrived 106 ms after `working` (case 2, no network).
   - The confirmation waits for the user but is reported as `done`, not `blocked`, so the app cannot show it as waiting.

4. **Refinement (`error`).**
   - `error` is now observed, so F2's "Claude `error` was never seen" is out of date.
   - What happens: a failed turn gives `working`, then `error` 106–440 ms later, with the on-screen error text in `msg`. No `Stop`, no `done`. `error` stays until the next prompt, and the next prompt starts with `working` as usual.
   - `StopFailure` also fires, carrying `error` (`model_not_found`, `server_error`), `prompt_id` and `last_assistant_message`. Its record was written 15–27 ms after the in-band `error`, and nothing guarantees that order across the two channels.
   - So the failure notification must be raised once per failed turn, whichever of `error` and `StopFailure` arrives first. The `error` report alone could carry the notification, since it is earlier and includes the message.
   - Read in the binary, not captured: auth failures are reported as `blocked kind=auth` instead of `error`.

5. **Confirmed (suspend and external editor).**
   - Ctrl-Z, the stopped period, `fg`, and Ctrl-G with its editor produce no report at all (case 4). The last report stays in force.
   - Nothing in the mapping needs to change. The app cannot tell a suspended Claude from one waiting at its prompt.
   - Ctrl-Z during a turn was not captured; it would presumably leave `working` standing with no reports.

6. **Confirmed (long turns).**
   - A 135-second turn produced one `working` with `msg` near its start and then 131 s of silence until `done` (case 5).
   - The plan's statement that the 120-second "status delayed" rule does not apply to this source is required: any timer on `working` would fire falsely on every long tool call.

7. **Refinement (identity, for P3.6 and F5).**
   - `SessionStart` arrives with `source` set to `startup`, `resume` (first spike), `clear`, `compact` or `fork`.
   - `compact` keeps the id. `clear` and `fork` bring a new one: a random id for `clear`, the `--session-id` value for `fork`.
   - The P3.6 handler must accept all five. F5 should add that a fork reports `source: "fork"` with the new id and leaves the source transcript untouched (case 6). `claudeForkAnnouncesNewSessionID` matches what Claude does.

8. **Note (liveness).**
   - In an already-trusted folder, `SessionStart` can run before Claude even sends the 7501 query (c2b: hook at 0.243 s, query at 0.386 s, `idle` at 0.415 s; c5b the same).
   - This does not conflict with "first report within 10 s marks the provider alive": every session's first report came within 0.5 s of spawn, or within 0.35 s of accepting the trust dialog.

## P3.6 capture (2026-11-12): `--resume` of a session that does not exist

Same machine, Claude Code 2.1.322, same harness, run from this shell (not inside a Clawddy agent), user's configured model (no model call happens). Three runs of
`claude --resume <uuid-X> --name p36name --settings <logging hooks> --debug-file …`, where `<uuid-X>` is a fresh random UUID that names no session anywhere. Captures: `/Volumes/Xcode/GhosttyBuilds/ghostty/tmp/p36/r1`–`r3`. All three share the folder `r1/work`.

- **r1, untrusted folder, nothing typed:** the trust dialog comes first. `7501;?` is sent and answered. Nothing else happens; the session is not looked up. The harness ended it with SIGHUP (exit status 129), and no hook ran.
- **r2, same folder, trust accepted (`down`, `enter` at 1.148 s):**
  ```
   1.505 OSC   '\x1b]7501;state=clear\x07'
   1.505 TEXT  No conversation found with session ID: <uuid-X>
   1.506 OSC   '\x1b]7501;state=clear\x07'
   1.530 HOOK  SessionEnd sid=<uuid-X> reason=other
         EXIT  status 1
  ```
- **r3, same folder, now trusted (the case Clawddy launches into):**
  ```
   0.277 TEXT  No conversation found with session ID: <uuid-X>
   0.303 HOOK  SessionEnd sid=<uuid-X> reason=other
         EXIT  status 1
  ```
  No OSC 7501 bytes at all: no query, no state. The debug log has `[ERROR] No conversation found with session ID: <uuid-X>`, then the `SessionEnd:other` hooks.
- **In both r2 and r3:**
  - No `SessionStart`. `SessionEnd` runs with `reason: "other"` and carries the requested id; its payload has only the common fields and `reason`.
  - Exit status 1. The harness sent SIGHUP only after the child had closed the terminal; a SIGHUP exit is 129 (r1), so 1 is Claude's own.
  - No transcript was created: the folder's project directory under `<CLAUDE_CONFIG>/projects/` does not exist.
- **Declining the trust dialog** also exits with status 1 and no `SessionStart` (A2), but runs no hook at all ("workspace trust not accepted"). So a `SessionEnd` with no `SessionStart` before it is what sets a missing session apart.

**Safety:** `run.sh` saw status-folder changes only during r1, in one live agent's files, from the owner's own session. The r1 session ran no hook, because trust was never accepted. In r2 and r3, the user's old global `clawddy-provider-hook.sh` entry also ran on `SessionEnd`; it found no agent identity (stripped by `clean-env`) and exited 0. The only global side effect was Claude's own trust and project entry for `r1/work` in its state file (`.claude.json` in the home folder).

**Rule used in P3.6:** a Claude launch that resumes a saved session (`--resume <id>`, not a fork) and records `SessionEnd` before any `SessionStart` found no such session. The agent shows it as a failed start that offers "Start fresh". The exit record (status 1) may arrive on either side of `SessionEnd`. A resume that exits with no hook at all stays an ordinary start failure. The on-screen text is not read.

Not captured: whether Claude looks for the id only under the current folder's project. A session that exists but was started in another folder may give the same result.

## Review S1 capture (2026-11-12): is a session with no message resumable?

Claude Code 2.1.323 (one patch release after the captures above), same harness and machine, run from this shell (not inside a Clawddy agent), user's configured model, `--settings` logging hooks in every run. Seven runs, all in one folder: `/Volumes/Xcode/GhosttyBuilds/ghostty/tmp/review-s1/<run>/` (each with `steps.json`, `settings.json`, `run.txt` and `cap/`), working folder `review-s1/work`. `clean-env` removed every `CLAUDE*` variable, including `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE`, which this shell carries; the debug log shows the user's own settings set that name, and the result below holds with it.

| Run | Command | Typed | Hooks | Exit | Transcript afterwards |
|---|---|---|---|---|---|
| a | `--session-id <A>` | trust, one one-word prompt, `/exit` | `SessionStart startup`, `UserPromptSubmit`, `Stop`, `SessionEnd prompt_input_exit` | 0 | `<A>.jsonl` written |
| b | `--resume <A> --fork-session --session-id <B>` | `/exit` only | `SessionStart fork` (its `transcript_path` names `<B>.jsonl`), `SessionEnd prompt_input_exit` | 0 | **no `<B>.jsonl`**; `<A>.jsonl` byte-identical |
| b2 | `--resume <B>` | nothing | `SessionEnd other` only | 1 | "No conversation found with session ID: `<B>`" |
| c | `--session-id <C>` (folder already trusted) | `/exit` only | `SessionStart startup`, `SessionEnd prompt_input_exit` | 0 | **no `<C>.jsonl`** |
| c2 | `--resume <C>` | nothing | `SessionEnd other` only | 1 | "No conversation found with session ID: `<C>`" |
| d | `--resume <A>` | `/clear`, then `/exit` | `SessionStart resume`, `SessionEnd clear`, `SessionStart clear` (new id `<D>`), `SessionEnd prompt_input_exit` | 0 | `<D>.jsonl` written (4495 bytes) |
| d2 | `--resume <D>` | `/exit` only | `SessionStart resume`, `SessionEnd prompt_input_exit` | 0 | resumed |

- **A new or forked session with no message is never written.** Both report `idle` at once and run `SessionStart` with the transcript path they would use, but the file does not exist when they exit, and a later `--resume` of the id fails exactly as in the P3.6 capture: no `SessionStart`, `SessionEnd reason: "other"`, exit status 1.
- **The first entry appended writes it.** A prompt does (a; the failing turns of P3.5a case 2 also left transcripts). `/clear` does too: the post-clear session holds the `/clear` command entry (`<command-name>/clear</command-name>`) and resumes (d, d2).
- **Consequence for Clawddy:** a binding names a resumable session only once the session has had its first entry. Clawddy cannot see the file, so it takes the first turn as that point (a settled `working`, a `blocked` or an `error`): until then a launch that created its session under an ID it chose has not saved it, and the next launch forks again from the fork's source, or starts a new session with a new `--session-id`. Waiting for the turn is conservative: a `/clear` with no prompt also writes the session, but nothing in the hooks Clawddy subscribes to separates it from a fork's `SessionStart`, and forking again loses only that empty session.

**Safety:** none of the four session ids appears anywhere in `<CLAWDDY_CONFIG>/status/`. `run.sh` saw changes only in two live agents' files, from the owner's own sessions running at the time. The old global `clawddy-provider-hook.sh` entry ran on each `SessionStart` and `SessionEnd`, found no agent identity and exited 0.

## Flows capture (2026-11-14): `/resume` inside Claude, `--resume`, `/clear`

The owner reported that an agent stopped showing its state after "continue". Its event file showed `SessionEnd` for the launch's session, then `SessionStart` for an older session of the same folder in the same launch, which is what `/resume` inside Claude does. These runs look for the cause. Claude Code 2.1.325, the same harness (`spike-harness/`, from this shell, not inside a Clawddy agent, `--settings` logging hooks), the user's configured model, one-word prompts. Captures: `/Volumes/Xcode/GhosttyBuilds/ghostty/tmp/flows1/<run>/` (`steps.json`, `settings.json`, `cap/`), all in the folder `flows1/work`. `<X>` is a conversation made first for the others to resume (run `x`: `--session-id <X> --name earlier-x`, one turn, `/exit`). Only OSC 7501 and hooks are shown.

**a: new session, a turn, `/resume <X>` typed with its argument, a turn** (`--session-id <A> --name "agent 1"`):
```
   0.249 HOOK  SessionStart sid=<A> source=startup
   0.422 OSC   state=idle
   8.118 OSC   state=working
   9.669 HOOK  Stop sid=<A>
   9.684 OSC   state=done
  11.708 OSC   state=done  [msg='replied with the single word ok as requested']
  16.048 KEY   enter (/resume <X>)
  16.064 OSC   state=working
  16.293 HOOK  SessionEnd sid=<A> reason=resume
  16.320 HOOK  SessionStart sid=<X> source=resume
  16.344 OSC   state=idle
  25.549 OSC   state=working
  25.577 HOOK  UserPromptSubmit sid=<X>
  26.724 HOOK  Stop sid=<X>
  26.735 OSC   state=done
  28.432 OSC   state=done  [msg="replied 'yes' as requested"]
```
**a3: the same through the picker** (`/resume`, Enter, type to search, Enter, Enter): the picker's Enter reports nothing; choosing a conversation gives `SessionEnd reason=resume` (23.111), `SessionStart source=resume` for `<X>` (23.140) and `idle` (23.164). The next turn reports `working` (27.828) and `done` (29.019) as usual.

**b: `--resume <A>` of a stopped agent, a turn:** `SessionStart source=resume` (0.327) runs before the `7501;?` query (0.456) and `idle` (0.503); the turn reports `working` (8.116) and `done` (9.436).

**c: `/clear`, then a turn** (`--session-id <C>`): `working` (26.055), `SessionEnd reason=clear` (26.075), `idle` (26.106), `SessionStart source=clear` with a new id (26.122); the next turn reports `working` (33.533), `done` (36.715) and its summary.

- **`SessionEnd` gives `reason: "resume"`** when `/resume` leaves a session; the `SessionStart` that follows has `source: "resume"` and the chosen conversation's id. Nothing in the OSC 7501 channel changes after `/resume`: the same reports, without `id`, keep coming.
- **`/resume` typed with its argument reports `working` for 280 ms** (434 ms in the run below), longer than `AgentBridge.turnStartDelay` (250 ms), so it starts a turn that `idle` ends without a completion. Through the picker it reports no `working`.

**Both `/resume` cases through the real app path** (`flows1/live-resume.log`, `flows1/live-picker.log`): a temporary test, not kept, ran a real Claude in a real Ghostty surface hosted by `AgentDetailViewController`, through a real `AgentBridge` with real timers, file watching and IO, on a temporary data root, typing through the surface's own input. After `/resume`, by argument and through the picker, each later turn showed Working, then Done (unread, as nothing viewed the agent), with the session rebound to `<X>`. The only difference from the capture above is the `working` of the typed `/resume`, which showed Working for 0.4 s and cleared the unread Done of the turn before.

**Not reproduced:** an agent that stops showing its state after `/resume`. Not tried: resuming a long conversation (the owner's was an 11.8 MB transcript), which may take another path inside Claude, and a model change with `/model`, which the owner's status line shows happened in that session.

## Flows 2 capture (2026-11-14): terminal titles, the list of conversations

For `docs/clawddy-design/flows.md` 5 (does Claude Code title the conversation?) and 8 (`claude --resume` with no id). Claude Code 2.1.325, the same harness (`spike-harness/`, from this shell, not inside a Clawddy agent, `--settings` logging hooks, OSC 7501 answered), the user's configured model, one-word prompts. Captures: `/Volumes/Xcode/GhosttyBuilds/ghostty/tmp/flows2/<run>/` (`steps.json`, `settings.json`, `cap/`), all in the folder `flows2/work`, new before t1. `<T>` is t1's conversation. Only OSC 0 (title), OSC 7501 and hooks are shown.

**t1: a new conversation with no `--name`** (`--session-id <T>`; the trust dialog accepted first):
```
   3.228 HOOK  SessionStart sid=<T> source=startup
   3.258 OSC   state=idle
   3.258 OSC   0 "Claude Code"
  10.983 OSC   state=working
  11.005 HOOK  UserPromptSubmit sid=<T>
  12.075 OSC   0 "Single word reply"
  12.111 OSC   state=done
  18.771 OSC   state=working                (a second prompt, on another topic)
  18.793 HOOK  UserPromptSubmit sid=<T>
  20.234 OSC   state=done                   (no new title)
  26.385 OSC   state=working, clear ×3, then 0 ""   (/exit)
```
- **Before the first prompt the title is "Claude Code"; 1.09 s after it, a few words about the conversation, which stay**: the second prompt, on another topic, changed nothing.
- `/exit` clears the title (`OSC 0 ""`) before the launch script's exit report; a Ghostty surface then shows its working directory as its title.

**t2: `--resume <T>`, no `--name`:** `0 "✳ Single word reply"` (0.311, before the status query is answered), then `idle` and `0 "Single word reply"` (0.462). The conversation keeps its title.

**t5, then t6: `--resume <T> --name named-by-user`, then `--resume <T>` with no name:** both show `0 "✳ named-by-user"`, then `0 "named-by-user"`. A name given once names the conversation for good.

**t3: `claude --resume` with no id** (Claude's own list of the folder's conversations, "Resume session … Esc to cancel"): `0 "claude · resume"` (0.253) and the status query; no other report and no hook while the list shows. Enter on the first row: `idle` and `0 "Single word reply"` (6.207), `SessionStart source=resume` for `<T>` (6.276). The next prompt reports `working`, `UserPromptSubmit`, `Stop`, `done` as usual.

**t4: the same list, Esc:** `9;4;0` and `state=clear` (6.153), exit status 1. No `SessionStart`, no hook at all.

- **Rules used:** a Clawddy agent whose name is not the user's is launched without `--name`, and the cleaned terminal title becomes its name (`AgentConversationTitle`: leading glyphs dropped; "Claude Code", "claude · resume" and a path give nothing; at most 40 characters). An agent made for "Continue an earlier conversation…" launches `claude --resume`; the `SessionStart` of the chosen conversation binds it, and an exit before the provider ever reported (t4) removes it.
- **A prompt is a turn; a command is not.** Every prompt captured runs `UserPromptSubmit` after its `working`, usually 18 to 31 ms after it and once 311 ms (P3.5a case 1); `/resume <id>`, `/clear` and `/exit` report a `working` and run none. Clawddy now starts a Claude turn on the prompt's record (`.promptSubmitted`), and a `working` with no prompt only after 1 s (`AgentBridge.turnStartDelay`), so `/resume` shows no Working and leaves the Done before it unread.

**Through the real app path** (a temporary test, not kept: real `claude` in real Ghostty surfaces hosted by `AgentDetailViewController`, through a real `AgentBridge` with real timers, file watching and IO, on a temporary data root, typing through the surface's own input; timeline `flows2/live-after-fix.log`):
- A new agent "agent 1" showed Working 0.47 s after Enter, Done, and took the name "Single word reply" 0.5 s after Done, saved in `agents.json`, with `autoNamed` in `state.json`. Its first run also showed that at `/exit` Ghostty's fallback title, the working directory, was taken as a name; paths are now ignored, and the second run kept "Single word reply".
- "Continue an earlier conversation…" in the same folder: Enter on the list bound the new agent to the conversation above (its binding file names it), named it "Single word reply 2", tracked its turn (Working, then Done), and after `/exit` a bring-back resumed that conversation.
- Esc on the list removed the agent within 0.1 s, nothing notified, nothing kept in Recently removed.
- Not tried: Codex's list (`codex resume`), whose choice binds only through Codex's hooks.

## agy (Antigravity CLI 1.5.17) captures (2026-11-25)

For `docs/clawddy-design/agy-plan.md`. agy 1.5.17 (`agy --version` prints `1.5.17`), run in a pseudo-terminal of its own by the probe script (`/Volumes/Xcode/GhosttyBuilds/ghostty/redesign-notes/agy/probes/stage1/probe.py`, outside the repository; captures beside it and in `probes/run2..run7-osc.log`). The probe answers the `7501;?` query as the fork does and `TERM` is `xterm-ghostty`; 120×40 cells. Each probe ran in a new throwaway folder `<WS>`, trusted for that session with `--settings '{"trustedWorkspaces":["<WS>"]}'`, and with a hook folder `<HOOKDIR>` passed with `--add-dir <HOOKDIR>` whose `.agents/hooks.json` logs every record. Prompts were one-line requests ("Reply with the single word ok."). Redactions: `<WS>`, `<HOOKDIR>`, `<id>`/`<A>`/`<B>` for conversation ids, `<model>` for the model's name and id, `<plan>` for the account's plan; the banner's account line is never shown. Times are seconds since launch; only OSC 7501 (`OSC`), hooks (`HOOK`) and keys (`KEY`) are shown.

### Status reports

- **Format:** `ESC ] 7501 ; state=<s>[:kind=<k>]:app=antigravity[:msg=<base64>] BEL`. Always BEL, always `app=antigravity`, fields always in this order. Never `id`, `progress` or `title`, never `clear`.
- **The query comes first** (`ESC]7501;?BEL`, 0.11–0.18 s). **Without an answer agy never reports** and otherwise works the same.

| Report | Bytes (msg decoded) | When |
| --- | --- | --- |
| Sign-in check | `state=blocked:kind=auth:app=antigravity:msg=` "Sign in required" (`U2lnbiBpbiByZXF1aXJlZA==`) | Right after the answer, while the start-up sign-in runs. Not always: absent once when the answer came late (0.78 s) and when sign-in failed offline |
| Ready | `state=idle:app=antigravity` | 30–40 ms after the sign-in check in ten starts; **500 ms after it in two** (0.14 → 0.64 s; both resumes that added a folder the conversation did not have yet). Another resume took 30 ms |
| Folder trust dialog | `state=blocked:kind=permission:app=antigravity:msg=` "Trust this folder?" | Instead of `idle`, while the dialog shows |
| Turn starts | `state=working:app=antigravity` | 10–20 ms after Return. **On a resumed conversation it carries the conversation's title as msg** (e.g. "Alpha And Beta Output"); in a conversation made in this process it carries none |
| Question | `state=blocked:kind=question:app=antigravity:msg=` the question | When the question menu shows. **Cut to 179 characters and "…"** past 180: a 272-character question gave 180 characters |
| Command needs approval | `state=blocked:kind=permission:app=antigravity:msg=` "Approve Bash: echo chosen" | When the permission menu shows (default mode; auto mode approves `echo` itself) |
| Answer or approval given | `state=working:app=antigravity` | 20 ms after Return |
| Turn ends | `state=done:app=antigravity:msg=` the reply's first line | After the Stop hook returns (40–90 ms after it starts). **Always a msg.** A reply "alpha\nbeta" gave "alpha"; a long first line is cut to 199 characters and "…" (200) |
| First key after `done` or `error` | `state=idle:app=antigravity` | Typing a character, the first Control-D, or Escape after an error |
| Interrupt | `state=idle:app=antigravity` | 60 ms after Escape |
| Failure | `state=error:app=antigravity:msg=` the error | See "A live failure" |
| Exit | `state=idle:app=antigravity` | At exit, after the terminal is restored |

- `/clear` reports nothing.

### Timelines

**A new conversation from `--prompt-interactive=<text>`** (reply "alpha\nbeta"):
```
   0.78 OSC   ?
   0.88 OSC   state=idle                     (no sign-in report this time; see above)
   2.06 OSC   state=working                  (the first prompt, 1.2 s after idle)
   3.21 HOOK  SessionStart <A>
   3.30 HOOK  PreInvocation <A> invocationNum=0 initialNumSteps=1
   6.18 HOOK  PostInvocation <A> invocationNum=0
   6.22 HOOK  Stop <A> terminationReason=NO_TOOL_CALL fullyIdle=true error=""
   6.26 OSC   state=done  [msg='alpha']
```
**A question** (typed prompt in the same conversation, Return on option 1):
```
   8.50 KEY   text typed  →  OSC state=idle
   9.08 OSC   state=working
   9.08 HOOK  PreInvocation <A> invocationNum=0 initialNumSteps=3
  12.55 OSC   state=blocked:kind=question  [msg='Before we continue … palette that …']
  14.09 KEY   enter
  14.11 OSC   state=working
  14.12 HOOK  PostInvocation <A> invocationNum=0
  14.15 HOOK  PreInvocation <A> invocationNum=1
  17.31 HOOK  PostInvocation <A> invocationNum=1
  17.34 HOOK  Stop <A>
  17.43 OSC   state=done  [msg='yes']
```
**A command that needs approval** (default mode, `--prompt-interactive`, Return on option 1):
```
   1.45 OSC   state=working
   2.40 HOOK  SessionStart <B>
   2.43 HOOK  PreInvocation <B> invocationNum=0
   5.56 OSC   state=blocked:kind=permission  [msg='Approve Bash: echo chosen']
   7.12 KEY   enter
   7.14 OSC   state=working
   7.16 HOOK  PostInvocation <B> invocationNum=0      (the transcript already holds the command's result)
   7.20 HOOK  PreInvocation <B> invocationNum=1
  17.23 HOOK  PostInvocation <B> invocationNum=1
  17.27 HOOK  Stop <B>
  17.29 OSC   state=done  [msg='done']
```
**An interrupt with a message queued:**
```
  19.99 OSC   state=working
  20.02 HOOK  PreInvocation <A> invocationNum=0
  35.56 KEY   "queued words", enter                   (nothing reported, no hook)
  37.11 KEY   esc
  37.17 OSC   state=idle
```
No PostInvocation, **no Stop**, and nothing more in the transcript after the prompt's own line; the queued text is back in the input box; the transcript area shows `  ⎿  Interrupted · What should Antigravity CLI do instead?`. Nothing came later either (the conversation was left by `/clear` 6 s later).

**`/clear`, then a prompt:** nothing reported and no hook at `/clear`. The presence lock moves to a new id at once (before any prompt); the old one is released. The next prompt: `working` (47.29), `SessionStart` with the new id (47.40), `PreInvocation` (47.43), …, `Stop` (50.94), `done` (50.96).

**`--conversation <A>`, then a prompt:** sign-in check (0.14), `idle` (0.64; 0.17 in another resume); the transcript of `<A>` is drawn again above the box; the lock of `<A>` is held from the start. **No hook before the first prompt, and no SessionStart at the first prompt either:** `working` with the title as msg (5.28), `PreInvocation <A> invocationNum=0 initialNumSteps=12` (5.34), `PostInvocation`, `Stop` (7.90), `done` (7.93). SessionStart fires only for a conversation made in this process.

**`--conversation` with an id that does not exist:** nothing on screen, nothing reported beyond the usual start-up, no lock for that id. agy starts a new session: the first prompt makes a new id, and SessionStart, PreInvocation and Stop carry the new id.

**A live failure** (the process given `HTTPS_PROXY`, `HTTP_PROXY` and `ALL_PROXY` naming a closed local port; nothing else changed): no sign-in report, `idle` (0.13), the banner shows no model. The prompt: `state=error` 10 ms after Return, msg "failed to construct executor: plan model not specified; you must specify a valid model", with no `working` before it and **no hook at all** (no SessionStart, no Stop). On screen under the prompt's echo: `⚠ failed to construct executor: …` (red) and `Error ID: <uuid>-1` (grey). The state stays `error` until Escape, which reports `idle`.

### Hooks

- **A resumed conversation keeps the folders it was made with.** `<A>` was made with `--add-dir <HOOKDIR-1>`; `--conversation <A> --add-dir <HOOKDIR-2>` ran the hooks of both folders, once each, and `workspacePaths` listed the launch folder, `<HOOKDIR-1>`, `<HOOKDIR-2>`. Passing `<HOOKDIR-1>` again on a resume ran its hooks once and listed it once.
- **Loaded from `--add-dir` folders:** `<HOOKDIR>/.agents/hooks.json` runs, with no trust question for `<HOOKDIR>`; agy's log says "loaded 1 named hooks from 1 hooks.json file(s)". `{"<name>": {"<Event>": [{"type": "command", "command": "...", "timeout": 10}]}}` is the shape used.
- **The process:** working folder `<HOOKDIR>/.agents`; environment adds `ANTIGRAVITY_CONVERSATION_ID=<id>`; the record on stdin, one line of JSON with sorted keys.
- **Common fields:** `artifactDirectoryPath` (`~/.gemini/antigravity-cli/brain/<id>`), `conversationId`, `cwd` (the launch folder, not the hook's folder), `hookEventName`, `lastUserInput` (the prompt of the turn, also on SessionStart), `modelName` (`<model id>`), `transcriptPath`, `workspacePaths` (the launch folder, then each added folder).
- **`transcriptPath` begins with a literal `~/`** and names `…/brain/<id>/.system_generated/logs/transcript_full.jsonl`. The docs name `transcript.jsonl`; both files exist and hold the same steps.
- **PreInvocation, PostInvocation:** add `initialNumSteps` (steps in the transcript at that moment) and `invocationNum` (0 at each turn's start, +1 after each tool result or answer).
- **Stop:** adds `continuationActive` (false), `error` (""), `executionNum` (0), `fullyIdle` (true), `terminationReason` ("NO_TOOL_CALL" for every turn seen).
- **What a hook prints:** hooks that print nothing at all and hooks that print `{}` behave the same on SessionStart, PreInvocation, PostInvocation and Stop: nothing on screen, nothing in agy's log, turns unchanged. (A PreToolUse hook that prints `{}` denies the tool call; probes `run2`.)
- **The transcript at Stop:** in every turn seen (four) the file named by `transcriptPath` already held the turn's last `PLANNER_RESPONSE` line, full text included ("alpha\nbeta"), when Stop ran; it was there at PostInvocation already. The file grows next only at the next prompt.
- **Transcript lines** (one JSON object per step, `json.dumps` spacing): `{"step_index", "source": "USER_EXPLICIT", "type": "USER_INPUT", "status": "DONE", "created_at", "content": "<USER_REQUEST>\n<prompt>\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: <time>.\n</ADDITIONAL_METADATA>"}` (the first prompt also carries a `<USER_SETTINGS_CHANGE>` block); `{"step_index", "source": "MODEL", "type": "PLANNER_RESPONSE", "status", "created_at", "model", "input_tokens", "cache_read_tokens", "output_tokens", "thinking"?, "content"?, "tool_calls"?}`; `{"type": "GENERIC", "content": "Created At: …\nCompleted At: …\n<result>"}` for a tool result (an answer is "A1: yes"). A `PLANNER_RESPONSE` that calls a tool has `tool_calls` and empty or no `content`; the reply is the last one with `content`.

### Resuming by hand

- **A conversation keeps the folders it was made with**, so one Clawddy made runs the agent's hooks (`<per-user cache folder>/<app data folder name>/<agent id>/agy/.agents/hooks.json`; before the move `<data root>/runtime/<agent id>/agy`) when the person resumes it by hand in another terminal while that folder exists. Clawddy removes the folder when the agent's terminal closes (and with the agent), and keeps it after a quit. Records from such a hand run carry the generation of the agent's last launch: the app takes them only while that launch runs (they then count as its own: binding, prompts, replies; the two would share one conversation, which agy allows); otherwise they are a stale launch's and change nothing but the agent's last-active time.
- **A remembered folder that no longer exists is skipped without a word**: a conversation made with `--add-dir <folder>`, the folder deleted, then `--conversation <id>` with no folder: no message on screen, agy's log says "loaded 0 named hooks from 0 hooks.json file(s)", and a prompt runs as usual (probe `stage2/gone-a`, `gone-b`, two model turns).

### The presence lock

- `~/.gemini/antigravity-cli/presence/<id>.lock`, 0 bytes, open read-write by the process and held with an exclusive `flock` (a non-blocking `flock` from another process fails while agy runs, succeeds after).
- Taken when the conversation is made (the first prompt), at start on a resume, and moved to the new id at `/clear`. Before the first prompt only the `presence` folder is open. The file stays after exit, free.
- Conversations are stored as `~/.gemini/antigravity-cli/conversations/<id>.db`.
- **Clawddy checks the lock, then agy takes it** when its terminal starts, a fraction of a second later. A second process opening the same conversation in that window is not refused (agy answers in a conversation open elsewhere). Claude Code and Codex leave the same window between Clawddy's check and their own start; it is accepted.

### Screens

- **Banner** (at start): agy's logo, then beside it "Antigravity CLI 1.5.17", the account and `(<plan>)`, the model's name and effort ("<model> (High)"), the folder. A sign-in screen ("Welcome to the Antigravity CLI…", "Signing in...") shows on the alternate screen first and is gone once ready.
- **Input box:** a full-width rule, the box, a full-width rule, the footer. The box's first row is `>` (blue `#8ab4f8`) and a space, then the text; continuation rows are indented two spaces.
- **Mode hints** (grey `#9aa0a6`, on the box's first row when it is empty):
  - default (`agentMode: ""`): none, a bare `>`;
  - `--mode accept-edits`: "> Accept-edits mode: file edits auto-approved (shift+tab to cycle)";
  - auto (no `--mode`, no `agentMode` in the settings): "> Auto mode: edits & safe commands auto-approved (shift+tab to cycle)";
  - `--mode plan`: "> Plan mode: research & plan only (shift+tab to cycle)".
  The hint shows only until the box has held text in this process (the first-prompt argument does not count): after a typed prompt was sent, or after typed text was emptied, the empty box is a bare `>`.
  - **A hint too long for the terminal is cut, never wrapped**: the row is at most the width less 3 cells, ending `...` (three full stops). At 44 columns: `> Auto mode: edits & safe commands auto-...`; at 60: `> Auto mode: edits & safe commands auto-approved (shift+...` (probes `stage2/narrow-44`, `narrow-60`, 2026-11-25, no model turn).
- **Footer:** on the left "? for shortcuts" (empty box), nothing (text in the box), "esc to cancel" (working, or a menu showing), "  Press up to edit queued messages" (a message queued), "press ctrl+c again to exit" / "press ctrl+d again to exit"; on the right, right-aligned, "<mode> · <model> · <effort>" ("auto · <model> · high"); default mode leaves out the mode.
- **Echo of a prompt:** a rule of 60 cells, then `> <prompt>` in bold blue, wrapped rows indented two spaces. The reply follows indented two spaces. This is the trap of plan item 4: only the box's rules span the terminal.
- **Working:** a braille spinner and "Generating..." or "Loading..." (grey with a moving highlight) above the box; tool lines `● Ran (echo chosen) (ctrl+o to expand)`; thinking lines `▸ Thought for 3s, 150 tokens`.
- **A queued message:** `▸ queued words (alt+m to send immediately)` above the box.
- **Question menu** (the question also printed above it as `? <question>`):
```
Question
────────────────────────────────────────── (full width)
Question 1/1: <question, wrapped>
> 1. yes
  2. no
  3. Write-in...
  ↑/↓ Navigate · enter Select · esc Skip
esc to cancel                                         auto · <model> · high
```
  After Enter the transcript shows `> yes` (bold blue) under the question.
- **Permission menu** (a `● Ran (echo chosen) (ctrl+o to expand)` line above it):
```
Command
────────────────────────────────────────── (full width)
Requesting permission for:
   echo chosen
Run this command?
> 1. Yes, run command
  2. Yes, and always allow in this conversation for commands that start with 'echo'
  3. Yes, and always allow for commands that start with 'echo' (Persist to settings.json)
  4. No, cancel
  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
esc to cancel                                                <model> · high
```
- **Trust dialog** (a folder not trusted): "Accessing workspace:", the folder, "Do you trust the contents of this project?", "Antigravity CLI requires permission to read, edit, and execute files here.", "> Yes, I trust this folder", "  No, exit", "  ↑/↓ Navigate · enter Confirm".
- **At exit:** `ESC[>4m ESC[<1u CR LF LF ESC[J ESC[?2004l ESC[0 q`, the `idle` report, then "Resume with -c (or command below):" and "agy --conversation=<id>" when a conversation exists. Exit status 0.
- **At start** agy writes `ESC[?2026$p ESC[?2027$p ESC]11;?BEL ESC]7501;?BEL`, switches to the alternate screen for sign-in, and sets bracketed paste, `ESC[>4;2m` and the kitty keyboard flags `ESC[>5u`.

### Keys

- **Return** submits; a bracketed paste lands in the box as typed, its newline kept (`run7`).
- **Escape** while working interrupts (60 ms to `idle`). With text in an idle box, **Escape twice empties it when the presses are less than about 0.3 s apart**: 0.16 s and 0.27 s apart emptied it; 0.33, 0.39, 0.7 and 1.2 s apart did not. One Escape does nothing to the text.
- **Control-C** with no turn: the first arms "press ctrl+c again to exit" and leaves the text; still armed 4 s later and after a paste; the second exits, typed text and all (`run7`). With a turn running it interrupts (plan, decision 5). Not probed again: the plan forbids sending it.
- **Control-D** on an empty box: the first shows "press ctrl+d again to exit", the second exits. With text in the box it does nothing.
- **Shift+Tab** cycles default → accept-edits → auto → plan, changing the hint and the footer.
- **Control-U** empties the line before the cursor. Typing `y` on the permission menu did nothing (`run3`); digits on the menus were not tried.
- A message sent while working is queued and does not interrupt; Escape gives it back into the box.

### Under the app (agy 1.5.17, 2026-11-25, Clawddy's real-CLI harness run)

Seen with the real `agy` launched by Clawddy (stage 5 of the plan; 13 model turns). Launches after the first carried `--settings '{"trustedWorkspaces":[…the harness folder…]}'` from a wrapper of the harness's own, so the trust dialog's "Yes" (which adds the folder to the owner's `trustedWorkspaces`; docs: "The CLI adds entries for you") was never chosen.
- **A first prompt runs behind the trust dialog.** Launched with `--prompt-interactive=<text>` in a folder nobody trusted, agy showed the trust dialog (`blocked kind=permission` "Trust this folder?") and ran the prompt's turn anyway while the dialog stayed on screen: SessionStart, PreInvocation (invocation 0, the prompt), Stop (the reply) all arrived within 8 s, and the conversation's `.db` was written. Declining the dialog then ended agy; Clawddy recorded the agent as stopped with no exit status (its launch script's exit report did not arrive). Declined with no prompt, in a terminal of the probe's own, agy exited with status 0.
- **Behind the dialog, with the hook logger** (probe `stage5/trustprompt`, one turn): `blocked kind=auth`,
  `blocked kind=permission` "Trust this folder?" at 0.16 s, then SessionStart, PreInvocation 0, PostInvocation and
  Stop by 5.1 s, **no `working` and no `done`**. "No, exit": `idle`, then exit status 0, the bytes
  `ESC[>4m ESC[<1u CR ESC[<rows>d ESC[?1049l ESC[?25h ESC[?2004l` and the `idle` report (`stage5/decline2.bin`; no exit
  screen, no resume line). Under Clawddy the launch script's exit report after it was once not read: Ghostty
  delivers the process's exit (its process watcher) without waiting for its reader to finish the terminal's last
  bytes.
- **The wake-up's last transcript step** (probe `stage5/wake2`, one turn): the turn's Stop at 22.4 s, then 2.8 s
  later PreInvocation 0 with `lastUserInput` the turn's prompt while the transcript's last step was the turn's
  `PLANNER_RESPONSE` (`initialNumSteps` 4); the terminal stayed `working` until one `done`. Every PreInvocation 0
  of a prompt the person sent had `USER_INPUT` last (stage 1: a launch's first prompt, typed prompts, a resumed
  conversation).
- **Auto mode approves more than `echo`.** With no start-mode flag and the owner's default mode (auto), "Run the shell command: echo chosen" and "…: rm -f no-such-file.txt" both ran without asking. After Shift+Tab twice (auto → plan → default) `echo chosen` asked: `blocked kind=permission` "Approve Bash: echo chosen", menu as under "Screens".
- **A long command runs in the background and wakes the agent later.** "Run the shell command: sleep 20, then reply…" ran `sleep 20` in the background ("Command duration exceeds the synchronous execution window…", "Waiting for sleep 20 to finish."), and the turn ended with a Stop. A message queued meanwhile then ran as its own turn (PreInvocation 0 with its words, Stop with its reply). When the command ended, agy woke itself: a `SYSTEM_MESSAGE` step in the transcript, then **PreInvocation with `invocationNum` 0 and `lastUserInput` still the previous prompt**, then Stop with the new reply. Nothing in that record but the transcript's last step tells it from a prompt.
- **Signed out** (probe `stage6/signedout`, a throwaway `HOME`, no model turn): `blocked kind=auth` "Sign in required"
  at 0.15 s and no other report; the screen "Welcome to the Antigravity CLI. You are currently not signed in.",
  "Select login method:", "> 1. Google OAuth", "  2. Use a Google Cloud project". Nothing opens a browser until a
  method is chosen (a stub `open` first on the `PATH` was never called). agy makes its data folder under that `HOME`.
- **A failure before any model call** (proxy variables naming a closed port, under the app): the tile worked from the
  send, and agy's `error` "failed to construct executor: plan model not specified; you must specify a valid model"
  came (in the stage 1 probe of the same failure, 10 ms after Return with no `working` before it); the screen
  "⚠ <that text>" and "Error ID: …", and **no hook record** (a prompt typed in the terminal is then in no record).
  The process keeps its environment: the next prompt in it fails the same way.
- **A network failure during a turn** (probe `stage6/midturn2`, a local proxy killed 4 s into a turn, one turn):
  agy stays `working` and retries, the spinner line "Model unavailable (attempt N/9), retrying in Ns..." (attempt 2 at
  +5 s, 4 at +25 s); at +148 s a **Stop record** with `terminationReason` "ERROR", `fullyIdle` true, no reply, and
  `error` "generating and executing: request failed: Post \"https://…/v1internal:streamGenerateContent?alt=sse\":
  proxyconnect tcp: dial tcp 127.0.0.1:<port>: connect: connection refused"; 0.9 s later
  `ESC]7501;state=error:app=antigravity:msg=<base64 "There was a network issue connecting to the server, please try
  again.">BEL`, the screen "⚠ <that text>" and "Error ID: …". Escape: `idle`.
- **What the app does with an `error` report** (agy, and the same code for every CLI): the turn fails with the
  report's message as the problem's text, shown as the tile's sentence as agy wrote it and kept in the agent's record
  (`status/<agent>.record.json`, `problem.text`). The Stop record's `error` reaches the event file with only
  `[:alnum:]_.:/-` kept (spaces dropped) and changes nothing: agy's failures come from the terminal (ruling 3). A
  usage-limit message would arrive the same way and show as a problem with agy's own words (not as "paused", which
  only Claude's `rate_limit` kind gives); it is in the record and on screen when one comes. Not seen.
- **`done` and its Stop** (every captured pair with its transcript: 10 in stage 1, 2, 5, plus `stage6/donelink`): the
  `done` message is the reply's first line exactly as written (Markdown kept), cut to 199 characters and "…" when the
  line is longer than 200; the Stop record's reply (the transcript's last `PLANNER_RESPONSE` with content) begins
  with it. `stage6/donelink`: a 239-character first line with a link, bold and code came as its first 199 characters
  and "…", the reply's later lines (an empty one, one starting with two spaces) only in the Stop. 7 more captured
  `done`s have no transcript to compare (probes without hooks). No captured reply began with a blank line or spaces;
  that case is not seen. So an uncut line is the reply's whole first line (the reply equals it or goes on after a
  line break), and only a 200-character line ending in "…" is a beginning. Hook records keep their order, so a
  Stop that came before a turn's prompt record (or agy's own start) is an earlier turn's, even with the same first
  line. A Stop that does not open with its turn's `done` line is another turn's or an earlier step's:
  the wake-up's first Stop ("Waiting…", `stage5/wake2`) comes inside the turn whose `done` is the wake-up's reply.
- **Workspace folders, sorted** (the hook-place probes, 9 model turns, `redesign-notes/agy/stage6/hookplace.txt`): agy
  sorts its workspace folders by path, whatever the order of the launch folder and `--add-dir` (all 138 conversations
  in agy's `cache/conversation_metadata.json` list `WorkspaceURIs` sorted; the hook records' `workspacePaths` too),
  and the model takes the first as its folder and its "default command folder". Asked "List your workspace folders in
  the order you were given them and name your default command folder", it answered the sorted order and the first
  folder, with the hook folder sorting first (`…/s7-a-out/hookdir` before `…/s7-a-ws`) and last alike. Given
  "Read notes.txt and summarize it in one sentence.", 3 of 3 runs with the hook folder first read `notes.txt` there
  first (a failed read, then the project's); 0 of 3 with it last. agy keeps `/var/folders/…` as given (no
  `/private` added), so a folder there sorts after `/Users` and `/Volumes`; hooks load from it with no trust
  question. No other way loads hooks: `--settings` hooks are not loaded (docs), the global and plugin places are
  under `~/.gemini/config`, and no environment variable moves that folder (binary strings).
- **Several queued messages run together** (probe `stage5/queue2`, two turns): two messages typed while a turn
  ran waited for its `done`, then ran as one turn whose PreInvocation 0 had `lastUserInput` "Reply with the word
  one.\nReply with the word two." (joined by a newline), one Stop, one `done`.
- **A queued message reports nothing until it runs.** Sent while agy works, it shows as `▸ <text> (alt+m to send immediately)` and no hook runs for it; its PreInvocation comes only when agy starts it, as the next turn.
- **Resuming** (`--conversation <id>`, after Clawddy quit and reopened) redraws the conversation's earlier turns; the next prompt's records carry the same id.
- **Control-D twice** on an empty box ended agy with status 0; Clawddy recorded it finished, with no problem.

### Not seen

`done` without a msg; `terminationReason` other than "NO_TOOL_CALL"; a Stop record with `error` set; what Escape does on the question or permission menu; what agy reports after start-up when signed out; the usage limit.
