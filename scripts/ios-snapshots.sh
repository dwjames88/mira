#!/bin/bash
# Headless iOS screenshots: build, boot, install, launch with MIRA_SNAPSHOT=1, capture the framebuffer.
# No taps, no keyboard, no pointer input -- launch + screenshot only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/snapshots/ios"
DERIVED="${DERIVED:-$(mktemp -d "${TMPDIR:-/tmp}/mira-ios-snap.XXXXXX")}"
BUNDLE_ID="com.fieldframes.mira.ios"
DEVICE_NAME="${DEVICE_NAME:-iPhone 17}"
SETTLE="${SETTLE:-4}"

mkdir -p "$OUT"

# Pick the first available simulator with this name; create one if none exists.
UDID="$(xcrun simctl list devices available | grep -E "^ +$DEVICE_NAME \(" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' || true)"
if [ -z "$UDID" ]; then
  RUNTIME="$(xcrun simctl list runtimes available | grep -E 'iOS' | tail -1 | sed -E 's/.* - //')"
  UDID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_NAME" "$RUNTIME")"
fi
echo "Simulator: $DEVICE_NAME ($UDID)"

cd "$ROOT"
xcodebuild -scheme MiraiOS -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" build 2>&1 | tail -3

APP="$(find "$DERIVED/Build/Products" -maxdepth 2 -name 'Mira.app' -path '*iphonesimulator*' | head -1)"
[ -n "$APP" ] || { echo "Built Mira.app not found" >&2; exit 1; }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"

shoot() { # name [tab]
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  SIMCTL_CHILD_MIRA_SNAPSHOT=1 SIMCTL_CHILD_MIRA_SNAPSHOT_TAB="${2:-develop}" \
    xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  sleep "$SETTLE"
  xcrun simctl io "$UDID" screenshot "$OUT/$1.png" >/dev/null 2>&1
  echo "$OUT/$1.png ($(stat -f%z "$OUT/$1.png") bytes)"
}

# Gallery: grant Photos headlessly (no taps), launch normally, let thumbnails load.
# photos-add first, then full photos last: the later grant wins (the reverse leaves add-only + a prompt).
xcrun simctl privacy "$UDID" reset photos "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl privacy "$UDID" grant photos-add "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl privacy "$UDID" grant photos "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
sleep "${GALLERY_SETTLE:-6}"
xcrun simctl io "$UDID" screenshot "$OUT/gallery.png" >/dev/null 2>&1
echo "$OUT/gallery.png ($(stat -f%z "$OUT/gallery.png") bytes)"

shoot editor-develop develop
shoot editor-films films

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
