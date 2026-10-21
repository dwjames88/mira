#!/usr/bin/env bash
# Builds Release, installs to /Applications and registers the Photos editing extension.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_SRC="build/DerivedData/Build/Products/Release/Emulsion.app"
APP_DST="/Applications/Emulsion.app"
APPEX="$APP_DST/Contents/PlugIns/EmulsionPhotos.appex"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

xcodegen generate
xcodebuild -project Emulsion.xcodeproj -scheme Emulsion -configuration Release \
  -derivedDataPath build/DerivedData build

rm -rf "$APP_DST"
ditto "$APP_SRC" "$APP_DST"
codesign --verify --deep --strict "$APP_DST"

pluginkit -a "$APPEX"
"$LSREGISTER" -f "$APP_DST"

echo "Photos editing extensions:"
LISTING="$(pluginkit -m -p com.apple.photo-editing -v)"
echo "$LISTING"
if ! grep "com.dwjames.emulsion.photos" <<<"$LISTING"; then
  echo "error: com.dwjames.emulsion.photos is not registered with pluginkit" >&2
  exit 1
fi
