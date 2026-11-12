#!/usr/bin/env python3
"""Scratch hook: append {time, argv, env names, payload} to LOG.
usage: hook.py LOG ARG... [--title TEXT]
With --title, SessionStart and UserPromptSubmit print a sessionTitle result."""
import json, os, sys, time
log = sys.argv[1]
args = sys.argv[2:]
title = None
title_on = ("SessionStart", "UserPromptSubmit")
if "--title" in args:
    i = args.index("--title")
    title = args[i + 1]
if "--title-on" in args:
    title_on = tuple(args[args.index("--title-on") + 1].split(","))
raw = sys.stdin.read()
try:
    payload = json.loads(raw)
except ValueError:
    payload = {"_unparsed": raw[:2000]}
env_names = sorted(k for k in os.environ if k.startswith(("CLAUDE", "CLAWDDY", "GHOSTTY", "CODEX", "TERM")))
with open(log, "a") as f:
    f.write(json.dumps({"t": time.time(), "pid": os.getpid(), "ppid": os.getppid(), "argv": args,
                        "env_names": env_names, "payload": payload}) + "\n")
event = payload.get("hook_event_name") if isinstance(payload, dict) else None
if title and event in title_on:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "sessionTitle": title + "-" + event}}))
