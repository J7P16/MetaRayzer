import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/input/hand_pose.dart';

/// Synthetic upright hand: wrist at (0.5, 0.8), knuckles 0.12 above, fingertips [tipLength]
/// beyond the knuckles (negative = folded back toward the wrist).
Float64List syntheticHand({required List<double> tipLengths, double conf = 0.9}) {
  final l = Float64List(63);
  void set(int j, double x, double y, [double c = 0.9]) {
    l[j * 3] = x;
    l[j * 3 + 1] = y;
    l[j * 3 + 2] = c;
  }

  set(0, 0.5, 0.8, conf);
  final xs = [0.44, 0.48, 0.52, 0.56];
  for (var f = 0; f < 4; f++) {
    final mcp = 5 + f * 4;
    set(mcp, xs[f], 0.68, conf);
    for (var k = 1; k <= 3; k++) {
      set(mcp + k, xs[f], 0.68 - tipLengths[f] * k / 3, conf);
    }
  }
  for (var j = 1; j <= 4; j++) {
    set(j, 0.42 - j * 0.02, 0.75, conf);
  }
  return l;
}

void main() {
  const classifier = PoseClassifier();

  group('synthetic hands', () {
    test('all fingers extended -> open', () {
      final c = classifier.classify(syntheticHand(tipLengths: [0.12, 0.13, 0.12, 0.1]));
      expect(c.pose, HandPose.open);
      expect(c.openness, greaterThan(0.8));
      expect(c.confidence, greaterThan(0.8));
    });

    test('all fingers folded back -> fist', () {
      final c = classifier.classify(syntheticHand(tipLengths: [-0.04, -0.04, -0.04, -0.03]));
      expect(c.pose, HandPose.fist);
      expect(c.openness, lessThan(0.2));
    });

    test('half-open hand is unknown (no accidental cast mid-transition)', () {
      final c = classifier.classify(syntheticHand(tipLengths: [0.05, 0.05, 0.05, 0.05]));
      expect(c.pose, HandPose.unknown);
      expect(c.openness, inInclusiveRange(0.3, 0.7));
    });

    test('two fingers up is the victory (spell switch) pose, never fist/open', () {
      expect(classifier.classify(syntheticHand(tipLengths: [0.12, 0.12, -0.04, -0.04])).pose, HandPose.victory);
    });

    test('one finger up (pointing) is unknown', () {
      expect(classifier.classify(syntheticHand(tipLengths: [0.12, -0.04, -0.04, -0.04])).pose, HandPose.unknown);
    });

    test('rotation and scale invariant', () {
      final base = syntheticHand(tipLengths: [0.12, 0.13, 0.12, 0.1]);
      final rotated = Float64List.fromList(base);
      const angle = 1.1, scale = 0.5;
      for (var j = 0; j < 21; j++) {
        final x = base[j * 3] - 0.5, y = base[j * 3 + 1] - 0.5;
        rotated[j * 3] = 0.5 + scale * (x * math.cos(angle) - y * math.sin(angle));
        rotated[j * 3 + 1] = 0.5 + scale * (x * math.sin(angle) + y * math.cos(angle));
      }
      expect(classifier.classify(rotated).pose, HandPose.open);
    });

    test('low joint confidence -> unknown with zero confidence', () {
      final c = classifier.classify(syntheticHand(tipLengths: [0.12, 0.13, 0.12, 0.1], conf: 0.1));
      expect(c.pose, HandPose.unknown);
      expect(c.confidence, 0);
    });
  });

  group('real Apple Vision landmarks (test/fixtures/real_hand_landmarks.json)', () {
    final doc = jsonDecode(File('test/fixtures/real_hand_landmarks.json').readAsStringSync()) as Map;
    for (final hand in (doc['hands'] as List).cast<Map>()) {
      test('${hand['source']} hand ${hand['hand']} -> ${hand['expected']}', () {
        final landmarks = Float64List.fromList((hand['landmarks'] as List).cast<num>().map((n) => n.toDouble()).toList());
        final aspect = (hand['width'] as int) / (hand['height'] as int);
        final c = classifier.classify(landmarks, aspect: aspect, handConfidence: (hand['confidence'] as num).toDouble());
        expect(c.pose.name, hand['expected']);
        expect(c.confidence, greaterThan(0.45));
      });
    }

    test('finger straightness (joint angles) agrees with the photographed poses', () {
      List<double> straightness(String source) {
        final h = (doc['hands'] as List).cast<Map>().firstWhere((h) => h['source'] == source);
        final landmarks = Float64List.fromList((h['landmarks'] as List).cast<num>().map((n) => n.toDouble()).toList());
        return classifier.classify(landmarks, aspect: (h['width'] as int) / (h['height'] as int)).fingerStraightness;
      }

      expect(straightness('male_full_height_hands.jpg'), everyElement(greaterThan(0.9)), reason: 'open palm: all straight');
      final point = straightness('pointing_up.jpg');
      expect(point[0], greaterThan(0.9), reason: 'index up');
      expect(point.skip(1), everyElement(lessThan(0.1)), reason: 'other fingers bent');
      final v = straightness('victory.jpg');
      expect(v.take(2), everyElement(greaterThan(0.9)));
      expect(v.skip(2), everyElement(lessThan(0.1)));
    });
  });
}
