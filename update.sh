#!/usr/bin/env bash
# Updates AI Usage Tracker to the latest release and opens it:
#
#   ./update.sh
#   curl -fsSL https://raw.githubusercontent.com/loubenita/ai-usage-tracker/main/update.sh | bash
#
# scripts/install.sh does the work — download, replace the app in Applications, clear the
# quarantine flag with xattr, open it. This wrapper only says which version you had and which
# you have now. Piped through bash there is no checkout, so it fetches install.sh as well.
set -euo pipefail

install_url="https://raw.githubusercontent.com/loubenita/ai-usage-tracker/main/scripts/install.sh"
source="${BASH_SOURCE[0]:-}"
local_install=""
[ -n "$source" ] && local_install="$(cd "$(dirname "$source")" && pwd)/scripts/install.sh"

run_install() {
  if [ -n "$local_install" ] && [ -x "$local_install" ]; then
    "$local_install"
  else
    curl -fsSL "$install_url" | bash
  fi
}

installed_version() {
  for app in /Applications/AIUsageTracker.app "$HOME/Applications/AIUsageTracker.app"; do
    if [ -f "$app/Contents/Info.plist" ]; then
      defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null && return
    fi
  done
  echo "not installed"
}

before="$(installed_version)"
run_install
after="$(installed_version)"

if [ "$before" = "$after" ]; then
  echo "Already on the latest version ($after)."
else
  echo "Updated: $before -> $after"
fi
