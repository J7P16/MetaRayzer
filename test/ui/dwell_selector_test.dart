import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/ui/dwell/dwell_selector.dart';

void main() {
  const play = 'play', quit = 'quit';
  final targets = {play: const Rect.fromLTWH(0, 0, 100, 50), quit: const Rect.fromLTWH(0, 100, 100, 50)};
  const onPlay = Offset(50, 25), onQuit = Offset(50, 125), nowhere = Offset(500, 500);

  late DwellSelector d;
  setUp(() => d = DwellSelector(dwellSeconds: 1.0));

  /// Hovers [cursor] for [seconds] in 1/60 s steps; returns all activations.
  List<Object> hover(Offset? cursor, double seconds) {
    final out = <Object>[];
    for (var t = 0.0; t < seconds - 1e-9; t += 1 / 60) {
      final a = d.update(cursor, 1 / 60, targets);
      if (a != null) out.add(a);
    }
    return out;
  }

  test('activates after the dwell duration, not before', () {
    expect(hover(onPlay, 0.9), isEmpty);
    expect(d.progress, closeTo(0.9, 0.02));
    expect(hover(onPlay, 0.15), [play]);
  });

  test('leaving the target resets progress', () {
    hover(onPlay, 0.8);
    hover(nowhere, 0.1);
    expect(d.progress, 0);
    expect(hover(onPlay, 0.8), isEmpty);
  });

  test('moving to another target restarts the timer for it', () {
    hover(onPlay, 0.8);
    expect(hover(onQuit, 0.8), isEmpty);
    expect(hover(onQuit, 0.25), [quit]);
  });

  test('one continuous hover activates only once', () {
    expect(hover(onPlay, 10), [play]);
    expect(d.hoveredIsLocked, isTrue);
  });

  test('leaving and coming back allows another activation', () {
    hover(onPlay, 1.1);
    hover(nowhere, 0.1);
    expect(hover(onPlay, 1.1), [play]);
  });

  test('losing the hand resets progress and releases the lock', () {
    hover(onPlay, 0.7);
    hover(null, 0.05);
    expect(d.progress, 0);
    hover(onPlay, 1.1);
    hover(null, 0.05);
    expect(hover(onPlay, 1.1), [play]);
  });

  test('dwell duration is configurable', () {
    d.dwellSeconds = 0.5;
    expect(hover(onPlay, 0.55), [play]);
  });

  test('cursor mapper stretches the central interaction box to the viewport', () {
    const m = CursorMapper(box: Rect.fromLTRB(0.2, 0.2, 0.8, 0.8));
    const view = Size(1000, 500);
    void near(Offset a, Offset b) {
      expect(a.dx, closeTo(b.dx, 1e-6));
      expect(a.dy, closeTo(b.dy, 1e-6));
    }

    near(m.map(const Offset(0.5, 0.5), view), const Offset(500, 250));
    near(m.map(const Offset(0.2, 0.2), view), Offset.zero);
    near(m.map(const Offset(0.95, 0.05), view), const Offset(1000, 0)); // clamped
    near(m.map(const Offset(0.3, 0.6), view, simulated: true), const Offset(300, 300));
  });
}
