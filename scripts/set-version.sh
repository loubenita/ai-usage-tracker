#!/usr/bin/env bash
# Sets the app's version and adds one to its build number, in both project.yml and
# App/Info.plist:
#
#   scripts/set-version.sh 0.3.0
#
# xcodegen writes App/Info.plist from project.yml, so the version has to change in both, or the
# next `xcodegen` loses it. This edits both directly, so xcodegen is not needed.
set -euo pipefail

version="${1:?Usage: scripts/set-version.sh <version>}"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  { echo "$version is not a version like 1.2.3." >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
spec="$root/project.yml"
plist="$root/App/Info.plist"

build="$(perl -ne 'print $1 if /^\s*CFBundleVersion:\s*"?(\d+)"?\s*$/' "$spec")"
[ -n "$build" ] || { echo "No CFBundleVersion in $spec." >&2; exit 1; }
export VERSION="$version" BUILD="$((build + 1))"

perl -pi -e 's/^(\s*CFBundleShortVersionString:).*$/$1 $ENV{VERSION}/' "$spec"
perl -pi -e 's/^(\s*CFBundleVersion:).*$/$1 "$ENV{BUILD}"/' "$spec"
perl -0pi -e 's|(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*|$1$ENV{VERSION}|' "$plist"
perl -0pi -e 's|(<key>CFBundleVersion</key>\s*<string>)[^<]*|$1$ENV{BUILD}|' "$plist"

grep -q "CFBundleShortVersionString: $VERSION$" "$spec" &&
  grep -q "CFBundleVersion: \"$BUILD\"$" "$spec" &&
  grep -q "<string>$VERSION</string>" "$plist" &&
  grep -q "<string>$BUILD</string>" "$plist" ||
  { echo "Could not set the version in $spec and $plist." >&2; exit 1; }
echo "Version $VERSION, build $BUILD"
