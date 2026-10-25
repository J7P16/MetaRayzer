import AVFoundation
import Foundation
import MWDATCamera
import MWDATCore
import Observation
import UIKit

#if DEBUG
import MWDATMockDevice
#endif

/// Owns the Meta Wearables Device Access Toolkit workflow on the phone:
/// registration with Meta AI -> device availability -> device session -> camera permission ->
/// camera stream. Frames are handed to [onFrame]; every state change is published via
/// [statusSnapshot] so the Mac can show it.
@Observable
@MainActor
final class GlassesController {
  enum Resolution: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var sdk: StreamingResolution {
      switch self {
      case .low: return .low
      case .medium: return .medium
      case .high: return .high
      }
    }
    var label: String {
      switch self {
      case .low: return "360×640"
      case .medium: return "504×896"
      case .high: return "720×1280"
      }
    }
  }

  // Published state
  private(set) var registrationState: RegistrationState
  private(set) var devices: [DeviceIdentifier] = []
  private(set) var hasActiveDevice = false
  private(set) var sessionState: DeviceSessionState = .idle
  private(set) var streamState: StreamState = .stopped
  private(set) var permission = "unknown"
  private(set) var lastError: String?
  private(set) var latestPreview: UIImage?
  private(set) var mockEnabled = false
  /// The Mac asked to start but we need the user to approve the Meta AI permission switch.
  var needsPermissionConfirmation = false

  var resolution: Resolution = .medium
  var frameRate: UInt = 24

  /// Called on a background queue for every decoded frame.
  @ObservationIgnored nonisolated(unsafe) var onFrame: ((UIImage, UInt64) -> Void)?
  /// Called on the main actor whenever anything the Mac should know about changes.
  @ObservationIgnored var onStatusChange: (() -> Void)?

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let selector: AutoDeviceSelector
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private let sessionTokens = ListenerTokenBag()
  @ObservationIgnored private let streamTokens = ListenerTokenBag()
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var startAfterSession = false
  @ObservationIgnored private var pendingStartUserInitiated = false
  @ObservationIgnored private var lastPreviewAt = Date.distantPast
  #if DEBUG
  @ObservationIgnored private var mockGlasses: MockGlasses?
  #endif

  init(wearables: WearablesInterface = Wearables.shared) {
    self.wearables = wearables
    self.selector = AutoDeviceSelector(wearables: wearables)
    self.registrationState = wearables.registrationState
    self.devices = wearables.devices

    tasks.append(Task { [weak self] in
      for await state in wearables.registrationStateStream() {
        self?.registrationState = state
        self?.log("registration: \(state)")
        self?.changed()
      }
    })
    tasks.append(Task { [weak self] in
      for await ids in wearables.devicesStream() {
        self?.devices = ids
        self?.changed()
      }
    })
    tasks.append(Task { [weak self, selector] in
      for await id in selector.activeDeviceStream() {
        self?.hasActiveDevice = id != nil
        self?.changed()
      }
    })
  }

  var isRegistered: Bool { registrationState == .registered }
  var isStreaming: Bool { streamState == .streaming }

  var deviceDescription: String {
    guard let id = devices.first else { return "none" }
    let name = wearables.deviceForIdentifier(id)?.nameOrId() ?? id
    return devices.count > 1 ? "\(name) (+\(devices.count - 1))" : name
  }

  // MARK: - Registration

  func register() {
    Task {
      do {
        try await wearables.startRegistration()
      } catch let error as RegistrationError {
        fail("Registration failed: \(error.description)")
      } catch {
        fail("Registration failed: \(error.localizedDescription)")
      }
    }
  }

  func unregister() {
    stopStream()
    Task {
      do {
        try await wearables.startUnregistration()
      } catch {
        fail("Unregistration failed: \(error.localizedDescription)")
      }
    }
  }

  func handleOpenURL(_ url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
    Task {
      do {
        _ = try await wearables.handleUrl(url)
        await refreshPermission()
      } catch {
        fail("Meta AI callback failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Streaming

  /// Starts (or resumes) everything needed for frames to flow. Safe to call repeatedly.
  /// [userInitiated] is false when the Mac requested it: we then never switch to the Meta AI app
  /// without the user confirming on the phone first.
  func startStream(userInitiated: Bool) {
    lastError = nil
    guard isRegistered || mockEnabled else {
      return fail("Not registered with Meta AI yet. Tap \"Connect glasses\" on the iPhone first.")
    }
    guard camera == nil else { return }
    guard let session, session.state == .started else {
      startAfterSession = true
      pendingStartUserInitiated = userInitiated
      startSession()
      return
    }
    Task { await beginStreamCheckingPermission(on: session, userInitiated: userInitiated) }
  }

  func stopStream() {
    startAfterSession = false
    needsPermissionConfirmation = false
    camera?.stop()  // cascades to the stream; detaches the camera so a later addCamera works
  }

  /// User tapped "Allow" for the Meta AI camera-permission switch.
  func confirmPermissionRequest() {
    needsPermissionConfirmation = false
    guard let session, session.state == .started else { return startStream(userInitiated: true) }
    Task {
      do {
        let status = try await wearables.requestPermission(.camera)
        permission = status == .granted ? "granted" : "denied"
        changed()
        guard status == .granted else { return fail("Camera permission denied in Meta AI.") }
        beginStream(on: session)
      } catch {
        fail("Camera permission request failed: \(error.localizedDescription)")
      }
    }
  }

  private func startSession() {
    guard session == nil else { return }
    do {
      let newSession = try wearables.createSession(deviceSelector: selector)
      session = newSession
      newSession.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.sessionStateChanged(state) }
      }.store(in: sessionTokens)
      newSession.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.sessionFailed(error) }
      }.store(in: sessionTokens)
      sessionState = .starting
      changed()
      try newSession.start()
    } catch {
      // createSession/start use typed throws: error is a DeviceSessionError.
      sessionFailed(error)
      cleanupSession()
    }
  }

  private func sessionStateChanged(_ state: DeviceSessionState) {
    sessionState = state
    log("session: \(state)")
    switch state {
    case .started:
      if startAfterSession, camera == nil, let session {
        startAfterSession = false
        let userInitiated = pendingStartUserInitiated
        Task { await beginStreamCheckingPermission(on: session, userInitiated: userInitiated) }
      }
    case .stopped:
      // Terminal: glasses folded/removed, connection lost, app removed in Meta AI, etc.
      // A new session is created on the next start request.
      camera = nil
      streamTokens.clear()
      streamState = .stopped
      cleanupSession()
    default:
      break
    }
    changed()
  }

  private func sessionFailed(_ error: DeviceSessionError) {
    switch error {
    case .noEligibleDevice:
      fail("No glasses available. Make sure they are on, unfolded, connected in Meta AI and Developer Mode is enabled.")
    case .datAppOnTheGlassesUpdateRequired:
      fail("The glasses need an update. Opening Meta AI…")
      Task { try? await wearables.openDATGlassesAppUpdate() }
    default:
      fail("Glasses session error: \(error.localizedDescription)")
    }
  }

  private func cleanupSession() {
    sessionTokens.clear()
    session = nil
  }

  private func beginStreamCheckingPermission(on session: DeviceSession, userInitiated: Bool) async {
    await refreshPermission()
    if permission == "granted" {
      beginStream(on: session)
    } else if userInitiated {
      confirmPermissionRequest()
    } else {
      needsPermissionConfirmation = true
      fail("Camera permission needed: tap \"Allow camera access\" on the iPhone.")
    }
  }

  private func refreshPermission() async {
    do {
      permission = try await wearables.checkPermissionStatus(.camera) == .granted ? "granted" : "not granted"
    } catch {
      permission = "unknown"
    }
    changed()
  }

  private func beginStream(on session: DeviceSession) {
    guard camera == nil else { return }
    // .raw gives decoded frames we can JPEG-encode directly; lower resolution/fps gives better
    // per-frame quality over Bluetooth (the SDK may still lower them when bandwidth is short).
    let config = StreamConfiguration(videoCodec: .raw, resolution: resolution.sdk, frameRate: frameRate)
    do {
      guard let newCamera = try session.addCamera(config: config) else {
        return fail("Couldn't attach the camera to the glasses session. Try again.")
      }
      camera = newCamera
      let stream = newCamera.stream
      stream.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.streamStateChanged(state) }
      }.store(in: streamTokens)
      stream.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.fail("Stream error: \(error.localizedDescription)") }
      }.store(in: streamTokens)
      stream.videoFramePublisher.listen { [weak self] frame in
        guard let image = frame.makeUIImage() else { return }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        self?.onFrame?(image, now)
      }.store(in: streamTokens)
      streamState = .starting
      changed()
      stream.start()
    } catch {
      camera = nil
      fail("Couldn't start the camera stream: \(error.localizedDescription)")
    }
  }

  private func streamStateChanged(_ state: StreamState) {
    streamState = state
    log("stream: \(state)")
    UIApplication.shared.isIdleTimerDisabled = state == .streaming
    if state == .stopped {
      camera = nil
      streamTokens.clear()
    }
    changed()
  }

  /// Throttled on-phone preview (the Mac is the real display).
  func showPreview(_ image: UIImage) {
    let now = Date()
    guard now.timeIntervalSince(lastPreviewAt) > 0.2 else { return }
    lastPreviewAt = now
    latestPreview = image
  }

  // MARK: - Mock device (development only)

  #if DEBUG
  /// DEVELOPMENT FALLBACK: Meta's MockDeviceKit simulates registered glasses whose camera is the
  /// iPhone's back camera. Lets the whole pipeline be exercised without real glasses. The Mac
  /// shows a "MOCK" badge while this is on.
  func setMockEnabled(_ enabled: Bool) {
    stopStream()
    if enabled {
      Task {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
          return fail("Mock glasses use the iPhone camera; allow camera access in Settings.")
        }
        MockDeviceKit.shared.enable()
        do {
          let glasses = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
          glasses.powerOn()
          glasses.unfold()
          glasses.don()
          glasses.services.camera.setCameraFeed(cameraFacing: .back)
          mockGlasses = glasses
          mockEnabled = true
          changed()
        } catch {
          fail("Mock glasses failed: \(error.localizedDescription)")
        }
      }
    } else {
      MockDeviceKit.shared.disable()
      mockGlasses = nil
      mockEnabled = false
      changed()
    }
  }
  #endif

  // MARK: - Status for the Mac

  func statusSnapshot() -> [String: Any] {
    var status: [String: Any] = [
      "registration": "\(registrationState)",
      "device": hasActiveDevice ? deviceDescription : "none",
      "permission": permission,
      "session": sessionState.description,
      "stream": "\(streamState)",
      "resolution": resolution.label,
      "fps": Int(frameRate),
      "mock": mockEnabled,
    ]
    if let lastError { status["error"] = lastError }
    return status
  }

  private func fail(_ message: String) {
    log("error: \(message)")
    lastError = message
    changed()
  }

  private func changed() {
    onStatusChange?()
  }

  private func log(_ message: String) {
    NSLog("[MetaRayzerCompanion] \(message)")
  }
}
