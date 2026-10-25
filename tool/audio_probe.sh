#!/bin/bash
# Offline (no speakers) checks of the game's spatial audio engine and synthesized sounds.
#   tool/audio_probe.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/packages/metarayzer_native/macos/metarayzer_native/Sources/metarayzer_native"
mkdir -p "$ROOT/build"
swiftc -O -module-name audio_probe -o "$ROOT/build/audio_probe" \
  "$ROOT/tool/audio_probe/main.swift" "$SRC/SpatialAudioEngine.swift" "$SRC/SoundSynth.swift"
exec "$ROOT/build/audio_probe"
