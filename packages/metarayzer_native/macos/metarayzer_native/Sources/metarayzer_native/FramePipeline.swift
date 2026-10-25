import CoreGraphics
import Foundation
import ImageIO

struct IncomingFrame {
  var jpeg: Data
  var seq: UInt32
  /// Capture time on the sender's clock (Unix ms); 0 if unknown.
  var captureTimeMs: UInt64
  /// Mac wall-clock time the frame finished arriving (Unix ms).
  var receivedAtMs: UInt64
  var source: String
}

struct ProcessedFrame {
  var frame: IncomingFrame
  var width: Int
  var height: Int
  /// nil when detection is disabled for this frame.
  var hands: [DetectedHand]?
  var decodeMs: Double
  var detectMs: Double
  /// Frames that arrived while we were busy and were skipped in favour of a newer one.
  var droppedBefore: Int
}

/// Latest-frame-wins processing loop.
///
/// Frames can arrive faster than we can decode + detect + display them. Instead of queueing,
/// the pipeline keeps exactly one pending frame and overwrites it with each new arrival; the
/// worker always picks up the newest. Display backpressure works the same way: at most
/// `maxOutstanding` processed frames may be waiting for the UI to acknowledge them.
final class FramePipeline {
  /// Called on the pipeline's background queue.
  var onProcessed: ((ProcessedFrame) -> Void)?
  var onError: ((String) -> Void)?

  var detectionEnabled: Bool {
    get { lock.locked { _detectionEnabled } }
    set { lock.locked { _detectionEnabled = newValue } }
  }

  let detector: HandDetector

  private let queue = DispatchQueue(label: "metarayzer.pipeline", qos: .userInteractive)
  private let lock = NSLock()
  private let maxOutstanding = 2
  // Guarded by `lock`.
  private var pending: IncomingFrame?
  private var busy = false
  private var dropped = 0
  private var outstanding = 0
  private var _detectionEnabled = true

  init(detector: HandDetector) {
    self.detector = detector
  }

  func submit(_ frame: IncomingFrame) {
    let start: Bool = lock.locked {
      if pending != nil { dropped += 1 }
      pending = frame
      return claimWorkerLocked()
    }
    if start { queue.async { self.drain() } }
  }

  /// The UI has taken delivery of one processed frame.
  func acknowledge() {
    let start: Bool = lock.locked {
      outstanding = max(0, outstanding - 1)
      return claimWorkerLocked()
    }
    if start { queue.async { self.drain() } }
  }

  /// Forget any queued frame and outstanding acks (e.g. when the source changes).
  func reset() {
    lock.locked {
      pending = nil
      dropped = 0
      outstanding = 0
    }
  }

  private func claimWorkerLocked() -> Bool {
    guard !busy, pending != nil, outstanding < maxOutstanding else { return false }
    busy = true
    return true
  }

  private func drain() {
    while true {
      let next: (IncomingFrame, Int, Bool)? = lock.locked {
        guard let frame = pending, outstanding < maxOutstanding else {
          busy = false
          return nil
        }
        pending = nil
        outstanding += 1
        defer { dropped = 0 }
        return (frame, dropped, _detectionEnabled)
      }
      guard let (frame, droppedBefore, detect) = next else { return }
      process(frame, droppedBefore: droppedBefore, detect: detect)
    }
  }

  private func process(_ frame: IncomingFrame, droppedBefore: Int, detect: Bool) {
    let t0 = CFAbsoluteTimeGetCurrent()
    guard let image = Self.decode(frame.jpeg) else {
      lock.locked { outstanding = max(0, outstanding - 1) }
      onError?("Could not decode frame \(frame.seq) (\(frame.jpeg.count) bytes)")
      return
    }
    let t1 = CFAbsoluteTimeGetCurrent()
    var hands: [DetectedHand]? = nil
    if detect {
      do {
        hands = try detector.detect(in: image)
      } catch {
        // Treat a failed inference like "nothing detected" for this frame; the tracker coasts.
        hands = []
        onError?("Hand detection failed: \(error.localizedDescription)")
      }
    }
    let t2 = CFAbsoluteTimeGetCurrent()
    onProcessed?(ProcessedFrame(
      frame: frame, width: image.width, height: image.height, hands: hands,
      decodeMs: (t1 - t0) * 1000, detectMs: detect ? (t2 - t1) * 1000 : 0,
      droppedBefore: droppedBefore))
  }

  static func decode(_ jpeg: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
    let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    return CGImageSourceCreateImageAtIndex(source, 0, options)
  }
}

extension NSLock {
  func locked<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
