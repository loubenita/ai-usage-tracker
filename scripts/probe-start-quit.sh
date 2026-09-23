#!/usr/bin/env bash
# Shows a session appearing and disappearing on the live strip, without the mouse or keyboard.
#
# Launches the app on real data in the hover state, starts a stand-in `claude` (/bin/sleep
# run under the name claude, so none of the owner's Claude hooks run) in a detached session
# on a private tmux server, and screenshots the app window before, 2 seconds after the start,
# and 2 seconds after the stand-in quits. The `ps` output at each moment is saved beside each
# picture. Nothing is typed into any window and the owner's own tmux server is not touched.
#
#   scripts/probe-start-quit.sh [output dir]    (default ~/.claude/proof/ai-usage-tracker/build-2)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/DerivedData/Build/Products/Debug/AIUsageTracker.app/Contents/MacOS/AIUsageTracker"
window_id="$root/build/tools/window-id"
out="${1:-$HOME/.claude/proof/ai-usage-tracker/build-2}"
mkdir -p "$out"
[ -x "$app" ] && [ -x "$window_id" ] || { echo "Build the app and run capture-states.sh first." >&2; exit 1; }

socket="aiut-probe-$$"

now() { perl -MTime::HiRes=time -MPOSIX=strftime -e 'my $t = time; printf "%s.%03d", strftime("%H:%M:%S", localtime $t), ($t - int $t) * 1000'; }

snap() {
  local name="$1" before after
  before="$(now)"
  screencapture -x -o -l "$id" "$out/$name.png"
  after="$(now)"
  LC_ALL=C ps -ww -Ao pid,ppid,tty,lstart,command > "$out/$name.ps.txt"
  echo "$before capture of $name started, finished $after"
}

cleanup() {
  tmux -L "$socket" kill-server 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
}

pkill -f "AIUsageTracker.app/Contents/MacOS" 2>/dev/null || true
"$app" --state hover --data real >/dev/null 2>&1 &
pid=$!
trap cleanup EXIT
id=""
for _ in $(seq 1 20); do
  sleep 0.5
  id="$("$window_id" "$pid" 2>/dev/null || true)"
  [ -n "$id" ] && break
done
[ -n "$id" ] || { echo "no overlay window" >&2; exit 1; }
sleep 2.5

snap 3-before-start
echo "$(now) starting stand-in claude on private tmux server $socket"
# tmux can take several seconds to return, so the clock starts when the process exists.
tmux -L "$socket" new-session -d -s probe -c "$HOME" "bash -c 'exec -a claude /bin/sleep 600'" &
standin=""
while [ -z "$standin" ]; do
  standin="$(pgrep -f '^claude 600$' || true)"
done
echo "$(now) stand-in is pid $standin"
sleep 2
snap 4-two-seconds-after-start
echo "$(now) quitting it"
kill "$standin"
while kill -0 "$standin" 2>/dev/null; do :; done
echo "$(now) stand-in has exited"
sleep 2
snap 5-two-seconds-after-quit
