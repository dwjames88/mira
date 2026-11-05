#!/bin/bash
# Prepare a simulator (boot, seed media once, grant Photos) and run the MiraiOSUITests UI tests on it.
# Usage: scripts/ios-uitests.sh [UDID]   (or env UDID). Default: the "Mira QA UI" device.
# Simulator-only input; never touches the host pointer or keyboard.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="${1:-${UDID:-59B50036-9FDC-4C79-8CCF-B2C94E51CA5A}}"
APP_ID="com.fieldframes.mira.ios"
RUNNER_ID="com.fieldframes.mira.ios.uitests.xctrunner"
DD="$ROOT/build/dd-uitests"

case "$UDID" in F7DAA9B9*) echo "Refusing to boot the iOS 27.0 runtime device" >&2; exit 1;; esac

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

# Seed media once (marker file per device).
MARK="$ROOT/build/.uitests-seeded-$UDID"
if [ ! -f "$MARK" ]; then
  mkdir -p "$ROOT/build"
  FILES=("$ROOT/Fixtures/sample.jpg" "$ROOT/Fixtures/raw/iphone-xs.dng")
  [ -f "$ROOT/Fixtures/raw/iphone-12-pro.dng" ] && FILES+=("$ROOT/Fixtures/raw/iphone-12-pro.dng")
  xcrun simctl addmedia "$UDID" "${FILES[@]}"
  touch "$MARK"
fi

cd "$ROOT"
xcodegen generate
DEST=(-scheme MiraiOS -destination "id=$UDID" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO)
xcodebuild build-for-testing "${DEST[@]}" | tail -3

# Grants need the apps installed (granting before install does not stick for the runner), so install first.
PRODUCTS="$DD/Build/Products/Debug-iphonesimulator"
xcrun simctl uninstall "$UDID" "$APP_ID" 2>/dev/null || true  # fresh app state (a saved RAW filter hides the PHOTOS label)
xcrun simctl install "$UDID" "$PRODUCTS/Mira.app"
xcrun simctl install "$UDID" "$PRODUCTS/MiraiOSUITests-Runner.app"

# photos-add first, then full photos (the later grant wins), for the app and the UI-test runner.
for id in "$APP_ID" "$RUNNER_ID"; do
  xcrun simctl privacy "$UDID" grant photos-add "$id"
  xcrun simctl privacy "$UDID" grant photos "$id"
done

xcodebuild test-without-building "${DEST[@]}" -only-testing:MiraiOSUITests
