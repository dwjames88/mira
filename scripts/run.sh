#!/usr/bin/env bash
# Builds a Debug copy of Emulsion into build/DerivedData and opens it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

xcodegen generate
xcodebuild -project Emulsion.xcodeproj -scheme Emulsion -configuration Debug \
  -derivedDataPath build/DerivedData build

open "build/DerivedData/Build/Products/Debug/Emulsion.app"
