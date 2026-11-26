#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cache .build/module-cache dist
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --product Branchline --configuration release --disable-sandbox --cache-path "$PWD/.build/cache" --scratch-path "$PWD/.build" --build-system native
swift build --product branchline-cli --configuration release --disable-sandbox --cache-path "$PWD/.build/cache" --scratch-path "$PWD/.build" --build-system native
bundle="$PWD/dist/脉络.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/release/Branchline "$bundle/Contents/MacOS/Branchline"
cp .build/release/branchline-cli "$bundle/Contents/MacOS/branchline-cli"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"; fi
rm -rf "$bundle/Contents/Resources/zh-Hans.lproj"; cp -R Resources/zh-Hans.lproj "$bundle/Contents/Resources/zh-Hans.lproj"
/usr/bin/codesign --force --deep --sign - --identifier local.branchline.progress "$bundle"
echo "Built: $bundle"
