#!/usr/bin/env bash
# Updates AI Usage Tracker to the latest release and opens it:
#
#   ./update.sh
#
# scripts/install.sh does the work — download, replace the app in Applications, clear the
# quarantine flag with xattr, open it. This wrapper only says which version you had and which
# you have now.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

installed_version() {
  for app in /Applications/AIUsageTracker.app "$HOME/Applications/AIUsageTracker.app"; do
    if [ -f "$app/Contents/Info.plist" ]; then
      defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null && return
    fi
  done
  echo "not installed"
}

before="$(installed_version)"
"$here/scripts/install.sh"
after="$(installed_version)"

if [ "$before" = "$after" ]; then
  echo "Already on the latest version ($after)."
else
  echo "Updated: $before -> $after"
fi
