import AVFoundation
import AVKit
import Foundation
import Observation
import SwiftUI

/// Plays sound events and music relayed by the Mac ("Glasses via iPhone" output).
///
/// How audio reaches the glasses (per Meta's "Use device microphones and speakers" docs): the
/// toolkit has no playback API; the glasses' speakers are the phone's standard Bluetooth A2DP
/// output. The app configures a `.playback` session (no options) and iOS routes it to the
/// current output. iOS lets the USER pick that output (Control Center, or the route picker this
/// app shows); an app cannot force a specific Bluetooth device. So this class:
/// - activates the session as soon as the Mac starts relaying (not lazily on the first sound),
/// - recovers after interruptions (e.g. Meta AI taking over for a permission prompt) and media
///   server resets,
/// - reports the ACTUAL output ports (`AVAudioSession.currentRoute`) and a played-sound count back
///   to the Mac, which shows "confirmed on the glasses" only when iOS reports a Bluetooth output
///   that is recognizably the glasses.
@Observable
@MainActor
final class CompanionAudio {
  @ObservationIgnored private var engine: SpatialAudioEngine?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var reportPending = false
  /// Called when the status the Mac should know about changes (route, engine, played count).
  @ObservationIgnored var onChange: (() -> Void)?

  private(set) var outputs: [(name: String, type: String)] = []
  private(set) var running = false
  private(set) var played = 0
  private(set) var lastError: String?

  init() {
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    })
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
      let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .ended
      MainActor.assumeIsolated { if ended { self?.resume() } else { self?.refresh() } }
    })
    observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.engine = nil  // the old engine is invalid after a reset
        self?.resume()
      }
    })
    refresh()
  }

  /// Current output port names (shown in the companion UI).
  var routeDescription: String {
    outputs.isEmpty ? "none" : outputs.map { "\($0.name) (\(Self.portLabel($0.type)))" }.joined(separator: ", ")
  }

  /// Whether iOS reports a Bluetooth output that looks like the glasses.
  var glassesActive: Bool {
    outputs.contains { Self.bluetoothTypes.contains($0.type) && Self.looksLikeGlasses($0.name) }
  }

  static let bluetoothTypes: Set<String> = [AVAudioSession.Port.bluetoothA2DP.rawValue, AVAudioSession.Port.bluetoothHFP.rawValue, AVAudioSession.Port.bluetoothLE.rawValue]

  static func looksLikeGlasses(_ name: String) -> Bool {
    let n = name.lowercased()
    return n.contains("ray-ban") || n.contains("rayban") || n.contains("ray ban") || n.contains("meta") || n.contains("oakley")
  }

  static func portLabel(_ type: String) -> String {
    switch type {
    case AVAudioSession.Port.bluetoothA2DP.rawValue: return "Bluetooth A2DP"
    case AVAudioSession.Port.bluetoothHFP.rawValue: return "Bluetooth HFP"
    case AVAudioSession.Port.bluetoothLE.rawValue: return "Bluetooth LE"
    case AVAudioSession.Port.builtInSpeaker.rawValue: return "iPhone speaker"
    default: return type
    }
  }

  /// Sent to the Mac inside the companion status (`status["audio"]`).
  func statusSnapshot() -> [String: Any] {
    var s: [String: Any] = [
      "engine": running,
      "outputs": outputs.map { ["name": $0.name, "type": $0.type] },
      "played": played,
      "glasses": glassesActive,
    ]
    if let lastError { s["error"] = lastError }
    return s
  }

  /// Configures the session exactly as Meta documents for glasses output (A2DP): `.playback`,
  /// default mode, no options, then activates it and starts the engine.
  @discardableResult
  private func ensureEngine() -> SpatialAudioEngine? {
    if let engine, engine.started { return engine }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
      let e = engine ?? SpatialAudioEngine()
      try e.start()
      engine = e
      lastError = nil
      NSLog("[MetaRayzerCompanion] audio route: \(routeDescription)")
    } catch {
      lastError = error.localizedDescription
      NSLog("[MetaRayzerCompanion] audio unavailable: \(error)")
    }
    refresh()
    return engine?.started == true ? engine : nil
  }

  private func resume() {
    engine?.stop()
    ensureEngine()
  }

  private func refresh() {
    outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { ($0.portName, $0.portType.rawValue) }
    running = engine?.started ?? false
    report()
  }

  /// Coalesces status reports (the played count changes with every sound).
  private func report() {
    guard !reportPending else { return }
    reportPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      MainActor.assumeIsolated {
        self?.reportPending = false
        self?.onChange?()
      }
    }
  }

  func handle(_ message: [String: Any]) {
    guard let e = ensureEngine() else { return }
    func f(_ k: String, _ d: Double) -> Float { Float((message[k] as? NSNumber)?.doubleValue ?? d) }
    switch message["op"] as? String {
    case "play":
      guard let name = message["s"] as? String, let id = SoundId(rawValue: name) else { return }
      e.play(id, x: f("x", 0), y: f("y", 1), z: f("z", 1), gain: f("g", 1), positional: message["p"] as? Bool ?? true)
      played += 1
      report()
    case "config":
      if message["sfx"] != nil || message["amb"] != nil { e.setVolumes(sfx: f("sfx", 0.8), ambient: f("amb", 0.45)) }
      if message["mus"] != nil { e.setMusicVolume(f("mus", 0.5)) }
      if let mode = message["mode"] as? String, let m = SpatialAudioEngine.Mode(rawValue: mode) { e.setMode(m) }
      if let ambient = message["ambient"] as? Bool { e.setAmbient(ambient) }
      if message["yaw"] != nil { e.setListenerYaw(radians: f("yaw", 0)) }
    case "music":
      e.setMusic((message["track"] as? String).flatMap(MusicTrack.init(rawValue:)))
    default:
      break
    }
  }
}

/// iOS's own audio-output picker (the same list as Control Center's AirPlay menu). This is the
/// supported way to choose the glasses as the phone's output; apps cannot select a Bluetooth
/// device programmatically.
struct AudioRoutePicker: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let v = AVRoutePickerView()
    v.prioritizesVideoDevices = false
    return v
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
