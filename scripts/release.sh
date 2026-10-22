#!/usr/bin/env bash
# Builds a signed Release, verifies it and packages Mira.app as zip + dmg. Does not install or publish.
# The in-app updater (MiraUpdates) reads the latest GitHub release and expects: tag v<version>, an asset named
# Mira-<version>.zip holding one top-level Mira.app (the dmg is the fallback), and the release notes as the body.
# This script checks that contract and prints the `gh release create` command; run that yourself to publish.
# Usage: scripts/release.sh <version>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?usage: scripts/release.sh <version>}"
OUT="build/release"
APP="$OUT/Mira.app"
APPEX="$APP/Contents/PlugIns/MiraPhotos.appex"
VERIFY="$OUT/verify-$VERSION.txt"
ZIP="$OUT/Mira-$VERSION.zip"
DMG="$OUT/Mira-$VERSION.dmg"
NOTES="$OUT/notes-$VERSION.md"

rm -rf "$OUT"; mkdir -p "$OUT"

xcodegen generate
# Generic identity name: the project uses automatic signing, and the team ID selects the Jon Wood certificate.
xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=VF945J28YU \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  build

ditto build/DerivedData/Build/Products/Release/Mira.app "$APP"

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
CHECK="$(mktemp -d)"
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict -R='anchor apple generic and identifier "com.fieldframes.mira" and certificate leaf[subject.OU] = "VF945J28YU"' "$CHECK/Mira.app"
rm -rf "$CHECK"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
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
3. Development-signed builds may refuse to run at all on a Mac not registered to the team. In that case build from source: `scripts/install.sh` (needs Xcode, XcodeGen and your own team ID in `project.yml`).
4. Enable the extension in System Settings ▸ General ▸ Login Items & Extensions ▸ Photos Editing ▸ Mira, and grant Photos access on first launch.
5. The free-team signature expires after 7 days.
INSTALL
} > "$NOTES"

# The release body is the CHANGELOG section for this version; refuse to ship an empty one.
if ! awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {on=1; next} on && /^## \[/ {exit} on && NF {found=1} END {exit !found}' CHANGELOG.md; then
  echo "error: CHANGELOG.md has no '## [$VERSION]' section with content (rename Unreleased first)" >&2; exit 1
fi

echo; echo "== artifacts =="
du -h "$ZIP" "$DMG"
shasum -a 256 "$ZIP" "$DMG"

echo; echo "== publish (not run) =="
echo "git tag v$VERSION && git push origin v$VERSION   # if the tag does not exist yet"
echo "gh release create v$VERSION \\"
echo "  \"$ZIP\" \"$DMG\" \\"
echo "  --repo dwjames88/mira --title \"Mira $VERSION\" --notes-file \"$NOTES\" --verify-tag"
