#!/usr/bin/env bash
# Screenshots every overlay state without touching the mouse or keyboard:
# launches the app once per state with `--state`, captures only its window
# with `screencapture -l`, then quits it.
#
#   scripts/capture-states.sh [output dir] [fake|real|counts]
#
# counts captures rest and hover on fake data with 1, 6, 12 and 20 sessions, to show
# the strip growing and what happens when the sessions do not fit.
#
# fake (the default) captures every state on the made-up data, to compare with the
# Paper frames. real captures the rest and hover strips with the sessions running in
# terminals right now, and saves the `ps` output taken at the same moment beside them.
# Output defaults to ~/.claude/proof/ai-usage-tracker/build.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# APP=<path to a .app> captures another copy, so a copy you are running is left alone.
app="${APP:-$root/build/DerivedData/Build/Products/Debug/AIUsageTracker.app}/Contents/MacOS/AIUsageTracker"
out="${1:-$HOME/.claude/proof/ai-usage-tracker/build}"
data="${2:-fake}"
mkdir -p "$out"

[ -x "$app" ] || { echo "Build the app first (see README)." >&2; exit 1; }

# Compiled once: running the helper through the Swift interpreter is slow enough to hang the loop.
window_id="$root/build/tools/window-id"
if [ ! -x "$window_id" ] || [ "$root/scripts/window-id.swift" -nt "$window_id" ]; then
  mkdir -p "$(dirname "$window_id")"
  swiftc -O "$root/scripts/window-id.swift" -o "$window_id"
fi

capture() {
  local state="$1" name="$2"
  shift 2
  # Only the copy this script starts is stopped afterwards; any other running copy is left alone.
  "$app" --state "$state" --data "${data/counts/fake}" "$@" >/dev/null 2>&1 &
  local pid=$!
  local id=""
  for _ in $(seq 1 20); do
    sleep 0.5
    id="$("$window_id" "$pid" 2>/dev/null || true)"
    [ -n "$id" ] && break
  done
  # Let the glass and the first tick render. SETTLE=15 gives real data time to measure the
  # owner's usual pace, which reads a week of transcripts in the background.
  sleep "${SETTLE:-1.5}"
  if [ -z "$id" ]; then
    echo "no overlay window for $state" >&2
  else
    screencapture -x -o -l "$id" "$out/$name.png"
    echo "$out/$name.png"
    if [ "$data" = real ]; then
      # The process list the app was reading when the picture was taken.
      LC_ALL=C ps -ww -Ao pid,ppid,tty,lstart,command > "$out/$name.ps.txt"
      echo "$out/$name.ps.txt"
    fi
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

if [ "$data" = real ]; then
  capture rest 1-rest.real
  capture hover 2-hover.real
  # The usage panel with every agent, on each period, then each agent's own view.
  capture open-today 4-open-today.real
  capture open-week 5-open-week.real
  capture open-month 6-open-month.real
  for agent in ${AGENTS:-claude-code codex cursor}; do
    capture open-week "7-open-week-$agent.real" --agent "$agent"
  done
  # OPEN_SESSION=claude-code-<pid> also captures that session's panel.
  if [ -n "${OPEN_SESSION:-}" ]; then
    capture open-session 3-open-session.real --session "$OPEN_SESSION"
  fi
elif [ "$data" = counts ]; then
  for n in 1 6 12 20; do
    capture rest "rest-$n-sessions" --sessions "$n"
    capture hover "hover-$n-sessions" --sessions "$n"
  done
else
  capture rest 1-rest.build
  capture hover 2-hover.build
  capture open-session 3-open-session.build
  # The usage panel as frames 4 to 6 draw it: All on Today, Claude on Week, Cursor on Month.
  capture open-today 4-open-today.build
  capture open-week 5-open-week-claude.build --agent claude-code
  capture open-month 6-open-month-cursor.build --agent cursor
  # Frame 7: the strip picked up, showing its handle where it was dragged to.
  capture drag 7-drag.build
fi
