#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache build
ljm_stage=$(mktemp -d "${TMPDIR:-/tmp}/ljm-build.XXXXXX")
trap 'rm -rf "$ljm_stage"' EXIT
# Bundle file name is what System Settings and the permission dialog show.
ljm_bundle="$ljm_stage/小名.app"
mkdir -p "$ljm_bundle/Contents/MacOS" "$ljm_bundle/Contents/Resources"

swiftc -swift-version 5 -O -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$PWD/.build/module-cache" \
  -framework Carbon -framework ScreenCaptureKit -framework AVFoundation -framework AVKit \
  LJM/App/*.swift LJM/UI/*.swift LJM/Capture/*.swift LJM/Storage/*.swift \
  -o "$ljm_bundle/Contents/MacOS/小名"

cp Info-build.plist "$ljm_bundle/Contents/Info.plist"
cp LJM/Resources/XuanPaper.png LJM/Resources/XuanPaper@2x.png LJM/Resources/XuanPaper@3x.png \
  LJM/Resources/GlowRidges.png LJM/Resources/GlowRidges@2x.png LJM/Resources/GlowRidges@3x.png \
  "$ljm_bundle/Contents/Resources/"
xattr -cr "$ljm_bundle"
# Keep a stable designated requirement (bundle id only) so Screen Recording
# permission survives rebuilds. The default ad-hoc requirement is a cdhash
# that changes every compile, which makes macOS ask again every time.
codesign --force --sign - --identifier dev.ljm.recorder \
  --requirements '=designated => identifier "dev.ljm.recorder"' \
  --entitlements LJM/LJM-adhoc.entitlements "$ljm_bundle"
codesign --verify --deep --strict "$ljm_bundle"
rm -rf "build/小名.app" "build/LJM.app"
ditto --norsrc "$ljm_bundle" "build/小名.app"
xattr -cr "build/小名.app"
# Refresh Launch Services so the system prompt uses the name「小名」.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/build/小名.app" >/dev/null 2>&1 || true
echo "Built: $PWD/build/小名.app"
