import CoreAudio
import Foundation

/// Mac-side audio: owns the [SpatialAudioEngine], picks the output route and, when the player
/// chose "Glasses via iPhone", relays sound events to the companion instead of playing locally.
///
/// Routes (AudioOutputChoice in Dart):
/// - `auto`: a Mac output whose name looks like the glasses (Ray-Ban/Meta/Oakley) if one is
///   connected to the Mac, else the system default output.
/// - `system`: the system default output (follows changes).
/// - `companion`: relay to the iPhone, which plays on ITS current route — the glasses when they
///   are the phone's Bluetooth audio device. Falls back to the Mac default while no phone is
///   connected.
/// - any other value: a specific CoreAudio device UID (falls back to default if it disappears).
///
/// Verification: the route reported to Dart separates what was requested from what is
/// verifiably active. For a Mac device it includes whether the engine is actually bound to it
/// (`bound`); for the iPhone route it includes the output the phone's AVAudioSession reports
/// (`phone`, relayed in the companion's status), so the app never claims "playing on the
/// glasses" from the preference alone. Music and every sound follow the same route.
/// Main thread only.
final class AudioController {
  private let engine = SpatialAudioEngine()
  /// Sends a JSON audio message to the companion.
  var relay: (([String: Any]) -> Void)?
  /// Reports the active route to Dart.
  var onRouteChange: (([String: Any]) -> Void)?

  var companionConnected = false {
    didSet { if companionConnected != oldValue { applyRoute() } }
  }

  private var choice = "auto"
  private var sfx: Float = 0.8
  private var ambient: Float = 0.45
  private var musicVolume: Float = 0.5
  private var musicTrack: MusicTrack?
  /// Audio status the companion reports (its engine state and AVAudioSession outputs).
  var companionAudio: [String: Any]? {
    didSet { if relaying { publishRoute() } }
  }
  private var mode: SpatialAudioEngine.Mode = .stereo
  private var ambientOn = false
  private var yaw: Float = 0
  private var lastRelayedYaw: Float = .infinity
  private var currentDevice: AudioDeviceID?
  private var relaying = false
  private(set) var route: [String: Any] = ["kind": "starting"]

  init() {
    do {
      try engine.start()
    } catch {
      NSLog("[MetaRayzer] audio engine failed to start: \(error)")
    }
    AudioDevices.observeChanges { [weak self] in self?.applyRoute() }
    applyRoute()
  }

  func configure(_ args: [String: Any]) {
    if let v = args["sfx"] as? Double { sfx = Float(v) }
    if let v = args["ambient"] as? Double { ambient = Float(v) }
    if let v = args["music"] as? Double { musicVolume = Float(v) }
    if let v = args["mode"] as? String, let m = SpatialAudioEngine.Mode(rawValue: v) { mode = m }
    if let v = args["ambientOn"] as? Bool { ambientOn = v }
    if let v = args["output"] as? String { choice = v }
    engine.setMode(mode)
    engine.setAmbient(ambientOn)
    applyRoute()
  }

  func play(_ args: [String: Any]) {
    guard let name = args["s"] as? String, let id = SoundId(rawValue: name) else { return }
    let x = Float(args["x"] as? Double ?? 0), y = Float(args["y"] as? Double ?? 1), z = Float(args["z"] as? Double ?? 1)
    let gain = Float(args["g"] as? Double ?? 1)
    let positional = args["p"] as? Bool ?? true
    if relaying {
      relay?(["op": "play", "s": name, "x": x, "y": y, "z": z, "g": gain, "p": positional])
    } else {
      engine.play(id, x: x, y: y, z: z, gain: gain, positional: positional)
    }
  }

  /// Background music: the same route as every other sound.
  func setMusic(_ name: String?) {
    let track = name.flatMap(MusicTrack.init(rawValue:))
    guard track != musicTrack else { return }
    musicTrack = track
    if relaying {
      relay?(["op": "music", "track": track.map { $0.rawValue as Any } ?? NSNull()])
    } else {
      engine.setMusic(track)
    }
  }

  /// Listener yaw follows the in-game view (radians, + = right).
  func setListenerYaw(_ radians: Float) {
    yaw = radians
    engine.setListenerYaw(radians: radians)
    if relaying, abs(radians - lastRelayedYaw) > 0.02 {
      lastRelayedYaw = radians
      relay?(["op": "config", "yaw": radians])
    }
  }

  func applyRoute() {
    let outputs = AudioDevices.outputs()
    let defaultID = AudioDevices.defaultOutput()
    let defaultName = outputs.first { $0.id == defaultID }?.name ?? "System default"
    var kind = "mac"
    var name = defaultName
    var note: String?
    var device: AudioOutputDevice?

    switch choice {
    case "companion" where companionConnected:
      kind = "companion"
      name = "iPhone companion"
      note = "Plays on the iPhone's current audio route (the glasses when they are its Bluetooth audio)."
    case "companion":
      kind = "fallback"
      note = "iPhone companion not connected: playing on this Mac."
    case "auto":
      device = outputs.first { AudioDevices.looksLikeGlasses($0.name) }
      if let device {
        kind = "device"
        name = device.name
      } else {
        note = "No glasses audio device on this Mac: using the default output."
      }
    case "system":
      break
    default:
      device = outputs.first { $0.uid == choice }
      if let device {
        kind = "device"
        name = device.name
      } else {
        kind = "fallback"
        note = "Selected output is unavailable: using the default output."
      }
    }

    let shouldRelay = kind == "companion"
    if relaying && !shouldRelay {
      // Silence the phone when leaving relay mode, and bring the music back to the Mac.
      relay?(["op": "config", "ambient": false])
      relay?(["op": "music", "track": NSNull()])
      engine.setMusic(musicTrack, fade: 0.4)
    }
    if !relaying && shouldRelay {
      engine.setMusic(nil, fade: 0.3)
    }
    relaying = shouldRelay
    if shouldRelay {
      engine.setVolumes(sfx: 0, ambient: 0)
      engine.setMusicVolume(0)
      relay?(["op": "config", "sfx": sfx, "amb": ambient, "mus": musicVolume, "mode": mode.rawValue, "ambient": ambientOn, "yaw": yaw])
      relay?(["op": "music", "track": musicTrack.map { $0.rawValue as Any } ?? NSNull()])
      lastRelayedYaw = yaw
    } else {
      engine.setVolumes(sfx: sfx, ambient: ambient)
      engine.setMusicVolume(musicVolume)
      engine.setMusic(musicTrack)
      if device?.id != currentDevice {
        currentDevice = device?.id
        engine.setOutputDevice(device?.id) // nil = system default
      }
    }

    var r: [String: Any] = [
      "kind": kind,
      "name": name,
      "note": note as Any,
      "requested": choice,
      "spatial": mode.rawValue,
      "devices": outputs.map { ["uid": $0.uid, "name": $0.name, "bluetooth": $0.isBluetooth, "glasses": AudioDevices.looksLikeGlasses($0.name)] },
    ]
    if let device {
      r["glasses"] = AudioDevices.looksLikeGlasses(device.name)
      r["bound"] = engine.currentOutputDevice() == device.id
    }
    route = r
    NSLog("[MetaRayzer] audio route: \(kind) · \(name)\(note.map { " (\($0))" } ?? "")")
    publishRoute()
  }

  /// Sends the route to Dart, with the phone's reported output while relaying.
  private func publishRoute() {
    var r = route
    if relaying, let phone = companionAudio { r["phone"] = phone }
    route = r
    onRouteChange?(r)
  }
}
