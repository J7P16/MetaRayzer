import 'dart:math' as math;
import 'dart:typed_data';

/// Coarse static hand pose, enough for "ready" (fist) vs "cast" (open palm).
enum HandPose {
  fist,
  open,

  /// Partially open, ambiguous (e.g. two fingers up), or not enough confident joints.
  unknown,
}

class PoseClassification {
  const PoseClassification({required this.pose, required this.confidence, required this.openness, this.fingerExtension = const []});

  static const none = PoseClassification(pose: HandPose.unknown, confidence: 0, openness: 0);

  final HandPose pose;

  /// 0..1: how much to trust [pose] (joint confidence of the joints used).
  final double confidence;

  /// 0 (all four fingers curled) .. 1 (all four fully extended). Continuous, used for the
  /// "charging" feedback while the hand opens.
  final double openness;

  /// Per finger (index, middle, ring, little), 0..1; -1 when the finger couldn't be measured.
  final List<double> fingerExtension;

  @override
  String toString() => 'PoseClassification(${pose.name}, conf=${confidence.toStringAsFixed(2)}, open=${openness.toStringAsFixed(2)})';
}

class PoseClassifierConfig {
  const PoseClassifierConfig({
    this.minJointConfidence = 0.3,
    this.curledRatio = 1.15,
    this.extendedRatio = 1.75,
    this.fingerExtendedAt = 0.55,
    this.fingerCurledAt = 0.35,
    this.minExtendedForOpen = 3,
    this.minCurledForFist = 3,
  });

  final double minJointConfidence;

  /// |wrist→tip| / |wrist→MCP| at which a finger counts as fully curled (0) and fully
  /// extended (1). Ratios in between are interpolated.
  final double curledRatio;
  final double extendedRatio;

  /// Per-finger extension above which a finger is "extended" / below which it is "curled".
  final double fingerExtendedAt;
  final double fingerCurledAt;

  /// Open palm: at least this many of the 4 fingers extended and none curled.
  final int minExtendedForOpen;

  /// Fist: at least this many curled and none extended.
  final int minCurledForFist;
}

/// Landmark-based fist / open-palm classifier (no extra model).
///
/// Works on the 21 MediaPipe-order joints the native detector already produces. For each of the
/// four fingers it compares the wrist→fingertip distance with the wrist→knuckle (MCP) distance:
/// an extended finger's tip is ~1.8-2.2x farther from the wrist than its knuckle, a curled
/// finger's tip folds back to ~1x. The ratio is scale- and rotation-invariant in the image plane.
/// The thumb is ignored (it's unreliable in both poses).
///
/// Limitation: fingers pointing straight at/away from the camera are foreshortened and look
/// curled. Players should cast with fingers pointing up (a "stop" gesture), see README.
class PoseClassifier {
  const PoseClassifier({this.config = const PoseClassifierConfig()});

  final PoseClassifierConfig config;

  static const _fingers = [(5, 8), (9, 12), (13, 16), (17, 20)]; // (MCP, tip)
  static const _wrist = 0;

  /// [aspect] = frame width / height, so distances are measured in square pixels.
  PoseClassification classify(Float64List landmarks, {double aspect = 1, double handConfidence = 1}) {
    if (landmarks.length < 63) return PoseClassification.none;
    double x(int j) => landmarks[j * 3] * aspect;
    double y(int j) => landmarks[j * 3 + 1];
    double c(int j) => landmarks[j * 3 + 2];
    double dist(int a, int b) => math.sqrt(math.pow(x(a) - x(b), 2) + math.pow(y(a) - y(b), 2));

    if (c(_wrist) < config.minJointConfidence) return PoseClassification.none;

    final extensions = <double>[];
    final confidences = <double>[c(_wrist)];
    for (final (mcp, tip) in _fingers) {
      if (c(mcp) < config.minJointConfidence || c(tip) < config.minJointConfidence) {
        extensions.add(-1);
        continue;
      }
      final base = dist(_wrist, mcp);
      if (base < 1e-6) {
        extensions.add(-1);
        continue;
      }
      final ratio = dist(_wrist, tip) / base;
      extensions.add(((ratio - config.curledRatio) / (config.extendedRatio - config.curledRatio)).clamp(0.0, 1.0));
      confidences
        ..add(c(mcp))
        ..add(c(tip));
    }

    final measured = extensions.where((e) => e >= 0).toList();
    if (measured.length < 3) {
      return PoseClassification(pose: HandPose.unknown, confidence: 0, openness: 0, fingerExtension: extensions);
    }
    final openness = measured.reduce((a, b) => a + b) / measured.length;
    final extended = measured.where((e) => e >= config.fingerExtendedAt).length;
    final curled = measured.where((e) => e <= config.fingerCurledAt).length;
    final jointConfidence = confidences.reduce((a, b) => a + b) / confidences.length;
    // Missing fingers lower confidence proportionally.
    final confidence = (jointConfidence * handConfidence * measured.length / 4).clamp(0.0, 1.0);

    final HandPose pose;
    if (extended >= config.minExtendedForOpen && curled == 0) {
      pose = HandPose.open;
    } else if (curled >= config.minCurledForFist && extended == 0) {
      pose = HandPose.fist;
    } else {
      pose = HandPose.unknown;
    }
    return PoseClassification(pose: pose, confidence: confidence, openness: openness, fingerExtension: extensions);
  }
}
