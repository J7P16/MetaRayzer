import Cocoa
import FlutterMacOS

/// Bridges the native frame link + hand detector to Dart.
///
/// - Method channel `metarayzer_native/control`: start/stop the listener, pick the frame source,
///   forward stream commands to the phone, acknowledge displayed frames.
/// - Event channel `metarayzer_native/events`: a single stream of typed maps (`type` key):
///   `server`, `companion`, `companionStatus`, `frame`, `webcam`, `error`.
///
/// All heavy work (network IO, JPEG decode, Vision inference) happens on background queues;
/// only the final event hand-off hops to the main thread, as Flutter requires.
public class MetarayzerNativePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private enum Source: String {
    case companion
    case webcam
  }

  private let server = FrameServer()
  private let pipeline = FramePipeline(detector: VisionHandDetector(maximumHandCount: 2))
  private let webcam = WebcamSource()
  private var source: Source = .companion  // main thread only
  private var sink: FlutterEventSink?  // main thread only
  // Last state events, replayed when Dart (re)subscribes. Main thread only.
  private var lastServerEvent: [String: Any]?
  private var lastCompanionEvent: [String: Any]?
  private var lastCompanionStatus: [String: Any]?
  private var stats = PipelineStats()  // pipeline queue only

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MetarayzerNativePlugin()
    let control = FlutterMethodChannel(name: "metarayzer_native/control", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(instance, channel: control)
    let events = FlutterEventChannel(name: "metarayzer_native/events", binaryMessenger: registrar.messenger)
    events.setStreamHandler(instance)
  }

  override init() {
    super.init()
    server.delegate = self
    pipeline.onProcessed = { [weak self] frame in self?.emitFrame(frame) }
    pipeline.onError = { [weak self] message in self?.emit(["type": "error", "message": message]) }
    webcam.onFrame = { [weak self] frame in self?.submit(frame, from: .webcam) }
    webcam.onError = { [weak self] message in self?.emit(["type": "error", "message": message]) }
  }

  // MARK: - Method channel

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "startServer":
      server.start()
      result([
        "port": Int(WireProtocol.defaultPort),
        "bonjourType": WireProtocol.bonjourType,
        "addresses": FrameServer.localIPv4Addresses(),
        "detector": pipeline.detector.name,
        "hostName": Host.current().localizedName ?? "",
      ])
    case "stopServer":
      server.stop()
      result(nil)
    case "sendCommand":
      guard let command = args["cmd"] as? String else {
        return result(FlutterError(code: "bad_args", message: "cmd is required", details: nil))
      }
      server.send(command: ["cmd": command])
      result(nil)
    case "setSource":
      guard let name = args["source"] as? String, let newSource = Source(rawValue: name) else {
        return result(FlutterError(code: "bad_args", message: "source must be companion|webcam", details: nil))
      }
      setSource(newSource, result: result)
    case "setDetectionEnabled":
      pipeline.detectionEnabled = args["enabled"] as? Bool ?? true
      result(nil)
    case "ackFrame":
      pipeline.acknowledge()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func setSource(_ newSource: Source, result: @escaping FlutterResult) {
    guard newSource != source else { return result(nil) }
    source = newSource
    pipeline.reset()
    switch newSource {
    case .webcam:
      webcam.start { [weak self] error in
        DispatchQueue.main.async {
          self?.emit(["type": "webcam", "running": error == nil, "error": error as Any])
          if let error { result(FlutterError(code: "webcam", message: error, details: nil)) } else { result(nil) }
        }
      }
    case .companion:
      webcam.stop()
      emit(["type": "webcam", "running": false])
      result(nil)
    }
  }

  // MARK: - Event channel

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    pipeline.reset()  // any frames in flight were for a previous listener
    for event in [lastServerEvent, lastCompanionEvent, lastCompanionStatus].compactMap({ $0 }) {
      events(event)
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  /// Thread-safe: hops to main before touching the sink.
  private func emit(_ event: [String: Any]) {
    if Thread.isMainThread {
      sink?(event)
    } else {
      DispatchQueue.main.async { self.sink?(event) }
    }
  }

  private func submit(_ frame: IncomingFrame, from frameSource: Source) {
    DispatchQueue.main.async {
      guard frameSource == self.source else { return }
      self.pipeline.submit(frame)
    }
  }

  private func emitFrame(_ processed: ProcessedFrame) {
    stats.record(processed)
    var event: [String: Any] = [
      "type": "frame",
      "jpeg": FlutterStandardTypedData(bytes: processed.frame.jpeg),
      "width": processed.width,
      "height": processed.height,
      "seq": Int(processed.frame.seq),
      "source": processed.frame.source,
      "captureTimeMs": Int(processed.frame.captureTimeMs),
      "receivedAtMs": Int(processed.frame.receivedAtMs),
      "processedAtMs": Int(Date().timeIntervalSince1970 * 1000),
      "decodeMs": processed.decodeMs,
      "detectMs": processed.detectMs,
      "dropped": processed.droppedBefore,
    ]
    if let hands = processed.hands {
      event["hands"] = hands.map { hand -> [String: Any] in
        var flat = [Double]()
        flat.reserveCapacity(hand.landmarks.count * 3)
        for p in hand.landmarks { flat.append(contentsOf: [p.x, p.y, p.confidence]) }
        return [
          "landmarks": FlutterStandardTypedData(float64: flat.withUnsafeBufferPointer { Data(buffer: $0) }),
          "confidence": hand.confidence,
          "chirality": hand.chirality,
        ]
      }
    }
    DispatchQueue.main.async {
      if let sink = self.sink {
        sink(event)
      } else {
        // Nobody is displaying frames; don't let the pipeline stall waiting for an ack.
        self.pipeline.acknowledge()
      }
    }
  }
}

// MARK: - FrameServerDelegate

extension MetarayzerNativePlugin: FrameServerDelegate {
  func frameServer(_ server: FrameServer, listenerStateChanged state: FrameServer.ListenerState) {
    var event: [String: Any] = ["type": "server"]
    switch state {
    case .stopped: event["state"] = "stopped"
    case .starting: event["state"] = "starting"
    case .listening(let port):
      event["state"] = "listening"
      event["port"] = Int(port)
      event["addresses"] = FrameServer.localIPv4Addresses()
    case .failed(let message):
      event["state"] = "failed"
      event["message"] = message
    }
    DispatchQueue.main.async {
      self.lastServerEvent = event
      self.sink?(event)
    }
  }

  func frameServer(_ server: FrameServer, clientConnected name: String) {
    NSLog("[MetaRayzer] companion connected from \(name)")
    let event: [String: Any] = ["type": "companion", "connected": true, "address": name]
    DispatchQueue.main.async {
      self.lastCompanionEvent = event
      self.sink?(event)
    }
  }

  func frameServer(_ server: FrameServer, clientDisconnected reason: String?) {
    NSLog("[MetaRayzer] companion disconnected: \(reason ?? "closed")")
    let event: [String: Any] = ["type": "companion", "connected": false, "reason": reason as Any]
    DispatchQueue.main.async {
      self.lastCompanionEvent = event
      self.lastCompanionStatus = nil
      self.sink?(event)
    }
  }

  func frameServer(_ server: FrameServer, received message: WireMessage) {
    switch message {
    case .frame(let frame):
      let now = UInt64(Date().timeIntervalSince1970 * 1000)
      submit(IncomingFrame(jpeg: frame.jpeg, seq: frame.seq, captureTimeMs: frame.captureTimeMs,
                           receivedAtMs: now, source: "glasses"), from: .companion)
    case .hello(let info):
      let event: [String: Any] = ["type": "companion", "connected": true, "hello": info]
      DispatchQueue.main.async {
        var merged = self.lastCompanionEvent ?? [:]
        merged.merge(event) { _, new in new }
        self.lastCompanionEvent = merged
        self.sink?(merged)
      }
    case .status(let status):
      let event: [String: Any] = ["type": "companionStatus", "status": status]
      DispatchQueue.main.async {
        self.lastCompanionStatus = event
        self.sink?(event)
      }
    case .command:
      break  // commands only flow mac -> phone
    }
  }
}

/// Periodic diagnostic log line so frame flow can be checked from Console/stderr.
private struct PipelineStats {
  private var windowStart = CFAbsoluteTimeGetCurrent()
  private var frames = 0
  private var dropped = 0
  private var hands = 0
  private var detectMs = 0.0

  mutating func record(_ f: ProcessedFrame) {
    frames += 1
    dropped += f.droppedBefore
    hands += f.hands?.count ?? 0
    detectMs += f.detectMs
    let elapsed = CFAbsoluteTimeGetCurrent() - windowStart
    guard elapsed >= 5 else { return }
    NSLog("[MetaRayzer] stats: %.1f fps processed, %d dropped, avg %.1f ms detect, avg %.2f hands/frame, last %dx%d from %@",
          Double(frames) / elapsed, dropped, detectMs / Double(frames), Double(hands) / Double(frames),
          f.width, f.height, f.frame.source)
    self = PipelineStats()
  }
}
