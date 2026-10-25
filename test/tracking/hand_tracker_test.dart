import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/geometry/hand_geometry.dart';
import 'package:metarayzer/src/tracking/hand_tracker.dart';

HandObservation obs(double x, double y, {double conf = 0.9, String chirality = 'unknown', double half = 0.05}) =>
    HandObservation(center: NormPoint(x, y), box: NormRect(x - half, y - half, x + half, y + half), confidence: conf, chirality: chirality);

const frameMs = 1000 / 30;

void main() {
  late HandTracker tracker;
  late double t;

  setUp(() {
    tracker = HandTracker();
    t = 0;
  });

  List<TrackedHand> step(List<HandObservation> detections) {
    t += frameMs;
    return tracker.update(detections, t);
  }

  test('no detections -> no hands', () {
    expect(step([]), isEmpty);
  });

  test('a new hand is shown only after it is confirmed', () {
    expect(step([obs(0.3, 0.5)]), isEmpty); // tentative
    final hands = step([obs(0.31, 0.5)]);
    expect(hands, hasLength(1));
    expect(hands.single.status, TrackStatus.active);
  });

  test('a one-frame false positive never appears', () {
    step([obs(0.3, 0.5)]);
    expect(step([]), isEmpty);
    expect(tracker.tracks, isEmpty);
  });

  test('low-confidence detections are ignored', () {
    step([obs(0.3, 0.5, conf: 0.2)]);
    expect(step([obs(0.3, 0.5, conf: 0.2)]), isEmpty);
  });

  test('keeps the id while a hand moves', () {
    step([obs(0.30, 0.5)]);
    final id = step([obs(0.32, 0.5)]).single.id;
    for (var i = 0; i < 20; i++) {
      final hands = step([obs(0.32 + i * 0.01, 0.5 + i * 0.005)]);
      expect(hands.single.id, id);
    }
  });

  test('two hands get distinct, stable ids while moving independently', () {
    step([obs(0.2, 0.5), obs(0.8, 0.5)]);
    var hands = step([obs(0.21, 0.5), obs(0.79, 0.5)]);
    expect(hands, hasLength(2));
    final leftId = hands.firstWhere((h) => h.smoothed.x < 0.5).id;
    final rightId = hands.firstWhere((h) => h.smoothed.x > 0.5).id;
    expect(leftId, isNot(rightId));

    for (var i = 0; i < 15; i++) {
      // Left hand moves up, right hand moves down. Detection order shuffles each frame.
      final l = obs(0.21, 0.5 - i * 0.01), r = obs(0.79, 0.5 + i * 0.01);
      hands = step(i.isEven ? [l, r] : [r, l]);
      expect(hands.firstWhere((h) => h.id == leftId).raw.x, closeTo(0.21, 1e-9));
      expect(hands.firstWhere((h) => h.id == rightId).raw.x, closeTo(0.79, 1e-9));
    }
  });

  test('a lost hand coasts briefly then disappears (no stale indicator)', () {
    step([obs(0.5, 0.5)]);
    step([obs(0.5, 0.5)]);
    final coasting = step([]);
    expect(coasting.single.status, TrackStatus.coasting);
    // Still within the 300 ms hold.
    t += 200;
    expect(tracker.expire(t), hasLength(1));
    t += 200;
    expect(tracker.expire(t), isEmpty);
  });

  test('a hand that returns within the hold keeps its id', () {
    step([obs(0.5, 0.5)]);
    final id = step([obs(0.5, 0.5)]).single.id;
    step([]);
    step([]);
    final back = step([obs(0.52, 0.5)]);
    expect(back.single.id, id);
    expect(back.single.status, TrackStatus.active);
  });

  test('tracks expire even if frames stop arriving altogether', () {
    step([obs(0.5, 0.5)]);
    step([obs(0.5, 0.5)]);
    // No more update() calls; only the UI housekeeping timer calls expire().
    expect(tracker.expire(t + 500), hasLength(1));
    expect(tracker.expire(t + 1100), isEmpty);
  });

  test('a far-away detection is a new hand, not a teleport', () {
    step([obs(0.1, 0.1)]);
    final first = step([obs(0.1, 0.1)]).single.id;
    step([obs(0.9, 0.9)]);
    final hands = step([obs(0.9, 0.9)]);
    final active = hands.where((h) => h.status == TrackStatus.active).single;
    expect(active.id, isNot(first));
    expect(active.raw.x, 0.9);
    // The old hand is only shown as "lost" at its last position, and only until the hold expires.
    expect(hands.where((h) => h.id == first).single.status, TrackStatus.coasting);
    expect(tracker.expire(t + 400).single.id, active.id);
  });

  test('never reports more than two hands and drops duplicate detections', () {
    final dets = [obs(0.2, 0.2, conf: 0.9), obs(0.205, 0.2, conf: 0.6), obs(0.8, 0.8, conf: 0.8), obs(0.5, 0.9, conf: 0.7)];
    step(dets);
    final hands = step(dets);
    expect(hands, hasLength(2));
    final xs = hands.map((h) => h.raw.x).toList()..sort();
    expect(xs, [0.2, 0.8]); // the near-duplicate (0.205) and the weakest third hand are dropped
  });

  test('crossing hands are flagged as identity-uncertain, then clear', () {
    step([obs(0.3, 0.5), obs(0.7, 0.5)]);
    step([obs(0.3, 0.5), obs(0.7, 0.5)]);
    // Move toward each other until they overlap.
    var hands = <TrackedHand>[];
    for (final d in [0.15, 0.08, 0.03, 0.0]) {
      hands = step([obs(0.5 - d, 0.5, half: 0.02), obs(0.5 + d, 0.5, half: 0.02)]);
    }
    expect(hands.every((h) => h.identityUncertain), isTrue);
    // Separate again; after the hold, identities are trusted again.
    for (var i = 0; i < 10; i++) {
      hands = step([obs(0.25, 0.5), obs(0.75, 0.5)]);
    }
    expect(hands, hasLength(2));
    expect(hands.any((h) => h.identityUncertain), isFalse);
  });

  test('well separated hands are never flagged uncertain', () {
    for (var i = 0; i < 10; i++) {
      final hands = step([obs(0.2, 0.3), obs(0.8, 0.7)]);
      expect(hands.any((h) => h.identityUncertain), isFalse);
    }
  });

  test('smoothing damps jitter but tracks the hand', () {
    step([obs(0.5, 0.5)]);
    for (var i = 0; i < 30; i++) {
      final jitter = i.isEven ? 0.005 : -0.005;
      final hand = step([obs(0.5 + jitter, 0.5)]).single;
      if (i > 10) expect((hand.smoothed.x - 0.5).abs(), lessThan(0.005));
    }
  });

  test('a third hand replaces the stalest coasting one', () {
    step([obs(0.2, 0.2), obs(0.8, 0.2)]);
    final ids = step([obs(0.2, 0.2), obs(0.8, 0.2)]).map((h) => h.id).toSet();
    // Hand at 0.2 leaves; a new hand appears far away while the old one is still coasting.
    step([obs(0.8, 0.2)]);
    step([obs(0.8, 0.2), obs(0.5, 0.9)]);
    final hands = step([obs(0.8, 0.2), obs(0.5, 0.9)]);
    expect(hands, hasLength(2));
    expect(tracker.tracks, hasLength(2));
    expect(hands.where((h) => !ids.contains(h.id)), hasLength(1));
  });
}
