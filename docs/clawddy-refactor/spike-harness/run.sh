#!/bin/sh
# usage: run.sh EXPDIR STEPS.json OSCMODE(reply|none) [--env K=V ...] -- cmd args...
# Runs the harness with agent identity stripped. EXPDIR/work is the child's cwd,
# EXPDIR/cap holds the capture. SPIKE_DIR (required) is the scratch directory
# that receives pids.log; keep EXPDIR inside it too.
set -e
SPIKE=${SPIKE_DIR:?set SPIKE_DIR to a scratch directory}
BIN=$(cd "$(dirname "$0")" && pwd)
EXP=$1; STEPS=$2; MODE=$3; shift 3
mkdir -p "$EXP/work" "$EXP/cap"
(cd "$HOME/.config/ghostty-agents/status" && stat -f '%N %z %m' *) > "$EXP/cap/status_before.txt"
echo "$(date '+%H:%M:%S') start $EXP" >> "$SPIKE/pids.log"
"$BIN/clean-env" /opt/homebrew/bin/python3 -I "$BIN/harness.py" \
  --out "$EXP/cap" --cwd "$EXP/work" --steps "$STEPS" --osc7501 "$MODE" "$@" || true
PID=$(cat "$EXP/cap/pid")
echo "$(date '+%H:%M:%S') child pid $PID for $EXP" >> "$SPIKE/pids.log"
sleep 1
echo "leftover processes in session/pgid $PID or with child as parent:"
ps -axo pid,ppid,pgid,sess,command | awk -v p="$PID" 'NR==1 || $1==p || $2==p || $3==p' | cut -c1-160
(cd "$HOME/.config/ghostty-agents/status" && stat -f '%N %z %m' *) > "$EXP/cap/status_after.txt"
echo "status files changed during run:"
diff "$EXP/cap/status_before.txt" "$EXP/cap/status_after.txt" | grep '^>' || echo "  (none)"
