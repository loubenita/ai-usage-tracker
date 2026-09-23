#!/bin/bash
# A Claude Code status line that also saves Claude's plan limits for AI Usage Tracker.
#
# Claude Code keeps its 5-hour and weekly limits out of the transcript, but hands them to the
# status line script on every update. This script appends them to
# ~/Library/Application Support/AIUsageTracker/claude-limits.jsonl whenever they change, and
# prints a short status line: "5h 62% · 7d 48%".
#
# To use it, add this to ~/.claude/settings.json (with the path to this file):
#   "statusLine": { "type": "command", "command": "/path/to/claude-statusline.sh" }
#
# To keep a status line you already have, set AIUT_STATUSLINE_NEXT to its command: this
# script then prints that command's output instead of its own.
set -u

input=$(cat)
log_dir="$HOME/Library/Application Support/AIUsageTracker"
log="$log_dir/claude-limits.jsonl"

limits=$(printf '%s' "$input" | jq -c '
  (.rate_limits // {}) as $r
  | {five_hour: $r.five_hour, seven_day: $r.seven_day}
  | with_entries(select(.value != null))
  | select(length > 0)' 2>/dev/null)

if [ -n "$limits" ]; then
  mkdir -p "$log_dir"
  last=$(tail -n 1 "$log" 2>/dev/null | jq -c 'del(.at)' 2>/dev/null)
  if [ "$limits" != "$last" ]; then
    printf '%s' "$limits" | jq -c --argjson at "$(date +%s)" '{at: $at} + .' >> "$log"
  fi
fi

if [ -n "${AIUT_STATUSLINE_NEXT:-}" ]; then
  printf '%s' "$input" | bash -c "$AIUT_STATUSLINE_NEXT"
  exit 0
fi

printf '%s' "$input" | jq -r '
  [ (.rate_limits.five_hour.used_percentage // empty | "5h \(round)%"),
    (.rate_limits.seven_day.used_percentage // empty | "7d \(round)%") ]
  | join(" · ")' 2>/dev/null
