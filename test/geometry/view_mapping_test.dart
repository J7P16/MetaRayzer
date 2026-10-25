import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/geometry/view_mapping.dart';

Matcher offsetCloseTo(Offset expected, [double eps = 1e-9]) => predicate<Offset>(
      (o) => (o.dx - expected.dx).abs() < eps && (o.dy - expected.dy).abs() < eps,
      'close to $expected',
    );

void main() {
  const portrait = Size(504, 896);

  group('contain', () {
    // 504x896 into 1000x896: scale 1, pillarboxed by (1000-504)/2 = 248 on each side.
    const m = FrameViewMapping(frameSize: portrait, viewSize: Size(1000, 896));

    test('image rect is centered and letterboxed', () {
      expect(m.scale, 1);
      expect(m.imageRect, const Rect.fromLTWH(248, 0, 504, 896));
    });

    test('frame center maps to image center', () {
      expect(m.frameCenterInView, offsetCloseTo(const Offset(500, 448)));
    });

    test('corners map to image rect corners', () {
      expect(m.toView(0, 0), offsetCloseTo(const Offset(248, 0)));
      expect(m.toView(1, 1), offsetCloseTo(const Offset(752, 896)));
    });

    test('scales down into a smaller view', () {
      const small = FrameViewMapping(frameSize: portrait, viewSize: Size(252, 1000));
      expect(small.scale, 0.5);
      expect(small.imageRect, const Rect.fromLTWH(0, 276, 252, 448));
      expect(small.toView(0.5, 0.25), offsetCloseTo(const Offset(126, 276 + 112)));
    });
  });

  group('cover', () {
    // 504x896 into 1008x896: scale 2 -> 1008x1792, cropped 448 above and below.
    const m = FrameViewMapping(frameSize: portrait, viewSize: Size(1008, 896), fit: PreviewFit.cover);

    test('fills the view and crops the overflow', () {
      expect(m.scale, 2);
      expect(m.imageRect, const Rect.fromLTWH(0, -448, 1008, 1792));
      expect(m.frameCenterInView, offsetCloseTo(const Offset(504, 448)));
    });

    test('points in the cropped area are reported invisible', () {
      expect(m.isVisible(m.toView(0.5, 0.1)), isFalse); // y = -448 + 179.2
      expect(m.isVisible(m.toView(0.5, 0.5)), isTrue);
    });
  });

  group('mirroring', () {
    const m = FrameViewMapping(frameSize: portrait, viewSize: portrait, mirrored: true);

    test('flips x only', () {
      expect(m.toView(0.25, 0.25), offsetCloseTo(const Offset(378, 224)));
      expect(m.frameCenterInView, offsetCloseTo(const Offset(252, 448)));
    });
  });

  group('rotation', () {
    test('one clockwise turn swaps dimensions and rotates points', () {
      const m = FrameViewMapping(frameSize: portrait, viewSize: Size(896, 504), quarterTurns: 1);
      expect(m.displayedFrameSize, const Size(896, 504));
      expect(m.imageRect, const Rect.fromLTWH(0, 0, 896, 504));
      // Top-left of the source ends up top-right after a clockwise turn.
      expect(m.toView(0, 0), offsetCloseTo(const Offset(896, 0)));
      // Top-right of the source ends up bottom-right.
      expect(m.toView(1, 0), offsetCloseTo(const Offset(896, 504)));
      expect(m.toView(0, 1), offsetCloseTo(const Offset(0, 0)));
    });

    test('four turns are the identity', () {
      const a = FrameViewMapping(frameSize: portrait, viewSize: Size(800, 800));
      const b = FrameViewMapping(frameSize: portrait, viewSize: Size(800, 800), quarterTurns: 4);
      expect(b.toView(0.2, 0.7), offsetCloseTo(a.toView(0.2, 0.7)));
    });
  });

  test('toFrameNormalized inverts toView for every transform combination', () {
    for (final fit in PreviewFit.values) {
      for (final mirrored in [false, true]) {
        for (var turns = 0; turns < 4; turns++) {
          final m = FrameViewMapping(frameSize: portrait, viewSize: const Size(1200, 700), fit: fit, mirrored: mirrored, quarterTurns: turns);
          for (final (x, y) in [(0.0, 0.0), (0.13, 0.82), (0.5, 0.5), (1.0, 0.3)]) {
            final back = m.toFrameNormalized(m.toView(x, y));
            expect(back, offsetCloseTo(Offset(x, y)), reason: 'fit=$fit mirrored=$mirrored turns=$turns point=($x,$y)');
          }
        }
      }
    }
  });
}
