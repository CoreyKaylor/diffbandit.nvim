#!/usr/bin/env bash
# Render the README demo GIFs with VHS.
#
#   demo/record.sh                     # all tapes
#   demo/record.sh 03-merge            # one tape (prefix match)
#   demo/record.sh 01 02               # several
#
# Each tape drives the user's REAL Neovim config (see demo/README.md), so the
# output reflects whatever colorscheme, completion and LSP setup is installed.

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SIZE_WARN_BYTES=$((2 * 1024 * 1024))

die() { printf 'record: %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
for bin in vhs ffmpeg nvim git; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not found on PATH (brew install $bin)"
done

# Clip 02 is a demonstration of LSP completion and diagnostics; without a Lua
# server it still records, but it records nothing worth publishing.
command -v lua-language-server >/dev/null 2>&1 \
  || die "lua-language-server not found; 02-editable-lsp would record an empty demo"

# Resolve the font without a pipeline: `cmd | grep -q` exits the pipeline early
# and, under `set -o pipefail`, reports failure even on a match.
if command -v fc-match >/dev/null 2>&1; then
  font_match="$(fc-match "JetBrainsMono Nerd Font Mono" 2>/dev/null || true)"
  case "$font_match" in
    *[Nn]erd*) ;;
    *) die "font 'JetBrainsMono Nerd Font Mono' not installed; icons would render as tofu" ;;
  esac
fi

# Tapes need `tic` so fixtures.sh can compile demo/terminfo/xterm-vhs.src
# (colored underlines under VHS). macOS ships it with ncurses.
command -v tic >/dev/null 2>&1 || die "tic not found (need ncurses terminfo compiler for xterm-vhs)"

# --- pick tapes --------------------------------------------------------------
all_tapes=(demo/[0-9][0-9]-*.tape)
tapes=()
if [ "$#" -eq 0 ]; then
  tapes=("${all_tapes[@]}")
else
  for want in "$@"; do
    matched=0
    for tape in "${all_tapes[@]}"; do
      case "$(basename "$tape" .tape)" in
        "$want"*) tapes+=("$tape"); matched=1 ;;
      esac
    done
    [ "$matched" -eq 1 ] || die "no tape matching '$want' (have: $(basename -a "${all_tapes[@]}" | tr '\n' ' '))"
  done
fi

mkdir -p docs/demo/.frames

# --- render ------------------------------------------------------------------
oversized=()
for tape in "${tapes[@]}"; do
  name="$(basename "$tape" .tape)"
  printf '\n=== %s ===\n' "$name"

  # Rebuild every time, not once up front: the tapes mutate their fixtures
  # (03 resolves and stages a merge, 04 creates a commit). A second run against
  # a used fixture records the wrong thing -- or hangs on a Wait that never
  # matches, because the conflict it is waiting for no longer exists.
  ./demo/fixtures.sh >/dev/null

  vhs "$tape"

  out="docs/demo/$name.gif"
  [ -f "$out" ] || die "$tape finished but produced no $out"
  bytes=$(wc -c <"$out" | tr -d ' ')
  printf '%s  %s\n' "$out" "$(du -h "$out" | cut -f1)"
  [ "$bytes" -gt "$SIZE_WARN_BYTES" ] && oversized+=("$name")
done

# --- report ------------------------------------------------------------------
printf '\n'
if [ "${#oversized[@]}" -gt 0 ]; then
  printf 'warning: over 2MB, GitHub will serve these slowly: %s\n' "${oversized[*]}"
  printf '  levers, in order: trim Sleep values, drop Set Framerate to 20, reduce Set Height.\n'
fi

printf 'done. Watch the GIFs before committing -- VHS cannot tell a mistimed\n'
printf 'Sleep from a correct one; it exits 0 either way. Stills for each beat\n'
printf 'are in docs/demo/.frames/ (untracked).\n'
