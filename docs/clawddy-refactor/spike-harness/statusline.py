#!/usr/bin/env python3
"""Scratch statusLine: append {time, payload} to LOG and print a short line."""
import json, sys, time
raw = sys.stdin.read()
try:
    payload = json.loads(raw)
except ValueError:
    payload = {"_unparsed": raw[:2000]}
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"t": time.time(), "payload": payload}) + "\n")
print("SPIKE-STATUSLINE")
