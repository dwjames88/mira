#!/usr/bin/env bash
# Compiles the Core Image Metal kernels (Packages/MiraCore/Kernels/*.ci.metal) into the
# metallib that MiraCore loads from its resource bundle. The result is checked in, so a normal
# `swift build` / `xcodebuild` never needs the Metal toolchain; run this after editing a kernel.
#
# Needs the Metal toolchain (Xcode: `xcodebuild -downloadComponent MetalToolchain`).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Packages/MiraCore/Kernels"
OUT="$ROOT/Packages/MiraCore/Sources/MiraCore/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

for file in "$SRC"/*.ci.metal; do
  name="$(basename "$file" .ci.metal)"
  xcrun -sdk macosx metal -fcikernel -c -mmacosx-version-min=26.0 "$file" -o "$TMP/$name.ci.air"
  xcrun -sdk macosx metallib -cikernel "$TMP/$name.ci.air" -o "$OUT/$name.ci.metallib"
  echo "built $OUT/$name.ci.metallib"
done
