import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/games/wizard/cast_gesture.dart';
import 'package:metarayzer/src/input/hand_input.dart';
import 'package:metarayzer/src/input/hand_pose.dart';

void main() {
  late CastGestureRecognizer r;
  late double now;
  late int frameId;

  setUp(() {
    now = 0;
    frameId = 0;
    r = CastGestureRecognizer(nowMs: () => now);
  });

  /// Feeds one new camera frame with [pose]; returns whether it cast.
  bool frame(HandPose pose, {double confidence = 0.9, double openness = -1}) {
    now += 40;
    return r.update(HandInputFrame(
      status: HandTrackingStatus.tracking,
      frameId: ++frameId,
      timestampMs: now,
      classification: PoseClassification(
        pose: pose,
        confidence: confidence,
        openness: openness >= 0 ? openness : (pose == HandPose.open ? 1 : 0),
      ),
    ));
  }

  bool noHand([HandTrackingStatus status = HandTrackingStatus.lost]) {
    now += 40;
    return r.update(HandInputFrame(status: status, frameId: ++frameId, timestampMs: now));
  }

  /// Returns the number of casts in a sequence.
  int run(List<HandPose> poses) => poses.where(frame).length;

  test('fist then open palm casts exactly once', () {
    expect(run([HandPose.fist, HandPose.fist, HandPose.open, HandPose.open]), 1);
  });

  test('holding the palm open does not cast again', () {
    run([HandPose.fist, HandPose.fist, HandPose.open, HandPose.open]);
    expect(run(List.filled(60, HandPose.open)), 0);
    expect(r.feedback.phase, CastPhase.spent);
  });

  test('must return to a fist before casting again', () {
    run([HandPose.fist, HandPose.fist, HandPose.open, HandPose.open]);
    expect(run([HandPose.open, HandPose.unknown, HandPose.open, HandPose.open]), 0);
    expect(run([HandPose.fist, HandPose.fist, HandPose.open, HandPose.open]), 1);
  });

  test('open palm without a prior fist never casts', () {
    expect(run(List.filled(30, HandPose.open)), 0);
  });

  test('a single noisy open frame while holding a fist does not cast', () {
    expect(run([HandPose.fist, HandPose.fist, HandPose.open, HandPose.fist, HandPose.fist, HandPose.open, HandPose.fist]), 0);
  });

  test('a single noisy fist frame does not arm', () {
    expect(run([HandPose.open, HandPose.fist, HandPose.open, HandPose.open, HandPose.open]), 0);
  });

  test('unknown frames during the transition are fine (fist -> partly open -> open casts once)', () {
    expect(run([HandPose.fist, HandPose.fist, HandPose.unknown, HandPose.unknown, HandPose.open, HandPose.open]), 1);
  });

  test('low-confidence open frames are ignored', () {
    run([HandPose.fist, HandPose.fist]);
    expect(frame(HandPose.open, confidence: 0.2), isFalse);
    expect(frame(HandPose.open, confidence: 0.2), isFalse);
    expect(r.armed, isTrue);
  });

  test('losing the hand never casts', () {
    run([HandPose.fist, HandPose.fist]);
    for (var i = 0; i < 5; i++) {
      expect(noHand(), isFalse);
    }
  });

  test('a brief dropout keeps the spell armed, but needs fresh confirmation', () {
    run([HandPose.fist, HandPose.fist]);
    noHand(); // 40 ms gap
    expect(frame(HandPose.open), isFalse, reason: 'one frame after a gap is not enough');
    expect(frame(HandPose.open), isTrue);
  });

  test('a long dropout disarms: a hand that reappears open does not cast', () {
    run([HandPose.fist, HandPose.fist]);
    for (var i = 0; i < 12; i++) {
      noHand(); // 480 ms
    }
    expect(run([HandPose.open, HandPose.open, HandPose.open]), 0);
  });

  test('re-delivered frames (same frameId) are not counted twice', () {
    frame(HandPose.fist);
    // Same frame id again: still only one confirmation frame.
    r.update(HandInputFrame(
      status: HandTrackingStatus.tracking,
      frameId: frameId,
      timestampMs: now,
      classification: const PoseClassification(pose: HandPose.fist, confidence: 0.9, openness: 0),
    ));
    expect(r.armed, isFalse);
    frame(HandPose.fist);
    expect(r.armed, isTrue);
  });

  test('feedback phases follow the gesture', () {
    noHand(HandTrackingStatus.searching);
    expect(r.feedback.phase, CastPhase.noHand);
    run([HandPose.fist, HandPose.fist]);
    expect(r.feedback.phase, CastPhase.ready);
    frame(HandPose.unknown, openness: 0.5);
    expect(r.feedback.phase, CastPhase.charging);
    expect(r.feedback.charge, 0.5);
    run([HandPose.open, HandPose.open]);
    expect(r.feedback.phase, CastPhase.spent);
  });

  test('extended dropout is reported after 2 s even with no new input', () {
    noHand(HandTrackingStatus.unavailable);
    expect(r.feedback.extendedDropout, isFalse);
    now += 2500;
    r.tick();
    expect(r.feedback.extendedDropout, isTrue);
    run([HandPose.fist, HandPose.fist]);
    expect(r.feedback.extendedDropout, isFalse);
  });
}
