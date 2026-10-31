#!/bin/sh
# Grove pre_delete hook: run the hook this one replaced (if any), then kill the
# Rex session labelled with the workspace name once the delete has finished.
# usage: pre-delete.sh <workspace-path> [workspace-name]
set -eu

path=${1:-}
name=${2:-}
[ -n "$path" ] || { printf 'usage: pre-delete.sh <workspace-path> [workspace-name]\n' >&2; exit 2; }
[ -n "$name" ] || name=$(basename "$path")

state_dir=${GROVE_REX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/grove-rex}
prev="$state_dir/pre_delete.prev"

# The hook that was here before install.sh, e.g. grove-herdr's. Its {path} and
# {name} placeholders become positional args, so nothing is re-quoted.
if [ -s "$prev" ]; then
  cmd=$(sed 's/{path}/"$1"/g; s/{name}/"$2"/g' "$prev")
  sh -c "$cmd" sh "$path" "$name" || printf 'grove-rex: previous pre_delete hook failed\n' >&2
fi

command -v rex >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
sid=$(rex ls --json 2>/dev/null | jq -r --arg n "$name" '.sessions[] | select(.label == $n) | .session_id' | head -n 1)
[ -n "$sid" ] || exit 0

# `gw go -bd` usually runs inside that session, so kill it only after the
# workspace dir is gone (or 120s), from a detached process that outlives gw.
python3 - "$path" "$sid" <<'PY'
import os, subprocess, sys, time
path, sid = sys.argv[1:]
if os.fork():
    sys.exit(0)
os.setsid()
if os.fork():
    os._exit(0)
devnull = os.open(os.devnull, os.O_RDWR)
for fd in (0, 1, 2):
    os.dup2(devnull, fd)
deadline = time.time() + 120
while os.path.exists(path) and time.time() < deadline:
    time.sleep(0.5)
time.sleep(0.5)
subprocess.run(["rex", "session", "kill", sid])
os._exit(0)
PY
