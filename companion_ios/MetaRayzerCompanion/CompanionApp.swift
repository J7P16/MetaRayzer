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
    glasses.onStatusChange = { [weak glasses, weak link] in
      guard let glasses, let link else { return }
      link.sendStatus(glasses.statusSnapshot())
    }
    link.statusProvider = { [weak glasses] in glasses?.statusSnapshot() ?? [:] }
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
