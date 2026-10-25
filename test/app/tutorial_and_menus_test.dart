
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/app/app_services.dart';
import 'package:metarayzer/src/app/app_settings.dart';
import 'package:metarayzer/src/app/app_shell.dart';
import 'package:metarayzer/src/app/key_value_store.dart';
import 'package:metarayzer/src/app/tracking_controller.dart';
import 'package:metarayzer/src/audio/audio_service.dart';
import 'package:metarayzer/src/games/wizard/enemies.dart';
import 'package:metarayzer/src/games/wizard/tutorial/tutorial_flow.dart';
import 'package:metarayzer/src/games/wizard/tutorial/tutorial_screen.dart';
import 'package:metarayzer/src/games/wizard/wizard_config.dart';
import 'package:metarayzer/src/games/wizard/wizard_game.dart';
import 'package:metarayzer/src/games/wizard/wizard_screen.dart';
import 'package:metarayzer/src/input/head_pose.dart';
import 'package:metarayzer/src/platform/app_navigator.dart';
import 'package:metarayzer/src/ui/camera_preview.dart';
import 'package:metarayzer/src/ui/menu/settings_screen.dart';
import 'package:metarayzer/src/ui/menu/start_menu.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import 'tracking_controller_test.dart' show FakeNative;

void main() {
  group('TutorialFlow', () {
    test('look step needs both directions; unavailable head tracking never completes it', () {
      final f = TutorialFlow();
      f.onHead(const HeadView(yaw: 0, pitch: 0, status: HeadTrackingStatus.unavailable));
      expect(f.stepComplete, isFalse);
      f.onHead(const HeadView(yaw: -0.3, pitch: 0, status: HeadTrackingStatus.tracking));
      expect(f.lookedLeft, isTrue);
      expect(f.stepComplete, isFalse);
      f.onHead(const HeadView(yaw: 0.3, pitch: 0, status: HeadTrackingStatus.tracking));
      expect(f.stepComplete, isTrue);
    });

    test('shield feedback distinguishes blocked / too early / too late', () {
      final f = TutorialFlow()
        ..next()
        ..next();
      expect(f.step, TutorialStep.shield);
      final p = Projectile(kind: ProjectileKind.arrow, spec: const ArcherSpec().arrow, source: EnemyKind.skeletonArcher, x: 0, z: 1, vx: 0, vz: -1, startElevation: 1);
      f.onEvents([ProjectileHitPlayer(p)], 5);
      expect(f.lastAttempt, ShieldAttempt.tooLate);
      f.onEvents([const ShieldExpired()], 6);
      f.onEvents([ProjectileHitPlayer(p)], 6.4);
      expect(f.lastAttempt, ShieldAttempt.tooEarly);
      f.onEvents([ProjectileBlocked(p, x: 0, z: 2)], 9);
      expect(f.lastAttempt, ShieldAttempt.blocked);
      expect(f.stepComplete, isTrue);
    });

    test('skipping records the skipped step and moves on', () {
      final f = TutorialFlow()..skip();
      expect(f.step, TutorialStep.cast);
      expect(f.skipped, {TutorialStep.look});
    });
  });

  group('app', () {
    late FakeNative native;
    late AppServices services;
    late MemoryStore store;
    var now = 0.0;
    var seq = 0;

    Future<void> boot(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      native = FakeNative();
      store = MemoryStore();
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
      services.settings.simulatedInput = false;
      services.tracking.dispose();
      tester.view.reset();
    }

    Future<void> cameraFrame(WidgetTester tester) async {
      now += 40;
      native.controller.add(FrameEvent(
        jpeg: Uint8List(0), width: 504, height: 896, seq: seq++, source: 'glasses', captureTimeMs: 0, receivedAtMs: 0,
        processedAtMs: 0, decodeMs: 0, detectMs: 0, dropped: 0, hands: const [],
      ));
      await tester.pump(const Duration(milliseconds: 40));
    }

    testWidgets('the live glasses feed shows behind the menus, persists across screens, and hides when off', (tester) async {
      await boot(tester);
      expect(find.byType(CameraPreview), findsNothing, reason: 'not streaming yet');
      native.controller.add(const CompanionStatusEvent({'stream': 'streaming'}));
      await cameraFrame(tester);
      expect(find.byType(StartMenu), findsOneWidget);
      expect(find.byType(CameraPreview), findsOneWidget);
      expect(find.textContaining('GLASSES VIEW'), findsOneWidget);
      final before = native.commands.length;

      await tester.tap(find.text('Settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await cameraFrame(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(CameraPreview), findsOneWidget, reason: 'one shared preview, not one per screen');
      expect(native.commands.length, before, reason: 'navigation never restarts the stream');

      // Stalled stream: shown as paused, not as a live feed. (The controller's stall timer runs in
      // the real zone here, so a status event triggers the rebuild instead.)
      now += 2000;
      native.controller.add(const CompanionStatusEvent({'stream': 'streaming'}));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('STREAM PAUSED'), findsOneWidget);

      services.settings.showMenuCamera = false;
      await cameraFrame(tester);
      expect(find.byType(CameraPreview), findsNothing);
      await teardown(tester);
    });

    testWidgets('mouse clicks still work over the camera feed', (tester) async {
      await boot(tester);
      native.controller.add(const CompanionStatusEvent({'stream': 'streaming'}));
      await cameraFrame(tester);
      await tester.tap(find.text('Tutorial'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(services.navigator.route, isA<TutorialRoute>());
      await teardown(tester);
    });

    testWidgets('tutorial: practice cast and shield with simulated input, then nothing permanent changed', (tester) async {
      await boot(tester);
      services.settings.simulatedInput = true;
      await tester.pump();
      expect(native.musicRequests.last, MusicTracks.menu);

      await tester.tap(find.text('Tutorial'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(WizardTutorialScreen), findsOneWidget);
      expect(native.musicRequests.last, MusicTracks.menu, reason: 'no restart when entering the tutorial');
      final state = tester.state<WizardTutorialScreenState>(find.byType(WizardTutorialScreen));

      // Step 1: look around (simulated head: arrow keys). HeadInput turns on a wall clock, so
      // let a little real time pass between frames.
      Future<void> turn(LogicalKeyboardKey key, int frames) async {
        await tester.sendKeyDownEvent(key);
        for (var i = 0; i < frames; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
          await tester.pump(const Duration(milliseconds: 25));
        }
        await tester.sendKeyUpEvent(key);
      }

      await turn(LogicalKeyboardKey.arrowLeft, 20);
      await turn(LogicalKeyboardKey.arrowRight, 40);
      expect(state.flow.lookedLeft && state.flow.lookedRight, isTrue);
      for (var i = 0; i < 50 && state.flow.step == TutorialStep.look; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(state.flow.step, TutorialStep.cast);

      // Step 2: fist (hold Space), then open (release) = one fireball at the practice target.
      services.simulated.move(const Offset(0.5, 0.6));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      for (var i = 0; i < 20 && !state.flow.castHit; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(state.flow.castHit, isTrue);
      for (var i = 0; i < 60 && state.flow.step == TutorialStep.cast; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(state.flow.step, TutorialStep.shield);

      // Step 3: wait for the telegraphed arrow, raise the shield (hold B) as it arrives.
      final game = state.game;
      expect(game.enemies.whereType<SkeletonArcher>(), hasLength(1), reason: 'only this step\'s practice actor');
      var raised = false;
      for (var i = 0; i < 400 && state.flow.step == TutorialStep.shield; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        final incoming = game.projectiles.where((p) => !p.done).toList();
        if (!raised && incoming.isNotEmpty) {
          final p = incoming.first;
          final eta = (p.z - game.config.shield.blockRadius) / p.speed;
          if (eta < 0.25) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
            raised = true;
          }
        }
        if (raised && state.flow.blocks > 0) break;
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
      expect(state.flow.blocks, 1, reason: 'the shield blocked the practice arrow');
      for (var i = 0; i < 60 && state.flow.step != TutorialStep.done; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(state.flow.step, TutorialStep.done);
      expect(find.text("YOU'RE READY"), findsOneWidget);

      // Nothing permanent changed.
      expect(game.score, 0);
      expect(game.lives, game.config.startingLives);
      expect(services.progression.unlocked, isEmpty);
      expect(services.leaderboards[wizardShooter.id]!.top, isEmpty);
      expect(await store.getString('progression.v1'), isNull);

      // Back to the menu: the sandbox is gone.
      await tester.tap(find.text('START MENU'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(StartMenu), findsOneWidget);
      expect(find.byType(WizardTutorialScreen), findsNothing);
      await teardown(tester);
    });

    testWidgets('tutorial can be exited mid-step and replayed from the start', (tester) async {
      await boot(tester);
      await tester.tap(find.text('Tutorial'));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50)); // past the shared 0.4 s activation guard
      }
      await tester.tap(find.text('Skip step'));
      await tester.pump();
      var state = tester.state<WizardTutorialScreenState>(find.byType(WizardTutorialScreen));
      expect(state.flow.step, TutorialStep.cast);
      expect(state.game.livingEnemies.single.kind, EnemyKind.troll, reason: 'practice target present');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(services.navigator.route, isA<StartMenuRoute>());
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Tutorial'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      state = tester.state<WizardTutorialScreenState>(find.byType(WizardTutorialScreen));
      expect(state.flow.step, TutorialStep.look, reason: 'a replay starts fresh');
      await teardown(tester);
    });

    testWidgets('a raised blocking hand never fires a spell', (tester) async {
      await boot(tester);
      services.settings.simulatedInput = true;
      await tester.pump();
      await tester.tap(find.text('PLAY'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final screen = tester.state<WizardGameScreenState>(find.byType(WizardGameScreen));
      services.simulated.move(const Offset(0.3, 0.6));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space); // fist: armed
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB); // raise the open hand to block
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(screen.game.shield.activations, 1);
      expect(screen.game.castsMade, 0, reason: 'blocking cancels the readied spell');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      await teardown(tester);
    });
  });
}
