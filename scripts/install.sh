#!/usr/bin/env bash
# Downloads the latest AI Usage Tracker release and installs it in /Applications:
#
#   curl -fsSL https://raw.githubusercontent.com/loubenita/ai-usage-tracker/main/scripts/install.sh | bash
#
# The app is signed with an Apple Development certificate but not notarized, so macOS would
# refuse to open a downloaded copy. This script removes the download's quarantine flag, which
# is what makes macOS ask, and then opens the app.
set -euo pipefail

url="https://github.com/loubenita/ai-usage-tracker/releases/latest/download/AIUsageTracker.zip"
apps="/Applications"
[ -w "$apps" ] || apps="$HOME/Applications"
mkdir -p "$apps"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading $url"
curl -fL --progress-bar "$url" -o "$work/AIUsageTracker.zip"
ditto -x -k "$work/AIUsageTracker.zip" "$work"

# Quit a running copy so it can be replaced.
pkill -x AIUsageTracker 2>/dev/null || true
rm -rf "$apps/AIUsageTracker.app"
ditto "$work/AIUsageTracker.app" "$apps/AIUsageTracker.app"
xattr -dr com.apple.quarantine "$apps/AIUsageTracker.app" 2>/dev/null || true

echo "Installed $apps/AIUsageTracker.app"
open "$apps/AIUsageTracker.app"
