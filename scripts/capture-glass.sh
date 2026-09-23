#!/usr/bin/env bash
# Proves the glass: shows a picture behind the overlay's corner of the screen, opens each
# state with `--state`, and captures that area of the screen with `screencapture -R`, so what
# is behind the window shows through (a capture of the window alone has nothing behind it).
# No mouse or keyboard input is sent.
#
#   scripts/capture-glass.sh <output dir> <name suffix> [backdrop image] [light|dark]
#
# APP=<path to a .app> captures another copy, such as an older build for the "before".
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="${APP:-$root/build/DerivedData/Build/Products/Debug/AIUsageTracker.app}/Contents/MacOS/AIUsageTracker"
out="${1:?output dir}"
suffix="${2:?name suffix, such as before or after}"
image="${3:-}"
appearance="${4:-}"
[ -n "$appearance" ] && appearance="--appearance $appearance"
mkdir -p "$out"

backdrop="$root/build/tools/backdrop"
if [ ! -x "$backdrop" ] || [ "$root/scripts/backdrop.swift" -nt "$backdrop" ]; then
  mkdir -p "$(dirname "$backdrop")"
  swiftc -O "$root/scripts/backdrop.swift" -o "$backdrop"
fi
screen="$root/build/tools/screen-frame"
if [ ! -x "$screen" ]; then
  printf 'import AppKit\nlet s = NSScreen.main!\nprint(Int(s.frame.width), Int(s.frame.maxY - s.visibleFrame.maxY), Int(s.visibleFrame.height))\n' \
    > "$root/build/tools/screen-frame.swift"
  swiftc -O "$root/build/tools/screen-frame.swift" -o "$screen"
fi
read -r width top height < <("$screen")
# The overlay's window: the right 440 points of the screen, below the menu bar.
region="$((width - 440)),$top,440,$height"

capture() {
  local state="$1" name="$2"
  shift 2
  "$backdrop" 10 $image >/dev/null 2>&1 &
  local backdrop_pid=$!
  sleep 1
  "$app" --state "$state" --data fake $appearance "$@" >/dev/null 2>&1 &
  local pid=$!
  sleep "${SETTLE:-4}"
  screencapture -x -R "$region" "$out/$name.$suffix.png"
  echo "$out/$name.$suffix.png"
  kill "$pid" "$backdrop_pid" 2>/dev/null || true
  wait "$pid" "$backdrop_pid" 2>/dev/null || true
}

capture hover glass-strip
capture open-session glass-session
capture open-today glass-usage
