import Foundation
import UIKit

/// Converts glasses frames to upright JPEGs off the main thread. Latest-frame-wins: if a frame
/// arrives while the previous one is still being encoded, it waits in a single pending slot and
/// replaces any older pending frame.
final class FrameEncoder: @unchecked Sendable {
  /// Called on the encoder queue with each encoded frame.
  var onEncoded: ((FrameMessage, UIImage) -> Void)?
  var quality: CGFloat = 0.6

  private let queue = DispatchQueue(label: "metarayzer.encoder", qos: .userInteractive)
  private let lock = NSLock()
  private var pending: (UIImage, UInt64)?
  private var busy = false
  private var seq: UInt32 = 0

  func submit(_ image: UIImage, captureTimeMs: UInt64) {
    let start: Bool = lock.withLock {
      pending = (image, captureTimeMs)
      if busy { return false }
      busy = true
      return true
    }
    if start { queue.async { self.drain() } }
  }

  private func drain() {
    while true {
      let next: (UIImage, UInt64)? = lock.withLock {
        guard let p = pending else {
          busy = false
          return nil
        }
        pending = nil
        return p
      }
      guard let (image, captureTimeMs) = next else { return }
      let upright = Self.upright(image)
      guard let jpeg = upright.jpegData(compressionQuality: quality), let cg = upright.cgImage else { continue }
      seq &+= 1
      let frame = FrameMessage(seq: seq, captureTimeMs: captureTimeMs,
                               width: UInt16(clamping: cg.width), height: UInt16(clamping: cg.height), jpeg: jpeg)
      onEncoded?(frame, upright)
    }
  }

  /// Bakes any EXIF-style orientation into the pixels so the Mac never has to guess rotation.
  static func upright(_ image: UIImage) -> UIImage {
    guard image.imageOrientation != .up else { return image }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }
  }
}
