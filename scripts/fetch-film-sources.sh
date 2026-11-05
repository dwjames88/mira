#!/usr/bin/env bash
# Fetches the original Hald CLUT PNGs that Films/Packed was built from (RawTherapee Film Simulation Collection,
# Pat David et al., CC BY-SA 4.0) and writes them, renamed, to FilmSources/HaldCLUT/<id>.png.
# You only need this to rebuild the packed cubes (scripts/pack-films.sh) or to run the tests that compare them
# with their PNGs; building and running the apps does not need it.
#
#   scripts/fetch-film-sources.sh
#
# Environment:
#   MIRA_FILM_SOURCES_DIR   output directory (default: FilmSources in the repository root)
#   MIRA_HALDCLUT_ZIP       use this local copy of HaldCLUT.zip instead of downloading (still checked by SHA-256)
#
# The archive is checked against ARCHIVE_SHA256 before anything is unpacked, and every PNG written is checked against
# FilmSources.sha256. Nothing from the archive is executed: it is only unzipped and the PNGs copied.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

URL="https://rawtherapee.com/shared/HaldCLUT.zip"
ARCHIVE_SHA256="0ffca81f30c72d7bbb85adab0ed98bbdeb0e1034cd6f5986f9f993bb66999dc2"
OUT="${MIRA_FILM_SOURCES_DIR:-$ROOT/FilmSources}"
MANIFEST="$ROOT/FilmSources.sha256"
FILMS_JSON="$ROOT/Films/films.json"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mira-hald.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ZIP="$WORK/HaldCLUT.zip"
if [ -n "${MIRA_HALDCLUT_ZIP:-}" ]; then
  cp "$MIRA_HALDCLUT_ZIP" "$ZIP"
else
  echo "Downloading $URL (about 420 MB)..."
  curl --fail --location --proto '=https' --tlsv1.2 --progress-bar -o "$ZIP" "$URL"
fi

ACTUAL="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$ARCHIVE_SHA256" ]; then
  echo "error: HaldCLUT.zip SHA-256 is $ACTUAL, expected $ARCHIVE_SHA256. Not unpacking." >&2
  exit 1
fi

mkdir "$WORK/unzipped"
unzip -q "$ZIP" -d "$WORK/unzipped"

mkdir -p "$OUT/HaldCLUT"
/usr/bin/env python3 -I - "$FILMS_JSON" "$WORK/unzipped" "$OUT" <<'PY'
import json, os, shutil, sys
films_json, extracted, out = sys.argv[1:4]
extracted = os.path.realpath(extracted)
films = json.load(open(films_json))
count = 0
for film in films:
    png, source = film.get("png"), film.get("source")
    if not png or not source:
        continue                       # procedural films have no source file
    src = os.path.realpath(os.path.join(extracted, source))
    if os.path.commonpath([src, extracted]) != extracted or not os.path.isfile(src):
        sys.exit("error: %s is missing from the archive (%s)" % (film["id"], source))
    dst = os.path.join(out, png)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    count += 1
print("Copied %d PNGs to %s" % (count, os.path.join(out, "HaldCLUT")))
PY

echo "Verifying against FilmSources.sha256..."
(cd "$OUT" && shasum -a 256 -c "$MANIFEST" --quiet) && echo "All PNGs match the manifest."
