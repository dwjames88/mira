#!/usr/bin/env bash
# Builds Release, installs to /Applications and registers the Photos editing extension.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_SRC="build/DerivedData/Build/Products/Release/Mira.app"
APP_DST="/Applications/Mira.app"
APPEX="$APP_DST/Contents/PlugIns/MiraPhotos.appex"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

xcodegen generate
xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Release \
  -derivedDataPath build/DerivedData build

rm -rf "$APP_DST"
ditto "$APP_SRC" "$APP_DST"
codesign --verify --deep --strict "$APP_DST"

# Builds register their own copies of the extension; drop those so only /Applications is registered.
for stale in "$ROOT"/build/DerivedData/Build/Products/*/Mira.app/Contents/PlugIns/MiraPhotos.appex; do
  [ -e "$stale" ] && pluginkit -r "$stale" || true
done

"$LSREGISTER" -f "$APP_DST"
sleep 1
# Registration is asynchronous: add, then retry until pluginkit sees the extension.
for _ in 1 2 3 4 5; do
  pluginkit -a "$APPEX"
  sleep 1
  pluginkit -m -A -D -i com.fieldframes.mira.photos | grep -q "$APP_DST" && break
done
pluginkit -e use -i com.fieldframes.mira.photos

echo "Photos editing extensions:"
LISTING="$(pluginkit -m -p com.apple.photo-editing -v)"
echo "$LISTING"
if ! grep "com.fieldframes.mira.photos" <<<"$LISTING"; then
  echo "error: com.fieldframes.mira.photos is not registered with pluginkit" >&2
  exit 1
fi
