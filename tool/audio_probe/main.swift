// Offline verification of the game's audio engine (SpatialAudioEngine + SoundSynth), rendered
// without speakers via AVAudioEngine manual rendering. Checks that every sound synthesizes,
// that left/right placement and distance attenuation work in both stereo and binaural modes,
// and the sign of the listener-yaw rotation. Run with tool/audio_probe.sh.

import AVFoundation
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
  print(ok ? "PASS  \(what)" : "FAIL  \(what)")
  if !ok { failures += 1 }
}

/// Renders [seconds] of audio after scheduling [setup]; returns (left energy, right energy).
func render(mode: SpatialAudioEngine.Mode, seconds: Double = 0.6, _ setup: (SpatialAudioEngine) -> Void) -> (Double, Double) {
  let a = SpatialAudioEngine()
  a.setMode(mode)
  let format = AVAudioFormat(standardFormatWithSampleRate: SoundSynth.sampleRate, channels: 2)!
  try! a.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
  try! a.start()
  setup(a)
  let out = AVAudioPCMBuffer(pcmFormat: a.engine.manualRenderingFormat, frameCapacity: 4096)!
  var l = 0.0, r = 0.0
  var remaining = Int(seconds * SoundSynth.sampleRate)
  while remaining > 0 {
    let n = AVAudioFrameCount(min(4096, remaining))
    _ = try! a.engine.renderOffline(n, to: out)
    let ch = out.floatChannelData!
    for i in 0..<Int(out.frameLength) {
      l += Double(ch[0][i] * ch[0][i])
      r += Double(ch[1][i] * ch[1][i])
    }
    remaining -= Int(n)
  }
  a.stop()
  return (l, r)
}

func db(_ x: Double) -> String { String(format: "%.1f dB", 10 * log10(max(x, 1e-12))) }

// 1. Every sound synthesizes, is non-silent and never clips.
let mono = AVAudioFormat(standardFormatWithSampleRate: SoundSynth.sampleRate, channels: 1)!
var bad: [String] = []
for id in SoundId.allCases {
  let b = SoundSynth.buffer(for: id, format: mono)
  let s = UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))
  let peak = s.map(abs).max() ?? 0
  if b.frameLength == 0 || peak < 0.01 || peak > 1.0 { bad.append("\(id.rawValue) (peak \(peak))") }
}
check(bad.isEmpty, "all \(SoundId.allCases.count) synthesized sounds are audible and unclipped \(bad)")
let ambient = SoundSynth.ambientLoop(format: AVAudioFormat(standardFormatWithSampleRate: SoundSynth.sampleRate, channels: 2)!)
check(ambient.frameLength > 0, "ambient loop synthesizes (\(Double(ambient.frameLength) / SoundSynth.sampleRate) s, stereo)")

// Stereo panning separates by level strongly. HRTF (binaural) localizes mainly by timing and
// spectral cues, so its broadband level difference is smaller: use a broadband sound and a
// lower (but still clearly lateral) threshold there.
for mode in [SpatialAudioEngine.Mode.stereo, .binaural] {
  let sound: SoundId = mode == .stereo ? .fireballImpact : .zap
  let factor = mode == .stereo ? 2.0 : 1.4
  let right = render(mode: mode) { $0.play(sound, x: 6, y: 1, z: 4, gain: 1) }
  let left = render(mode: mode) { $0.play(sound, x: -6, y: 1, z: 4, gain: 1) }
  let center = render(mode: mode) { $0.play(sound, x: 0, y: 1, z: 6, gain: 1) }
  check(right.1 > right.0 * factor, "[\(mode)] enemy on the right is louder in the right ear (L \(db(right.0)), R \(db(right.1)))")
  check(left.0 > left.1 * factor, "[\(mode)] enemy on the left is louder in the left ear (L \(db(left.0)), R \(db(left.1)))")
  let ratio = center.0 / center.1
  check(ratio > 0.7 && ratio < 1.4, "[\(mode)] enemy straight ahead is centered (L/R \(String(format: "%.2f", ratio)))")
  let near = render(mode: mode) { $0.play(.zap, x: 0, y: 1, z: 3, gain: 1) }
  let far = render(mode: mode) { $0.play(.zap, x: 0, y: 1, z: 28, gain: 1) }
  check(near.0 + near.1 > (far.0 + far.1) * 4, "[\(mode)] near enemies are louder than distant ones (near \(db(near.0 + near.1)), far \(db(far.0 + far.1)))")
}

// 3. Listener yaw: looking 40° to the right, a sound straight ahead must come from the left.
let turned = render(mode: .stereo) { a in
  a.setListenerYaw(radians: 40 * .pi / 180)
  a.play(.fireballImpact, x: 0, y: 1, z: 6, gain: 1)
}
check(turned.0 > turned.1 * 2, "turning the view right moves a straight-ahead sound to the left ear (L \(db(turned.0)), R \(db(turned.1)))")

// 4. Volume control.
let quiet = render(mode: .stereo) { a in
  a.setVolumes(sfx: 0.1, ambient: 0)
  a.play(.fireballImpact, x: 0, y: 1, z: 4, gain: 1)
}
let loud = render(mode: .stereo) { a in
  a.setVolumes(sfx: 1, ambient: 0)
  a.play(.fireballImpact, x: 0, y: 1, z: 4, gain: 1)
}
check(loud.0 > quiet.0 * 20, "SFX volume scales output (\(db(quiet.0)) at 0.1 vs \(db(loud.0)) at 1.0)")

print(failures == 0 ? "\nALL AUDIO CHECKS PASSED" : "\n\(failures) AUDIO CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
