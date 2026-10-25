// Positional game audio for MetaRayzer.
//
// KEEP IN SYNC: an identical copy lives in companion_ios/MetaRayzerCompanion/SpatialAudioEngine.swift
// (tool/link_selftest.sh checks this).

import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
#endif

/// AVAudioEngine + AVAudioEnvironmentNode:
/// - every sound plays through a pool of mono voices positioned in 3D (listener at the origin);
/// - `.stereo` mode = equal-power panning + distance attenuation (works on any output);
/// - `.binaural` mode = HRTF rendering (convincing on headphones; NOT head-tracked by the OS —
///   the listener only turns with the in-game view via [setListenerYaw]);
/// - a separate stereo ambient loop bypasses spatialization;
/// - background music: two stereo players crossfaded so a track change never overlaps two
///   copies of the same track (setMusic ignores the track that is already playing).
///
/// Game coordinates (x right, z ahead, y up) map to AVAudio (x right, y up, -z ahead).
final class SpatialAudioEngine {
  enum Mode: String { case stereo, binaural }

  let engine = AVAudioEngine()
  private let environment = AVAudioEnvironmentNode()
  private let ambientPlayer = AVAudioPlayerNode()
  private var voices: [AVAudioPlayerNode] = []
  private var nextVoice = 0
  private var buffers: [SoundId: AVAudioPCMBuffer] = [:]
  private var ambientBuffer: AVAudioPCMBuffer?
  private let mono = AVAudioFormat(standardFormatWithSampleRate: SoundSynth.sampleRate, channels: 1)!
  private let stereo = AVAudioFormat(standardFormatWithSampleRate: SoundSynth.sampleRate, channels: 2)!
  private var ambientOn = false
  private let musicPlayers = [AVAudioPlayerNode(), AVAudioPlayerNode()]
  private var musicBuffers: [MusicTrack: AVAudioPCMBuffer] = [:]
  private var activeMusicPlayer = 0
  private(set) var musicTrack: MusicTrack?
  private var musicVolume: Float = 0.5
  private var musicLevels: [Float] = [0, 0]  // per-player fade level 0..1
  private var musicFadeTimer: Timer?
  private var musicRequest = 0
  private(set) var mode: Mode = .stereo
  private(set) var started = false
  private var configObserver: NSObjectProtocol?

  /// Meters per game world unit (game distances are larger than comfortable audio distances).
  static let worldScale: Float = 0.6

  init(voiceCount: Int = 20) {
    engine.attach(environment)
    engine.attach(ambientPlayer)
    for _ in 0..<voiceCount {
      let v = AVAudioPlayerNode()
      engine.attach(v)
      engine.connect(v, to: environment, format: mono)
      voices.append(v)
    }
    engine.connect(environment, to: engine.mainMixerNode, format: stereo)
    engine.connect(ambientPlayer, to: engine.mainMixerNode, format: stereo)
    for p in musicPlayers {
      engine.attach(p)
      engine.connect(p, to: engine.mainMixerNode, format: stereo)
      p.volume = 0
    }

    let d = environment.distanceAttenuationParameters
    d.distanceAttenuationModel = .inverse
    d.referenceDistance = 1.5
    d.maximumDistance = 30
    d.rolloffFactor = 1.1
    environment.reverbParameters.enable = true
    environment.reverbParameters.loadFactoryReverbPreset(.mediumHall)
    environment.reverbParameters.level = -14
    environment.outputVolume = 0.8
    ambientPlayer.volume = 0.45
    setMode(.stereo)

    for id in SoundId.allCases { buffers[id] = SoundSynth.buffer(for: id, format: mono) }
    ambientBuffer = SoundSynth.ambientLoop(format: stereo)

    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
      // Output device changed (e.g. headphones/glasses connected): restart on the new route.
      self?.restart()
    }
  }

  deinit {
    if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
  }

  func start() throws {
    guard !started else { return }
    engine.prepare()
    try engine.start()
    started = true
    if ambientOn { startAmbient() }
    // Players stop with the engine (e.g. after an output-route change): resume the music.
    if let track = musicTrack, let buffer = musicBuffers[track] {
      let p = musicPlayers[activeMusicPlayer]
      p.stop()
      p.scheduleBuffer(buffer, at: nil, options: .loops)
      p.play()
      musicLevels[activeMusicPlayer] = 1
      applyMusicVolumes()
    }
  }

  func stop() {
    engine.stop()
    started = false
  }

  func restart() {
    stop()
    do { try start() } catch { NSLog("[MetaRayzer] audio restart failed: \(error)") }
  }

  func setMode(_ mode: Mode) {
    self.mode = mode
    let algorithm: AVAudio3DMixingRenderingAlgorithm = mode == .binaural ? .HRTFHQ : .equalPowerPanning
    for v in voices {
      v.renderingAlgorithm = algorithm
      v.reverbBlend = 0.12
    }
  }

  func setVolumes(sfx: Float, ambient: Float) {
    environment.outputVolume = max(0, min(1, sfx))
    ambientPlayer.volume = max(0, min(1, ambient))
  }

  /// Turns the listener with the in-game view. Positive = looking right.
  func setListenerYaw(radians: Float) {
    // AVAudio yaw is in degrees; positive turns the listener to the right (verified by
    // tool/audio_probe: with +40°, a sound straight ahead is heard in the left ear).
    environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: radians * 180 / .pi, pitch: 0, roll: 0)
  }

  /// Plays [id] at game-world position (x right, z ahead, y up). [positional] = false plays it
  /// close in front of the listener (UI sounds).
  func play(_ id: SoundId, x: Float, y: Float, z: Float, gain: Float, positional: Bool = true) {
    guard started, let buffer = buffers[id] else { return }
    let v = voices[nextVoice]
    nextVoice = (nextVoice + 1) % voices.count
    if v.isPlaying { v.stop() } // steal the oldest voice
    v.position = positional
      ? AVAudio3DPoint(x: x * Self.worldScale, y: y * Self.worldScale, z: -z * Self.worldScale)
      : AVAudio3DPoint(x: 0, y: 0, z: -1)
    v.volume = max(0, min(1, gain))
    v.scheduleBuffer(buffer, at: nil, options: [])
    v.play()
  }

  func setMusicVolume(_ volume: Float) {
    musicVolume = max(0, min(1, volume))
    applyMusicVolumes()
  }

  private func applyMusicVolumes() {
    for (i, p) in musicPlayers.enumerated() { p.volume = musicLevels[i] * musicVolume }
  }

  /// The (cached) loop for [track]; synthesized on first use.
  func musicBuffer(_ track: MusicTrack) -> AVAudioPCMBuffer {
    if let b = musicBuffers[track] { return b }
    let b = SoundSynth.music(track, format: stereo)
    musicBuffers[track] = b
    return b
  }

  /// Crossfades to [track] over [fade] seconds, or fades out (nil). Requests for the track
  /// already playing are ignored. Call on the main thread; with [synchronous] false a track's
  /// first synthesis runs on a background queue and the latest request wins.
  func setMusic(_ track: MusicTrack?, fade: Double = 1.2, synchronous: Bool = false) {
    guard track != musicTrack else { return }
    musicTrack = track
    musicRequest += 1
    let request = musicRequest
    guard let track else { return crossfade(to: nil, fade: fade) }
    if musicBuffers[track] != nil || synchronous {
      crossfade(to: musicBuffer(track), fade: fade)
      return
    }
    let format = stereo
    DispatchQueue.global(qos: .userInitiated).async {
      let buffer = SoundSynth.music(track, format: format)
      DispatchQueue.main.async {
        self.musicBuffers[track] = buffer
        if request == self.musicRequest { self.crossfade(to: buffer, fade: fade) }
      }
    }
  }

  private func crossfade(to buffer: AVAudioPCMBuffer?, fade: Double) {
    let outgoing = activeMusicPlayer
    let incoming = 1 - outgoing
    if let buffer, started {
      let p = musicPlayers[incoming]
      p.stop()
      p.scheduleBuffer(buffer, at: nil, options: .loops)
      p.play()
      musicLevels[incoming] = 0
      activeMusicPlayer = incoming
    }
    musicFadeTimer?.invalidate()
    let target: [Float] = buffer == nil ? [0, 0] : (incoming == 0 ? [1, 0] : [0, 1])
    if fade <= 0 {
      musicLevels = target
      applyMusicVolumes()
      for (i, p) in musicPlayers.enumerated() where target[i] == 0 { p.stop() }
      return
    }
    let start = musicLevels
    let began = Date()
    musicFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      let k = Float(min(1, Date().timeIntervalSince(began) / fade))
      for i in 0..<2 { self.musicLevels[i] = start[i] + (target[i] - start[i]) * k }
      self.applyMusicVolumes()
      if k >= 1 {
        timer.invalidate()
        for (i, p) in self.musicPlayers.enumerated() where target[i] == 0 { p.stop() }
      }
    }
  }

  func setAmbient(_ on: Bool) {
    ambientOn = on
    if on { startAmbient() } else { ambientPlayer.stop() }
  }

  private func startAmbient() {
    guard started, let ambientBuffer, !ambientPlayer.isPlaying else { return }
    ambientPlayer.scheduleBuffer(ambientBuffer, at: nil, options: .loops)
    ambientPlayer.play()
  }

  #if os(macOS)
  /// Routes output to a specific CoreAudio device, or back to the system default (nil).
  func setOutputDevice(_ deviceID: AudioDeviceID?) {
    let wasStarted = started
    stop()
    var id = deviceID ?? AudioDevices.defaultOutput() ?? 0
    if let unit = engine.outputNode.audioUnit, id != 0 {
      let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
      if status != noErr { NSLog("[MetaRayzer] could not select audio device \(id): \(status)") }
    }
    if wasStarted { restart() }
  }

  /// The CoreAudio device the engine is actually bound to (to verify a requested route).
  func currentOutputDevice() -> AudioDeviceID? {
    guard let unit = engine.outputNode.audioUnit else { return nil }
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
    return status == noErr && id != 0 ? id : nil
  }
  #endif
}

#if os(macOS)
struct AudioOutputDevice {
  let id: AudioDeviceID
  let uid: String
  let name: String
  let isBluetooth: Bool
}

/// CoreAudio output-device discovery (macOS only).
enum AudioDevices {
  static func outputs() -> [AudioOutputDevice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
      guard outputChannels(id) > 0 else { return nil }
      return AudioOutputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)", name: string(id, kAudioObjectPropertyName) ?? "Device \(id)", isBluetooth: transport(id) == kAudioDeviceTransportTypeBluetooth || transport(id) == kAudioDeviceTransportTypeBluetoothLE)
    }
  }

  static func defaultOutput() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    return status == noErr && id != 0 ? id : nil
  }

  /// Calls [handler] on the main queue when devices are added/removed or the default changes.
  static func observeChanges(_ handler: @escaping () -> Void) {
    for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
      var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in handler() }
    }
  }

  private static func outputChannels(_ id: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
  }

  private static func transport(_ id: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    return value
  }

  /// Heuristic for "these are the Meta glasses" (used by the Auto output choice).
  static func looksLikeGlasses(_ name: String) -> Bool {
    let n = name.lowercased()
    return n.contains("ray-ban") || n.contains("rayban") || n.contains("ray ban") || n.contains("meta") || n.contains("oakley")
  }
}
#endif
