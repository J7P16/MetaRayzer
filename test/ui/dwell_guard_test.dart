import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/input/hand_input.dart';
import 'package:metarayzer/src/ui/dwell/dwell_scope.dart';
import 'package:metarayzer/src/ui/menu/fantasy_theme.dart';

void main() {
  testWidgets('a mouse click and a completing hand dwell on the same button activate it once', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    var presses = 0;
    final input = ValueNotifier(HandInputFrame.unavailable);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DwellScope(
          enabled: true,
          input: input,
          dwellSeconds: 1.0,
          child: Center(child: FantasyButton(label: 'GO', onPressed: () => presses++)),
        ),
      ),
    ));
    // Hand hovers the button (simulated positions are viewport-normalized).
    final c = tester.getCenter(find.text('GO'));
    var id = 0;
    void hand() => input.value = HandInputFrame(status: HandTrackingStatus.tracking, frameId: ++id, timestampMs: 0, position: Offset(c.dx / 800, c.dy / 600), simulated: true);
    for (var i = 0; i < 19; i++) {
      hand();
      await tester.pump(const Duration(milliseconds: 50)); // 0.95 s of dwell
    }
    expect(presses, 0);
    // Mouse click lands just before the dwell would complete.
    await tester.tap(find.text('GO'));
    expect(presses, 1);
    for (var i = 0; i < 30; i++) {
      hand();
      await tester.pump(const Duration(milliseconds: 50)); // keep hovering 1.5 s more
    }
    expect(presses, 1, reason: 'the hand hover must not fire the same button again');
    // Leave and come back: a new deliberate hover works.
    input.value = HandInputFrame(status: HandTrackingStatus.searching, frameId: ++id, timestampMs: 0);
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 24; i++) {
      hand();
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(presses, 2);
    tester.view.reset();
  });
}
