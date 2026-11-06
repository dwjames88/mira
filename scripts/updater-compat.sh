#!/usr/bin/env bash
# Runs a SHIPPED updater (the MiraUpdates sources of <tag>) against a release JSON, to prove that release is
# picked up by the build users already have.
#
# Usage: scripts/updater-compat.sh <tag> [<release-json-file> | live]
#   <tag>        v0.3.0, v0.3.1, v0.4.0 (v0.2.0 has no updater), or any later tag / ref.
#   <json>       a GitHub "release" API response (default: the repo fixture release-v1.0.0.json).
#   live         fetch https://api.github.com/repos/dwjames88/mira/releases/latest with that tag's own
#                UpdateChecker, then download the chosen asset from the real release (that tag's own
#                UpdateDownloader: size + sha256), unzip it and run that tag's BundleVerifier on it.
# Env: MIRA_COMPAT_CURRENT=<version>  version to pretend to run (default: the tag's own version).
#      MIRA_COMPAT_KEEP=1             keep the scratch dir (printed).
# Prints: current version, detected latest version, chosen asset (+ URL host trusted?), would-update yes/no, and
# in live mode the download and bundle-verification result. Exit 0 iff would-update is yes (and live checks pass).
# Nothing is installed; everything happens in a temp directory.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:?usage: scripts/updater-compat.sh <tag> [<release-json>|live]}"
SRC="${2:-$ROOT/Packages/MiraCore/Tests/MiraUpdatesTests/Fixtures/release-v1.0.0.json}"

if ! git -C "$ROOT" cat-file -e "$TAG:Packages/MiraCore/Sources/MiraUpdates/Release.swift" 2>/dev/null; then
  echo "$TAG has no MiraUpdates updater (builds of $TAG cannot self-update)." >&2; exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/updater-compat.XXXXXX")"
if [ "${MIRA_COMPAT_KEEP:-0}" = 1 ]; then echo "scratch: $WORK"; else trap 'rm -rf "$WORK"' EXIT; fi
mkdir -p "$WORK/tag" "$WORK/cli/Sources/compat"
git -C "$ROOT" archive "$TAG" Packages/MiraCore | tar -x -C "$WORK/tag"

# A tiny package depending on the tag's own MiraUpdates product. Tools version 6.2 / macOS 26 as MiraCore.
cat > "$WORK/cli/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "compat",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "MiraCore", path: "../tag/Packages/MiraCore")],
    targets: [.executableTarget(name: "compat",
        dependencies: [.product(name: "MiraUpdates", package: "MiraCore")],
        swiftSettings: [.swiftLanguageMode(.v5)])]
)
SWIFT

cat > "$WORK/cli/Sources/compat/main.swift" <<'SWIFT'
import Foundation
import MiraUpdates

// args: <tag-version> <json-path|live>
let args = CommandLine.arguments
let tagVersion = args[1], source = args[2]
let currentText = ProcessInfo.processInfo.environment["MIRA_COMPAT_CURRENT"] ?? tagVersion
guard let current = SemanticVersion(currentText) else { print("bad current version \(currentText)"); exit(3) }
func out(_ k: String, _ v: String) { print(k.padding(toLength: 18, withPad: " ", startingAt: 0) + v) }

let release: Release
do {
    if source == "live" {
        out("source", "live \(UpdateChecker.latestReleaseURL.absoluteString)")
        release = try await UpdateChecker().fetchLatest()
    } else {
        out("source", source)
        release = try Release.decode(try Data(contentsOf: URL(fileURLWithPath: source)))
    }
} catch { out("fetch/decode", "FAILED \(error)"); exit(1) }

out("current", current.description)
out("latest", "\(release.version) (tag \(release.tag), prerelease \(release.isPrerelease))")
out("assets", release.assets.map(\.name).joined(separator: ", "))
let asset = release.installableAsset
if let asset {
    out("chosen asset", "\(asset.name) \(asset.size) bytes, sha256 \(asset.sha256 ?? "(none)")")
    out("download url", "\(asset.downloadURL.absoluteString) trusted=\(Release.isTrustedDownloadURL(asset.downloadURL))")
    out("kind", asset.isZip ? "zip (auto-install)" : "dmg (manual hand-off)")
} else { out("chosen asset", "NONE") }
let newer = release.version > current && !release.isPrerelease
let wouldUpdate = newer && asset != nil
out("would update", wouldUpdate ? "YES" : "NO (newer=\(newer), asset=\(asset != nil))")
guard wouldUpdate, let asset, source == "live" else { exit(wouldUpdate ? 0 : 1) }

// Live: download from the real release, verify like the app does.
let work = FileManager.default.temporaryDirectory.appendingPathComponent("compat-live-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: work) }
do {
    let file = work.appendingPathComponent(asset.name)
    try await UpdateDownloader.download(asset, to: file) { _, _ in }
    out("download", "OK, size + sha256 verified")
    guard asset.isZip else { out("verify", "skipped (dmg is a manual install)"); exit(0) }
    let app = try await UpdateInstaller.extractApp(from: file, into: work.appendingPathComponent("x"))
    out("extract", "OK \(app.lastPathComponent)")
    try BundleVerifier.verify(bundleAt: app, version: release.version)
    out("bundle verify", "ACCEPTED (id \(BundleVerifier.bundleIdentifier), team \(BundleVerifier.teamIdentifier), version \(release.version))")
} catch { out("live", "FAILED \(error)"); exit(1) }
SWIFT

# The version to pretend to run: the tag name without its "v" (set MIRA_COMPAT_CURRENT to override).
TAGVER="${TAG#v}"
case "$SRC" in live) ARG2=live ;; *) ARG2="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")" ;; esac
echo "== $TAG: building its MiraUpdates sources =="
# A failed build must stop the script (the grep alone used to hide it and the run died on a missing binary).
if ! (cd "$WORK/cli" && swift build -c release --quiet) >"$WORK/build.log" 2>&1; then
  grep -E "error" "$WORK/build.log" >&2 || tail -20 "$WORK/build.log" >&2
  echo "error: building $TAG's MiraUpdates failed" >&2; exit 1
fi
echo "== $TAG: result =="
"$WORK/cli/.build/release/compat" "$TAGVER" "$ARG2"
