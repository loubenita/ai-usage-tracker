#!/usr/bin/env bash
# Builds the Release app for Apple silicon and Intel Macs and zips it for a GitHub release:
#
#   scripts/set-version.sh 0.1.0
#   SIGN_IDENTITY="Apple Development: you@example.com" scripts/release.sh 0.1.0
#
# SIGN_IDENTITY=- signs it ad hoc, which needs no certificate. The Release workflow
# (.github/workflows/release.yml) runs all of this for you.
#
# The zip holds only AIUsageTracker.app, at build/release/AIUsageTracker.zip. Publishing it is
# a separate, deliberate step:
#
#   gh release create v0.1.0 build/release/AIUsageTracker.zip --title "AI Usage Tracker 0.1.0"
set -euo pipefail

version="${1:?Usage: scripts/release.sh <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
identity="${SIGN_IDENTITY:?Set SIGN_IDENTITY to your signing identity, such as 'Apple Development: you@example.com', or to - to sign ad hoc}"
team="${TEAM_ID:-C6F25575D8}"
app="$root/build/ReleaseData/Build/Products/Release/AIUsageTracker.app"
zip="$root/build/release/AIUsageTracker.zip"
log="$root/build/release/xcodebuild.log"

signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity")
[ "$identity" = "-" ] || signing+=(DEVELOPMENT_TEAM="$team")

cd "$root"
mkdir -p "$(dirname "$zip")"
xcodebuild -project AIUsageTracker.xcodeproj -scheme AIUsageTracker -configuration Release \
  -derivedDataPath build/ReleaseData ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  "${signing[@]}" build >"$log" 2>&1 ||
  { tail -n 60 "$log" >&2; echo "The build failed. Full log: $log" >&2; exit 1; }

built="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")"
[ "$built" = "$version" ] || { echo "The app says version $built, not $version: run scripts/set-version.sh $version first." >&2; exit 1; }
archs="$(lipo -archs "$app/Contents/MacOS/AIUsageTracker")"
for arch in arm64 x86_64; do
  [[ " $archs " == *" $arch "* ]] || { echo "The app is not built for $arch, only for: $archs." >&2; exit 1; }
done
codesign --verify --deep --strict "$app"

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip"
shasum -a 256 "$zip"
