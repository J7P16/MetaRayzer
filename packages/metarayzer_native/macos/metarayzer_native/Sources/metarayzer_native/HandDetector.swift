import CoreGraphics
import Foundation
import Vision

/// One hand found in a frame. Coordinates are normalized to the frame with a top-left origin:
/// x in [0, 1] grows rightward, y in [0, 1] grows downward (image convention).
struct DetectedHand {
  /// Exactly `HandJoint.allCases.count` entries in `HandJoint` order. Joints the model could not
  /// locate have `confidence == 0`.
  var landmarks: [(x: Double, y: Double, confidence: Double)]
  /// Overall detection confidence, 0...1.
  var confidence: Double
  /// "left", "right" or "unknown", from the model's perspective of the image.
  var chirality: String
}

/// 21-joint hand skeleton in the same order as MediaPipe Hand Landmarker, so a MediaPipe- or
/// TFLite-based detector can be dropped in without changing the Dart side.
enum HandJoint: Int, CaseIterable {
  case wrist
  case thumbCMC, thumbMCP, thumbIP, thumbTip
  case indexMCP, indexPIP, indexDIP, indexTip
  case middleMCP, middlePIP, middleDIP, middleTip
  case ringMCP, ringPIP, ringDIP, ringTip
  case littleMCP, littlePIP, littleDIP, littleTip
}

/// Swap-in point for the hand model. Implementations are called from a single background queue,
/// one frame at a time, and may keep per-instance state.
protocol HandDetector {
  var name: String { get }
  func detect(in image: CGImage) throws -> [DetectedHand]
}

/// Apple Vision `VNDetectHumanHandPoseRequest`: on-device, ships with macOS, runs on the
/// Neural Engine/GPU on Apple silicon, returns 21 joints per hand.
final class VisionHandDetector: HandDetector {
  let name = "Apple Vision VNDetectHumanHandPoseRequest"

  private let request: VNDetectHumanHandPoseRequest

  init(maximumHandCount: Int = 2) {
    request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = maximumHandCount
  }

  func detect(in image: CGImage) throws -> [DetectedHand] {
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
    try handler.perform([request])
    return (request.results ?? []).compactMap(Self.convert)
  }

  private static let jointNames: [HandJoint: VNHumanHandPoseObservation.JointName] = [
    .wrist: .wrist,
    .thumbCMC: .thumbCMC, .thumbMCP: .thumbMP, .thumbIP: .thumbIP, .thumbTip: .thumbTip,
    .indexMCP: .indexMCP, .indexPIP: .indexPIP, .indexDIP: .indexDIP, .indexTip: .indexTip,
    .middleMCP: .middleMCP, .middlePIP: .middlePIP, .middleDIP: .middleDIP, .middleTip: .middleTip,
    .ringMCP: .ringMCP, .ringPIP: .ringPIP, .ringDIP: .ringDIP, .ringTip: .ringTip,
    .littleMCP: .littleMCP, .littlePIP: .littlePIP, .littleDIP: .littleDIP, .littleTip: .littleTip,
  ]

  private static func convert(_ observation: VNHumanHandPoseObservation) -> DetectedHand? {
    guard let points = try? observation.recognizedPoints(.all) else { return nil }
    let landmarks = HandJoint.allCases.map { joint -> (x: Double, y: Double, confidence: Double) in
      guard let name = jointNames[joint], let p = points[name], p.confidence > 0 else {
        return (0, 0, 0)
      }
      // Vision uses a bottom-left origin; flip to the top-left image convention.
      return (Double(p.location.x), 1 - Double(p.location.y), Double(p.confidence))
    }
    let chirality: String
    switch observation.chirality {
    case .left: chirality = "left"
    case .right: chirality = "right"
    default: chirality = "unknown"
    }
    return DetectedHand(landmarks: landmarks, confidence: Double(observation.confidence), chirality: chirality)
  }
}
