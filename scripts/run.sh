#!/usr/bin/env bash
# Builds a Debug copy of Mira into build/DerivedData and opens it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

xcodegen generate
xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug \
  -derivedDataPath build/DerivedData build

open "build/DerivedData/Build/Products/Debug/Mira.app"
