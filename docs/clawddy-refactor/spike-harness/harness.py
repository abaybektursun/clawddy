#!/usr/bin/env python3
"""PTY harness: run a command in a pseudo-terminal that answers terminal
queries like Ghostty, type scripted input, and log every byte with times.

usage: harness.py --out DIR --cwd DIR --steps steps.json [--osc7501 reply|none]
                  [--env K=V ...] -- cmd args...

Writes in DIR:
  log.jsonl   one record per chunk: {"t": seconds, "dir": "out"|"in"|"reply"|"step", "b": latin-1 text}
  out.bin     raw child output
  pid         child pid
Steps (JSON list), run in order:
  {"wait": "regex"}              wait until the visible text since the last step matches (timeout 90s or "timeout")
  {"wait_raw": "regex"}          same, against raw bytes (latin-1)
  {"quiet": seconds}             wait until the child is silent this long
  {"sleep": seconds}
  {"type": "text"}               type text one char at a time, 20ms apart
  {"key": "enter"|"esc"|"ctrl-c"|"ctrl-d"|"down"|"up"|"tab"}
  {"mark": "label"}              just logs a label
"""
import argparse, fcntl, json, os, pty, re, select, signal, struct, sys, termios, time

ap = argparse.ArgumentParser()
ap.add_argument("--out", required=True)
ap.add_argument("--cwd", required=True)
ap.add_argument("--steps", required=True)
ap.add_argument("--osc7501", default="reply", choices=["reply", "none"])
ap.add_argument("--rows", type=int, default=40)
ap.add_argument("--cols", type=int, default=120)
ap.add_argument("--env", action="append", default=[])
ap.add_argument("--max", type=float, default=300.0, help="hard time limit")
ap.add_argument("cmd", nargs=argparse.REMAINDER)
a = ap.parse_args()
cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
steps = json.load(open(a.steps))
os.makedirs(a.out, exist_ok=True)

env = dict(os.environ)
env.update({"TERM": "xterm-ghostty", "TERM_PROGRAM": "ghostty",
            "TERM_PROGRAM_VERSION": "1.3.2-dev", "COLORTERM": "truecolor",
            "TERMINFO": "/Applications/Ghostty.app/Contents/Resources/terminfo"})
for kv in a.env:
    k, _, v = kv.partition("=")
    if v == "":
        env.pop(k, None)
    else:
        env[k] = v

T0 = time.monotonic()
logf = open(os.path.join(a.out, "log.jsonl"), "w")
rawf = open(os.path.join(a.out, "out.bin"), "wb")

def log(direction, data):
    if isinstance(data, bytes):
        data = data.decode("latin-1")
    logf.write(json.dumps({"t": round(time.monotonic() - T0, 3), "dir": direction, "b": data}) + "\n")
    logf.flush()

pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", a.rows, a.cols, a.cols * 8, a.rows * 16))
    os.chdir(a.cwd)
    os.execvpe(cmd[0], cmd, env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", a.rows, a.cols, a.cols * 8, a.rows * 16))
open(os.path.join(a.out, "pid"), "w").write(str(pid))
log("step", json.dumps({"spawn": cmd, "pid": pid, "osc7501": a.osc7501}))

kitty_stack = [0]
buf = b""          # unparsed tail for query detection
since = b""        # raw output since the last step
alive = True

def write(data, direction="in"):
    os.write(fd, data)
    log(direction, data)

ST_RE = rb"(?:\x07|\x1b\\)"
def answer(chunk):
    """Find queries in output and reply like Ghostty."""
    global buf
    buf = (buf + chunk)[-8192:]
    out = []
    consumed = 0
    for m in re.finditer(rb"\x1b\[(\??)(>?)([0-9;]*)([\$]?)([a-zA-Z~])|\x1b\](\d+);([^\x07\x1b]*)(\x07|\x1b\\)|\x1bP\+q([0-9a-fA-F;]*)\x1b\\", buf):
        consumed = m.end()
        if m.group(5):
            q, gt, params, dollar, final = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)
            if final == b"c" and not q and not gt and params in (b"", b"0"):
                out.append(b"\x1b[?62;22c")
            elif final == b"c" and gt:
                out.append(b"\x1b[>1;10;0c")
            elif final == b"n" and not q and params == b"6":
                out.append(b"\x1b[1;1R")
            elif final == b"n" and not q and params == b"5":
                out.append(b"\x1b[0n")
            elif final == b"n" and q and params == b"996":
                out.append(b"\x1b[?997;1n")
            elif final == b"q" and gt:
                out.append(b"\x1bP>|ghostty 1.3.2-dev\x1b\\")
            elif final == b"u" and q and not params:
                out.append(b"\x1b[?%du" % kitty_stack[-1])
            elif final == b"u" and gt:
                kitty_stack.append(int(params or b"0"))
            elif final == b"u" and buf[m.start() + 2:m.start() + 3] == b"<":
                if len(kitty_stack) > 1:
                    kitty_stack.pop()
            elif final == b"p" and q and dollar:
                mode = int(params or b"0")
                supported = {1, 7, 25, 47, 1000, 1002, 1003, 1004, 1006, 1047, 1049, 2004, 2026, 2027, 2031, 2048}
                out.append(b"\x1b[?%d;%d$y" % (mode, 2 if mode in supported else 0))
            elif final == b"t" and params == b"14":
                out.append(b"\x1b[4;%d;%dt" % (a.rows * 16, a.cols * 8))
            elif final == b"t" and params == b"16":
                out.append(b"\x1b[6;16;8t")
            elif final == b"t" and params == b"18":
                out.append(b"\x1b[8;%d;%dt" % (a.rows, a.cols))
        elif m.group(6):
            num, body, term = m.group(6), m.group(7), m.group(8)
            if num == b"7501" and body == b"?":
                if a.osc7501 == "reply":
                    out.append(b"\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth" + term)
            elif num in (b"10", b"11", b"12") and body == b"?":
                color = {b"10": b"rgb:ffff/ffff/ffff", b"11": b"rgb:1d1d/1f1f/2121", b"12": b"rgb:ffff/ffff/ffff"}[num]
                out.append(b"\x1b]" + num + b";" + color + term)
            elif num == b"4" and body.endswith(b";?"):
                out.append(b"\x1b]4;" + body[:-2] + b";rgb:8080/8080/8080" + term)
        elif m.group(9) is not None:
            out.append(b"\x1bP0+r\x1b\\")
    buf = buf[consumed:]
    for r in out:
        write(r, "reply")

def visible(raw):
    t = raw.decode("utf-8", "replace")
    t = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", t)
    t = re.sub(r"\x1bP.*?\x1b\\", "", t, flags=re.S)
    t = re.sub(r"\x1b\[[0-9;?<>=$]*[ -/]*[@-~]", " ", t)
    t = re.sub(r"\x1b.", "", t)
    return re.sub(r"\s+", " ", t)

def pump(timeout):
    """Read output for up to timeout seconds. Returns seconds since last output."""
    global alive, since
    end = time.monotonic() + timeout
    last = time.monotonic()
    while alive and time.monotonic() < end:
        r, _, _ = select.select([fd], [], [], max(0.0, min(0.1, end - time.monotonic())))
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b""
            if not data:
                alive = False
                break
            rawf.write(data); rawf.flush()
            log("out", data)
            since += data
            answer(data)
            last = time.monotonic()
        if time.monotonic() - T0 > a.max:
            log("step", json.dumps({"error": "hard time limit"}))
            alive = False
    return time.monotonic() - last

KEYS = {"enter": b"\r", "esc": b"\x1b", "ctrl-c": b"\x03", "ctrl-d": b"\x04", "tab": b"\t",
        "down": b"\x1b[B", "up": b"\x1b[A", "shift-tab": b"\x1b[Z", "backspace": b"\x7f", "ctrl-u": b"\x15", "focus-in": b"\x1b[I", "focus-out": b"\x1b[O"}
KITTY = {"enter": b"\x1b[13u", "esc": b"\x1b[27u", "ctrl-c": b"\x1b[99;5u", "ctrl-d": b"\x1b[100;5u", "tab": b"\x1b[9u",
         "ctrl-u": b"\x1b[117;5u"}

for st in steps:
    if not alive:
        break
    log("step", json.dumps(st))
    if "wait" in st or "wait_raw" in st:
        pat = st.get("wait") or st.get("wait_raw")
        deadline = time.monotonic() + st.get("timeout", 90)
        ok = False
        while alive and time.monotonic() < deadline:
            hay = visible(since) if "wait" in st else since.decode("latin-1")
            if re.search(pat, hay, re.S):
                ok = True
                break
            pump(0.2)
        log("step", json.dumps({"wait_result": ok, "pattern": pat}))
        if not ok and st.get("required", True):
            log("step", json.dumps({"abort": "wait failed"}))
            break
    elif "quiet" in st:
        deadline = time.monotonic() + st.get("timeout", 60)
        while alive and time.monotonic() < deadline:
            if pump(st["quiet"]) >= st["quiet"]:
                break
    elif "sleep" in st:
        pump(st["sleep"])
    elif "type" in st:
        for ch in st["type"].encode():
            write(bytes([ch]))
            pump(0.02)
    elif "key" in st:
        k = st["key"]
        flags = kitty_stack[-1]
        data = KITTY[k] if (flags & 1 and k in ("esc", "ctrl-c", "ctrl-d", "ctrl-u")) or (flags & 8 and k in KITTY) else KEYS[k]
        write(data)
    since = b"" if st.get("reset", True) else since
    pump(0.05)

# Drain, then make sure the child is gone (only the child we started).
pump(3)
for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGKILL):
    try:
        wpid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        break
    if wpid == pid:
        log("step", json.dumps({"exit_status": status}))
        break
    log("step", json.dumps({"signal": int(sig), "pid": pid}))
    os.kill(pid, sig)
    t_end = time.monotonic() + 5
    while time.monotonic() < t_end:
        pump(0.2)
        try:
            wpid, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            wpid = pid
        if wpid == pid:
            log("step", json.dumps({"exit_status_after_signal": status}))
            break
    else:
        continue
    break
log("step", json.dumps({"done": True}))
