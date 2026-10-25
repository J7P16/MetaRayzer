#!/bin/sh
# Builds and runs the Vision hand-detector probe against image files.
#   tool/vision_probe.sh photo1.jpg photo2.jpg
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/packages/metarayzer_native/macos/metarayzer_native/Sources/metarayzer_native"
OUT="$ROOT/build/vision_probe"
mkdir -p "$ROOT/build"
swiftc -O -module-name vision_probe -o "$OUT" \
  "$ROOT/tool/vision_probe/main.swift" "$SRC/HandDetector.swift" "$SRC/FramePipeline.swift"
exec "$OUT" "$@"
