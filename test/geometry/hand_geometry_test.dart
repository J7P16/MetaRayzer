import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/geometry/hand_geometry.dart';

/// 21 joints, all at (x, y) with confidence [c], then individual overrides.
Float64List landmarks({double x = 0.5, double y = 0.5, double c = 0.9, Map<int, (double, double, double)> joints = const {}}) {
  final l = Float64List(63);
  for (var j = 0; j < 21; j++) {
    final (jx, jy, jc) = joints[j] ?? (x, y, c);
    l[j * 3] = jx;
    l[j * 3 + 1] = jy;
    l[j * 3 + 2] = jc;
  }
  return l;
}

void main() {
  test('palm centroid averages wrist and MCP joints only', () {
    final l = landmarks(x: 0.9, y: 0.9, joints: {
      0: (0.2, 0.6, 1),
      5: (0.3, 0.4, 1),
      9: (0.4, 0.4, 1),
      13: (0.5, 0.4, 1),
      17: (0.6, 0.4, 1),
    });
    final c = HandGeometry.palmCentroid(l)!;
    expect(c.x, closeTo(0.4, 1e-12));
    expect(c.y, closeTo(0.44, 1e-12));
  });

  test('palm centroid ignores low-confidence joints and needs at least 3', () {
    final two = landmarks(c: 0, joints: {0: (0.1, 0.1, 1), 5: (0.3, 0.3, 1)});
    expect(HandGeometry.palmCentroid(two), isNull);

    final three = landmarks(c: 0, joints: {0: (0.1, 0.1, 1), 5: (0.3, 0.3, 1), 9: (0.2, 0.5, 0.8), 13: (0.9, 0.9, 0.1)});
    final c = HandGeometry.palmCentroid(three)!;
    expect(c.x, closeTo(0.2, 1e-12));
    expect(c.y, closeTo(0.3, 1e-12));
  });

  test('bounding box covers confident joints', () {
    final l = landmarks(c: 0, joints: {0: (0.1, 0.8, 1), 4: (0.05, 0.5, 1), 8: (0.3, 0.2, 1), 20: (0.99, 0.01, 0.1)});
    final box = HandGeometry.boundingBox(l)!;
    expect((box.left, box.top, box.right, box.bottom), (0.05, 0.2, 0.3, 0.8));
    expect(box.center.x, closeTo(0.175, 1e-12));
    expect(box.center.y, closeTo(0.5, 1e-12));
  });

  test('center falls back to bounding box when the palm is not visible', () {
    final l = landmarks(c: 0, joints: {4: (0.2, 0.2, 1), 8: (0.4, 0.6, 1)});
    final c = HandGeometry.center(l)!;
    expect(c.x, closeTo(0.3, 1e-12));
    expect(c.y, closeTo(0.4, 1e-12));
    expect(HandGeometry.center(landmarks(c: 0)), isNull);
  });

  test('IoU', () {
    const a = NormRect(0, 0, 0.2, 0.2);
    expect(a.iou(a), 1);
    expect(a.iou(const NormRect(0.5, 0.5, 0.6, 0.6)), 0);
    expect(a.iou(const NormRect(0.1, 0, 0.3, 0.2)), closeTo(1 / 3, 1e-12));
  });

  test('distance is in units of the frame diagonal and respects aspect', () {
    const a = NormPoint(0, 0), b = NormPoint(1, 1);
    expect(a.distanceTo(b), closeTo(1, 1e-12));
    expect(a.distanceTo(b, aspect: 504 / 896), closeTo(1, 1e-12));
    // Moving across the full width of a portrait frame is a shorter physical distance than
    // moving across its full height.
    const aspect = 504 / 896;
    expect(a.distanceTo(const NormPoint(1, 0), aspect: aspect), lessThan(a.distanceTo(const NormPoint(0, 1), aspect: aspect)));
  });
}
