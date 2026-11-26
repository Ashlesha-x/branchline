#!/bin/zsh
# Packages dist/脉络.app (from scripts/build.sh) into a drag-to-Applications disk image.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/dist/脉络.app"
[ -d "$app" ] || { echo "Run scripts/build.sh first" >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg="$PWD/dist/Branchline-$version-macOS-arm64.dmg"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto "$app" "$stage/脉络.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
/usr/bin/hdiutil create -volname "脉络 $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
/usr/bin/hdiutil verify "$dmg" >/dev/null
echo "Built: $dmg"
shasum -a 256 "$dmg"
