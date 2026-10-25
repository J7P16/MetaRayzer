import MWDATCore
import SwiftUI

@main
struct CompanionApp: App {
  @State private var model: CompanionModel

  init() {
    do {
      try Wearables.configure()
    } catch {
      NSLog("[MetaRayzerCompanion] Wearables.configure failed: \(error)")
    }
    _model = State(wrappedValue: CompanionModel())
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .onOpenURL { model.glasses.handleOpenURL($0) }
    }
  }
}

/// Wires the three parts together: glasses (DAT SDK) -> encoder (JPEG) -> Mac link (TCP).
@MainActor
final class CompanionModel {
  let glasses = GlassesController()
  let link = MacLink()
  let audio = CompanionAudio()
  private let encoder = FrameEncoder()

  init() {
    let link = link
    let glasses = glasses
    glasses.onFrame = { [encoder] image, captureTimeMs in
      encoder.submit(image, captureTimeMs: captureTimeMs)
    }
    encoder.onEncoded = { frame, image in
      link.send(frame: frame)
      Task { @MainActor in glasses.showPreview(image) }
    }
    let audio = audio
    // One status message carries the glasses state and the phone's actual audio output.
    let status = { [weak glasses] () -> [String: Any] in
      var s = glasses?.statusSnapshot() ?? [:]
      s["audio"] = audio.statusSnapshot()
      return s
    }
    glasses.onStatusChange = { [weak link] in link?.sendStatus(status()) }
    audio.onChange = { [weak link] in link?.sendStatus(status()) }
    glasses.onMotion = { qx, qy, qz, qw, t in
      link.send(motion: MotionMessage(qx: qx, qy: qy, qz: qz, qw: qw, timestampNs: t))
    }
    link.onAudio = { message in audio.handle(message) }
    link.statusProvider = status
    link.onCommand = { [weak glasses] cmd in
      switch cmd {
      case "startStream": glasses?.startStream(userInitiated: false)
      case "stopStream": glasses?.stopStream()
      default: NSLog("[MetaRayzerCompanion] unknown command \(cmd)")
      }
    }
    link.startBrowsing()
  }
}
