#!/usr/bin/env bash
# Record a tape in a real Ghostty window so the Kitty-graphics connector
# (bezier ribbons) shows -- VHS's xterm.js host cannot display it.
#
#   demo/ghostty/record.sh                      # every tape, keyframe mode
#   demo/ghostty/record.sh 03 04                # some tapes (prefix match)
#   demo/ghostty/record.sh --realtime 01        # realtime mode
#   demo/ghostty/record.sh --both 01            # both modes, for comparison
#
# Tape headers: `-- cwd: <dir>` (required) and `-- size: <cols>x<rows>`
# (optional; overrides the window size in ghostty.conf).
#
# Modes (see runner.lua):
#   keyframe  one window screenshot per visible change, explicit durations
#   realtime  ScreenCaptureKit films the window while the tape runs live
#
# Output: docs/demo/ghostty/<tape>.<mode>.gif; stills in docs/demo/.frames/.
# Needs macOS with a GUI session, Ghostty, ffmpeg, swiftc, and Screen
# Recording permission for the terminal that runs this script.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/demo/ghostty"
# Not under /tmp/diffbandit-demo: fixtures.sh wipes that tree on every run.
BIN=/tmp/diffbandit-demo-tools
REC=/tmp/diffbandit-demo-rec
# Captures wider than this are Retina (2x) and get halved.
HALVE_ABOVE=1800
GIF_FPS=24

die() { printf 'record: %s\n' "$*" >&2; exit 1; }

modes=(keyframe)
wants=()
for arg in "$@"; do
  case "$arg" in
    --realtime) modes=(realtime) ;;
    --both) modes=(keyframe realtime) ;;
    --keyframe) modes=(keyframe) ;;
    -*) die "unknown flag $arg" ;;
    *) wants+=("$arg") ;;
  esac
done

all_tapes=("$HERE"/tapes/[0-9][0-9]-*.lua)
tapes=()
if [ "${#wants[@]}" -eq 0 ]; then
  tapes=("${all_tapes[@]}")
else
  for want in "${wants[@]}"; do
    matched=0
    for tp in "${all_tapes[@]}"; do
      case "$(basename "$tp" .lua)" in "$want"*) tapes+=("$tp"); matched=1 ;; esac
    done
    [ "$matched" -eq 1 ] || die "no tape matching '$want'"
  done
fi

for b in ffmpeg nvim swiftc; do command -v "$b" >/dev/null || die "$b not on PATH"; done
[ -d /Applications/Ghostty.app ] || die "Ghostty.app not in /Applications"

# --- helpers (compiled once; rebuilt when the source is newer) --------------
mkdir -p "$BIN"
for tool in winid winrec; do
  if [ ! -x "$BIN/$tool" ] || [ "$HERE/$tool.swift" -nt "$BIN/$tool" ]; then
    swiftc -O "$HERE/$tool.swift" -o "$BIN/$tool" 2>/dev/null || die "failed to compile $tool.swift"
  fi
done

if "$BIN/winid" diffbandit-demo >/dev/null 2>&1; then
  die "a diffbandit-demo Ghostty window is already open; close it first"
fi

mkdir -p "$ROOT/docs/demo/ghostty"

record_mode() {
  local tape="$1" mode="$2"
  local name; name="$(basename "$tape" .lua)"
  local cwd size
  cwd="$(sed -n 's/^-- cwd: //p' "$tape" | head -1)"
  [ -n "$cwd" ] || die "$tape has no '-- cwd: <dir>' header"
  size="$(sed -n 's/^-- size: //p' "$tape" | head -1)"
  local out="$REC/$name-$mode"
  local gif="$ROOT/docs/demo/ghostty/$name.$mode.gif"
  printf '\n=== %s (%s) ===\n' "$name" "$mode"

  # Tapes may mutate fixtures, so rebuild before every run (as demo/record.sh).
  "$ROOT/demo/fixtures.sh" >/dev/null
  rm -rf "$out"; mkdir -p "$out"

  # The command goes in a per-run config file, not `-e`: Ghostty asks for
  # confirmation ("Allow Ghostty to execute ...?") before running a command
  # handed to it on the command line via `open`.
  cat >"$out/run.conf" <<CONF
command = /usr/bin/env DEMO_CWD=$cwd DEMO_RUNNER=$HERE/runner.lua DEMO_TAPE=$tape DEMO_MODE=$mode DEMO_OUT=$out DEMO_STILLS=$ROOT/docs/demo/.frames /bin/sh $HERE/drive.sh
CONF
  if [ -n "$size" ]; then
    printf 'window-width = %s\nwindow-height = %s\n' "${size%x*}" "${size#*x}" >>"$out/run.conf"
  fi
  open -na Ghostty.app --args --config-default-files=false \
    --config-file="$HERE/ghostty.conf" --config-file="$out/run.conf"

  local info="" i
  for i in $(seq 1 100); do
    info="$("$BIN/winid" diffbandit-demo 2>/dev/null)" && break
    sleep 0.1
  done
  [ -n "$info" ] || die "Ghostty window never appeared"
  local wid="${info%% *}"
  printf 'window %s\n' "$info"
  printf '%s\n' "$wid" >"$out/winid"

  local rec_pid=""
  if [ "$mode" = realtime ]; then
    for i in $(seq 1 300); do [ -e "$out/show" ] || [ -e "$out/done" ] && break; sleep 0.1; done
    [ -e "$out/show" ] || die "tape never reached show() ($(cat "$out/error" 2>/dev/null))"
    "$BIN/winrec" "$wid" "$out/raw.mov" 60 >"$out/winrec.log" 2>&1 &
    rec_pid=$!
    for i in $(seq 1 100); do grep -q '^recording' "$out/winrec.log" 2>/dev/null && break; sleep 0.05; done
    grep -q '^recording' "$out/winrec.log" || { kill "$rec_pid" 2>/dev/null; die "winrec: $(cat "$out/winrec.log")"; }
    : >"$out/recording"
  fi

  for i in $(seq 1 1800); do [ -e "$out/done" ] && break; sleep 0.1; done
  if [ -n "$rec_pid" ]; then kill -INT "$rec_pid"; wait "$rec_pid" || true; fi
  [ -e "$out/done" ] || die "tape did not finish within 180s"
  [ -e "$out/error" ] && die "tape failed: $(cat "$out/error")"

  # Same palette/dither for both modes so the comparison is only about
  # capture. Scale only by an integer factor (halve a Retina capture): a
  # fractional resample smears every glyph and defeats GIF frame diffing.
  local palette="split[a][b];[a]palettegen=stats_mode=full:max_colors=256[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
  local scale="scale='if(gt(iw,$HALVE_ABOVE),iw/2,iw)':-2:flags=lanczos"
  if [ "$mode" = keyframe ]; then
    ffmpeg -v error -y -f concat -safe 0 -i "$out/frames.txt" \
      -vf "$scale,$palette" -fps_mode vfr -loop 0 "$gif"
  else
    # The HEVC capture has codec noise on frames that are visually
    # identical; mpdecimate drops them so the GIF stores only real changes.
    # Dropping the trailing duplicates also drops the final hold, so measure
    # what was lost and give it back as the last frame's delay.
    local vf="fps=$GIF_FPS,mpdecimate=hi=512:lo=256:frac=0.1,$scale,$palette"
    ffmpeg -v error -y -i "$out/raw.mov" -vf "$vf" -fps_mode vfr -loop 0 "$gif"
    local raw_s gif_s tail_cs
    raw_s="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out/raw.mov")"
    gif_s="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$gif")"
    tail_cs="$(awk -v r="$raw_s" -v g="$gif_s" 'BEGIN { d = (r - g) * 100; print (d > 0 ? int(d + 0.5) : 0) }')"
    if [ "$tail_cs" -gt 5 ]; then
      ffmpeg -v error -y -i "$out/raw.mov" -vf "$vf" -fps_mode vfr -loop 0 \
        -final_delay "$tail_cs" "$gif"
    fi
  fi
  printf '%s  %s\n' "$gif" "$(du -h "$gif" | cut -f1)"
}

for tp in "${tapes[@]}"; do
  for m in "${modes[@]}"; do
    record_mode "$tp" "$m"
  done
done
printf '\nCheck the stills in docs/demo/.frames/ghostty-* before committing.\n'

