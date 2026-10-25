import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/app/app_services.dart';
import 'package:metarayzer/src/app/app_settings.dart';
import 'package:metarayzer/src/app/app_shell.dart';
import 'package:metarayzer/src/app/key_value_store.dart';
import 'package:metarayzer/src/app/tracking_controller.dart';
import 'package:metarayzer/src/games/wizard/wizard_screen.dart';
import 'package:metarayzer/src/platform/app_navigator.dart';
import 'package:metarayzer/src/platform/minigame.dart';
import 'package:metarayzer/src/ui/camera_preview.dart';
import 'package:metarayzer/src/ui/dwell/dwell_selector.dart';
import 'package:metarayzer/src/ui/menu/game_over_screen.dart';
import 'package:metarayzer/src/ui/menu/settings_screen.dart';
import 'package:metarayzer/src/ui/menu/start_menu.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import '../app/tracking_controller_test.dart' show FakeNative;

/// All camera behavior here is driven by simulated native events ([FakeNative]); nothing in this
/// file talks to glasses, the companion or a real camera.
void main() {
  late FakeNative native;
  late AppServices services;
  var now = 0.0;
  var seq = 0;

  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    native = FakeNative();
    final store = MemoryStore();
    final tracking = TrackingController(native: native, nowMs: () => now, scheduleAck: (ack) => ack());
    services = AppServices(tracking: tracking, settings: AppSettings(store: store), games: const [wizardShooter], store: store);
    await tester.runAsync(() async {
      await tracking.start();
      await services.load();
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AppShell(services: services))));
    native.controller.add(const CompanionEvent(connected: true));
    await tester.pump();
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    services.tracking.dispose();
    tester.view.reset();
  }

  /// One camera frame; with [hand] (display-normalized), a detected hand centered there.
  Future<void> cameraFrame(WidgetTester tester, {Offset? hand}) async {
    now += 40;
    List<NativeHand>? hands = const [];
    if (hand != null) {
      final lm = Float64List(63);
      for (var j = 0; j < 21; j++) {
        lm[j * 3] = hand.dx;
        lm[j * 3 + 1] = hand.dy;
        lm[j * 3 + 2] = 0.9;
      }
      hands = [NativeHand(landmarks: lm, confidence: 0.9, chirality: 'left')];
    }
    native.controller.add(FrameEvent(
      jpeg: Uint8List(0), width: 504, height: 896, seq: seq++, source: 'glasses', captureTimeMs: 0, receivedAtMs: 0,
      processedAtMs: 0, decodeMs: 0, detectMs: 0, dropped: 0, hands: hands,
    ));
    await tester.pump(const Duration(milliseconds: 40));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  SharedFrameDecoder decoder() => SharedFrameDecoder.of(services.tracking);

  testWidgets('starting the stream does not put the feed behind screens that did not ask for it', (tester) async {
    await boot(tester);
    // Results screen first, then the stream starts.
    services.navigator.playDefault();
    await settle(tester);
    final runId = (services.navigator.route as PlayingRoute).runId;
    await tester.runAsync(() => services.navigator.finishRun(RunResult(gameId: wizardShooter.id, runId: runId, score: 10, duration: const Duration(seconds: 5))));
    await settle(tester);
    expect(find.byType(GameOverScreen), findsOneWidget);
    native.controller.add(const CompanionStatusEvent({'stream': 'streaming'}));
    await cameraFrame(tester);
    await cameraFrame(tester);
    expect(cameraFeedState(services.tracking), CameraFeedState.live, reason: 'a feed is available');
    expect(find.byType(CameraFeedView), findsNothing, reason: 'but the results screen does not show it');
    expect(decoder().users, 0, reason: 'nothing decodes frames for an invisible feed');

    // The Start Menu opts in.
    services.navigator.openStartMenu();
    await settle(tester);
    await cameraFrame(tester);
    expect(find.byType(StartMenu), findsOneWidget);
    expect(find.byType(CameraFeedView), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('menu and gameplay show the same view through one decoder, without restarting anything', (tester) async {
    await boot(tester);
    native.controller.add(const CompanionStatusEvent({'stream': 'streaming'}));
    await cameraFrame(tester);
    final commands = native.commands.length;
    expect(native.controller.hasListener, isTrue);

    CameraPreview preview() => tester.widget<CameraPreview>(find.byType(CameraPreview));
    final menuPreview = preview();
    expect(menuPreview.controller, same(services.tracking));
    expect(menuPreview.pointerBox, const CursorMapper().box);
    expect(decoder().users, 1);

    await tester.tap(find.text('PLAY'));
    await settle(tester);
    await cameraFrame(tester);
    expect(find.byType(WizardGameScreen), findsOneWidget);
    expect(find.byType(CameraFeedView), findsOneWidget, reason: 'the in-game inset; the menu backdrop is off');
    final gamePreview = preview();
    expect(gamePreview.controller, same(menuPreview.controller), reason: 'same source and frames');
    expect(gamePreview.pointerBox, menuPreview.pointerBox, reason: 'same overlays');
    expect(decoder().users, 1, reason: 'one decoder subscription, not one per screen');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await cameraFrame(tester);
    expect(find.byType(StartMenu), findsOneWidget);
    expect(decoder().users, 1);
    expect(native.commands.length, commands, reason: 'navigation never restarts the stream');
    await teardown(tester);
  });

  testWidgets('two visible previews decode each frame once', (tester) async {
    await boot(tester);
    native.controller.add(const CompanionStatusEvent({'stream': 'streaming'}));
    await cameraFrame(tester);
    await tester.pumpWidget(MaterialApp(
      home: ListenableBuilder(
        listenable: services.tracking,
        builder: (_, _) => Row(children: [
          Expanded(child: CameraFeedView(controller: services.tracking)),
          Expanded(child: CameraFeedView(controller: services.tracking)),
        ]),
      ),
    ));
    expect(decoder().users, 2);
    // Let each decode finish (it runs outside the fake clock) before the next frame.
    Future<void> decodeDone() => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await decodeDone();
    final before = decoder().decodes;
    for (var i = 0; i < 5; i++) {
      await cameraFrame(tester);
      await decodeDone();
    }
    expect(decoder().decodes - before, 5);
    await teardown(tester);
    expect(decoder().users, 0, reason: 'released with the last preview');
  });

  testWidgets('a stopped, stalled or lost stream is never shown as live; reconnecting recovers', (tester) async {
    await boot(tester);
    native.controller.add(const CompanionStatusEvent({'stream': 'streaming'}));
    await cameraFrame(tester);
    expect(find.byType(CameraFeedView), findsOneWidget);
    expect(find.textContaining('STREAM PAUSED'), findsNothing);

    // Stalled: last frame, dimmed and labeled.
    now += 2000;
    native.controller.add(const CompanionStatusEvent({'stream': 'streaming'}));
    await tester.pump(const Duration(milliseconds: 200));
    expect(cameraFeedState(services.tracking), CameraFeedState.paused);
    expect(find.textContaining('STREAM PAUSED'), findsOneWidget);
    expect(find.textContaining('GLASSES VIEW'), findsNothing);

    // Stopped: the controller keeps the last frame, but it is not shown at all.
    native.controller.add(const CompanionStatusEvent({'stream': 'stopped'}));
    await tester.pump();
    expect(services.tracking.hasFrame, isTrue);
    expect(cameraFeedState(services.tracking), CameraFeedState.hidden);
    expect(find.byType(CameraPreview), findsNothing);

    // Disconnected, then reconnected and streaming again.
    native.controller.add(const CompanionEvent(connected: false, reason: 'test'));
    await tester.pump();
    expect(find.byType(CameraPreview), findsNothing);
    native.controller.add(const CompanionEvent(connected: true));
    native.controller.add(const CompanionStatusEvent({'stream': 'streaming'}));
    await cameraFrame(tester);
    expect(cameraFeedState(services.tracking), CameraFeedState.live);
    expect(find.byType(CameraFeedView), findsOneWidget);
    expect(decoder().users, 1);
    await teardown(tester);
  });

  testWidgets('hand-dwell navigation works while the feed is visible', (tester) async {
    await boot(tester);
    native.controller.add(const CompanionStatusEvent({'stream': 'streaming'}));
    await cameraFrame(tester);
    expect(find.byType(CameraFeedView), findsOneWidget);

    // Put the camera hand where the cursor lands on the Settings button.
    final target = tester.getCenter(find.text('Settings'));
    final box = const CursorMapper().box;
    final hand = Offset(box.left + box.width * target.dx / 1400, box.top + box.height * target.dy / 900);
    for (var i = 0; i < 100 && services.navigator.route is! SettingsRoute; i++) {
      await cameraFrame(tester, hand: hand);
    }
    expect(services.navigator.route, isA<SettingsRoute>());
    await settle(tester);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(CameraFeedView), findsOneWidget, reason: 'Settings shows the feed too');
    await teardown(tester);
  });

  testWidgets('simulated input hides the camera view in menus and gameplay alike', (tester) async {
    await boot(tester);
    native.controller.add(const CompanionStatusEvent({'stream': 'streaming'}));
    await cameraFrame(tester);
    expect(find.byType(CameraFeedView), findsOneWidget);
    services.settings.simulatedInput = true;
    await cameraFrame(tester);
    expect(find.byType(CameraPreview), findsNothing, reason: 'the mouse is the hand; camera overlays would not match the cursor');
    services.settings.simulatedInput = false;
    await cameraFrame(tester);
    expect(find.byType(CameraFeedView), findsOneWidget);
    await teardown(tester);
  });

  test('starting the controller twice keeps a single native subscription', () async {
    final fake = FakeNative();
    var listens = 0;
    fake.controller.onListen = () => listens++;
    final t = TrackingController(native: fake, scheduleAck: (ack) => ack());
    await t.start();
    await t.start();
    expect(listens, 1);
    t.dispose();
  });
}
