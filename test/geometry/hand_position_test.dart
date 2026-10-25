import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/geometry/hand_position.dart';

void main() {
  group('HandPosition', () {
    // Glasses "medium" stream resolution, portrait.
    const w = 504.0, h = 896.0;

    test('frame center maps to zero offset and (0,0) relative', () {
      final p = HandPosition.fromPixels(w / 2, h / 2, frameWidth: w, frameHeight: h);
      expect(p.offsetX, 0);
      expect(p.offsetY, 0);
      expect(p.xn, 0.5);
      expect(p.yn, 0.5);
      expect(p.xr, 0);
      expect(p.yr, 0);
    });

    test('corners map to -1/+1 relative and 0/1 normalized', () {
      final topLeft = HandPosition.fromPixels(0, 0, frameWidth: w, frameHeight: h);
      expect((topLeft.xr, topLeft.yr), (-1.0, -1.0));
      expect((topLeft.xn, topLeft.yn), (0.0, 0.0));
      expect((topLeft.offsetX, topLeft.offsetY), (-w / 2, -h / 2));

      final bottomRight = HandPosition.fromPixels(w, h, frameWidth: w, frameHeight: h);
      expect((bottomRight.xr, bottomRight.yr), (1.0, 1.0));
      expect((bottomRight.xn, bottomRight.yn), (1.0, 1.0));
    });

    test('positive x is rightward and positive y is downward', () {
      final p = HandPosition.fromPixels(378, 224, frameWidth: w, frameHeight: h);
      expect(p.offsetX, 126); // 378 - 252
      expect(p.offsetY, -224); // 224 - 448: above center
      expect(p.xr, closeTo(0.5, 1e-12));
      expect(p.yr, closeTo(-0.5, 1e-12));
      expect(p.xn, closeTo(0.75, 1e-12));
      expect(p.yn, closeTo(0.25, 1e-12));
    });

    test('normalized coordinates are resolution independent', () {
      final low = HandPosition(xn: 0.3, yn: 0.7, frameWidth: 360, frameHeight: 640);
      final high = HandPosition(xn: 0.3, yn: 0.7, frameWidth: 720, frameHeight: 1280);
      expect(low.xr, closeTo(high.xr, 1e-12));
      expect(low.yr, closeTo(high.yr, 1e-12));
      expect(high.offsetX, closeTo(2 * low.offsetX, 1e-9));
      expect(high.xPixels, closeTo(216, 1e-9));
      expect(high.yPixels, closeTo(896, 1e-9));
    });
  });
}
