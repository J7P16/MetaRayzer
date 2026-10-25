#!/bin/bash
# Loopback integration test of the phone <-> Mac link using the real Swift sources from both the
# macOS plugin and the iPhone companion. No phone, glasses or Flutter needed.
#   tool/link_selftest.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC="$ROOT/packages/metarayzer_native/macos/metarayzer_native/Sources/metarayzer_native"
PHONE="$ROOT/companion_ios/MetaRayzerCompanion"

# Shared Swift files must stay identical apart from their "keep in sync" header lines.
for f in WireProtocol.swift SoundSynth.swift SpatialAudioEngine.swift; do
  # Compare from the first import on (the header comments point at each other on purpose).
  if ! diff <(sed -n '/^import /,$p' "$MAC/$f") <(sed -n '/^import /,$p' "$PHONE/$f") >/dev/null 2>&1; then
    echo "FAIL  $f differs between the Mac plugin and the companion" >&2
    exit 1
  fi
  echo "PASS  $f copies are in sync"
done

mkdir -p "$ROOT/build"
swiftc -O -module-name link_selftest -o "$ROOT/build/link_selftest" \
  "$ROOT/tool/link_selftest/main.swift" "$MAC/WireProtocol.swift" "$MAC/FrameServer.swift" "$PHONE/FrameSender.swift"
exec "$ROOT/build/link_selftest"
