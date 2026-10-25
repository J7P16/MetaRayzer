import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/tracking/one_euro_filter.dart';

void main() {
  test('first sample passes through', () {
    expect(OneEuroFilter().filter(0.42, 0), 0.42);
  });

  test('constant input stays constant', () {
    final f = OneEuroFilter();
    for (var i = 0; i < 50; i++) {
      expect(f.filter(0.3, i / 30), closeTo(0.3, 1e-12));
    }
  });

  test('reduces jitter on a stationary hand', () {
    final f = OneEuroFilter();
    final rng = math.Random(7);
    var rawVar = 0.0, filtVar = 0.0;
    for (var i = 0; i < 300; i++) {
      final noise = (rng.nextDouble() - 0.5) * 0.02;
      final out = f.filter(0.5 + noise, i / 30);
      if (i > 30) {
        rawVar += noise * noise;
        filtVar += (out - 0.5) * (out - 0.5);
      }
    }
    expect(filtVar, lessThan(rawVar * 0.5));
  });

  test('follows a fast move with little lag', () {
    final f = OneEuroFilter();
    var out = 0.0;
    for (var i = 0; i < 30; i++) {
      out = f.filter(0.2, i / 30);
    }
    // Jump to 0.8 and hold: within ~5 frames (170 ms at 30 fps) we should be most of the way there.
    for (var i = 30; i < 35; i++) {
      out = f.filter(0.8, i / 30);
    }
    expect(out, greaterThan(0.7));
  });

  test('reset forgets history', () {
    final f = OneEuroFilter()..filter(0.1, 0)..filter(0.1, 0.1);
    f.reset();
    expect(f.filter(0.9, 0.2), 0.9);
  });
}
