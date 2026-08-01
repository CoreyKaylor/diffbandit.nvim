#!/usr/bin/env bash
# Build the demo fixture tree under /tmp/diffbandit-demo.
#
# Everything here is disposable and rebuilt from scratch on every run, so the
# recordings in demo/*.tape are reproducible and never touch real work.
#
# Source material for the "real code" fixtures lives in demo/fixtures/; the
# throwaway folder-diff trees are generated inline below.

set -euo pipefail

DEMO_ROOT="${DEMO_ROOT:-/tmp/diffbandit-demo}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"

# Fixed identity so commits are byte-identical across runs.
export GIT_AUTHOR_NAME="DiffBandit Demo"
export GIT_AUTHOR_EMAIL="demo@diffbandit.test"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_AUTHOR_DATE="2024-01-01T09:00:00 +0000"
export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"

git_init() {
  local dir="$1"
  git -C "$dir" init --quiet --initial-branch=main
  git -C "$dir" config user.name "$GIT_AUTHOR_NAME"
  git -C "$dir" config user.email "$GIT_AUTHOR_EMAIL"
  git -C "$dir" config commit.gpgsign false
}

# Pin the lua_ls project root deterministically. Without this, lua-language-server
# walks up from /tmp looking for .git and can land somewhere unexpected, which
# makes the LSP clip behave differently run to run.
write_luarc() {
  cat >"$1/.luarc.json" <<'JSON'
{
  "runtime.version": "LuaJIT",
  "diagnostics.globals": ["vim"],
  "workspace.checkThirdParty": false,
  "telemetry.enable": false
}
JSON
}

rm -rf "$DEMO_ROOT"
mkdir -p "$DEMO_ROOT"

# ---------------------------------------------------------------------------
# pair/ -- two-way diff material (clips 01 and 02)
# ---------------------------------------------------------------------------
mkdir -p "$DEMO_ROOT/pair"
cp "$SRC/pair/before.lua" "$SRC/pair/after.lua" "$DEMO_ROOT/pair/"
write_luarc "$DEMO_ROOT/pair"

# ---------------------------------------------------------------------------
# merge/ -- a repo genuinely mid-conflict (clip 03)
#
# The merge session reads index stages 1/2/3 via `git show :N:path`; it never
# parses conflict markers out of the worktree file. So the conflict has to be a
# real one, produced by a real failed merge.
# ---------------------------------------------------------------------------
mkdir -p "$DEMO_ROOT/merge"
git_init "$DEMO_ROOT/merge"
write_luarc "$DEMO_ROOT/merge"

cp "$SRC/merge/retry.base.lua" "$DEMO_ROOT/merge/retry.lua"
cp "$SRC/merge/budget.base.lua" "$DEMO_ROOT/merge/budget.lua"
git -C "$DEMO_ROOT/merge" add -A
git -C "$DEMO_ROOT/merge" commit --quiet -m "Add retry and budget policy"

git -C "$DEMO_ROOT/merge" checkout --quiet -b feature
cp "$SRC/merge/retry.remote.lua" "$DEMO_ROOT/merge/retry.lua"
cp "$SRC/merge/budget.remote.lua" "$DEMO_ROOT/merge/budget.lua"
git -C "$DEMO_ROOT/merge" commit --quiet -am "Raise limits and add jitter backoff"

git -C "$DEMO_ROOT/merge" checkout --quiet main
cp "$SRC/merge/retry.local.lua" "$DEMO_ROOT/merge/retry.lua"
cp "$SRC/merge/budget.local.lua" "$DEMO_ROOT/merge/budget.lua"
git -C "$DEMO_ROOT/merge" commit --quiet -am "Tune retry policy for slow upstreams"

# Expected to fail -- that failure IS the fixture.
if git -C "$DEMO_ROOT/merge" merge --quiet feature >/dev/null 2>&1; then
  echo "fixtures: merge/ was expected to conflict but merged cleanly" >&2
  exit 1
fi
if ! git -C "$DEMO_ROOT/merge" show :1:retry.lua >/dev/null 2>&1; then
  echo "fixtures: merge/ has no stage-1 entry for retry.lua" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# repo/ -- clean history plus dirty worktree (clip 04)
# Yields two modified files and one untracked file in the commit panel.
# ---------------------------------------------------------------------------
mkdir -p "$DEMO_ROOT/repo"
git_init "$DEMO_ROOT/repo"
write_luarc "$DEMO_ROOT/repo"

cp "$SRC/repo/baseline/"*.lua "$DEMO_ROOT/repo/"
git -C "$DEMO_ROOT/repo" add -A
git -C "$DEMO_ROOT/repo" commit --quiet -m "Add router and logger"

cp "$SRC/repo/working/"*.lua "$DEMO_ROOT/repo/"

# ---------------------------------------------------------------------------
# folder-left / folder-right -- recursive folder diff (clip 05)
# Throwaway content; the point is the mix of statuses, not the code.
# ---------------------------------------------------------------------------
mkdir -p "$DEMO_ROOT"/folder-{left,right}/{store,util}

same() {
  # same <relpath> <body>
  printf '%s\n' "$2" >"$DEMO_ROOT/folder-left/$1"
  printf '%s\n' "$2" >"$DEMO_ROOT/folder-right/$1"
}

same "init.lua"       'return require("store")'
same "util/str.lua"   'return { trim = function(s) return (s:gsub("^%s+", "")) end }'
same "store/index.lua" 'return { version = 3 }'

# modified on both sides
printf 'return {\n  retries = 3,\n  timeout = 5,\n}\n'  >"$DEMO_ROOT/folder-left/config.lua"
printf 'return {\n  retries = 5,\n  timeout = 30,\n}\n' >"$DEMO_ROOT/folder-right/config.lua"

# store/cache.lua is the file the folder-diff tape drills into, so it carries a
# real two-sided diff rather than a one-liner.
cat >"$DEMO_ROOT/folder-left/store/cache.lua" <<'LUA'
local M = {}

M.capacity = 128

function M.key(scope, id)
  return scope .. ":" .. id
end

function M.warm(store, rows)
  for _, row in ipairs(rows) do
    store[M.key("row", row.id)] = row
  end
  return store
end

return M
LUA
cat >"$DEMO_ROOT/folder-right/store/cache.lua" <<'LUA'
local M = {}

M.capacity = 512
M.ttl = 300

function M.key(scope, id)
  return scope .. "/" .. id
end

function M.warm(store, rows, now)
  for _, row in ipairs(rows) do
    store[M.key("row", row.id)] = {
      row = row,
      at = now,
    }
  end
  return store
end

return M
LUA

# one-sided
printf 'return { deprecated = true }\n' >"$DEMO_ROOT/folder-left/legacy.lua"
printf 'return { enabled = true }\n'    >"$DEMO_ROOT/folder-right/telemetry.lua"

# ---------------------------------------------------------------------------
# terminfo/ -- xterm-256color + colored underlines for VHS (see demo/README.md)
# Tapes launch nvim with TERMINFO=$DEMO_ROOT/terminfo TERM=xterm-vhs.
# ---------------------------------------------------------------------------
SRC_TI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/terminfo/xterm-vhs.src"
if command -v tic >/dev/null 2>&1 && [ -f "$SRC_TI" ]; then
  mkdir -p "$DEMO_ROOT/terminfo"
  tic -x -o "$DEMO_ROOT/terminfo" "$SRC_TI"
else
  echo "fixtures: warning: could not compile xterm-vhs terminfo (need tic + demo/terminfo/xterm-vhs.src)" >&2
fi

echo "fixtures: built $DEMO_ROOT"
