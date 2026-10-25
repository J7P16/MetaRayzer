import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/games/wizard/shield_gesture.dart';
import 'package:metarayzer/src/geometry/view_mapping.dart';
import 'package:metarayzer/src/input/camera_hand_input.dart';
import 'package:metarayzer/src/input/hand_input.dart';
import 'package:metarayzer/src/input/hand_pose.dart';
import 'package:metarayzer/src/input/simulated_hand_input.dart';

/// Real Apple Vision landmarks from test/fixtures (MediaPipe order, normalized, top-left).
({Float64List landmarks, int width, int height}) fixture(String source, {int hand = 0}) {
  final doc = jsonDecode(File('test/fixtures/real_hand_landmarks.json').readAsStringSync()) as Map;
  final h = (doc['hands'] as List).cast<Map>().firstWhere((h) => h['source'] == source && h['hand'] == hand);
  return (
    landmarks: Float64List.fromList((h['landmarks'] as List).cast<num>().map((n) => n.toDouble()).toList()),
    width: h['width'] as int,
    height: h['height'] as int,
  );
}

/// Re-poses a real hand in a [w]×[h] frame: rotate by [radians] about its wrist→knuckle midpoint,
/// scale by [scale], and move that point to [center] (normalized). Done in pixels so the hand
/// keeps its real proportions.
Float64List repose(Float64List lm, int srcW, int srcH, {required double radians, required double scale, required Offset center, int w = 504, int h = 896}) {
  final out = Float64List(lm.length);
  final px = (lm[0] + lm[27]) / 2 * srcW, py = (lm[1] + lm[28]) / 2 * srcH;
  final (c, s) = (math.cos(radians), math.sin(radians));
  for (var j = 0; j < 21; j++) {
    final x = (lm[j * 3] * srcW - px) * scale, y = (lm[j * 3 + 1] * srcH - py) * scale;
    out[j * 3] = (center.dx * w + x * c - y * s) / w;
    out[j * 3 + 1] = (center.dy * h + x * s + y * c) / h;
    out[j * 3 + 2] = lm[j * 3 + 2];
  }
  return out;
}

FrameViewMapping mapping({bool mirrored = false, int turns = 0}) => FrameViewMapping(frameSize: const Size(504, 896), viewSize: const Size(1, 1), mirrored: mirrored, quarterTurns: turns);

/// The real open palm (photographed sideways, fingers pointing left) turned upright.
Float64List uprightPalm({double scale = 4.5, Offset center = const Offset(0.5, 0.48), double extraTilt = 0}) {
  final f = fixture('male_full_height_hands.jpg');
  return repose(f.landmarks, f.width, f.height, radians: math.pi / 2 + extraTilt, scale: scale, center: center);
}

HandInputFrame frame(int id, HandShape? shape, {double t = 0, HandTrackingStatus status = HandTrackingStatus.tracking}) => HandInputFrame(
      status: status,
      frameId: id,
      timestampMs: t,
      position: shape?.bounds.center,
      shape: shape,
      classification: const PoseClassification(pose: HandPose.open, confidence: 1, openness: 1),
    );

void main() {
  const config = ShieldGestureConfig();

  group('hand shape from real landmarks', () {
    test('an upright real palm raised close to the camera meets the blocking pose', () {
      final shape = CameraHandInput.handShape(uprightPalm(), mapping())!;
      final m = BlockPoseMetrics.measure(shape, config.region);
      expect(shape.tilt, lessThan(config.maxTilt), reason: 'fingers up');
      expect(m.coverage, greaterThanOrEqualTo(config.minCoverage));
      expect(m.palmLength, greaterThanOrEqualTo(config.minPalmLength));
      expect(m.reach, greaterThanOrEqualTo(config.minReach));
    });

    test('the same hand at arm\'s length does not (too small to cover the region)', () {
      final shape = CameraHandInput.handShape(uprightPalm(scale: 1.5), mapping())!;
      final m = BlockPoseMetrics.measure(shape, config.region);
      expect(m.coverage, lessThan(config.minCoverage));
      expect(m.palmLength, lessThan(config.minPalmLength));
    });

    test('a close hand lying sideways (not a vertical line) is rejected by orientation', () {
      final shape = CameraHandInput.handShape(uprightPalm(extraTilt: 1.2), mapping())!;
      expect(shape.tilt, greaterThan(config.maxTilt));
    });

    test('a real fist (thumb-up photo) is rejected', () {
      final f = fixture('thumb_up.jpg');
      final shape = CameraHandInput.handShape(repose(f.landmarks, f.width, f.height, radians: 0, scale: 1.4, center: const Offset(0.5, 0.5)), mapping())!;
      final m = BlockPoseMetrics.measure(shape, config.region);
      final enters = m.coverage >= config.minCoverage && m.palmLength >= config.minPalmLength && m.tilt <= config.maxTilt && m.reach >= config.minReach;
      expect(enters, isFalse);
    });

    test('a hand off to the side of the region does not count, even when large', () {
      final shape = CameraHandInput.handShape(uprightPalm(center: const Offset(0.12, 0.5)), mapping())!;
      expect(BlockPoseMetrics.measure(shape, config.region).coverage, 0);
    });

    test('mirroring the preview keeps the measurement (same display space as the cursor)', () {
      final a = CameraHandInput.handShape(uprightPalm(), mapping())!;
      final b = CameraHandInput.handShape(uprightPalm(), mapping(mirrored: true))!;
      expect(b.tilt, closeTo(a.tilt, 1e-9));
      expect(b.palmLength, closeTo(a.palmLength, 1e-9));
      expect(b.bounds.center.dx, closeTo(1 - a.bounds.center.dx, 1e-9));
    });

    test('too few confident joints gives no shape (fails safe)', () {
      final lm = uprightPalm();
      for (var j = 0; j < 21; j++) {
        lm[j * 3 + 2] = j < 5 ? 0.9 : 0.1;
      }
      expect(CameraHandInput.handShape(lm, mapping()), isNull);
    });
  });

  group('recognizer', () {
    final block = CameraHandInput.handShape(uprightPalm(), mapping())!;
    final relaxed = CameraHandInput.handShape(uprightPalm(scale: 1.5), mapping())!;

    test('needs consecutive confirming frames, then reports the activation once', () {
      final r = ShieldGestureRecognizer();
      expect(r.update(frame(1, block)), isFalse);
      expect(r.held, isFalse);
      expect(r.update(frame(2, block)), isTrue);
      expect(r.held, isTrue);
      for (var i = 3; i < 60; i++) {
        expect(r.update(frame(i, block)), isFalse, reason: 'holding never re-reports');
      }
      expect(r.held, isTrue);
    });

    test('a single noisy frame neither activates nor releases', () {
      final r = ShieldGestureRecognizer();
      r.update(frame(1, block));
      r.update(frame(2, relaxed));
      r.update(frame(3, block));
      expect(r.held, isFalse, reason: 'the confirm count restarted');
      r.update(frame(4, block));
      expect(r.held, isTrue);
      r.update(frame(5, relaxed));
      expect(r.held, isTrue, reason: 'one bad frame is not a release');
      r.update(frame(6, relaxed));
      expect(r.held, isFalse);
    });

    test('status-only re-deliveries of a frame are not counted twice', () {
      final r = ShieldGestureRecognizer();
      r.update(frame(1, block));
      expect(r.update(frame(1, block)), isFalse);
      expect(r.held, isFalse);
    });

    test('low confidence frames are ignored', () {
      final r = ShieldGestureRecognizer();
      final weak = HandShape(bounds: block.bounds, wrist: block.wrist, middleKnuckle: block.middleKnuckle, aspect: block.aspect, confidence: 0.2);
      for (var i = 1; i < 10; i++) {
        expect(r.update(frame(i, weak)), isFalse);
      }
      expect(r.held, isFalse);
    });

    test('a short dropout keeps the pose; a long one releases it; a dropout never activates', () {
      final r = ShieldGestureRecognizer();
      r.update(frame(1, block, t: 0));
      r.update(frame(2, block, t: 40));
      expect(r.held, isTrue);
      r.update(frame(3, null, t: 80, status: HandTrackingStatus.lost));
      r.update(frame(4, null, t: 200, status: HandTrackingStatus.lost));
      expect(r.held, isTrue, reason: '120 ms gap');
      r.update(frame(5, null, t: 400, status: HandTrackingStatus.lost));
      expect(r.held, isFalse, reason: '320 ms gap');
      expect(r.update(frame(6, block, t: 420)), isFalse, reason: 'reappearing needs fresh confirmation');
      expect(r.update(frame(7, block, t: 460)), isTrue);
    });

    test('the simulated block pose is recognized; the simulated casting hand is not', () {
      final r = ShieldGestureRecognizer();
      r.update(frame(1, SimulatedHandInput.blockShape));
      expect(r.update(frame(2, SimulatedHandInput.blockShape)), isTrue);
      final sim = SimulatedHandInput()
        ..move(const Offset(0.5, 0.5))
        ..active = true;
      final cast = ShieldGestureRecognizer();
      for (var i = 0; i < 5; i++) {
        expect(cast.update(HandInputFrame(status: HandTrackingStatus.tracking, frameId: i, timestampMs: i * 33.0, shape: sim.value.shape)), isFalse);
      }
      sim.dispose();
    });
  });
}
