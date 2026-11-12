#!/usr/bin/env python3
"""Print a timeline of steps, replies and OSC sequences from a harness log.

usage: decode.py DIR [--all-osc] [--text]
  default shows OSC 0/1/2 (titles), 7501, 9, 777, 99, 7, 133, 1337 and steps.
  --text also prints visible text snippets per output chunk.
"""
import base64, json, re, sys

d = sys.argv[1]
show_all = "--all-osc" in sys.argv
show_text = "--text" in sys.argv
INTERESTING = {"0", "1", "2", "7501", "9", "777", "99", "7", "133", "1337", "22", "21"}
recs = [json.loads(l) for l in open(d + "/log.jsonl")]
stream = ""       # accumulated output (latin-1)
offsets = []      # (start offset, t)
for r in recs:
    if r["dir"] == "out":
        offsets.append((len(stream), r["t"]))
        stream += r["b"]

def t_at(off):
    t = 0
    for o, tt in offsets:
        if o <= off:
            t = tt
        else:
            break
    return t

events = []
for m in re.finditer(r"\x1b\](\d+);?([^\x07\x1b]*)(\x07|\x1b\\)", stream):
    num, body, term = m.group(1), m.group(2), m.group(3)
    if not show_all and num not in INTERESTING:
        continue
    extra = ""
    if num == "7501":
        for kv in body.split(":"):
            k, _, v = kv.partition("=")
            if k in ("msg", "title") and v:
                try:
                    extra += f"  [{k}={base64.b64decode(v).decode('utf-8', 'replace')!r}]"
                except Exception as e:
                    extra += f"  [{k} undecodable: {e}]"
    raw = m.group(0).encode("latin-1").decode("utf-8", "replace")
    events.append((t_at(m.start()), "OSC", f"{raw!r}{extra}"))

def vis(s):
    s = s.encode("latin-1").decode("utf-8", "replace")
    s = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", s)
    s = re.sub(r"\x1bP.*?\x1b\\", "", s, flags=re.S)
    s = re.sub(r"\x1b\[[0-9;?<>=$]*[ -/]*[@-~]", " ", s)
    s = re.sub(r"\x1b.", "", s)
    return re.sub(r"\s+", " ", s).strip()

for r in recs:
    if r["dir"] == "step":
        events.append((r["t"], "STEP", r["b"]))
    elif r["dir"] in ("reply", "in"):
        events.append((r["t"], r["dir"].upper(), repr(r["b"])))
    elif r["dir"] == "out" and show_text:
        v = vis(r["b"])
        if v:
            events.append((r["t"], "TEXT", v[:200]))
events.sort(key=lambda e: e[0])
last_in = None
for t, kind, s in events:
    if kind == "IN" and last_in is not None and len(s) <= 6:
        last_in[2].append(s)  # collapse typing
        continue
    if kind == "IN":
        last_in = [t, kind, [s]]
        print(f"{t:8.3f} IN    {s}")
        continue
    last_in = None
    print(f"{t:8.3f} {kind:5} {s}")
