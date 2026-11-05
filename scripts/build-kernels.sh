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
  # iOS needs its own metallib: the macOS one carries a macosx target triple and does not load on iOS.
  xcrun -sdk iphoneos metal -fcikernel -c -mios-version-min=18.0 "$file" -o "$TMP/$name.ci.ios.air"
  xcrun -sdk iphoneos metallib -cikernel "$TMP/$name.ci.ios.air" -o "$OUT/$name.ci.ios.metallib"
  echo "built $OUT/$name.ci.ios.metallib"
  xcrun -sdk iphonesimulator metal -fcikernel -c -mios-simulator-version-min=18.0 "$file" -o "$TMP/$name.ci.iossim.air"
  xcrun -sdk iphonesimulator metallib -cikernel "$TMP/$name.ci.iossim.air" -o "$OUT/$name.ci.iossim.metallib"
  echo "built $OUT/$name.ci.iossim.metallib"
done
