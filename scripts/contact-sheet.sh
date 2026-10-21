#!/bin/bash
# Renders contact sheets of every film (and a first-6 effects sheet) into build/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
INPUT="${1:-Fixtures/sample.jpg}"

swift build -c release --package-path Packages/EmulsionCore --product emulsion-sheet
BIN="$(swift build -c release --package-path Packages/EmulsionCore --show-bin-path)/emulsion-sheet"

mkdir -p build
"$BIN" --films Films --input "$INPUT" --output build/contact-sheet.png

echo
echo "== effects sheet (first 6 films) =="
"$BIN" --films Films --input "$INPUT" --output build/contact-sheet-effects.png --limit 6 \
  --recipe-json '{"grainAmount":0.5,"halationAmount":0.6,"bloomAmount":0.3,"vignetteAmount":0.4}'
