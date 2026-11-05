#!/usr/bin/env bash
# Rebuilds Films/Packed/<id>.mlut from the Hald PNGs in FilmSources/ (run scripts/fetch-film-sources.sh first).
# Deterministic: on unchanged sources it leaves `git status` clean.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -d FilmSources/HaldCLUT ] || { echo "error: FilmSources/ is missing; run scripts/fetch-film-sources.sh first" >&2; exit 1; }
exec swift run -c release --package-path Packages/MiraCore mira-sheet --pack-films FilmSources Films --fixtures-dir Fixtures
