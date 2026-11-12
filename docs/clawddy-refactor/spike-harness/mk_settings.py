#!/usr/bin/env python3
"""Write a scratch Claude settings file with logging hooks and statusLine.
usage: mk_settings.py OUT.json CAPDIR AGENT GEN [TITLE [TITLE_ON_EVENTS]]"""
import json, os, sys
out, cap, agent, gen = sys.argv[1:5]
title = sys.argv[5] if len(sys.argv) > 5 else None
title_on = sys.argv[6] if len(sys.argv) > 6 else None
BIN = os.path.dirname(os.path.abspath(__file__))
PY = "/opt/homebrew/bin/python3 -I"
cmd = (f"{PY} {BIN}/hook.py {cap}/hooks.jsonl {agent} {gen}" + (f" --title {title}" if title else "")
       + (f" --title-on {title_on}" if title_on else ""))
events = ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd", "Notification",
          "PermissionRequest", "PermissionDenied", "PreToolUse", "PostToolUse", "PostToolUseFailure",
          "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"]
settings = {
    "hooks": {e: [{"hooks": [{"type": "command", "command": cmd, "timeout": 10}]}] for e in events},
    "statusLine": {"type": "command", "command": f"{PY} {BIN}/statusline.py {cap}/statusline.jsonl"},
}
json.dump(settings, open(out, "w"), indent=1)
print(cmd)
