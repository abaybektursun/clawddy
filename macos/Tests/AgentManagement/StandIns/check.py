#!/usr/bin/env -S python3 -I
"""Drives the stand-in `claude`, `codex` and `agy` in pseudo-terminals and checks
what they show, report (OSC 7501) and run (hooks, notify).

usage: check.py [name ...]     run every check, or only those named

Each check gets its own temporary folder laid out like a harness folder:
bin/<cli> (a link to the stand-in), standin/<session-id>.json (its script),
work/ (the working folder), settings.json whose hooks append their stdin to
hooks.log, and a statusLine command that saves its input; for agy a hook folder
hookdir/.agents/hooks.json (passed with --add-dir $HOOKDIR) whose hooks append
their stdin to hooks.log and their working folder and conversation variable to
hookctx.log, and agy-data/ as its data folder. The terminal side
answers the OSC 7501 query as Ghostty does and encodes keys with the kitty
protocol once the program pushes it, as Ghostty does. A small screen model
replays the output so checks can read the screen as text.
"""
import fcntl
import json
import os
import pty
import re
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import traceback
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
REPLY = "\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth"
AGY_EVENTS = ["SessionStart", "PreInvocation", "PostInvocation", "Stop"]
EVENTS = ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd", "PreToolUse", "PostToolUse",
          "PermissionRequest", "Notification", "PreCompact", "PostCompact", "SubagentStop"]


class Screen:
    """Enough of a terminal to read back what the stand-in drew."""

    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[" "] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.wrap = False

    def resize(self, rows, cols):
        grid = [[" "] * cols for _ in range(rows)]
        for i in range(min(rows, self.rows)):
            for j in range(min(cols, self.cols)):
                grid[i][j] = self.grid[i + max(0, self.rows - rows)][j]
        self.grid, self.rows, self.cols = grid, rows, cols
        self.r, self.c = min(self.r, rows - 1), min(self.c, cols - 1)

    def lf(self):
        if self.r == self.rows - 1:
            self.grid.pop(0)
            self.grid.append([" "] * self.cols)
        else:
            self.r += 1

    def put(self, ch):
        w = 2 if unicodedata.east_asian_width(ch) in "WF" else 0 if unicodedata.combining(ch) else 1
        if w == 0:
            return
        if self.wrap or self.c + w > self.cols:
            self.c = 0
            self.lf()
            self.wrap = False
        self.grid[self.r][self.c] = ch
        if w == 2:
            self.grid[self.r][self.c + 1] = ""
        self.c += w
        if self.c >= self.cols:
            self.c = self.cols - 1
            self.wrap = True

    TOKEN = re.compile(r"\x1b\[([0-9;?<>=:]*)[ -/]*([@-~])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b.|[\x00-\x1f]|[^\x00-\x1f\x1b]+")

    def feed(self, text):
        for m in self.TOKEN.finditer(text):
            t = m.group(0)
            if m.group(2):
                p, f = m.group(1), m.group(2)
                n = int(p) if p.isdigit() else 1
                self.wrap = False if f in "ABCDHJ" else self.wrap
                if f == "A":
                    self.r = max(0, self.r - n)
                elif f == "B":
                    self.r = min(self.rows - 1, self.r + n)
                elif f == "C":
                    self.c = min(self.cols - 1, self.c + n)
                elif f == "D":
                    self.c = max(0, self.c - n)
                elif f == "H":
                    parts = (p.split(";") + ["1", "1"])[:2]
                    self.r, self.c = int(parts[0] or 1) - 1, int(parts[1] or 1) - 1
                elif f == "J":
                    if p in ("", "0"):
                        self.grid[self.r][self.c:] = [" "] * (self.cols - self.c)
                        for i in range(self.r + 1, self.rows):
                            self.grid[i] = [" "] * self.cols
                    elif p == "2":
                        self.grid = [[" "] * self.cols for _ in range(self.rows)]
                elif f == "K":
                    self.grid[self.r][self.c:] = [" "] * (self.cols - self.c)
            elif t.startswith("\x1b"):
                continue
            elif t == "\r":
                self.c, self.wrap = 0, False
            elif t == "\n":
                self.lf()
            elif t == "\b":
                self.c = max(0, self.c - 1)
            elif t[0] >= " ":
                for ch in t:
                    self.put(ch)

    def text(self):
        return ["".join(row).rstrip() for row in self.grid]


class Run:
    def __init__(self, tmp, cli, args, script=None, sid=None, rows=40, cols=100):
        self.tmp, self.cli = tmp, cli
        for d in ("bin", "standin", "work"):
            os.makedirs(os.path.join(tmp, d), exist_ok=True)
        exe = os.path.join(tmp, "bin", cli)
        if not os.path.exists(exe):
            os.symlink(os.path.join(HERE, "agy" if cli == "agy" else "claude"), exe)
        if script is not None:
            with open(os.path.join(tmp, "standin", sid + ".json"), "w") as f:
                json.dump(script, f)
        self.log = os.path.join(tmp, "hooks.log")
        self.notify_log = os.path.join(tmp, "notify.log")
        self.status_log = os.path.join(tmp, "status.json")
        self.settings = os.path.join(tmp, "settings.json")
        q = shlex.quote
        hook = f"cat >> {q(self.log)}; echo >> {q(self.log)}"
        with open(self.settings, "w") as f:
            json.dump({"hooks": {e: [{"hooks": [{"type": "command", "command": hook, "timeout": 5}]}] for e in EVENTS},
                       "statusLine": {"type": "command", "command": f"cat > {q(self.status_log)}; echo 'main · 2 checks'"}}, f)
        self.hookdir = os.path.join(tmp, "hookdir")
        self.data = os.path.join(tmp, "agy-data")
        self.ctx_log = os.path.join(tmp, "hookctx.log")
        os.makedirs(os.path.join(self.hookdir, ".agents"), exist_ok=True)
        ctx = f'{hook}; printf "%s %s\\n" "$(pwd)" "$ANTIGRAVITY_CONVERSATION_ID" >> {q(self.ctx_log)}'
        with open(os.path.join(self.hookdir, ".agents", "hooks.json"), "w") as f:
            json.dump({"check": {e: [{"type": "command", "command": ctx, "timeout": 5}] for e in AGY_EVENTS}}, f)
        self.rows, self.cols = rows, cols
        self.chunks = []      # output bytes, and ("resize", rows, cols) markers
        self.raw = b""
        self.kitty = [0]
        self.status = None
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("CLAUDE", "CODEX", "GHOSTTY", "CLAWDDY", "AGY", "ANTIGRAVITY"))}
        env.update(TERM="xterm-ghostty", TERM_PROGRAM="ghostty", COLORTERM="truecolor", AGY_STANDIN_DATA_DIR=self.data)
        argv = [exe] + [a.replace("$SETTINGS", self.settings).replace("$NOTIFY", self.notify_log)
                        .replace("$HOOKDIR", self.hookdir) for a in args]
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(os.path.join(tmp, "work"))
            os.execve(exe, argv, env)
        self.set_size(rows, cols)
        self.t0 = time.monotonic()

    def set_size(self, rows, cols):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, cols * 8, rows * 16))

    def pump(self, seconds=0.05):
        end = time.monotonic() + seconds
        while True:
            left = end - time.monotonic()
            if left <= 0 or self.status is not None:
                return
            r, _, _ = select.select([self.fd], [], [], left)
            if not r:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                data = b""
            if not data:
                self.reap(2)
                return
            self.raw += data
            self.chunks.append(data)
            for m in re.finditer(rb"\x1b\]7501;\?(\x07|\x1b\\)", data):
                os.write(self.fd, REPLY.encode() + m.group(1))
            for m in re.finditer(rb"\x1b\[([<>])(\d*)u", data):
                if m.group(1) == b">":
                    self.kitty.append(int(m.group(2) or 0))
                elif len(self.kitty) > 1:
                    self.kitty.pop()

    def reap(self, timeout):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            pid, st = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = st
                return st
            time.sleep(0.02)
        return None

    def wait(self, what, pred, timeout=8):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            got = pred()
            if got:
                return got
            if self.status is not None:
                break
            self.pump(0.05)
        raise AssertionError(f"{what}: not seen within {timeout}s\n--- screen ---\n" + "\n".join(self.screen()[-18:]))

    def send(self, data):
        os.write(self.fd, data.encode() if isinstance(data, str) else data)
        self.pump(0.02)

    KEYS = {"enter": "\r", "esc": "\x1b", "ctrl-c": "\x03", "ctrl-d": "\x04", "down": "\x1b[B", "up": "\x1b[A",
            "backspace": "\x7f", "ctrl-u": "\x15", "shift-tab": "\x1b[Z"}
    KITTY = {"esc": "\x1b[27u", "ctrl-c": "\x1b[99;5u", "ctrl-d": "\x1b[100;5u", "ctrl-u": "\x1b[117;5u",
             "shift-tab": "\x1b[9;2u"}

    def key(self, name):
        self.send(self.KITTY[name] if self.kitty[-1] & 1 and name in self.KITTY else self.KEYS[name])

    def type(self, text):
        for ch in text:
            self.send(ch)

    def paste(self, text):
        self.send("\x1b[200~" + text + "\x1b[201~")

    def resize(self, rows, cols):
        self.chunks.append(("resize", rows, cols))
        self.mark = len(self.raw)
        self.set_size(rows, cols)

    def screen(self):
        s = Screen(self.rows, self.cols)
        data = b""
        for ch in self.chunks + [("resize", None, None)]:
            if isinstance(ch, tuple):
                s.feed(data.decode("utf-8", "replace"))
                data = b""
                if ch[1]:
                    s.resize(ch[1], ch[2])
            else:
                data += ch
        return s.text()

    def screen_has(self, needle):
        return lambda: any(needle in row for row in self.screen())

    def reports(self):
        """Every OSC 7501 the program sent: (fields, terminator), the query as {"?": True}."""
        out = []
        for m in re.finditer(rb"\x1b\]7501;([^\x07\x1b]*)(\x07|\x1b\\)", self.raw):
            body = m.group(1).decode()
            if body.startswith("?"):
                out.append(({"?": True}, m.group(2)))
                continue
            fields = dict(kv.split("=", 1) for kv in body.split(":"))
            if "msg" in fields:
                import base64
                fields["msg"] = base64.b64decode(fields["msg"]).decode()
            out.append((fields, m.group(2)))
        return out

    def states(self):
        return [f.get("state", "?") for f, _ in self.reports()]

    def hooks(self, event=None):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            items = [json.loads(line) for line in f if line.strip()]
        return [h for h in items if event is None or h.get("hook_event_name", h.get("hookEventName")) == event]

    def hook(self, event, pred=lambda h: True):
        return lambda: next((h for h in self.hooks(event) if pred(h)), None)

    def notes(self):
        if not os.path.exists(self.notify_log):
            return []
        with open(self.notify_log) as f:
            return [json.loads(line) for line in f if line.strip()]

    def close(self):
        # Close our side first: a dying child blocks on output nobody reads.
        if self.status is None:
            os.kill(self.pid, signal.SIGKILL)
        os.close(self.fd)
        if self.status is None:
            os.waitpid(self.pid, 0)


def expect(cond, what):
    if not cond:
        raise AssertionError(what)


def ordered(seq, wanted):
    """Whether `wanted` appears in `seq` in this order (other items may sit between)."""
    it = iter(seq)
    return all(any(x == w for x in it) for w in wanted)


CLAUDE = ["--session-id", "S1", "--settings", "$SETTINGS", "--dangerously-skip-permissions"]

# ---- the checks ----


def check_first_prompt_and_typed_turn(tmp):
    """The first-prompt argument and a typed prompt each run a turn: hooks, reports, screen."""
    run = Run(tmp, "claude", CLAUDE + ["--name", "Fix login", "--unknown-flag", "the first prompt"])
    try:
        ups = run.wait("UserPromptSubmit of the first prompt", run.hook("UserPromptSubmit", lambda h: h["prompt"] == "the first prompt"))
        expect(ups["session_id"] == "S1" and ups["permission_mode"] == "bypassPermissions", f"UserPromptSubmit fields: {ups}")
        stop = run.wait("Stop of the first prompt", run.hook("Stop", lambda h: "the first prompt" in h["last_assistant_message"]))
        run.wait("the summary done", lambda: any(f.get("msg") for f, _ in run.reports() if f.get("state") == "done"))
        run.type("fix the login bug")
        run.wait("typed text in the line", run.screen_has("❯\u00a0fix the login bug"))
        run.key("enter")
        run.wait("UserPromptSubmit of the typed prompt", run.hook("UserPromptSubmit", lambda h: h["prompt"] == "fix the login bug"))
        run.wait("the prompt in the transcript", run.screen_has("❯ fix the login bug"))
        run.wait("a tool line", run.screen_has("⏺ Search("))
        stop2 = run.wait("Stop of the typed prompt", run.hook("Stop", lambda h: "fix the login bug" in h["last_assistant_message"]))
        run.pump(0.3)
        starts = run.hooks("SessionStart")
        expect(starts and starts[0]["source"] == "startup" and starts[0]["session_id"] == "S1", f"SessionStart: {starts}")
        expect(len(run.hooks("PreToolUse")) >= 8 and len(run.hooks("PostToolUse")) >= 8, "PreToolUse/PostToolUse per tool line")
        expect(stop["prompt_id"] != stop2["prompt_id"] and stop2["stop_hook_active"] is False, "Stop fields")
        reps = run.reports()
        expect(all(t == b"\x07" for _, t in reps), "every claude 7501 ends with BEL")
        expect(all(f.get("app") == "claude-code" for f, _ in reps if "state" in f), "app=claude-code")
        st = run.states()
        expect(st[0] == "?", f"the query comes first: {st}")
        # A new session given a first prompt reports `working` first, as the real one does.
        expect(ordered(st, ["?", "working", "done", "done", "working", "done"]) and "idle" not in st[:2],
               f"report order: {st}")
        expect(os.path.exists(run.status_log), "the statusLine command ran")
        run.wait("the status line under the box", run.screen_has("main · 2 checks"))
        expect(json.load(open(run.status_log))["session_id"] == "S1", "status line payload")
        return f"7501 order {' → '.join(st)}; hooks {len(run.hooks())}"
    finally:
        run.close()


def check_paste(tmp):
    """Bracketed paste of several lines, then a separate Return, submits one message."""
    run = Run(tmp, "claude", CLAUDE)
    try:
        run.wait("idle", lambda: "idle" in run.states())
        run.paste("line one\nline two\r\nline three")
        run.pump(0.4)
        expect(not run.hooks("UserPromptSubmit"), "a paste alone does not submit")
        run.wait("pasted lines in the line", lambda: run.screen_has("❯\u00a0line one")() and run.screen_has("  line three")())
        run.key("enter")
        h = run.wait("one UserPromptSubmit", run.hook("UserPromptSubmit"))
        expect(h["prompt"] == "line one\nline two\nline three", f"pasted prompt: {h['prompt']!r}")
        run.pump(0.5)
        expect(len(run.hooks("UserPromptSubmit")) == 1, "exactly one message")
        return "3 pasted lines → 1 prompt"
    finally:
        run.close()


def check_queue(tmp):
    """A prompt sent while working is submitted at once and joins the running turn: one Stop for both."""
    run = Run(tmp, "claude", CLAUDE)
    try:
        run.wait("idle", lambda: "idle" in run.states())
        run.type("first task")
        run.key("enter")
        run.wait("working", lambda: "working" in run.states())
        run.pump(0.2)
        run.type("second task")
        run.key("enter")
        run.wait("queued line", run.screen_has("Queued · ctrl+enter to send now"))
        run.wait("the queued hint in the line", run.screen_has("Press up to edit queued messages"))
        ups = run.hooks("UserPromptSubmit")
        expect(len(ups) == 2 and ups[1]["prompt"] == "second task" and ups[1]["prompt_id"] == ups[0]["prompt_id"],
               f"the queued prompt is submitted at once, in the running turn: {ups}")
        stop = run.wait("Stop", run.hook("Stop"), timeout=10)
        expect("second task" in stop["last_assistant_message"], f"the turn answers the latest prompt: {stop}")
        run.wait("the queued prompt in the transcript", run.screen_has("❯ second task"))
        run.pump(1.0)
        expect(len(run.hooks("Stop")) == 1, "one Stop for the folded turn")
        return "queued prompt submitted at once, folded into the running turn, one Stop"
    finally:
        run.close()


def check_escape(tmp):
    """Escape while working: idle, no Stop; the prompt comes back only if the turn showed nothing yet."""
    run = Run(tmp, "claude", CLAUDE)
    try:
        run.wait("idle", lambda: "idle" in run.states())
        run.type("interrupt me")
        run.key("enter")
        run.wait("working", lambda: "working" in run.states())
        run.pump(0.1)
        run.key("esc")
        run.wait("idle after working", lambda: run.states()[-1] == "idle")
        run.wait("the prompt back in the line", run.screen_has("❯\u00a0interrupt me"))
        expect(not run.screen_has("❯ interrupt me")(), "the given-back prompt left the transcript")
        run.key("enter")
        run.wait("the restored prompt submits", lambda: len(run.hooks("UserPromptSubmit")) == 2)
        expect(run.hooks("UserPromptSubmit")[1]["prompt"] == "interrupt me", "restored prompt text")
        run.wait("a tool line", run.screen_has("⏺ Search("))
        run.key("esc")
        run.wait("idle again", lambda: run.states()[-1] == "idle")
        run.wait("the interrupt line", run.screen_has("Interrupted · What should Claude do instead?"))
        run.pump(1.0)
        expect(not run.screen_has("❯\u00a0interrupt me")(), "a turn that showed work gives nothing back")
        expect(not run.hooks("Stop"), "no Stop for an interrupted turn")
        # Clearing an idle line: Escape twice, or Ctrl-C (which arms the exit).
        run.type("left by hand")
        run.key("esc")
        run.pump(0.2)
        expect(run.screen_has("❯\u00a0left by hand")(), "one Escape keeps the text")
        run.key("esc")
        run.wait("two Escapes clear the line", lambda: not run.screen_has("left by hand")())
        run.type("again")
        run.key("ctrl-c")
        run.wait("Ctrl-C clears and arms the exit", run.screen_has("Press Ctrl-C again to exit"))
        expect(not run.screen_has("❯\u00a0again")() and run.status is None, "cleared, still running")
        return "early Esc gives the prompt back, late Esc does not; Esc Esc and Ctrl-C clear the line"
    finally:
        run.close()


def check_question(tmp):
    """A scripted question reports blocked and waits for the answer."""
    script = {"steps": [{"working": "Checking the alarm sound"}, {"wait": 0.3},
                        {"ask": "Pick one?", "options": ["Alpha", "Beta"], "header": "Choice"},
                        {"print": ["⏺ Bash(make)", "⎿ built"]}, {"finish": "Went with Beta."}]}
    run = Run(tmp, "claude", ["--resume", "SQ", "--settings", "$SETTINGS"], script=script, sid="SQ")
    try:
        blocked = run.wait("blocked report", lambda: next((f for f, _ in run.reports() if f.get("state") == "blocked"), None))
        expect(blocked.get("kind") == "question" and blocked.get("msg") == "answer: Pick one? (Alpha · Beta)", f"blocked: {blocked}")
        run.wait("PermissionRequest", run.hook("PermissionRequest", lambda h: h["tool_name"] == "AskUserQuestion"))
        run.wait("the menu", run.screen_has("❯ 1. Alpha"))
        n = len(run.reports())
        run.pump(1.5)
        expect(len(run.reports()) == n and not run.hooks("Stop"), "it waits for the answer")
        run.key("down")
        run.wait("selection moves", run.screen_has("❯ 2. Beta"))
        run.key("enter")
        post = run.wait("PostToolUse with the answer", run.hook("PostToolUse", lambda h: h["tool_name"] == "AskUserQuestion"))
        expect(post["tool_input"]["answers"] == {"Pick one?": "Beta"}, f"answers: {post['tool_input']}")
        run.wait("Stop", run.hook("Stop", lambda h: h["last_assistant_message"] == "Went with Beta."))
        expect(run.hooks("SessionStart")[0]["source"] == "resume", "resume source")
        expect(ordered(run.states(), ["blocked", "working", "done"]), f"states: {run.states()}")
        return "blocked kind=question, answered Beta, then done"
    finally:
        run.close()


def check_failures(tmp):
    """Scripted failures: login expired is blocked kind=auth, usage limit is error with the reset time."""
    run = Run(os.path.join(tmp, "a"), "claude", CLAUDE, script={"steps": [{"working": "x"}, {"fail": "login"}]}, sid="S1")
    try:
        auth = run.wait("blocked auth", lambda: next((f for f, _ in run.reports() if f.get("kind") == "auth"), None))
        expect("/login" in auth.get("msg", ""), f"auth msg: {auth}")
        run.wait("StopFailure", run.hook("StopFailure", lambda h: h["error"] == "authentication_failed"))
        run.wait("the error on screen", run.screen_has("Please run /login"))
        run.type("/login")
        run.key("enter")
        run.wait("idle after /login", lambda: run.states()[-1] == "idle")
    finally:
        run.close()
    run = Run(os.path.join(tmp, "b"), "claude", CLAUDE,
              script={"steps": [{"working": "x"}, {"fail": "usage", "resets": "3pm (Europe/Berlin)"}]}, sid="S1")
    try:
        err = run.wait("error report", lambda: next((f for f, _ in run.reports() if f.get("state") == "error"), None))
        expect("3pm (Europe/Berlin)" in err.get("msg", ""), f"error msg: {err}")
        fail = run.wait("StopFailure", run.hook("StopFailure"))
        expect(fail["error"] == "rate_limit" and "3pm" in fail["last_assistant_message"], f"StopFailure: {fail}")
        expect(not run.hooks("Stop"), "no Stop in a failed turn")
        return "login → blocked kind=auth, /login → idle; usage → error with reset time"
    finally:
        run.close()


def check_resize(tmp):
    """A resize clears and redraws everything at the new size."""
    script = {"screen": ["> earlier question", "⏺ Read(Sources/App.swift)", "⎿ Read 12 lines", "⏺ An earlier answer."]}
    run = Run(tmp, "claude", CLAUDE, script=script, sid="S1", rows=40, cols=100)
    try:
        run.wait("idle", lambda: "idle" in run.states())
        run.wait("rule at 100", lambda: any(r.startswith("─") and len(r) == 100 for r in run.screen()))
        run.resize(24, 70)
        run.wait("a full redraw", lambda: b"\x1b[2J" in run.raw[run.mark:])
        run.pump(0.3)
        rows = run.screen()
        expect(any(r.startswith("─") and len(r) == 70 for r in rows), "rule at 70 columns")
        expect(any("An earlier answer." in r for r in rows) and any("⎿ \u00a0Read 12 lines" in r for r in rows), "transcript redrawn")
        expect("bypass permissions" in [r for r in rows if r][-1], "the footer is the last line drawn")
        run.type("after resize")
        run.wait("typing still lands", run.screen_has("❯\u00a0after resize"))
        return "100×40 → 70×24, transcript and box redrawn"
    finally:
        run.close()


def check_sigterm(tmp):
    """SIGTERM ends the session (SessionEnd other) and restores the terminal."""
    run = Run(tmp, "claude", CLAUDE)
    try:
        run.wait("idle", lambda: "idle" in run.states())
        raw_mode = termios.tcgetattr(run.fd)[3]
        expect(not raw_mode & termios.ICANON, "raw mode while running")
        os.kill(run.pid, signal.SIGTERM)
        run.wait("exit", lambda: run.status is not None, timeout=5)
        lflag = termios.tcgetattr(run.fd)[3]
        expect(lflag & termios.ICANON and lflag & termios.ECHO, "terminal back in cooked mode")
        expect(os.WEXITSTATUS(run.status) == 143, f"exit status {os.WEXITSTATUS(run.status)}")
        expect(run.raw.endswith(b"\x1b[?25h\x1b[?2004l\x1b[<u") or b"\x1b[?25h\x1b[?2004l\x1b[<u" in run.raw[-200:],
               "cursor shown, paste mode and kitty flags popped")
        expect(run.states()[-3:] == ["clear"] * 3, f"clear reports: {run.states()}")
        end = run.wait("SessionEnd", run.hook("SessionEnd"))
        expect(end["reason"] == "other", f"SessionEnd: {end}")
    finally:
        run.close()
    # A closed terminal: the kernel hangs up the session (SIGHUP) and writes fail.
    run = Run(os.path.join(tmp, "hup"), "claude", CLAUDE)
    try:
        run.wait("idle", lambda: "idle" in run.states())
        os.close(run.fd)
        _, st = os.waitpid(run.pid, 0)
        run.status, run.fd = st, os.open("/dev/null", os.O_RDONLY)
        expect(os.WIFEXITED(st) and os.WEXITSTATUS(st) == 129, f"hang-up exit {st}")
        end = run.wait("SessionEnd after hang-up", run.hook("SessionEnd"))
        expect(end["reason"] == "other", f"SessionEnd: {end}")
        return "SIGTERM: exit 143, cooked mode, SessionEnd other; hang-up: exit 129, SessionEnd other"
    finally:
        run.close()


def check_exits(tmp):
    """Ctrl-C twice, Ctrl-D and /exit each end the program."""
    out = []
    for name, keys in (("ctrl-c twice", ["ctrl-c", "ctrl-c"]), ("ctrl-d", ["ctrl-d"]), ("/exit", None)):
        run = Run(os.path.join(tmp, name.replace("/", "")), "claude", CLAUDE)
        try:
            run.wait("idle", lambda: "idle" in run.states())
            if keys:
                run.key(keys[0])
                if len(keys) > 1:
                    run.wait("the hint", run.screen_has("Press Ctrl-C again to exit"))
                    expect(run.status is None, "one Ctrl-C does not exit")
                    run.key(keys[1])
            else:
                run.type("/exit")
                run.key("enter")
            run.wait("exit", lambda: run.status is not None, timeout=5)
            expect(os.WEXITSTATUS(run.status) == 0, f"{name}: exit {run.status}")
            end = run.wait("SessionEnd", run.hook("SessionEnd"))
            expect(end["reason"] == "prompt_input_exit", f"{name}: {end}")
            if not keys:
                expect(run.states()[-3:] == ["working", "clear", "clear"], f"/exit reports: {run.states()}")
            out.append(name)
        finally:
            run.close()
    return ", ".join(out) + " exit 0"


def check_opening_screen(tmp):
    """A script's opening screen is on screen at start, and a scripted working turn finishes."""
    script = {"title": "Wind barbs drawn in knots", "folder": "~/projects/tidepool", "plus": 38, "minus": 9,
              "screen": ["> wind barbs ignore the units setting", "⏺ Grep(\"wind\", Sources/)", "⎿ 4 files"],
              "steps": [{"working": "Testing the unit switch", "elapsed": 130}, {"print": ["⏺ Bash(swift test)", "⎿ 7 passed"], "rate": 10},
                        {"wait": 0.5}, {"finish": "Wind barbs now follow the units setting.", "summary": "barbs follow units"},
                        {"wait": "prompt"}, {"fail": "error", "text": "API Error: 500 overloaded"}]}
    run = Run(tmp, "claude", ["--resume", "SW", "--settings", "$SETTINGS"], script=script, sid="SW")
    try:
        run.wait("opening lines", run.screen_has("⏺ Grep(\"wind\", Sources/)"))
        run.wait("folder in the header", run.screen_has("~/projects/tidepool"))
        run.wait("spinner with elapsed time", lambda: any("Testing the unit switch…" in r and "2m 1" in r for r in run.screen()))
        stop = run.wait("Stop", run.hook("Stop"))
        expect(stop["last_assistant_message"] == "Wind barbs now follow the units setting.", f"Stop: {stop}")
        run.wait("the given summary", lambda: any(f.get("msg") == "barbs follow units" for f, _ in run.reports()))
        expect(not run.hooks("UserPromptSubmit"), "a scripted turn has no prompt")
        run.type("try again")
        run.key("enter")
        run.wait("the scripted failure after the prompt", run.hook("StopFailure", lambda h: h["error"] == "server_error"))
        expect(run.states()[-1] == "error", f"states {run.states()}")
        return "opening screen, scripted turn, wait for prompt, scripted error"
    finally:
        run.close()


def check_codex(tmp):
    """codex: its own look, ESC-backslash reports, notify JSON, resume script, queue and Escape."""
    notify = '["/bin/sh", "-c", "printf \'%s\\\\n\' \\"$1\\" >> \'$NOTIFY\'", "sh"]'
    script = {"screen": ["> an earlier codex prompt", "⏺ Bash(cargo build)", "⎿ Finished dev profile"]}
    run = Run(tmp, "codex", ["--dangerously-bypass-approvals-and-sandbox", "-c", "notify=" + notify,
                             "-c", 'model_reasoning_effort="high"', "--no-daemon", "resume", "C1", "codex first prompt"],
              script=script, sid="C1")
    try:
        run.wait("the codex header", run.screen_has("OpenAI Codex"))
        run.wait("the resumed transcript", run.screen_has("› an earlier codex prompt"))
        own = lambda: [n for n in run.notes() if n["thread-id"] == "C1"]
        note = run.wait("notify after the first prompt", lambda: own()[0] if own() else None)
        expect(note["type"] == "agent-turn-complete" and note["client"] == "codex-tui", f"notify: {note}")
        expect(note["input-messages"] == ["codex first prompt"] and "codex first prompt" in note["last-assistant-message"], f"notify: {note}")
        title = [n for n in run.notes() if n["thread-id"] != "C1"]
        expect(len(title) == 1 and title[0]["input-messages"][0].startswith("Generate a concise"), f"title notify: {title}")
        reps = run.reports()
        expect(all(t == b"\x1b\\" for _, t in reps), "every codex 7501 ends with ESC \\")
        expect(not any(f.get("?") for f, _ in reps), "codex never queries")
        st = run.states()
        # Resumed with a prompt, codex works at once.
        expect(ordered(st, ["working", "done"]) and st[0] == "working", f"codex states {st}")
        run.wait("the codex result line", run.screen_has("  └ test result: ok."))
        run.type("second codex task")
        run.key("enter")
        run.wait("working", lambda: run.states()[-1] == "working")
        run.pump(0.3)
        run.type("third")
        run.key("enter")
        run.wait("queued", run.screen_has("↳ third"))
        run.wait("the queue's header", run.screen_has("Messages to be submitted after next tool call"))
        run.key("esc")
        run.wait("the interrupt line", run.screen_has("■ Conversation interrupted - use /feedback if something went wrong"))
        run.wait("Esc sends the queued prompt at once", run.screen_has("› third"))
        composer = [r for r in run.screen() if r.startswith("› ")][-1]
        expect("second codex task" not in composer, f"codex gives no prompt back: {composer!r}")
        run.wait("working on it", lambda: run.states()[-1] == "working")
        run.key("ctrl-c")
        run.wait("idle after Ctrl-C", lambda: run.states()[-1] == "idle")
        run.pump(0.3)
        expect(len(own()) == 1, "no notify for an interrupted turn")
        run.type("typed")
        run.key("esc")
        run.pump(0.2)
        expect(run.screen_has("› typed")(), "Escape leaves codex's composer alone")
        run.key("ctrl-c")
        run.wait("Ctrl-C empties the composer", run.screen_has("Ask Codex to do anything"))
        run.type("/quit")
        run.key("enter")
        run.wait("exit", lambda: run.status is not None, timeout=5)
        expect(run.states()[-1] == "clear", f"/quit clears: {run.states()}")
        expect(b"codex resume C1" in run.raw, "the resume hint")
        return f"7501 {' → '.join(run.states())}; notify ok"
    finally:
        run.close()


def check_codex_failure(tmp):
    """codex: a scripted usage limit reports error (no msg, as observed)."""
    run = Run(tmp, "codex", ["fork", "C2"], script={"steps": [{"wait": "prompt"}, {"fail": "usage", "resets": "3:00 PM"}]}, sid="C2")
    try:
        run.wait("idle", lambda: "idle" in run.states())
        run.type("go")
        run.key("enter")
        run.wait("error", lambda: run.states()[-1] == "error")
        run.wait("the message", run.screen_has("Try again at 3:00 PM."))
        return "error reported, message on screen"
    finally:
        run.close()


def check_prototype_scene(tmp):
    """The prototype's agents: well formed, and each kind of state comes up as the scene says."""
    with open(os.path.join(HERE, "..", "Scenes", "prototype.json")) as f:
        agents = [agent for project in json.load(f)["projects"] for agent in project["agents"]]
    expect(len({a["session"] for a in agents}) == len(agents), "unique session ids")
    verbs = {"print", "working", "finish", "ask", "fail", "wait"}
    for a in agents:
        expect(all(len(set(st) & verbs) == 1 for st in a["standin"]["steps"]), f"steps of {a['name']}")
    wanted = {"asks": ("blocked", "question"), "failed": ("blocked", "auth"), "paused": ("error", None),
              "working": ("working", None), "finished": ("idle", None)}
    seen = []
    for state, (report, kind) in wanted.items():
        a = next(a for a in agents if a["state"] == state and not a["settled"])
        run = Run(os.path.join(tmp, state), "claude", ["--resume", a["session"], "--settings", "$SETTINGS",
                                                       "--dangerously-skip-permissions"],
                  script=a["standin"], sid=a["session"])
        try:
            run.wait(f"{a['name']}: {report}", lambda: any(f.get("state") == report and f.get("kind") == kind
                                                           for f, _ in run.reports()[1:]))
            last = [line for line in a["standin"]["screen"] if line][-1].lstrip("⏺⎿> ").strip()
            run.wait(f"{a['name']}: last opening line on screen", run.screen_has(last))
            seen.append(f"{state}→{report}{'/' + kind if kind else ''}")
        finally:
            run.close()
    live = sum(not a["settled"] for a in agents)
    return f"{len(agents)} agents ({live} live, {len(agents) - live} settled); " + ", ".join(seen)


def check_dialogs(tmp):
    """Start-up dialogs: claude's folder trust (blocked kind=permission, no hook until trusted) and codex's update."""
    run = Run(os.path.join(tmp, "trust"), "claude", CLAUDE, script={"trust": True}, sid="S1")
    try:
        b = run.wait("blocked on trust", lambda: next((f for f, _ in run.reports() if f.get("state") == "blocked"), None))
        expect(b.get("kind") == "permission" and b.get("msg") == "trust this folder", f"trust report: {b}")
        run.wait("the dialog", run.screen_has("❯ No, exit"))
        run.type("typed early")
        run.pump(0.5)
        expect(not run.hooks() and not run.screen_has("typed early")(), "keys and hooks wait for trust")
        run.key("down")
        run.key("enter")
        run.wait("idle once trusted", lambda: run.states()[-1] == "idle")
        expect(ordered(run.states(), ["?", "blocked", "clear", "idle"]), f"states {run.states()}")
        run.wait("SessionStart after trust", run.hook("SessionStart"))
    finally:
        run.close()
    run = Run(os.path.join(tmp, "update"), "codex", ["resume", "C3"], script={"update": True}, sid="C3")
    try:
        run.wait("the update dialog", run.screen_has("› 1. Update now"))
        run.pump(1.0)
        expect(not run.reports(), "no report while the update dialog shows")
        run.key("esc")
        run.wait("idle after skipping", lambda: "idle" in run.states())
        run.wait("the composer", run.screen_has("Ask Codex to do anything"))
        return "trust: blocked/permission, hooks after trust; codex update dialog: silent until skipped"
    finally:
        run.close()


AGY_QUESTION = ("Before the harbour view ships, should the evening palette keep the old blue tones while the morning "
                "palette moves to the warmer colours described in the second part of the notes, or should both "
                "palettes stay exactly as they are today?")
AGY_AUTH = b"\x1b]7501;state=blocked:kind=auth:app=antigravity:msg=U2lnbiBpbiByZXF1aXJlZA==\x07"
AGY_IDLE = b"\x1b]7501;state=idle:app=antigravity\x07"


def held(path):
    """Whether another process holds an flock on `path`."""
    fd = os.open(path, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)


def box(run):
    """The rows between the last two full-width rules: agy's input box."""
    rows = run.screen()
    rules = [i for i, r in enumerate(rows) if r == "─" * run.cols]
    return rows[rules[-2] + 1:rules[-1]] if len(rules) > 1 else None


def footer(run):
    return [r for r in run.screen() if r][-1]


def last_reply(path):
    with open(path) as f:
        steps = [json.loads(line) for line in f]
    return [s for s in steps if s["type"] == "PLANNER_RESPONSE" and s.get("content")][-1]["content"], len(steps)


def check_agy(tmp):
    """agy: start, first prompt, question, permission, interrupt with a queued message, exit, resume, Ctrl-C."""
    script = {"title": "Harbour palette", "steps": [
        {"wait": "prompt"}, {"finish": "First line of the reply.\nSecond line."},
        {"wait": "prompt"}, {"ask": AGY_QUESTION, "options": ["yes", "no"]}, {"finish": "yes"},
        {"wait": "prompt"}, {"permission": "make test"}, {"finish": "Tests pass."},
        {"wait": "prompt"}, {"print": ["⏺ Bash(make long)"]}, {"wait": 30}, {"finish": "not reached"}]}
    run = Run(tmp, "agy", ["--add-dir", "$HOOKDIR", "--effort", "medium", "--prompt-interactive=-first prompt"],
              script=script, sid="default")
    try:
        run.wait("idle", lambda: "idle" in run.states())
        expect(run.states()[:3] == ["?", "blocked", "idle"] and AGY_AUTH in run.raw and AGY_IDLE in run.raw,
               f"start-up reports: {run.states()}")
        run.wait("the mode's hint in the box", lambda: box(run) == ["> Auto mode: edits & safe commands auto-approved (shift+tab to cycle)"])
        stop = run.wait("Stop of the first prompt", run.hook("Stop"))
        cid = stop["conversationId"]
        start = run.hooks("SessionStart")
        pre = run.hooks("PreInvocation")
        expect(len(start) == 1 and start[0]["conversationId"] == cid and start[0]["lastUserInput"] == "-first prompt",
               f"SessionStart: {start}")
        expect(pre[0]["invocationNum"] == 0 and pre[0]["initialNumSteps"] == 1, f"PreInvocation: {pre}")
        expect(stop["terminationReason"] == "NO_TOOL_CALL" and stop["fullyIdle"] is True and stop["error"] == ""
               and stop["workspacePaths"] == [os.path.join(tmp, "work"), run.hookdir] and stop["modelName"] == "example-model",
               f"Stop: {stop}")
        with open(run.ctx_log) as f:
            expect(set(f.read().split("\n")[:-1]) == {f"{run.hookdir}/.agents {cid}"}, "hooks run in .agents with the id set")
        reply, steps = last_reply(stop["transcriptPath"])
        expect(reply == "First line of the reply.\nSecond line." and steps == 2, f"transcript: {reply!r}, {steps}")
        run.wait("done", lambda: run.states()[-1] == "done")
        done = [f for f, _ in run.reports() if f.get("state") == "done"][-1]
        expect(done["msg"] == "First line of the reply.", f"done msg: {done}")
        lock = os.path.join(run.data, "presence", cid + ".lock")
        expect(held(lock), "the conversation's lock is held")
        run.wait("the echo of the prompt", lambda: "> -first prompt" in run.screen() and "─" * 60 in run.screen())
        expect(footer(run).endswith("auto · example-model · medium"), f"footer: {footer(run)!r}")
        # A question longer than 180 characters is cut in the report.
        run.type("ask me")
        run.wait("idle once a key is typed after done", lambda: run.states()[-1] == "idle")
        run.key("enter")
        blocked = run.wait("blocked", lambda: next((f for f, _ in run.reports() if f.get("kind") == "question"), None))
        expect(blocked["msg"] == AGY_QUESTION[:179] + "…", f"question msg: {blocked}")
        run.wait("the question menu", lambda: "> 1. yes" in run.screen() and "  3. Write-in..." in run.screen())
        run.key("down")
        run.wait("selection moves", lambda: "> 2. no" in run.screen())
        run.key("up")
        run.key("enter")
        run.wait("Stop after the answer", lambda: len(run.hooks("Stop")) == 2)
        expect(any(h["invocationNum"] == 1 for h in run.hooks("PreInvocation")), "the model is called again after the answer")
        run.wait("a bare box once typed in", lambda: box(run) == [">"])
        # Permission.
        run.type("run the tests")
        run.key("enter")
        perm = run.wait("blocked permission", lambda: next((f for f, _ in run.reports() if f.get("kind") == "permission"), None))
        expect(perm["msg"] == "Approve Bash: make test", f"permission msg: {perm}")
        run.wait("the permission menu", lambda: "Requesting permission for:" in run.screen() and "> 1. Yes, run command" in run.screen())
        run.key("enter")
        run.wait("Stop after approving", lambda: len(run.hooks("Stop")) == 3)
        expect(last_reply(stop["transcriptPath"])[0] == "Tests pass.", "the reply is in the transcript at Stop")
        # Interrupt with a queued message.
        run.type("count slowly")
        run.key("enter")
        run.wait("the tool line", lambda: "● Ran (make long) (ctrl+o to expand)" in run.screen())
        _, before = last_reply(stop["transcriptPath"])
        run.type("queued words")
        run.key("enter")
        run.wait("the queued line", lambda: "▸ queued words (alt+m to send immediately)" in run.screen()
                 and footer(run).startswith("  Press up to edit queued messages"))
        run.key("esc")
        run.wait("idle", lambda: run.states()[-1] == "idle")
        run.wait("queued text back in the box", lambda: box(run) == ["> queued words"])
        expect("  ⎿  Interrupted · What should Antigravity CLI do instead?" in run.screen(), "the interrupt line")
        run.pump(0.5)
        expect(len(run.hooks("Stop")) == 3 and last_reply(stop["transcriptPath"])[1] == before,
               "no Stop and no transcript step for an interrupted turn")
        run.key("esc")
        run.key("esc")
        run.wait("Escape twice empties the box", lambda: box(run) == [">"])
        # Control-D twice on an empty box exits.
        run.key("ctrl-d")
        run.wait("the exit hint", lambda: footer(run).startswith("press ctrl+d again to exit"))
        run.key("ctrl-d")
        run.wait("exit", lambda: run.status is not None, timeout=5)
        expect(os.WEXITSTATUS(run.status) == 0, f"exit {run.status}")
        expect(run.raw.endswith(AGY_IDLE + f"\r\nResume with -c (or command below):\r\nagy --conversation={cid}\r\n".encode()),
               f"exit bytes: {run.raw[-160:]!r}")
        expect(not held(lock), "the lock is free after exit")
    finally:
        run.close()
    n_hooks = len(run.hooks())
    run = Run(tmp, "agy", ["--add-dir", "$HOOKDIR", "--conversation", cid])
    try:
        run.wait("auth", lambda: "blocked" in run.states())
        t = time.monotonic()
        run.wait("idle", lambda: "idle" in run.states())
        waited = time.monotonic() - t
        expect(waited > 0.4, f"a resume stands on sign-in about 0.5 s: {waited:.2f}")
        expect(held(lock), "the lock is held from the start when resuming")
        run.type("again")
        run.key("enter")
        pre = run.wait("PreInvocation", lambda: next((h for h in run.hooks()[n_hooks:] if h["hookEventName"] == "PreInvocation"), None))
        work = [f for f, _ in run.reports() if f.get("state") == "working"][-1]
        expect(work.get("msg") == "Harbour palette", f"a resumed conversation's working carries its title: {work}")
        run.wait("Stop", lambda: any(h.get("hookEventName") == "Stop" for h in run.hooks()[n_hooks:]))
        expect(not [h for h in run.hooks()[n_hooks:] if h["hookEventName"] == "SessionStart"],
               "no SessionStart on resume, not even at the first prompt")
        expect(pre["conversationId"] == cid and pre["initialNumSteps"] > 1, f"PreInvocation after resume: {pre}")
        # Control-C: the first arms the exit and keeps the text, the second exits.
        run.type("kept")
        run.key("ctrl-c")
        run.wait("the Control-C hint", lambda: footer(run).startswith("press ctrl+c again to exit"))
        expect(box(run) == ["> kept"] and run.status is None, "one Control-C keeps the text and the program")
        run.key("ctrl-c")
        run.wait("exit", lambda: run.status is not None, timeout=5)
        return f"conversation {cid[:8]}; 7501 {' → '.join(run.states())}"
    finally:
        run.close()


def check_agy_screens(tmp):
    """agy: mode hints and Shift+Tab, a hint cut at 44 columns, the trust dialog, an unknown conversation id, a failure, skipped permissions."""
    run = Run(os.path.join(tmp, "plan"), "agy", ["--mode", "plan"])
    try:
        run.wait("the plan hint", lambda: box(run) == ["> Plan mode: research & plan only (shift+tab to cycle)"])
        expect(footer(run).endswith("plan · example-model · high"), f"footer {footer(run)!r}")
        run.key("shift-tab")
        run.wait("default mode: a bare box", lambda: box(run) == [">"] and footer(run).endswith("  example-model · high"))
        run.key("shift-tab")
        run.wait("accept-edits", lambda: box(run) == ["> Accept-edits mode: file edits auto-approved (shift+tab to cycle)"])
    finally:
        run.close()
    run = Run(os.path.join(tmp, "narrow"), "agy", [], cols=44)
    try:
        run.wait("the hint cut to the box", lambda: box(run) == ["> Auto mode: edits & safe commands auto-..."])
    finally:
        run.close()
    run = Run(os.path.join(tmp, "default"), "agy", ["--settings", '{"agentMode": ""}'])
    try:
        run.wait("idle", lambda: "idle" in run.states())
        run.wait("default mode from the settings", lambda: box(run) == [">"])
    finally:
        run.close()
    run = Run(os.path.join(tmp, "trust"), "agy", [], script={"trust": True}, sid="default")
    try:
        trust = run.wait("blocked on trust", lambda: next((f for f, _ in run.reports() if f.get("kind") == "permission"), None))
        expect(trust["msg"] == "Trust this folder?" and run.states()[:3] == ["?", "blocked", "blocked"], f"trust: {run.states()}")
        run.wait("the dialog", lambda: "> Yes, I trust this folder" in run.screen()
                 and "Do you trust the contents of this project?" in run.screen())
        run.key("enter")
        run.wait("idle once trusted", lambda: run.states()[-1] == "idle")
    finally:
        run.close()
    script = {"steps": [{"wait": "prompt"}, {"permission": "rm -r build"}, {"fail": "error"}]}
    run = Run(os.path.join(tmp, "unknown"), "agy", ["--add-dir", "$HOOKDIR", "--conversation", "0b9e2c1a-7d4f-4e3b-9a52-1c0ffee00000",
                                                   "--dangerously-skip-permissions"], script=script, sid="default")
    try:
        run.wait("idle", lambda: "idle" in run.states())
        run.pump(0.6)
        expect(not run.hooks(), "an unknown id: no hook before the first prompt")
        run.type("go")
        run.key("enter")
        err = run.wait("error", lambda: next((f for f, _ in run.reports() if f.get("state") == "error"), None))
        expect(err["msg"].startswith("failed to construct executor"), f"error: {err}")
        expect(not any(f.get("state") == "blocked" for f, _ in run.reports()[3:]), "skipped permissions do not ask")
        start = run.hooks("SessionStart")
        expect(len(start) == 1 and start[0]["conversationId"] != "0b9e2c1a-7d4f-4e3b-9a52-1c0ffee00000",
               f"an unknown id starts a new conversation: {start}")
        expect(not run.hooks("Stop"), "a failure runs no Stop")
        run.wait("the error on screen", lambda: any(r.startswith("⚠ failed to construct executor") for r in run.screen()))
        run.key("esc")
        run.wait("Escape after the error reports idle", lambda: run.states()[-1] == "idle")
        return "plan/default/accept-edits hints, trust dialog, unknown id → new conversation, error, no Stop"
    finally:
        run.close()


def check_agy_wake(tmp):
    """agy: a background command's wake-up (Stop, then its own PreInvocation 0 with the last prompt), and a first prompt run behind the trust dialog, then "No, exit"."""
    script = {"steps": [{"wait": "prompt"}, {"wake": "Waiting for sleep 20 to finish.", "after": 1}, {"finish": "slept"}]}
    run = Run(os.path.join(tmp, "wake"), "agy", ["--add-dir", "$HOOKDIR"], script=script, sid="default")
    try:
        run.wait("idle", lambda: "idle" in run.states())
        run.type("go")
        run.key("enter")
        run.wait("two Stops", lambda: len(run.hooks("Stop")) == 2)
        pre = run.hooks("PreInvocation")
        expect([(h["invocationNum"], h["lastUserInput"], h["initialNumSteps"]) for h in pre] == [(0, "go", 1), (0, "go", 2)],
               f"PreInvocation: {pre}")
        with open(run.hooks("Stop")[-1]["transcriptPath"]) as f:
            steps = [json.loads(line) for line in f]
        expect([(t["type"], t.get("content", "")[:7]) for t in steps] ==
               [("USER_INPUT", "<USER_R"), ("PLANNER_RESPONSE", "Waiting"), ("PLANNER_RESPONSE", "slept")], f"transcript: {steps}")
        run.wait("done", lambda: run.states()[-1] == "done")
        expect(run.states()[3:] == ["working", "done"], f"one working, one done: {run.states()}")
    finally:
        run.close()
    run = Run(os.path.join(tmp, "behind"), "agy", ["--add-dir", "$HOOKDIR", "--prompt-interactive=go"],
              script={"trust": True, "steps": [{"wait": "prompt"}, {"finish": "ok"}]}, sid="default")
    try:
        run.wait("Stop behind the dialog", run.hook("Stop"))
        expect(run.states() == ["?", "blocked", "blocked"], f"no report behind the dialog: {run.states()}")
        run.key("down")
        run.key("enter")
        run.wait("the exit", lambda: run.status is not None)
        status = run.status
        expect(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, f"exit: {status}")
        expect(run.raw.endswith(b"\x1b[>4m\x1b[<1u\r\x1b[40d\x1b[?1049l\x1b[?25h\x1b[?2004l" + AGY_IDLE),
               f"decline bytes: {run.raw[-80:]!r}")
        return "wake-up: Stop, PreInvocation 0 with the last prompt, one done; behind the trust dialog: hooks, no reports; No, exit: idle, status 0"
    finally:
        run.close()


CHECKS = [v for k, v in sorted(globals().items()) if k.startswith("check_")]


def run_one(name, tmp):
    """One check in this process; prints its result as one JSON line."""
    check = globals()["check_" + name]
    t = time.monotonic()
    try:
        ok, detail = True, check(tmp)
    except Exception:
        ok, detail = False, traceback.format_exc()
    print(json.dumps({"ok": ok, "detail": detail, "took": time.monotonic() - t}))


def main():
    if sys.argv[1:2] == ["--one"]:
        return run_one(sys.argv[2], sys.argv[3])
    wanted = sys.argv[1:]
    names = [c.__name__[6:] for c in CHECKS if not wanted or c.__name__[6:] in wanted]
    root = tempfile.mkdtemp(prefix="standin-check-", dir=os.environ.get("TMPDIR"))
    # Each check runs in its own process: forking a terminal child from a threaded process can hang.
    procs = []
    for name in names:
        tmp = os.path.join(root, name)
        os.makedirs(tmp)
        procs.append((name, subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "--one", name, tmp],
                                             stdout=subprocess.PIPE, text=True)))
    failed = 0
    for name, proc in procs:
        out, _ = proc.communicate(timeout=120)
        r = json.loads(out.strip().splitlines()[-1])
        failed += not r["ok"]
        print(f"{'PASS' if r['ok'] else 'FAIL'}  {name:<28} {r['took']:5.1f}s  {r['detail'] if r['ok'] else ''}")
        if not r["ok"]:
            print("      " + r["detail"].replace("\n", "\n      "))
    print(f"\n{len(procs) - failed} passed, {failed} failed")
    if not failed:
        shutil.rmtree(root)
    else:
        print(f"folders kept in {root}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
