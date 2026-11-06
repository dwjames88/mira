#!/bin/bash
# Headless iOS screenshots: build, boot, install, launch with MIRA_SNAPSHOT=1, capture the framebuffer.
# No taps, no keyboard, no pointer input -- launch + screenshot only.
# Usage: scripts/ios-snapshots.sh [UDID]   (or env UDID; DEVICE_NAME picks by name when no UDID is given).
# SNAP_DISPLAY=1 picks display 1 (multi-display devices such as the "iPhone Duo" type).
# Landscape (simctl cannot rotate a headless simulator): run the UI test CameraOrientationSnapshotTests, e.g.
#   TEST_RUNNER_MIRA_SNAPSHOT_OUT=$PWD/build/snapshots/ios xcodebuild test -scheme MiraiOS -destination "id=<udid>" \
#     -only-testing:MiraiOSUITests/CameraOrientationSnapshotTests CODE_SIGNING_ALLOWED=NO   # writes camera-portrait/-landscape.png
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/snapshots/ios"
DERIVED="${DERIVED:-$(mktemp -d "${TMPDIR:-/tmp}/mira-ios-snap.XXXXXX")}"
BUNDLE_ID="com.fieldframes.mira.ios"
DEVICE_NAME="${DEVICE_NAME:-iPhone 17}"
SETTLE="${SETTLE:-4}"

mkdir -p "$OUT"

# Simulator: pass a UDID (first argument or env UDID) to use that exact device, else the first available device named
# $DEVICE_NAME, else create one on the newest iOS runtime. The iOS 27.0 runtime is never used (PosterBoard crash-loops
# there): a UDID on it is refused, and it is skipped when picking by name or creating.
#
# One line per available iOS device: "<udid><TAB><runtime>"<TAB>"<name>", e.g. "53F8...<TAB>iOS 27.2<TAB>iPhone 17".
list_devices() {
  xcrun simctl list devices available | awk '
    /^-- .* --$/ { runtime = $0; sub(/^-- /, "", runtime); sub(/ --$/, "", runtime); next }
    runtime ~ /^iOS / && match($0, /\([0-9A-Fa-f]+(-[0-9A-Fa-f]+)+\)/) {
      udid = substr($0, RSTART + 1, RLENGTH - 2)
      name = substr($0, 1, RSTART - 2); sub(/^ +/, "", name)
      print udid "\t" runtime "\t" name
    }'
}
is_banned_runtime() { [[ "$1" =~ ^iOS\ 27\.0($|[^0-9]) ]]; }

UDID="${1:-${UDID:-}}"
if [ -n "$UDID" ]; then
  case "$UDID" in F7DAA9B9*) echo "Refusing to use the iOS 27.0 runtime device $UDID" >&2; exit 1;; esac
  LINE="$(list_devices | grep -i -F "$UDID" | head -1 || true)"
  [ -n "$LINE" ] || { echo "No available iOS simulator with UDID $UDID" >&2; exit 1; }
  RUNTIME_OF="$(cut -f2 <<<"$LINE")"
  if is_banned_runtime "$RUNTIME_OF"; then echo "Refusing to use $UDID: it is on $RUNTIME_OF" >&2; exit 1; fi
  DEVICE_NAME="$(cut -f3 <<<"$LINE")"
else
  UDID=""
  while IFS=$'\t' read -r candidate runtime name; do
    if [ "$name" = "$DEVICE_NAME" ] && ! is_banned_runtime "$runtime"; then UDID="$candidate"; break; fi
  done < <(list_devices)
  if [ -z "$UDID" ]; then
    RUNTIME="$(xcrun simctl list runtimes available | grep -E '^iOS ' | grep -v -E '^iOS 27\.0( |$)' | tail -1 | sed -E 's/.* - //' || true)"
    [ -n "$RUNTIME" ] || { echo "No usable iOS runtime (27.0 is excluded)" >&2; exit 1; }
    UDID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_NAME" "$RUNTIME")"
  fi
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

shoot() { # name [tab] [sheet] [detail] [focus] [hidden]
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  SIMCTL_CHILD_MIRA_SNAPSHOT=1 SIMCTL_CHILD_MIRA_SNAPSHOT_TAB="${2:-develop}" SIMCTL_CHILD_MIRA_SNAPSHOT_SHEET="${3:-}" \
    SIMCTL_CHILD_MIRA_SNAPSHOT_DETAIL="${4:-}" SIMCTL_CHILD_MIRA_SNAPSHOT_FOCUS="${5:-}" SIMCTL_CHILD_MIRA_SNAPSHOT_HIDDEN="${6:-}" \
    xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  sleep "$SETTLE"
  xcrun simctl io "$UDID" screenshot ${SNAP_DISPLAY:+--display=$SNAP_DISPLAY} "$OUT/$1.png" >/dev/null 2>&1
  echo "$OUT/$1.png ($(stat -f%z "$OUT/$1.png") bytes)"
}

# Editor shots first: the gallery launch below raises a system permission prompt that would otherwise sit over them.
shoot editor-develop develop
shoot editor-films films
shoot films-presets films
shoot save-preset films savepreset
shoot films-options films "" 1
shoot films-hidden films "" "" "" 1
shoot develop-curves develop "" "" curves
shoot develop-curves-hidden develop "" "" curves 1
# Camera with the fake source (no camera permission prompt). Landscape cannot be shot headless (no rotation without input).
shoot camera camera

# Gallery: grant Photos headlessly (no taps), launch normally, let thumbnails load.
# photos-add first, then full photos last: the later grant wins (the reverse leaves add-only + a prompt).
# Seed a few pictures so the album list / grid have content (headless; no taps).
SEED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mira-seed.XXXXXX")"
for f in "$ROOT"/Fixtures/*.jpg; do [ -f "$f" ] && cp "$f" "$SEED_DIR/" || true; done
if [ -n "$(ls -A "$SEED_DIR")" ]; then xcrun simctl addmedia "$UDID" "$SEED_DIR"/* 2>/dev/null || true; fi

xcrun simctl privacy "$UDID" reset photos "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl privacy "$UDID" grant photos-add "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl privacy "$UDID" grant photos "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
SIMCTL_CHILD_MIRA_LAUNCH_SCREEN=gallery xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
sleep "${GALLERY_SETTLE:-6}"
xcrun simctl io "$UDID" screenshot ${SNAP_DISPLAY:+--display=$SNAP_DISPLAY} "$OUT/gallery.png" >/dev/null 2>&1
echo "$OUT/gallery.png ($(stat -f%z "$OUT/gallery.png") bytes)"
# The root screen is the album list (a pushed grid needs a tap, which this script never does).
# If the sim honors the grant it shows the album list; otherwise the system permission prompt over the chrome.
cp "$OUT/gallery.png" "$OUT/albums.png"
echo "$OUT/albums.png"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
