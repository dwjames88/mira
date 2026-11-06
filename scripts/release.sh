#!/usr/bin/env bash
# Builds a signed Release, verifies it and packages Mira.app as zip + dmg. Does not install or publish.
# The in-app updater (MiraUpdates) reads the latest GitHub release and expects: tag v<version>, an asset named
# Mira-<version>.zip holding one top-level Mira.app (the dmg is the fallback), and the release notes as the body.
# This script checks that contract and prints the `gh release create` command; run that yourself to publish.
# Usage: scripts/release.sh [--dry-run] <version>
#   --dry-run  builds and verifies the signed Release app and the zip contract into build/release-dry-run, but writes no
#              DMG and no release notes and prints no publish command. Nothing is tagged, published or notarized either way.
# Env: DERIVED  derived-data directory (default: build/DerivedData).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; shift; fi
VERSION="${1:?usage: scripts/release.sh [--dry-run] <version>}"
DERIVED="${DERIVED:-build/DerivedData}"
OUT="build/release"
[ "$DRY_RUN" = 1 ] && OUT="build/release-dry-run"
APP="$OUT/Mira.app"
APPEX="$APP/Contents/PlugIns/MiraPhotos.appex"
VERIFY="$OUT/verify-$VERSION.txt"
ZIP="$OUT/Mira-$VERSION.zip"
DMG="$OUT/Mira-$VERSION.dmg"
NOTES="$OUT/notes-$VERSION.md"

# The release body is the CHANGELOG section for this version; refuse to ship an empty one (checked first: a build takes minutes).
if ! awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {on=1; next} on && /^## \[/ {exit} on && NF {found=1} END {exit !found}' CHANGELOG.md; then
  if [ "$DRY_RUN" = 1 ]; then
    echo "warning: CHANGELOG.md has no '## [$VERSION]' section with content (a real release would stop here)" >&2
  else
    echo "error: CHANGELOG.md has no '## [$VERSION]' section with content (rename Unreleased first)" >&2; exit 1
  fi
fi

TMPDIRS=()
trap 'rm -rf "${TMPDIRS[@]+"${TMPDIRS[@]}"}"' EXIT

rm -rf "$OUT"; mkdir -p "$OUT"

xcodegen generate
# Generic identity name: the project uses automatic signing, and the team ID selects the Jon Wood certificate.
xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=VF945J28YU \
  MIRA_BUNDLE_PREFIX=com.fieldframes \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  build

ditto "$DERIVED/Build/Products/Release/Mira.app" "$APP"

BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$BUILT" != "$VERSION" ]; then
  echo "error: Info.plist version $BUILT != $VERSION" >&2; exit 1
fi

{
  echo "Mira $VERSION (CFBundleVersion $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
  echo; echo "== codesign --verify --deep --strict =="
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1
  for t in "$APP" "$APPEX"; do
    echo; echo "== codesign -dv $t =="
    codesign -dv --verbose=2 "$t" 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Timestamp|flags|Signature' || true
  done
  echo; echo "== spctl --assess --type execute -vv (rejection expected: not notarized) =="
  spctl --assess --type execute -vv "$APP" 2>&1 || echo "(spctl exit status $?)"
} 2>&1 | tee "$VERIFY"
# verify failure inside the pipeline group would not stop tee; check explicitly
codesign --verify --deep --strict "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"

# Updater contract: the zip has exactly one top-level item, Mira.app, and it unpacks to a validly signed app.
TOP="$(unzip -Z1 "$ZIP" | cut -d/ -f1 | grep -v '^__MACOSX$' | sort -u)"
if [ "$TOP" != "Mira.app" ]; then
  echo "error: $ZIP must contain exactly Mira.app at the top level, found: $TOP" >&2; exit 1
fi
CHECK="$(mktemp -d)"; TMPDIRS+=("$CHECK")
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict -R='anchor apple generic and identifier "com.fieldframes.mira" and certificate leaf[subject.OU] = "VF945J28YU"' "$CHECK/Mira.app"
rm -rf "$CHECK"

if [ "$DRY_RUN" = 1 ]; then
  echo; echo "== dry run: built, verified and zipped $ZIP; no DMG, notes or publish step =="
  du -h "$ZIP"
  exit 0
fi

STAGE="$(mktemp -d)"; TMPDIRS+=("$STAGE")
ditto "$APP" "$STAGE/Mira.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Mira $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

{
  awk -v v="$VERSION" '
    $0 ~ "^## \\[" v "\\]" {on=1; next}
    on && /^## \[/ {exit}
    on {print}' CHANGELOG.md
  echo
  cat <<'INSTALL'
## Install

1. Download the DMG (or zip) and drag **Mira** to Applications.
2. Mira is signed with a free Personal Team development certificate (no Developer ID, not notarized), so macOS blocks the first launch on other Macs. Right-click Mira, choose Open, then Open again; or go to System Settings ▸ Privacy & Security and click "Open Anyway".
3. Development-signed builds may refuse to run at all on a Mac not registered to the team. In that case build from source: `scripts/install.sh` (needs Xcode and XcodeGen; put your own team ID in `Local.xcconfig`, see the README).
4. Enable the extension in System Settings ▸ General ▸ Login Items & Extensions ▸ Photos Editing ▸ Mira, and grant Photos access on first launch.
5. The free-team signature expires after 7 days.
6. Updating from inside Mira (0.3.0 and later): the sandboxed updater cannot clear the quarantine flag on the downloaded app, so macOS may ask once more on the first launch after the update; right-click Mira and choose Open.
INSTALL
} > "$NOTES"

echo; echo "== artifacts =="
du -h "$ZIP" "$DMG"
shasum -a 256 "$ZIP" "$DMG"

echo; echo "== publish (not run) =="
echo "git tag v$VERSION && git push origin v$VERSION   # if the tag does not exist yet"
echo "gh release create v$VERSION \\"
echo "  \"$ZIP\" \"$DMG\" \\"
echo "  --repo dwjames88/mira --title \"Mira $VERSION\" --notes-file \"$NOTES\" --verify-tag"
