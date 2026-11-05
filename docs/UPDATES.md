# In-app updates: what every shipped build accepts

Audited 2026-11-04 against tags v0.2.0, v0.3.0, v0.3.1, v0.4.0 and main (0.5.0 work).

## Which builds can self-update

| Tag | Updater | Notes |
|---|---|---|
| v0.2.0 | none | No `MiraUpdates` target, no `App/Sources/Updates`. Users must install 1.0.0 by hand (DMG/zip from the release page). |
| v0.3.0 | yes, first shipped here | `Packages/MiraCore/Sources/MiraUpdates/*` and `App/Sources/Updates/*` added. |
| v0.3.1 | yes | `git diff v0.3.0 v0.3.1 -- Packages/MiraCore/Sources/MiraUpdates App/Sources/Updates` is empty. |
| v0.4.0 | yes | Same diff against v0.3.0 is empty. |
| main / 0.5.0 | yes | Also identical to v0.3.0. |

So there is exactly one updater implementation in the field. All file:line citations below are valid for v0.3.0,
v0.3.1, v0.4.0 and main (`Packages/MiraCore/Sources/MiraUpdates/` unless noted).

## Audit (identical for v0.3.0, v0.3.1, v0.4.0)

| Aspect | Behaviour | Where |
|---|---|---|
| Lookup endpoint | `GET https://api.github.com/repos/dwjames88/mira/releases/latest` (not the list, not by tag). GitHub never returns drafts or prereleases here, and returns the newest published non-prerelease by creation date. | UpdateChecker.swift:22, 40-41 |
| Request headers | `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`, `User-Agent: Mira-Updater`. 20 s timeout, no auth. HTTP status other than 200 is a failure. | UpdateChecker.swift:31-32, 41-44, 57 |
| Tag format | Parsed by `SemanticVersion`: optional leading `v`/`V`, 1 to 3 numeric parts, optional `-prerelease`, `+build` dropped. `v1.0.0` and `1.0.0` both parse; anything else (e.g. `nightly`) throws and the check fails. | Release.swift:69-71; SemanticVersion.swift:18-42 |
| Draft / prerelease flags | `draft` is decoded but never read. `prerelease == true` makes the check report up to date. | Release.swift:57-58, 85; UpdateChecker.swift:79 |
| Version comparison | `release.version > current` with SemVer precedence (a prerelease sorts below its release; `1.0.0` > `0.4.0`, `0.5.0`). `current` is the app's `CFBundleShortVersionString`. | UpdateChecker.swift:79; SemanticVersion.swift:49-54 |
| Asset selection | Only assets whose `browser_download_url` passes the host check. Zip first: name (case-insensitive) `mira-<version>.zip`, else `mira-<tag minus v>.zip`, else any `.zip` starting with `mira`. Then DMG (`mira-<version>.dmg`, else any `mira*.dmg`). | Release.swift:98-116 |
| What is downloaded | `installableAsset = zipAsset ?? diskImageAsset`. A zip is installed in place; a DMG is only saved to Downloads for a manual install. | Release.swift:116; App/Sources/Updates/UpdateController.swift:158, 195-197 |
| URL used | `browser_download_url` (never the API asset `url`). Assets with an unparseable URL are dropped. | Release.swift:49, 76 |
| Host allow-list | `https` and host `github.com`, `*.github.com`, `githubusercontent.com`, or `*.githubusercontent.com`. Checked on the asset URL (twice: selection and download). It covers `objects.githubusercontent.com` and `release-assets.githubusercontent.com`. Redirects are not re-checked (no redirect delegate), so the CDN hop is followed whatever its host. | Release.swift:91-95; UpdateDownloader.swift:13 |
| Download request | New ephemeral session, `User-Agent: Mira-Updater`, no `Accept` header (default `*/*`; fine for `browser_download_url`), 60 s timeout, non-200 final status fails. | UpdateDownloader.swift:72-73, 114-117 |
| Size limit | None in bytes. If the JSON `size` is > 0 the downloaded file must match it exactly. | UpdateDownloader.swift:28 |
| Checksum | Optional. If the asset JSON has `digest: "sha256:<hex>"` the file must match it; absent digest means no check. | Release.swift:77-81; UpdateDownloader.swift:29 |
| Archive layout | `ditto -x -k`; after ignoring `__MACOSX` and `.DS_Store` the folder must hold exactly one item and it must end in `.app` (name is free, `Mira.app` by convention). | UpdateInstaller.swift:13, 19-25 |
| Bundle checks | From disk: `CFBundleIdentifier == com.fieldframes.mira`; `CFBundleShortVersionString` parses and equals the release version (so Info.plist must say `1.0.0`). | BundleVerifier.swift:8, 30-40 |
| Signature requirement | `anchor apple generic and identifier "com.fieldframes.mira" and certificate leaf[subject.OU] = "VF945J28YU"`, checked with `kSecCSCheckAllArchitectures \| kSecCSStrictValidate \| kSecCSCheckNestedCode` (so the Photos extension inside is validated too). The designated requirement is not consulted; notarization and hardened runtime are not required. Re-run on the staged copy before the swap. | BundleVerifier.swift:9, 12-14, 44-54; App/Sources/Updates/UpdateController.swift:203, 218-222 |
| Skip / throttle | Launch checks run at most once a day and honour a skipped version; manual checks ignore both. | UpdateChecker.swift:65-69, 82 |

Empirical check (2026-11-04): `curl -I` on `https://github.com/dwjames88/mira/releases/download/v0.4.0/Mira-0.4.0.zip`
redirects to `https://release-assets.githubusercontent.com/...`. `scripts/updater-compat.sh v0.4.0 live` (v0.4.0's own
code) downloaded that asset, passed size and SHA-256, unzipped it and accepted the bundle.

## Contract for v1.0.0

All of these must hold for v0.3.0, v0.3.1 and v0.4.0 builds (and 0.5.0+) to update to it:

1. Git tag `v1.0.0`, release published (not draft, not prerelease), and it is the newest non-prerelease release
   (the app asks for `/releases/latest`). Do not publish a later-created non-prerelease release that has no valid assets.
2. Release page URL (`html_url`) present (always true on GitHub).
3. Assets named exactly `Mira-1.0.0.zip` and `Mira-1.0.0.dmg`, uploaded (`state: uploaded`). The zip is what gets
   installed; the DMG is only the fallback. Download URLs must be `https://github.com/dwjames88/mira/releases/download/v1.0.0/<name>`.
4. `Mira-1.0.0.zip` made with `ditto -c -k --keepParent`, with exactly one top-level item: `Mira.app` (no extra README, no
   second app).
5. `Mira.app/Contents/Info.plist`: `CFBundleIdentifier = com.fieldframes.mira`, `CFBundleShortVersionString = 1.0.0`.
6. Code signature valid under strict, nested, all-architecture validation, signing identifier `com.fieldframes.mira`,
   leaf certificate OU `VF945J28YU`, Apple-anchored certificate (Apple Development is accepted).
7. Upload both assets before announcing; size and digest are read from the API at check time, so they must be the final files.
8. Release notes in `body`; the part from `## Install` on is stripped from the update window.

## Compatibility verdict

No incompatibility found. `scripts/release.sh 1.0.0` produces what the contract needs (tag `v<version>`,
`Mira-<version>.zip` with a single `Mira.app`, DMG, Info.plist version check, the same signing requirement verified on
the unpacked zip at release.sh:55-64).

The critical point, the download host: GitHub now redirects asset downloads to `release-assets.githubusercontent.com`.
Every shipped build allows `*.githubusercontent.com` (Release.swift:93-94), and the allow-list is only applied to the
`github.com` URL the app starts from; the redirect target is never checked. So both the old
`objects.githubusercontent.com` and the new host work. Nothing on our side needs a workaround.

Residual risks (none can be fixed in shipped code, all are release hygiene):

- Publishing the release as a draft first and flipping it later is fine; creating it as a prerelease is not (silently
  ignored by every build).
- Any non-prerelease release newer than v1.0.0's creation time (a stray v0.x hotfix) would become "latest" and hide 1.0.0.
- Tag must stay parseable (`v1.0.0`; a name like `release-1.0` breaks every check).
- If the zip is rebuilt after the Info.plist version changes, the in-app install fails on the version check.
- `scripts/release.sh` signs with a free Personal Team Apple Development certificate; the verifier accepts that
  (proved by the live v0.4.0 run above), so no change is needed.

## Testing it

- Unit: `cd Packages/MiraCore && swift test --filter MiraUpdatesTests`. `ReleaseV1FixtureTests` runs the current code on
  `Fixtures/release-v1.0.0.json` (shaped like the real v0.2.0 API response).
- Shipped code: `scripts/updater-compat.sh <tag> [<release.json>|live]`. It extracts `<tag>`'s `Packages/MiraCore`
  with `git archive`, builds a small CLI against that tag's own `MiraUpdates`, and prints the detected latest version,
  chosen asset, URL trust and would-update. With `live` it hits the real `releases/latest`, downloads the chosen asset
  (size and SHA-256 checked by that tag's downloader), unzips and runs that tag's `BundleVerifier`. Use
  `MIRA_COMPAT_CURRENT=<version>` to pretend to be another build. After publishing 1.0.0 run, for each of v0.3.0, v0.3.1
  and v0.4.0: `scripts/updater-compat.sh <tag> live`.
- Current code, live: `MIRA_LIVE_UPDATE=1 swift test --filter LiveUpdateTests` (opt-in; temp dirs only). It is pinned to
  0.2.0 (`LiveUpdateTests.swift:26, 35, 57`), so it fails as soon as a newer release is latest; update those literals when
  1.0.0 is published.
