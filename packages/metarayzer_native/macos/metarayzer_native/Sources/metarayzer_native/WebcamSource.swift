import AVFoundation
import CoreImage
import Foundation

/// DEVELOPMENT FALLBACK ONLY: feeds the Mac's own camera through the same pipeline so the
/// detection, tracking and overlay can be validated without glasses or a phone. Frames are
/// JPEG-encoded so they follow exactly the same decode path as frames from the companion.
final class WebcamSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  var onFrame: ((IncomingFrame) -> Void)?
  var onError: ((String) -> Void)?

  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "metarayzer.webcam", qos: .userInteractive)
  private let ciContext = CIContext()
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private var seq: UInt32 = 0
  private var configured = false

  func start(completion: @escaping (String?) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      queue.async { completion(self.startOnQueue()) }
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        if granted {
          self.queue.async { completion(self.startOnQueue()) }
        } else {
          completion("Camera access was denied.")
        }
      }
    default:
      completion("Camera access is denied. Enable it in System Settings > Privacy & Security > Camera.")
    }
  }

  func stop() {
    queue.async {
      if self.session.isRunning { self.session.stopRunning() }
    }
  }

  private func startOnQueue() -> String? {
    if !configured {
      guard let device = AVCaptureDevice.default(for: .video) else { return "No camera found on this Mac." }
      session.beginConfiguration()
      session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
      do {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { return "Cannot use camera \(device.localizedName)." }
        session.addInput(input)
      } catch {
        session.commitConfiguration()
        return "Cannot open camera: \(error.localizedDescription)"
      }
      let output = AVCaptureVideoDataOutput()
      output.alwaysDiscardsLateVideoFrames = true
      output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
      output.setSampleBufferDelegate(self, queue: queue)
      guard session.canAddOutput(output) else {
        session.commitConfiguration()
        return "Cannot read frames from camera."
      }
      session.addOutput(output)
      session.commitConfiguration()
      configured = true
    }
    if !session.isRunning { session.startRunning() }
    return nil
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]
    guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
      onError?("Could not encode webcam frame")
      return
    }
    seq &+= 1
    let now = UInt64(Date().timeIntervalSince1970 * 1000)
    onFrame?(IncomingFrame(jpeg: jpeg, seq: seq, captureTimeMs: now, receivedAtMs: now, source: "mac-webcam"))
  }
}
