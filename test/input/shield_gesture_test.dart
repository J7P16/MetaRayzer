import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/games/wizard/shield.dart';
import 'package:metarayzer/src/games/wizard/shield_gesture.dart';
import 'package:metarayzer/src/games/wizard/wizard_config.dart';
import 'package:metarayzer/src/games/wizard/wizard_game.dart';
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

const classifier = PoseClassifier();

/// Classifies a fixture hand re-posed into the glasses' 504×896 portrait frame.
PoseClassification classifyFixture(String source, {int hand = 0, double radians = 0, double scale = 1, Offset center = const Offset(0.5, 0.5)}) {
  final f = fixture(source, hand: hand);
  final lm = repose(f.landmarks, f.width, f.height, radians: radians, scale: scale, center: center);
  return classifier.classify(lm, aspect: 504 / 896);
}

/// Synthetic hand seen from the side in a square frame: each finger bends by [bends] (radians)
/// at the knuckle, middle and end joints (0 = straight up).
Float64List bentHand(List<double> bends, {double conf = 0.9}) {
  final l = Float64List(63);
  void set(int j, Offset p) {
    l[j * 3] = p.dx;
    l[j * 3 + 1] = p.dy;
    l[j * 3 + 2] = conf;
  }

  set(0, const Offset(0.5, 0.8));
  for (var j = 1; j <= 4; j++) {
    set(j, Offset(0.42 - j * 0.02, 0.75));
  }
  const xs = [0.44, 0.48, 0.52, 0.56];
  const segments = [0.05, 0.035, 0.03];
  for (var f = 0; f < 4; f++) {
    var p = Offset(xs[f], 0.68);
    set(5 + f * 4, p);
    var dir = -math.pi / 2; // up
    for (var k = 0; k < 3; k++) {
      dir += bends[f]; // curling folds the finger toward the palm (+y)
      p += Offset(math.cos(dir), math.sin(dir)) * segments[k];
      set(5 + f * 4 + k + 1, p);
    }
  }
  return l;
}

PoseClassification classifyBent(List<double> bends, {double conf = 0.9}) => classifier.classify(bentHand(bends, conf: conf));

bool enters(PoseClassification c, [ShieldGestureConfig config = const ShieldGestureConfig()]) {
  final m = OneFingerMetrics.measure(c);
  return m != null && c.confidence >= config.minConfidence && m.index >= config.enterIndex && m.minCurled >= config.enterCurled;
}

HandInputFrame frame(int id, PoseClassification? c, {double? t, HandTrackingStatus status = HandTrackingStatus.tracking, int handId = 1}) => HandInputFrame(
      status: status,
      frameId: id,
      timestampMs: t ?? id * 40.0, // 25 fps
      position: const Offset(0.5, 0.5),
      handId: c == null ? null : handId,
      classification: c ?? PoseClassification.none,
    );

void main() {
  const config = ShieldGestureConfig();
  final point = classifyFixture('pointing_up.jpg');
  final open = classifyFixture('male_full_height_hands.jpg', radians: math.pi / 2);
  final fist = classifyFixture('thumb_up.jpg');
  final victory = classifyFixture('victory.jpg');

  group('one-finger pose from real landmarks', () {
    test('the real index-finger-up hand meets the pose', () {
      final m = OneFingerMetrics.measure(point)!;
      expect(m.index, greaterThanOrEqualTo(config.enterIndex));
      expect(m.minCurled, greaterThanOrEqualTo(config.enterCurled));
      expect(point.confidence, greaterThanOrEqualTo(config.minConfidence));
      expect(point.pose, HandPose.unknown, reason: 'neither fist nor open: it can never arm or fire a cast');
    });

    test('robust to hand size/distance, in-plane rotation and position', () {
      for (final scale in [0.4, 1.0, 2.5]) {
        for (final radians in [-1.2, -0.5, 0.0, 0.7, math.pi / 2]) {
          for (final center in const [Offset(0.5, 0.5), Offset(0.2, 0.3), Offset(0.8, 0.75)]) {
            expect(enters(classifyFixture('pointing_up.jpg', scale: scale, radians: radians, center: center)), isTrue, reason: 'scale $scale, rotation $radians, at $center');
          }
        }
      }
    });

    test('common alternative poses are rejected: open palm, fist, V sign', () {
      for (final hand in [0, 1]) {
        expect(enters(classifyFixture('male_full_height_hands.jpg', hand: hand)), isFalse, reason: 'open palm $hand');
      }
      expect(enters(fist), isFalse, reason: 'fist / thumb up');
      expect(enters(victory), isFalse, reason: 'V sign (spell switch)');
    });

    test('synthetic: index up accepted; other one/two-finger and half-curled poses rejected', () {
      const up = 0.0, curled = 1.8, half = 0.75; // real curled fingers bend to 26–50° at the middle joint
      expect(enters(classifyBent([up, curled, curled, curled])), isTrue);
      expect(enters(classifyBent([up, up, curled, curled])), isFalse, reason: 'V sign');
      expect(enters(classifyBent([up, curled, curled, up])), isFalse, reason: 'index + little');
      expect(enters(classifyBent([curled, up, curled, curled])), isFalse, reason: 'middle finger only');
      expect(enters(classifyBent([up, half, half, half])), isFalse, reason: 'others only half curled: ambiguous');
      expect(enters(classifyBent([half, curled, curled, curled])), isFalse, reason: 'index only half extended');
      expect(enters(classifyBent([up, up, up, up])), isFalse, reason: 'open hand');
      expect(enters(classifyBent([curled, curled, curled, curled])), isFalse, reason: 'fist');
    });

    test('low-confidence or missing joints are rejected, never guessed', () {
      expect(enters(classifyBent([0, 1.8, 1.8, 1.8], conf: 0.2)), isFalse);
      final lm = bentHand([0, 1.8, 1.8, 1.8]);
      lm[16 * 3 + 2] = 0.05; // ring fingertip not seen
      expect(OneFingerMetrics.measure(classifier.classify(lm)), isNull, reason: 'a finger that cannot be measured makes the pose ambiguous');
    });
  });

  group('recognizer', () {
    test('activates once, only after the recognition interval', () {
      final r = ShieldGestureRecognizer();
      expect(r.update(frame(1, point)), isFalse);
      expect(r.phase, ShieldGesturePhase.recognizing);
      expect(r.update(frame(2, point)), isFalse);
      expect(r.update(frame(3, point)), isTrue, reason: '3 frames spanning 80 ms');
      expect(r.held, isTrue);
      for (var i = 4; i < 100; i++) {
        expect(r.update(frame(i, point)), isFalse, reason: 'holding never re-reports');
      }
      expect(r.held, isTrue);
    });

    test('the interval is time-based too: fast frames still wait recognizeMs', () {
      final r = ShieldGestureRecognizer();
      var activatedAt = -1.0;
      for (var i = 1; i < 20 && activatedAt < 0; i++) {
        if (r.update(frame(i, point, t: i * 10.0))) activatedAt = i * 10.0;
      }
      expect(activatedAt - 10, greaterThanOrEqualTo(config.recognizeMs));
    });

    test('flickering landmarks (pose every other frame) never activate', () {
      final r = ShieldGestureRecognizer();
      for (var i = 1; i < 80; i++) {
        expect(r.update(frame(i, i.isOdd ? point : open)), isFalse);
      }
    });

    test('alternative poses held for seconds never activate', () {
      for (final pose in [open, fist, victory]) {
        final r = ShieldGestureRecognizer();
        for (var i = 1; i < 80; i++) {
          expect(r.update(frame(i, pose)), isFalse);
        }
        expect(r.phase, ShieldGesturePhase.idle);
      }
    });

    test('a single noisy frame neither releases nor retriggers; a real release re-arms', () {
      final r = ShieldGestureRecognizer();
      var activations = 0;
      void feed(PoseClassification c, int n) {
        for (var k = 0; k < n; k++) {
          if (r.update(frame(_id++, c))) activations++;
        }
      }

      feed(point, 10);
      expect(activations, 1);
      for (var k = 0; k < 5; k++) {
        feed(open, 1); // one-frame glitch
        feed(point, 6);
      }
      expect(activations, 1, reason: 'noise during a hold is not a release');
      expect(r.held, isTrue);
      feed(open, 4);
      expect(r.held, isFalse, reason: 'confident non-pose frames: release recognized');
      feed(point, 10);
      expect(activations, 2, reason: 'a new gesture after the release');
    });

    test('low-confidence and ambiguous frames never activate and never release', () {
      final weak = PoseClassification(pose: point.pose, confidence: 0.2, openness: point.openness, fingerExtension: point.fingerExtension, fingerStraightness: point.fingerStraightness);
      const ambiguous = PoseClassification(pose: HandPose.unknown, confidence: 0.9, openness: 0.3, fingerExtension: [1, -1, 0, 0], fingerStraightness: [1, -1, 0, 0]);
      final r = ShieldGestureRecognizer();
      for (var i = 1; i < 40; i++) {
        expect(r.update(frame(i, i.isEven ? weak : ambiguous)), isFalse);
      }
      expect(r.held, isFalse);
      for (var i = 40; i < 45; i++) {
        r.update(frame(i, point));
      }
      expect(r.held, isTrue);
      for (var i = 45; i < 60; i++) {
        r.update(frame(i, weak));
      }
      expect(r.held, isTrue, reason: 'uncertain frames are not evidence of a release');
    });

    test('a dropout never activates; a short one keeps the pose, a long one releases it', () {
      final r = ShieldGestureRecognizer();
      r.update(frame(1, point, t: 0));
      r.update(frame(2, point, t: 40));
      r.update(frame(3, null, t: 80, status: HandTrackingStatus.lost));
      expect(r.update(frame(4, point, t: 120)), isFalse, reason: 'recognition restarts after a gap');
      expect(r.update(frame(5, point, t: 160)), isFalse);
      expect(r.update(frame(6, point, t: 200)), isTrue);
      r.update(frame(7, null, t: 240, status: HandTrackingStatus.lost));
      r.update(frame(8, null, t: 400, status: HandTrackingStatus.lost));
      expect(r.held, isTrue, reason: '160 ms gap');
      r.update(frame(9, null, t: 600, status: HandTrackingStatus.unavailable));
      expect(r.held, isFalse, reason: '360 ms gap');
    });

    test('status-only re-deliveries of a frame are not counted twice', () {
      final r = ShieldGestureRecognizer();
      r.update(frame(1, point, t: 0));
      r.update(frame(1, point, t: 100));
      r.update(frame(1, point, t: 200));
      expect(r.held, isFalse);
    });

    test('the simulated shield pose (B key) is recognized; the simulated casting hand is not', () {
      final r = ShieldGestureRecognizer();
      var activated = false;
      for (var i = 1; i < 6; i++) {
        activated |= r.update(frame(i, SimulatedHandInput.pointClassification));
      }
      expect(activated, isTrue);
      final sim = SimulatedHandInput()
        ..move(const Offset(0.5, 0.5))
        ..active = true;
      final cast = ShieldGestureRecognizer();
      for (var i = 0; i < 10; i++) {
        sim.setFist(i.isEven);
        expect(cast.update(HandInputFrame(status: HandTrackingStatus.tracking, frameId: i, timestampMs: i * 33.0, handId: 1, classification: sim.value.classification)), isFalse);
      }
      sim.dispose();
    });
  });

  group('recognizer driving the shield', () {
    /// Feeds [c] for [seconds] at 25 fps into recognizer → game, like WizardSession.onHand.
    void hold(WizardGame g, ShieldGestureRecognizer r, PoseClassification? c, double seconds, {HandTrackingStatus status = HandTrackingStatus.tracking}) {
      for (var t = 0.0; t < seconds - 1e-9; t += 0.04) {
        _clockMs += 40;
        r.update(frame(_id++, c, t: _clockMs, status: status));
        g.setShieldPose(r.held);
        g.update(0.04);
      }
    }

    WizardGame quiet() => WizardGame(seed: 1, config: const WizardConfig(difficulty: DifficultySpec(spawnIntervalStart: 1e9, spawnIntervalEnd: 1e9, firstSpawnDelay: 1e9), dayNight: DayNightSpec(enabled: false)));

    test('active for exactly 0.5 s; holding never extends or retriggers; release + new gesture re-activates', () {
      final g = quiet();
      final r = ShieldGestureRecognizer();
      hold(g, r, point, 0.12);
      expect(g.shield.isActive, isTrue);
      var activeFor = 0.0;
      for (var i = 0; i < 100; i++) {
        _clockMs += 10;
        if (i % 4 == 0) r.update(frame(_id++, point, t: _clockMs));
        g.setShieldPose(r.held);
        if (g.shield.isActive) activeFor += 0.01;
        g.update(0.01);
      }
      expect(activeFor, closeTo(0.5 - 0.04, 0.011), reason: '0.5 s window, of which 0.04 s elapsed above');
      hold(g, r, point, 3);
      expect(g.shield.activations, 1);
      expect(g.shield.isActive, isFalse);
      expect(g.shield.state, ShieldState.recharging, reason: 'awaiting release');
      hold(g, r, open, 0.3);
      expect(g.shield.state, ShieldState.ready);
      hold(g, r, point, 0.2);
      expect(g.shield.activations, 2);
    });

    test('tracking loss cannot keep the shield active', () {
      final g = quiet();
      final r = ShieldGestureRecognizer();
      hold(g, r, point, 0.12);
      expect(g.shield.isActive, isTrue);
      hold(g, r, null, 2, status: HandTrackingStatus.unavailable);
      expect(g.shield.isActive, isFalse);
      expect(r.held, isFalse, reason: 'a long dropout counts as a release');
      expect(g.shield.state, ShieldState.ready);
    });

    test('the gesture-raised shield blocks a projectile; without the gesture it hits', () {
      for (final raise in [true, false]) {
        final g = quiet();
        final r = ShieldGestureRecognizer();
        final archer = g.spawn(EnemyKind.skeletonArcher, x: 0)..z = 14;
        g.fireProjectile(archer, const ProjectileSpec(speed: 9, aimSpread: 0, minAimSpread: 0));
        g.enemies.remove(archer);
        final p = g.projectiles.last;
        // Start the gesture ~0.35 s before the arrow reaches the shield radius.
        while (math.sqrt(p.x * p.x + p.z * p.z) > g.config.shield.blockRadius + 9 * 0.35) {
          hold(g, r, open, 0.04);
        }
        hold(g, r, raise ? point : open, 2);
        expect(g.lives, raise ? 3 : 2, reason: raise ? 'blocked' : 'not blocked');
        expect(g.drainEvents().whereType<ProjectileBlocked>(), raise ? hasLength(1) : isEmpty);
      }
    });
  });

  group('hand shape (still used for display-space geometry)', () {
    FrameViewMapping mapping({bool mirrored = false}) => FrameViewMapping(frameSize: const Size(504, 896), viewSize: const Size(1, 1), mirrored: mirrored);
    Float64List palm() {
      final f = fixture('male_full_height_hands.jpg');
      return repose(f.landmarks, f.width, f.height, radians: math.pi / 2, scale: 4.5, center: const Offset(0.5, 0.48));
    }

    test('mirroring the preview mirrors the shape', () {
      final a = CameraHandInput.handShape(palm(), mapping())!;
      final b = CameraHandInput.handShape(palm(), mapping(mirrored: true))!;
      expect(b.tilt, closeTo(a.tilt, 1e-9));
      expect(b.bounds.center.dx, closeTo(1 - a.bounds.center.dx, 1e-9));
    });

    test('too few confident joints gives no shape (fails safe)', () {
      final lm = palm();
      for (var j = 0; j < 21; j++) {
        lm[j * 3 + 2] = j < 5 ? 0.9 : 0.1;
      }
      expect(CameraHandInput.handShape(lm, mapping()), isNull);
    });
  });
}

var _id = 1000;
var _clockMs = 0.0;
