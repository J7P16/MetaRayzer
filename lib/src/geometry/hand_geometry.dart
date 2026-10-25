import 'dart:math' as math;
import 'dart:typed_data';

/// A point in normalized frame coordinates (0..1, top-left origin, +y down).
class NormPoint {
  const NormPoint(this.x, this.y);
  final double x;
  final double y;

  /// Distance in units of the frame diagonal, so it means the same thing for portrait and
  /// landscape frames. [aspect] is width / height.
  double distanceTo(NormPoint other, {double aspect = 1}) {
    final dx = (x - other.x) * aspect;
    final dy = y - other.y;
    return math.sqrt(dx * dx + dy * dy) / math.sqrt(aspect * aspect + 1);
  }

  @override
  String toString() => '(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})';
}

/// Axis-aligned rectangle in normalized frame coordinates.
class NormRect {
  const NormRect(this.left, this.top, this.right, this.bottom);
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get area => math.max(0, width) * math.max(0, height);
  NormPoint get center => NormPoint((left + right) / 2, (top + bottom) / 2);

  double iou(NormRect other) {
    final ix = math.max(0.0, math.min(right, other.right) - math.max(left, other.left));
    final iy = math.max(0.0, math.min(bottom, other.bottom) - math.max(top, other.top));
    final inter = ix * iy;
    final union = area + other.area - inter;
    return union <= 0 ? 0 : inter / union;
  }
}

/// How a hand's single "center" point is derived from its landmarks.
enum CenterMode {
  /// Mean of wrist + the four finger MCP knuckles. Stays put while fingers move, so it is the
  /// most stable choice for a position indicator. Falls back to [boundingBox] when fewer than
  /// three of those joints are confident.
  palmCentroid,

  /// Center of the box around all confident landmarks.
  boundingBox,
}

/// Joint indices in MediaPipe order: wrist, index/middle/ring/little MCP.
const List<int> kPalmJoints = [0, 5, 9, 13, 17];

/// Geometry helpers over a flat `[x, y, confidence] * 21` landmark list.
class HandGeometry {
  HandGeometry._();

  static NormRect? boundingBox(Float64List landmarks, {double minConfidence = 0.3}) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    var count = 0;
    for (var i = 0; i + 2 < landmarks.length; i += 3) {
      if (landmarks[i + 2] < minConfidence) continue;
      minX = math.min(minX, landmarks[i]);
      maxX = math.max(maxX, landmarks[i]);
      minY = math.min(minY, landmarks[i + 1]);
      maxY = math.max(maxY, landmarks[i + 1]);
      count++;
    }
    return count == 0 ? null : NormRect(minX, minY, maxX, maxY);
  }

  static NormPoint? palmCentroid(Float64List landmarks, {double minConfidence = 0.3, int minJoints = 3}) {
    var sx = 0.0, sy = 0.0;
    var n = 0;
    for (final j in kPalmJoints) {
      if (landmarks[j * 3 + 2] < minConfidence) continue;
      sx += landmarks[j * 3];
      sy += landmarks[j * 3 + 1];
      n++;
    }
    return n < minJoints ? null : NormPoint(sx / n, sy / n);
  }

  /// The hand center per [mode], or null if the landmarks are too unreliable to place it.
  static NormPoint? center(Float64List landmarks, {CenterMode mode = CenterMode.palmCentroid, double minConfidence = 0.3}) {
    if (mode == CenterMode.palmCentroid) {
      final palm = palmCentroid(landmarks, minConfidence: minConfidence);
      if (palm != null) return palm;
    }
    return boundingBox(landmarks, minConfidence: minConfidence)?.center;
  }
}
