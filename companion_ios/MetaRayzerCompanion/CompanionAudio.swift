import AVFoundation
import Foundation

/// Plays sound events relayed by the Mac ("Glasses via iPhone" output). iOS routes the audio to
/// the phone's current output: the glasses when they are its connected Bluetooth audio device.
/// Positions use the same spatial engine as the Mac (shared SpatialAudioEngine.swift).
@MainActor
final class CompanionAudio {
  private var engine: SpatialAudioEngine?

  private func ensureEngine() -> SpatialAudioEngine? {
    if let engine { return engine }
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try AVAudioSession.sharedInstance().setActive(true)
      let e = SpatialAudioEngine()
      try e.start()
      engine = e
      NSLog("[MetaRayzerCompanion] audio route: \(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName))")
      return e
    } catch {
      NSLog("[MetaRayzerCompanion] audio unavailable: \(error)")
      return nil
    }
  }

  /// Current output port names (shown in the companion UI).
  var routeDescription: String {
    AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ")
  }

  func handle(_ message: [String: Any]) {
    guard let e = ensureEngine() else { return }
    func f(_ k: String, _ d: Double) -> Float { Float((message[k] as? NSNumber)?.doubleValue ?? d) }
    switch message["op"] as? String {
    case "play":
      guard let name = message["s"] as? String, let id = SoundId(rawValue: name) else { return }
      e.play(id, x: f("x", 0), y: f("y", 1), z: f("z", 1), gain: f("g", 1), positional: message["p"] as? Bool ?? true)
    case "config":
      if message["sfx"] != nil || message["amb"] != nil { e.setVolumes(sfx: f("sfx", 0.8), ambient: f("amb", 0.45)) }
      if let mode = message["mode"] as? String, let m = SpatialAudioEngine.Mode(rawValue: mode) { e.setMode(m) }
      if let ambient = message["ambient"] as? Bool { e.setAmbient(ambient) }
      if message["yaw"] != nil { e.setListenerYaw(radians: f("yaw", 0)) }
    default:
      break
    }
  }
}
