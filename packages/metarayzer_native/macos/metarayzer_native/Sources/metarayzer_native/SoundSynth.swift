// Procedural sound effects for MetaRayzer (no audio files, no licensing).
//
// KEEP IN SYNC: an identical copy lives in companion_ios/MetaRayzerCompanion/SoundSynth.swift
// (tool/link_selftest.sh checks this).

import AVFoundation
import Foundation

/// Sound ids shared with Dart (lib/src/audio/sound_ids.dart).
enum SoundId: String, CaseIterable {
  case uiHover = "ui_hover"
  case uiSelect = "ui_select"
  case gameStart = "game_start"
  case fireballCast = "fireball_cast"
  case fireballImpact = "fireball_impact"
  case fizzle
  case defeatTroll = "defeat_troll"
  case defeatGoblin = "defeat_goblin"
  case defeatFrog = "defeat_frog"
  case defeatSkeleton = "defeat_skeleton"
  case defeatSlime = "defeat_slime"
  case slimeSplit = "slime_split"
  case spawn
  case telegraph
  case bowDraw = "bow_draw"
  case arrowRelease = "arrow_release"
  case playerHurt = "player_hurt"
  case lightningCast = "lightning_cast"
  case zap
  case unlock
  case spellSwitch = "spell_switch"
  case gameOver = "game_over"
}

/// Generates mono Float32 buffers (for the 3D environment) and a stereo ambient loop.
enum SoundSynth {
  static let sampleRate: Double = 44_100

  static func buffer(for id: SoundId, format: AVAudioFormat) -> AVAudioPCMBuffer {
    let samples = render(id)
    return makeBuffer([samples], format: format)
  }

  /// Seamless stereo ambient loop: wind, a low magical drone and sparse ember crackles.
  static func ambientLoop(format: AVAudioFormat, seconds: Double = 12) -> AVAudioPCMBuffer {
    let n = Int(seconds * sampleRate)
    var channels: [[Float]] = []
    for ch in 0..<2 {
      var rng = SplitMix(seed: UInt64(77 + ch))
      var out = [Float](repeating: 0, count: n)
      var lp: Float = 0, lp2: Float = 0
      for i in 0..<n {
        let t = Double(i) / sampleRate
        // Wind: low-passed noise whose brightness and level slowly breathe (periodic over the loop).
        let gust = 0.55 + 0.45 * sin(2 * .pi * t / seconds * 2 + Double(ch) * 1.7)
        let cutoff = Float(0.004 + 0.012 * gust)
        lp += cutoff * (rng.noise() - lp)
        lp2 += cutoff * (lp - lp2)
        var s = lp2 * Float(3.2 * gust)
        // Drone: 55 Hz + fifth, gentle beating.
        s += Float(0.05 * sin(2 * .pi * 55 * t) + 0.03 * sin(2 * .pi * 82.4 * t + Double(ch)))
        out[i] = s
      }
      // Ember crackles.
      for _ in 0..<Int(seconds * 3) {
        let at = Int(rng.unit() * Double(n - 400))
        let amp = Float(0.05 + 0.08 * rng.unit())
        for k in 0..<300 { out[at + k] += rng.noise() * amp * exp(-Float(k) / 40) }
      }
      channels.append(crossfadeLoop(out, fade: Int(0.5 * sampleRate)))
    }
    return makeBuffer(channels, format: format)
  }

  // MARK: - Recipes

  static func render(_ id: SoundId) -> [Float] {
    // Stable seed (String.hashValue is randomized per process).
    var rng = SplitMix(seed: id.rawValue.unicodeScalars.reduce(UInt64(1)) { $0 &* 31 &+ UInt64($1.value) })
    switch id {
    case .uiHover:
      return tone(0.05, { t in sin(2 * .pi * 1400 * t) }, env: .pluck(0.02), gain: 0.25)
    case .uiSelect:
      return mix(
        tone(0.25, { t in sin(2 * .pi * 880 * t) + 0.3 * sin(2 * .pi * 2640 * t) }, env: .pluck(0.08), gain: 0.35),
        delay(tone(0.3, { t in sin(2 * .pi * 1320 * t) + 0.3 * sin(2 * .pi * 3960 * t) }, env: .pluck(0.1), gain: 0.35), 0.07))
    case .gameStart:
      var out: [Float] = []
      for (i, f) in [523.25, 659.25, 783.99, 1046.5].enumerated() {
        out = mix(out, delay(tone(0.5, { t in sin(2 * .pi * f * t) + 0.25 * sin(2 * .pi * 2 * f * t) }, env: .pluck(0.18), gain: 0.3), Double(i) * 0.09))
      }
      return mix(out, whoosh(0.6, from: 300, to: 2400, gain: 0.25, rng: &rng))
    case .fireballCast:
      return mix(whoosh(0.45, from: 250, to: 1800, gain: 0.6, rng: &rng),
                 tone(0.25, { t in sin(2 * .pi * (90 - 40 * t) * t) }, env: .pluck(0.08), gain: 0.5))
    case .fireballImpact:
      return mix(noiseBurst(0.7, cutoffStart: 0.25, cutoffEnd: 0.02, decay: 0.18, gain: 0.9, rng: &rng),
                 tone(0.4, { t in sin(2 * .pi * (70 - 30 * t) * t) }, env: .pluck(0.12), gain: 0.8))
    case .fizzle:
      return highpass(noiseBurst(0.35, cutoffStart: 0.6, cutoffEnd: 0.3, decay: 0.12, gain: 0.25, rng: &rng), 0.2)
    case .defeatTroll:
      return lowpass(tone(0.6, { t in saw((95 - 40 * t) * t + 0.02 * sin(2 * .pi * 7 * t)) }, env: .swell(0.05, 0.45), gain: 0.45), 0.08)
    case .defeatGoblin:
      return tone(0.3, { t in sin(2 * .pi * ((900 - 1500 * t) * t) + 0.4 * sin(2 * .pi * 30 * t)) }, env: .swell(0.01, 0.25), gain: 0.4)
    case .defeatFrog:
      return tone(0.35, { t in sin(2 * .pi * 150 * t) * (0.5 + 0.5 * sin(2 * .pi * 28 * t)) + 0.3 * sin(2 * .pi * 300 * t) }, env: .swell(0.02, 0.3), gain: 0.55)
    case .defeatSkeleton:
      var out: [Float] = []
      for i in 0..<7 {
        out = mix(out, delay(highpass(noiseBurst(0.04, cutoffStart: 0.9, cutoffEnd: 0.5, decay: 0.01, gain: 0.5, rng: &rng), 0.3), Double(i) * 0.05 + rng.unit() * 0.02))
      }
      return out
    case .defeatSlime, .slimeSplit:
      let squelch = lowpass(noiseBurst(0.3, cutoffStart: 0.15, cutoffEnd: 0.03, decay: 0.08, gain: 0.5, rng: &rng), 0.2)
      let bubble = tone(0.25, { t in sin(2 * .pi * ((id == .slimeSplit ? 500 : 320) - 900 * t) * t) }, env: .pluck(0.08), gain: 0.4)
      return mix(squelch, bubble)
    case .spawn:
      return tone(0.8, { t in (sin(2 * .pi * 1210 * t) + sin(2 * .pi * 1217 * t) + 0.5 * sin(2 * .pi * 2420 * t)) * (0.6 + 0.4 * sin(2 * .pi * 9 * t)) }, env: .swell(0.25, 0.5), gain: 0.12)
    case .telegraph:
      return mix(whoosh(0.4, from: 120, to: 700, gain: 0.35, rng: &rng),
                 lowpass(tone(0.4, { t in saw(70 * t) }, env: .swell(0.25, 0.12), gain: 0.35), 0.1))
    case .bowDraw:
      return lowpass(tone(0.6, { t in Double(rng.noise()) * (0.5 + 0.5 * sin(2 * .pi * 18 * t)) }, env: .swell(0.5, 0.08), gain: 0.25), 0.15)
    case .arrowRelease:
      return mix(tone(0.35, { t in sin(2 * .pi * 210 * t) * exp(-t * 9) }, env: .pluck(0.3), gain: 0.5),
                 highpass(noiseBurst(0.08, cutoffStart: 0.8, cutoffEnd: 0.4, decay: 0.02, gain: 0.3, rng: &rng), 0.3))
    case .playerHurt:
      return mix(tone(0.4, { t in sin(2 * .pi * (60 - 20 * t) * t) }, env: .pluck(0.15), gain: 0.9),
                 lowpass(noiseBurst(0.3, cutoffStart: 0.3, cutoffEnd: 0.05, decay: 0.08, gain: 0.5, rng: &rng), 0.3))
    case .lightningCast:
      var out = whoosh(0.35, from: 800, to: 5000, gain: 0.3, rng: &rng)
      for _ in 0..<14 {
        out = mix(out, delay(highpass(noiseBurst(0.03, cutoffStart: 1, cutoffEnd: 0.6, decay: 0.008, gain: 0.6, rng: &rng), 0.4), rng.unit() * 0.45))
      }
      return out
    case .zap:
      return mix(tone(0.2, { t in square(120 * t) * 0.5 + square(183 * t) * 0.3 }, env: .pluck(0.06), gain: 0.35),
                 highpass(noiseBurst(0.18, cutoffStart: 1, cutoffEnd: 0.5, decay: 0.05, gain: 0.45, rng: &rng), 0.3))
    case .unlock:
      var out: [Float] = []
      for (i, f) in [523.25, 659.25, 783.99, 1046.5, 1318.5, 1568.0].enumerated() {
        out = mix(out, delay(tone(1.0, { t in sin(2 * .pi * f * t) + 0.3 * sin(2 * .pi * 3 * f * t) }, env: .pluck(0.4), gain: 0.22), Double(i) * 0.11))
      }
      return mix(out, tone(1.6, { t in sin(2 * .pi * 2093 * t) * (0.5 + 0.5 * sin(2 * .pi * 11 * t)) }, env: .swell(0.6, 0.9), gain: 0.08))
    case .spellSwitch:
      return mix(whoosh(0.25, from: 600, to: 2000, gain: 0.2, rng: &rng),
                 tone(0.25, { t in sin(2 * .pi * 1046.5 * t) }, env: .pluck(0.1), gain: 0.25))
    case .gameOver:
      var out: [Float] = []
      for (i, f) in [392.0, 349.23, 311.13, 261.63].enumerated() {
        out = mix(out, delay(tone(0.8, { t in sin(2 * .pi * f * t) + 0.4 * sin(2 * .pi * f / 2 * t) }, env: .pluck(0.35), gain: 0.3), Double(i) * 0.28))
      }
      return mix(out, lowpass(tone(2.0, { t in saw(55 * t) }, env: .swell(0.4, 1.4), gain: 0.25), 0.05))
    }
  }

  // MARK: - DSP helpers

  enum Envelope {
    /// Instant attack, exponential decay with the given time constant.
    case pluck(Double)
    /// Linear attack, then exponential release.
    case swell(Double, Double)

    func value(_ t: Double) -> Double {
      switch self {
      case .pluck(let tau): return exp(-t / tau)
      case .swell(let attack, let release): return t < attack ? t / attack : exp(-(t - attack) / release)
      }
    }
  }

  static func tone(_ seconds: Double, _ wave: (Double) -> Double, env: Envelope, gain: Double) -> [Float] {
    let n = Int(seconds * sampleRate)
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
      let t = Double(i) / sampleRate
      // Short fade-out at the end avoids clicks.
      let tail = min(1, Double(n - i) / 200)
      out[i] = Float(wave(t) * env.value(t) * gain * tail)
    }
    return out
  }

  static func whoosh(_ seconds: Double, from: Double, to: Double, gain: Double, rng: inout SplitMix) -> [Float] {
    let n = Int(seconds * sampleRate)
    var out = [Float](repeating: 0, count: n)
    var lp: Float = 0, bp: Float = 0
    for i in 0..<n {
      let p = Double(i) / Double(n)
      let f = from * pow(to / from, p)
      let a = Float(min(0.99, 2 * Double.pi * f / sampleRate))
      lp += a * (rng.noise() - lp)
      bp += a * (lp - bp)
      let env = sin(Double.pi * p)
      out[i] = (lp - bp) * Float(env * gain * 2.5)
    }
    return out
  }

  static func noiseBurst(_ seconds: Double, cutoffStart: Float, cutoffEnd: Float, decay: Double, gain: Double, rng: inout SplitMix) -> [Float] {
    let n = Int(seconds * sampleRate)
    var out = [Float](repeating: 0, count: n)
    var lp: Float = 0
    for i in 0..<n {
      let p = Float(i) / Float(n)
      let c = cutoffStart + (cutoffEnd - cutoffStart) * p
      lp += c * (rng.noise() - lp)
      out[i] = lp * Float(exp(-Double(i) / sampleRate / decay) * gain) * min(1, Float(n - i) / 200)
    }
    return out
  }

  static func lowpass(_ x: [Float], _ a: Float) -> [Float] {
    var y: Float = 0
    return x.map { v in y += a * (v - y); return y * (1 / max(a, 0.05)) * 0.5 }
  }

  static func highpass(_ x: [Float], _ a: Float) -> [Float] {
    var lp: Float = 0
    return x.map { v in lp += a * (v - lp); return v - lp }
  }

  static func delay(_ x: [Float], _ seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * sampleRate)) + x
  }

  static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
    var out = [Float](repeating: 0, count: max(a.count, b.count))
    for i in 0..<a.count { out[i] += a[i] }
    for i in 0..<b.count { out[i] += b[i] }
    return out
  }

  static func saw(_ phase: Double) -> Double { 2 * (phase - floor(phase + 0.5)) }
  static func square(_ phase: Double) -> Double { phase - floor(phase) < 0.5 ? 1 : -1 }

  static func crossfadeLoop(_ x: [Float], fade: Int) -> [Float] {
    var out = Array(x[0..<(x.count - fade)])
    for i in 0..<fade {
      let w = Float(i) / Float(fade)
      out[i] = out[i] * w + x[x.count - fade + i] * (1 - w)
    }
    return out
  }

  static func makeBuffer(_ channels: [[Float]], format: AVAudioFormat) -> AVAudioPCMBuffer {
    let frames = channels.map(\.count).max() ?? 0
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let peak = max(channels.flatMap { $0 }.map(abs).max() ?? 1, 1e-6)
    let norm: Float = peak > 0.95 ? 0.95 / peak : 1 // never clip
    for ch in 0..<Int(format.channelCount) {
      let src = channels[min(ch, channels.count - 1)]
      let dst = buffer.floatChannelData![ch]
      for i in 0..<frames { dst[i] = i < src.count ? src[i] * norm : 0 }
    }
    return buffer
  }
}

/// Small deterministic PRNG so every launch synthesizes identical sounds.
struct SplitMix {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
  mutating func noise() -> Float { Float(unit() * 2 - 1) }
}
