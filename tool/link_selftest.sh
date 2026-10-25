#!/bin/bash
# Loopback integration test of the phone <-> Mac link using the real Swift sources from both the
# macOS plugin and the iPhone companion. No phone, glasses or Flutter needed.
#   tool/link_selftest.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC="$ROOT/packages/metarayzer_native/macos/metarayzer_native/Sources/metarayzer_native"
PHONE="$ROOT/companion_ios/MetaRayzerCompanion"

# The two WireProtocol.swift copies must stay identical apart from the "keep in sync" header.
if ! diff <(tail -n +7 "$MAC/WireProtocol.swift") <(tail -n +7 "$PHONE/WireProtocol.swift") >/dev/null 2>&1; then
  echo "FAIL  WireProtocol.swift copies differ between the Mac plugin and the companion" >&2
  exit 1
fi
echo "PASS  WireProtocol.swift copies are in sync"

mkdir -p "$ROOT/build"
swiftc -O -module-name link_selftest -o "$ROOT/build/link_selftest" \
  "$ROOT/tool/link_selftest/main.swift" "$MAC/WireProtocol.swift" "$MAC/FrameServer.swift" "$PHONE/FrameSender.swift"
exec "$ROOT/build/link_selftest"
