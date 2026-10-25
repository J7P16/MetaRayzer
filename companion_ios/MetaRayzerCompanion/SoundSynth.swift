// Procedural sound effects for MetaRayzer (no audio files, no licensing).
//
// KEEP IN SYNC: an identical copy lives in packages/metarayzer_native/.../SoundSynth.swift
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
  // Version 4.
  case shieldUp = "shield_up"
  case shieldBlock = "shield_block"
  case shieldFade = "shield_fade"
  case archerWarn = "archer_warn"
  case projectileMiss = "projectile_miss"
  case bossCharge = "boss_charge"
  case bossBolt = "boss_bolt"
  case bossAppear = "boss_appear"
  case bossDefeat = "boss_defeat"
  case nightFall = "night_fall"
  case dawn
  case tutorialSuccess = "tutorial_success"
}

/// Background music tracks shared with Dart (MusicTracks in lib/src/audio/audio_service.dart).
enum MusicTrack: String, CaseIterable {
  case menu, day, night
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
    case .shieldUp:
      // Bright rising shimmer: the shield snaps on.
      return mix(whoosh(0.25, from: 900, to: 4200, gain: 0.25, rng: &rng),
                 tone(0.45, { t in (sin(2 * .pi * 880 * t) + 0.6 * sin(2 * .pi * 1320 * t) + 0.3 * sin(2 * .pi * 1767 * t)) * (1 + 0.3 * sin(2 * .pi * 24 * t)) }, env: .swell(0.02, 0.18), gain: 0.22))
    case .shieldBlock:
      // Glassy clang + spark: a projectile stopped.
      var out = tone(0.7, { t in sin(2 * .pi * 1046.5 * t) + 0.7 * sin(2 * .pi * 1568 * t) + 0.5 * sin(2 * .pi * 2637 * t) + 0.3 * sin(2 * .pi * 3951 * t) }, env: .pluck(0.16), gain: 0.32)
      out = mix(out, highpass(noiseBurst(0.12, cutoffStart: 1, cutoffEnd: 0.6, decay: 0.03, gain: 0.6, rng: &rng), 0.35))
      return mix(out, tone(0.25, { t in sin(2 * .pi * (180 - 80 * t) * t) }, env: .pluck(0.06), gain: 0.5))
    case .shieldFade:
      return tone(0.35, { t in sin(2 * .pi * (1320 - 700 * t) * t) * 0.6 }, env: .swell(0.02, 0.15), gain: 0.18)
    case .archerWarn:
      // Two sharp rising "incoming!" pips over a bone rattle: distinct from every other cue.
      var out: [Float] = []
      for i in 0..<2 {
        out = mix(out, delay(tone(0.12, { t in square((1200 + 1400 * t * 8) * t) * 0.5 }, env: .pluck(0.05), gain: 0.22), Double(i) * 0.14))
      }
      for i in 0..<6 {
        out = mix(out, delay(highpass(noiseBurst(0.03, cutoffStart: 0.8, cutoffEnd: 0.5, decay: 0.008, gain: 0.35, rng: &rng), 0.3), 0.3 + Double(i) * 0.035))
      }
      return out
    case .projectileMiss:
      return whoosh(0.4, from: 2600, to: 500, gain: 0.3, rng: &rng)
    case .bossCharge:
      // Rising unearthly choir tone over the telegraph.
      return mix(tone(1.3, { t in (sin(2 * .pi * (110 + 160 * t) * t) + 0.5 * sin(2 * .pi * (165 + 240 * t) * t)) * (0.6 + 0.4 * sin(2 * .pi * 6 * t)) }, env: .swell(1.1, 0.15), gain: 0.3),
                 whoosh(1.3, from: 200, to: 1600, gain: 0.18, rng: &rng))
    case .bossBolt:
      return mix(tone(0.6, { t in saw((220 - 150 * t) * t) * 0.6 + sin(2 * .pi * (110 - 50 * t) * t) }, env: .pluck(0.2), gain: 0.4),
                 whoosh(0.5, from: 300, to: 2000, gain: 0.3, rng: &rng))
    case .bossAppear:
      // Low horn swell and a dissonant cluster: a boss has arrived.
      var out = lowpass(tone(2.4, { t in saw(55 * t) + saw(55.4 * t) + 0.6 * saw(82.4 * t) }, env: .swell(0.6, 1.2), gain: 0.4), 0.06)
      for (i, f) in [233.08, 246.94, 329.63].enumerated() {
        out = mix(out, delay(tone(1.6, { t in sin(2 * .pi * f * t) * (0.7 + 0.3 * sin(2 * .pi * 5 * t)) }, env: .swell(0.3, 0.9), gain: 0.14), 0.25 + Double(i) * 0.12))
      }
      return out
    case .bossDefeat:
      // Shattering bones, then a triumphant major arpeggio.
      var out = lowpass(noiseBurst(1.0, cutoffStart: 0.5, cutoffEnd: 0.02, decay: 0.3, gain: 0.7, rng: &rng), 0.3)
      for i in 0..<10 {
        out = mix(out, delay(highpass(noiseBurst(0.05, cutoffStart: 0.9, cutoffEnd: 0.5, decay: 0.012, gain: 0.45, rng: &rng), 0.3), Double(i) * 0.06 + rng.unit() * 0.03))
      }
      for (i, f) in [392.0, 493.88, 587.33, 783.99, 987.77].enumerated() {
        out = mix(out, delay(tone(1.0, { t in sin(2 * .pi * f * t) + 0.3 * sin(2 * .pi * 2 * f * t) }, env: .pluck(0.35), gain: 0.22), 0.6 + Double(i) * 0.1))
      }
      return out
    case .nightFall:
      return mix(lowpass(tone(2.2, { t in saw(73.42 * t) + saw(73.8 * t) }, env: .swell(0.8, 1.0), gain: 0.3), 0.05),
                 tone(2.0, { t in sin(2 * .pi * (587.33 - 120 * t) * t) * 0.5 }, env: .swell(0.4, 1.0), gain: 0.12))
    case .dawn:
      var out: [Float] = []
      for (i, f) in [293.66, 369.99, 440.0, 587.33].enumerated() {
        out = mix(out, delay(tone(1.4, { t in sin(2 * .pi * f * t) + 0.25 * sin(2 * .pi * 2 * f * t) }, env: .swell(0.15, 0.8), gain: 0.18), Double(i) * 0.16))
      }
      return out
    case .tutorialSuccess:
      var out: [Float] = []
      for (i, f) in [659.25, 783.99, 1046.5].enumerated() {
        out = mix(out, delay(tone(0.5, { t in sin(2 * .pi * f * t) + 0.3 * sin(2 * .pi * 3 * f * t) }, env: .pluck(0.2), gain: 0.28), Double(i) * 0.08))
      }
      return out
    }
  }

  // MARK: - Music

  /// A seamless stereo loop for [track] (see [MusicSynth]).
  static func music(_ track: MusicTrack, format: AVAudioFormat) -> AVAudioPCMBuffer {
    makeBuffer(MusicSynth.render(track), format: format)
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

/// A tiny sequencer for the background music: chord pads, a bass line, an arpeggio and (for the
/// gameplay tracks) light percussion. Notes that ring past the end of the loop wrap around to
/// its start, so every track loops without a seam.
enum MusicSynth {
  struct Score {
    let bpm: Double
    /// One chord (MIDI notes) per bar.
    let chords: [[Int]]
    /// Arpeggio steps per beat (0 = none) and the octave shift applied to it.
    let arpPerBeat: Int
    let arpOctave: Int
    /// Bass notes per bar (on the beat).
    let bassPerBar: Int
    let drums: Bool
    let padGain: Double
    let darkness: Double
  }

  static func score(_ track: MusicTrack) -> Score {
    switch track {
    case .menu:
      // Calm, mysterious: Am – F – C – G, slow arpeggio, no drums.
      return Score(bpm: 72, chords: [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]], arpPerBeat: 2, arpOctave: 12, bassPerBar: 1, drums: false, padGain: 0.16, darkness: 0.3)
    case .day:
      // Driving but bright: Dm – C – Bb – C, eighth-note arpeggio, light kick/hat.
      return Score(bpm: 104, chords: [[50, 53, 57], [48, 52, 55], [46, 50, 53], [48, 52, 55], [50, 53, 57], [48, 52, 55], [46, 50, 53], [45, 49, 52]], arpPerBeat: 2, arpOctave: 12, bassPerBar: 4, drums: true, padGain: 0.12, darkness: 0.2)
    case .night:
      // The boss: E Phrygian ostinato, low and tense, heavier drums.
      return Score(bpm: 128, chords: [[40, 43, 47], [41, 45, 48], [40, 43, 47], [38, 42, 45], [40, 43, 47], [41, 45, 48], [43, 46, 50], [41, 44, 48]], arpPerBeat: 4, arpOctave: 12, bassPerBar: 8, drums: true, padGain: 0.13, darkness: 0.6)
    }
  }

  static func hz(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

  static func render(_ track: MusicTrack) -> [[Float]] {
    let sc = score(track)
    let sr = SoundSynth.sampleRate
    let beat = 60 / sc.bpm
    let bar = beat * 4
    let n = Int((bar * Double(sc.chords.count) * sr).rounded())
    var left = [Float](repeating: 0, count: n), right = [Float](repeating: 0, count: n)
    var rng = SplitMix(seed: UInt64(track.rawValue.unicodeScalars.reduce(7) { $0 &* 131 &+ UInt64($1.value) }))

    /// Adds a note starting at [at] seconds, wrapping past the loop end.
    func add(_ at: Double, _ seconds: Double, pan: Double, gain: Double, _ wave: (Double) -> Double) {
      let start = Int(at * sr), count = Int(seconds * sr)
      let gl = Float(gain * sqrt(0.5 * (1 - pan))), gr = Float(gain * sqrt(0.5 * (1 + pan)))
      for k in 0..<count {
        let v = Float(wave(Double(k) / sr))
        let i = (start + k) % n
        left[i] += v * gl
        right[i] += v * gr
      }
    }

    for (b, chord) in sc.chords.enumerated() {
      let t0 = Double(b) * bar
      // Pad: detuned saws through a soft envelope, one voice per chord tone, spread in stereo.
      for (k, note) in chord.enumerated() {
        let f = hz(note + 12)
        let pan = Double(k - 1) * 0.5
        var lp = 0.0
        let cutoff = 0.04 - 0.02 * sc.darkness
        add(t0, bar + 0.6, pan: pan, gain: sc.padGain) { t in
          let raw = SoundSynth.saw(f * t) + SoundSynth.saw(f * 1.004 * t) + 0.5 * sin(2 * .pi * f * 0.5 * t)
          lp += cutoff * (raw - lp)
          let env = min(1, t / 0.5) * (t > bar ? exp(-(t - bar) / 0.2) : 1)
          return lp * env
        }
      }
      // Bass.
      let step = bar / Double(sc.bassPerBar)
      for i in 0..<sc.bassPerBar {
        let f = hz(chord[0] - 12 + (track == .night && i % 4 == 3 ? 1 : 0))
        add(t0 + Double(i) * step, step * 0.95, pan: 0, gain: track == .menu ? 0.22 : 0.26) { t in
          (sin(2 * .pi * f * t) + 0.35 * SoundSynth.saw(f * t)) * exp(-t / (step * 0.6)) * min(1, t / 0.005)
        }
      }
      // Arpeggio: chord tones up and down, alternating left/right.
      if sc.arpPerBeat > 0 {
        let steps = 4 * sc.arpPerBeat
        let pattern = chord + [chord[1] + 12, chord[0] + 12] + chord.reversed().dropFirst()
        for i in 0..<steps {
          let note = pattern[i % pattern.count] + sc.arpOctave
          let f = hz(note)
          let at = t0 + Double(i) * beat / Double(sc.arpPerBeat)
          add(at, 0.45, pan: i % 2 == 0 ? -0.35 : 0.35, gain: track == .menu ? 0.1 : 0.075) { t in
            (sin(2 * .pi * f * t) + 0.25 * sin(2 * .pi * 2 * f * t)) * exp(-t / 0.14) * min(1, t / 0.003)
          }
        }
      }
      // Percussion.
      if sc.drums {
        for i in 0..<4 {
          let at = t0 + Double(i) * beat
          let kickGain = track == .night ? 0.5 : 0.35
          if track == .night || i % 2 == 0 {
            add(at, 0.3, pan: 0, gain: kickGain) { t in sin(2 * .pi * (95 * exp(-t * 18) + 45) * t) * exp(-t / 0.12) }
          }
          if i % 2 == 1 {
            var hp = 0.0
            let seed = rng.unit()
            var noise = SplitMix(seed: UInt64(seed * 1e9))
            add(at, 0.18, pan: 0.1, gain: track == .night ? 0.22 : 0.15) { t in
              let x = Double(noise.noise())
              hp += 0.25 * (x - hp)
              return (x - hp) * exp(-t / 0.05)
            }
          }
          // Off-beat hats.
          var lpHat = 0.0
          var noise = SplitMix(seed: UInt64(b * 16 + i + 1))
          add(at + beat / 2, 0.06, pan: 0.3, gain: 0.07) { t in
            let x = Double(noise.noise())
            lpHat += 0.5 * (x - lpHat)
            return (x - lpHat) * exp(-t / 0.015)
          }
        }
      }
    }
    return [left, right]
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
