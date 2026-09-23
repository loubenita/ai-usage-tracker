#!/usr/bin/env bash
# Builds the Release app signed by loubenita's Apple Development certificate and zips it for a
# GitHub release:
#
#   scripts/release.sh 0.1.0
#
# The zip holds only AIUsageTracker.app, at build/release/AIUsageTracker.zip. Publishing it is
# a separate, deliberate step:
#
#   gh release create v0.1.0 build/release/AIUsageTracker.zip --title "AI Usage Tracker 0.1.0"
set -euo pipefail

version="${1:?Usage: scripts/release.sh <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
identity="${SIGN_IDENTITY:?Set SIGN_IDENTITY to your signing identity, such as 'Apple Development: you@example.com'}"
team="${TEAM_ID:-C6F25575D8}"
app="$root/build/ReleaseData/Build/Products/Release/AIUsageTracker.app"
zip="$root/build/release/AIUsageTracker.zip"

cd "$root"
xcodebuild -project AIUsageTracker.xcodeproj -scheme AIUsageTracker -configuration Release \
  -derivedDataPath build/ReleaseData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" build >/dev/null

built="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")"
[ "$built" = "$version" ] || { echo "The app says version $built, not $version: update App/Info.plist." >&2; exit 1; }
codesign --verify --deep --strict "$app"

mkdir -p "$(dirname "$zip")"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip"
shasum -a 256 "$zip"
