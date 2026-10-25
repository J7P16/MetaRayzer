import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/games/wizard/aim.dart';
import 'package:metarayzer/src/games/wizard/spell_switch.dart';
import 'package:metarayzer/src/input/hand_input.dart';
import 'package:metarayzer/src/input/hand_pose.dart';
import 'package:metarayzer/src/input/head_pose.dart';

const deg = math.pi / 180;

/// Head turned right by [yaw] (rotation about +y, right-handed: turning right = negative angle
/// about +y when looking down -z) and up by [pitch].
Quat headPose(double yaw, [double pitch = 0]) => Quat.axisAngle(0, 1, 0, -yaw) * Quat.axisAngle(1, 0, 0, pitch);

void main() {
  group('HeadPoseTracker', () {
    test('first sample is the baseline: output starts at zero even if the head is turned', () {
      final t = HeadPoseTracker();
      t.addSample(headPose(30 * deg), 0);
      expect(t.yaw, closeTo(0, 1e-9));
      expect(t.statusAt(10), HeadTrackingStatus.tracking);
    });

    test('measures relative yaw (right = positive) and pitch (up = positive)', () {
      final t = HeadPoseTracker(config: const HeadTrackerConfig(filterMinCutoff: 1000, filterBeta: 0)); // ~no smoothing
      t.addSample(headPose(10 * deg), 0);
      for (var i = 1; i <= 30; i++) {
        t.addSample(headPose(30 * deg, 8 * deg), i * 33.0);
      }
      expect(t.yaw, closeTo(20 * deg, 0.5 * deg));
      expect(t.pitch, closeTo(8 * deg, 0.5 * deg));
    });

    test('dropout: output eases back toward center instead of freezing, no jumps on reacquire', () {
      final t = HeadPoseTracker(config: const HeadTrackerConfig(filterMinCutoff: 1000, filterBeta: 0));
      t.addSample(headPose(0), 0);
      for (var i = 1; i <= 20; i++) {
        t.addSample(headPose(25 * deg), i * 33.0);
      }
      final before = t.yaw;
      var now = 20 * 33.0;
      for (var i = 0; i < 30; i++) {
        now += 33;
        t.tick(now);
      }
      expect(t.statusAt(now), HeadTrackingStatus.lost);
      expect(t.yaw.abs(), lessThan(before.abs()));
      final held = t.yaw;
      // Reacquire with the head at a very different absolute orientation: no jump.
      now += 33;
      t.addSample(headPose(-40 * deg), now);
      expect((t.yaw - held).abs(), lessThan(1 * deg));
    });

    test('unavailable after a long silence or with no samples at all', () {
      final t = HeadPoseTracker();
      expect(t.statusAt(0), HeadTrackingStatus.unavailable);
      t.addSample(Quat.identity, 0);
      expect(t.statusAt(5000), HeadTrackingStatus.unavailable);
    });

    test('recenter makes the current pose straight ahead, smoothly', () {
      final t = HeadPoseTracker(config: const HeadTrackerConfig(filterMinCutoff: 1000, filterBeta: 0, offsetDecayTimeConstantS: 0.3));
      t.addSample(headPose(0), 0);
      t.addSample(headPose(20 * deg), 33);
      final before = t.yaw;
      t.recenter();
      t.addSample(headPose(20 * deg), 66);
      expect((t.yaw - before).abs(), lessThan(3 * deg), reason: 'no snap: one smooth easing step at most');
      for (var i = 3; i < 90; i++) {
        t.addSample(headPose(20 * deg), i * 33.0);
      }
      expect(t.yaw.abs(), lessThan(1 * deg), reason: 'eased to center');
    });
  });

  group('HeadView (sensitivity)', () {
    test('effective = measured × sensitivity, in radians, clamped', () {
      expect(HeadView.fromMeasured(yaw: 10 * deg, pitch: 0, sensitivity: 1.5, status: HeadTrackingStatus.tracking).yaw, closeTo(15 * deg, 1e-9));
      expect(HeadView.fromMeasured(yaw: 10 * deg, pitch: 0, sensitivity: 0, status: HeadTrackingStatus.tracking).yaw, 0);
      expect(HeadView.fromMeasured(yaw: 80 * deg, pitch: 0, sensitivity: 2, status: HeadTrackingStatus.tracking).yaw, closeTo(40 * deg, 1e-9));
      expect(HeadView.fromMeasured(yaw: 10 * deg, pitch: 0, sensitivity: 1, status: HeadTrackingStatus.tracking, invertYaw: true).yaw, closeTo(-10 * deg, 1e-9));
    });
  });

  group('StaffAim', () {
    HandInputFrame hand(Offset? p, {HandTrackingStatus status = HandTrackingStatus.tracking, int id = 0}) =>
        HandInputFrame(status: status, frameId: id, timestampMs: 0, position: p);

    test('maps the interaction box to the staff region and aim yaw consistently', () {
      final s = StaffAim(config: const AimConfig(filterMinCutoff: 1000, filterBeta: 0));
      for (var i = 0; i < 5; i++) {
        s.update(hand(const Offset(0.5, 0.5)), i * 33.0);
      }
      expect(s.tip.dx, closeTo(0.5, 1e-6));
      expect(s.handYaw, closeTo(0, 1e-6));
      for (var i = 5; i < 10; i++) {
        s.update(hand(const Offset(0.8, 0.5)), i * 33.0); // right edge of the box
      }
      expect(s.tip.dx, closeTo(1, 1e-6));
      expect(s.handYaw, closeTo(s.config.handYawRange, 1e-6));
      expect(s.worldAimYaw(10 * deg), closeTo(10 * deg + s.config.handYawRange, 1e-6));
    });

    test('clamps: a hand outside the box keeps the staff on screen', () {
      final s = StaffAim(config: const AimConfig(filterMinCutoff: 1000, filterBeta: 0));
      for (var i = 0; i < 5; i++) {
        s.update(hand(const Offset(1.4, -0.3)), i * 33.0);
      }
      final tip = s.tipOnScreen(const Size(1000, 800));
      expect(tip.dx, lessThanOrEqualTo(600 + 1e-6));
      expect(tip.dy, greaterThanOrEqualTo(320 - 1e-6));
    });

    test('smoothing reduces jitter', () {
      final s = StaffAim();
      double maxStep = 0;
      Offset? prev;
      for (var i = 0; i < 120; i++) {
        final jitter = i.isEven ? 0.01 : -0.01;
        s.update(hand(Offset(0.5 + jitter, 0.5)), i * 33.0);
        if (prev != null && i > 30) maxStep = math.max(maxStep, (s.tip.dx - prev.dx).abs());
        prev = s.tip;
      }
      expect(maxStep, lessThan(0.01), reason: 'raw jitter is 0.033 in box units');
    });

    test('returns to rest after the hand is lost for a while', () {
      final s = StaffAim(config: const AimConfig(filterMinCutoff: 1000, filterBeta: 0));
      s.update(hand(const Offset(0.8, 0.2)), 0);
      s.update(hand(null, status: HandTrackingStatus.searching), 100);
      expect(s.tip.dx, closeTo(1, 1e-6), reason: 'held briefly');
      s.update(hand(null, status: HandTrackingStatus.searching), 700);
      expect(s.tip.dx, closeTo(s.config.restPosition.dx, 1e-3));
      expect(s.tip.dy, closeTo(s.config.restPosition.dy, 1e-3));
      expect(s.hasHand, isFalse);
    });
  });

  group('SpellSwitchRecognizer', () {
    late SpellSwitchRecognizer r;
    var id = 0;
    var t = 0.0;
    setUp(() {
      r = SpellSwitchRecognizer();
      t = 0;
    });
    bool frame(HandPose pose) {
      t += 40;
      return r.update(HandInputFrame(
        status: HandTrackingStatus.tracking,
        frameId: ++id,
        timestampMs: t,
        classification: PoseClassification(pose: pose, confidence: 0.9, openness: 0.5),
      ));
    }

    int run(HandPose pose, int frames) => List.generate(frames, (_) => frame(pose)).where((x) => x).length;

    test('holding ✌ for ~0.45 s switches exactly once', () {
      expect(run(HandPose.victory, 8), 0); // 320 ms
      expect(run(HandPose.victory, 40), 1);
    });

    test('a brief ✌ (e.g. while opening the hand) does not switch', () {
      expect(run(HandPose.victory, 5) + run(HandPose.open, 3) + run(HandPose.victory, 5), 0);
    });

    test('must release before switching again', () {
      expect(run(HandPose.victory, 20), 1);
      expect(run(HandPose.fist, 3), 0);
      expect(run(HandPose.victory, 20), 1);
    });

    test('fist and open palm never switch', () {
      expect(run(HandPose.fist, 50) + run(HandPose.open, 50), 0);
    });
  });
}
