#!/bin/bash
# Optional real-terminal smoke test: run DiffBandit in a real TUI inside tmux
# and apply the same visual checks the child-Neovim tests use. Everything else
# runs headless (nvim -l tests/run_all.lua); this guards the TUI path itself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SESSION="diffbandit_smoke_$$"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/diffbandit_smoke.XXXXXX")"
trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true' EXIT

tmux new-session -d -s "$SESSION" -x 120 -y 48 -c "$ROOT"
tmux send-keys -t "$SESSION" \
  "TERM=screen-256color COLORTERM=truecolor nvim -u '$ROOT/tests/integration/init.lua' -c 'DiffBandit tests/files/left_mixed.txt tests/files/right_mixed.txt'" Enter

# Poll until the diff is on screen and the frame stops changing.
prev=""
for _ in $(seq 1 100); do
  cur="$(tmux capture-pane -t "$SESSION" -e -p)"
  if [[ "$cur" == *"Delete this line"* && "$cur" == "$prev" ]]; then
    break
  fi
  prev="$cur"
  sleep 0.1
done

tmux capture-pane -t "$SESSION" -p > "$OUT/capture.txt"
tmux capture-pane -t "$SESSION" -e -p > "$OUT/capture.ansi"

nvim --headless -u NONE -l /dev/stdin "$ROOT" "$OUT" <<'LUA'
local root, out = arg[1], arg[2]
package.path = root .. "/tests/?.lua;" .. package.path
local verify = require("helpers.verify")
local errors = verify.check("mixed", verify.read_capture(out .. "/capture.txt"), verify.read_capture(out .. "/capture.ansi"))
if #errors > 0 then
  io.stderr:write("tmux smoke FAILED (captures: " .. out .. "):\n  - " .. table.concat(errors, "\n  - ") .. "\n")
  os.exit(1)
end
print("tmux smoke OK")
LUA
rm -rf "$OUT"
