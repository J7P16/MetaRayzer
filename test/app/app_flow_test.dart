import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/app/app_services.dart';
import 'package:metarayzer/src/app/app_settings.dart';
import 'package:metarayzer/src/app/app_shell.dart';
import 'package:metarayzer/src/app/key_value_store.dart';
import 'package:metarayzer/src/app/tracking_controller.dart';
import 'package:metarayzer/src/games/wizard/wizard_config.dart';
import 'package:metarayzer/src/games/wizard/wizard_screen.dart';
import 'package:metarayzer/src/platform/app_navigator.dart';
import 'package:metarayzer/src/platform/minigame.dart';
import 'package:metarayzer/src/ui/menu/game_over_screen.dart';
import 'package:metarayzer/src/ui/menu/start_menu.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import 'tracking_controller_test.dart' show FakeNative;

/// The real wizard game, tuned so a run ends within a few seconds: one life, goblins only.
final fastWizard = MinigameDefinition(
  id: wizardShooter.id,
  title: wizardShooter.title,
  tagline: wizardShooter.tagline,
  builder: (context, host) => WizardGameScreen(
    host: host,
    seed: 4,
    config: WizardConfig(
      startingLives: 1,
      difficulty: const DifficultySpec(firstSpawnDelay: 0.2, spawnIntervalStart: 0.5, spawnIntervalEnd: 0.5),
      enemies: {
        for (final e in WizardConfig.defaultEnemies.entries)
          e.key: EnemySpec(
            kind: e.value.kind,
            name: e.value.name,
            speed: e.value.speed,
            score: e.value.score,
            attackDistance: e.value.attackDistance,
            attackWindup: e.value.attackWindup,
            spawnWeightStart: e.key == EnemyKind.goblin ? 1 : 0,
            spawnWeightEnd: e.key == EnemyKind.goblin ? 1 : 0,
            height: e.value.height,
          ),
      },
    ),
  ),
);

NativeHand fixtureHand(int width) {
  final doc = jsonDecode(File('test/fixtures/real_hand_landmarks.json').readAsStringSync()) as Map;
  final h = (doc['hands'] as List).cast<Map>().firstWhere((h) => h['width'] == width);
  return NativeHand(
    landmarks: Float64List.fromList((h['landmarks'] as List).cast<num>().map((n) => n.toDouble()).toList()),
    confidence: 1,
    chirality: 'unknown',
  );
}

void main() {
  final fist = fixtureHand(382), open = fixtureHand(638);

  late FakeNative native;
  late AppServices services;
  var seq = 0;
  var now = 0.0;

  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    native = FakeNative();
    final store = MemoryStore();
    final tracking = TrackingController(native: native, nowMs: () => now, scheduleAck: (ack) => ack());
    services = AppServices(tracking: tracking, settings: AppSettings(store: store), games: [fastWizard], store: store);
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

  Future<void> handFrame(WidgetTester tester, NativeHand hand) async {
    now += 40;
    native.controller.add(FrameEvent(
      jpeg: Uint8List(0), width: 504, height: 896, seq: seq++, source: 'glasses', captureTimeMs: 0, receivedAtMs: 0,
      processedAtMs: 0, decodeMs: 0, detectMs: 0, dropped: 0, hands: [hand],
    ));
    await tester.pump(const Duration(milliseconds: 40));
  }

  testWidgets('Start Menu -> Play -> cast with real gesture landmarks -> Game Over -> Play Again -> Esc', (tester) async {
    await boot(tester);
    expect(find.byType(StartMenu), findsOneWidget);
    expect(find.text('No scores yet. Be the first wizard to hold the line.'), findsOneWidget);
    expect(find.textContaining('camera streaming'), findsNothing);
    expect(find.text('Glasses connected · camera off'), findsOneWidget, reason: 'stream indicator: connected, not streaming');
    expect(find.textContaining('LIVE'), findsNothing);

    await tester.tap(find.text('PLAY'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(WizardGameScreen), findsOneWidget);
    final game = tester.state<WizardGameScreenState>(find.byType(WizardGameScreen)).game;
    expect(game.lives, 1);

    // Fist (ready) then open palm (cast), using real Apple Vision landmarks.
    for (var i = 0; i < 3; i++) {
      await handFrame(tester, fist);
    }
    for (var i = 0; i < 8; i++) {
      await handFrame(tester, open);
    }
    expect(game.castsMade, 1, reason: 'one fist->open transition = one fireball; holding open does not repeat');

    // Let the goblins through: the run ends and the results screen appears.
    for (var i = 0; i < 300 && find.byType(GameOverScreen).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(game.isOver, isTrue);
    expect(find.byType(GameOverScreen), findsOneWidget);
    final frozenAt = game.elapsed;
    await tester.pump(const Duration(milliseconds: 400)); // cross-fade
    expect(game.elapsed, frozenAt, reason: 'the finished game is frozen');
    expect(find.byType(WizardGameScreen), findsNothing, reason: 'gameplay must not continue behind the results');
    expect(find.text('${game.score}'), findsWidgets);
    expect(services.leaderboards[wizardShooter.id]!.top.single.score, game.score);

    await tester.tap(find.text('PLAY AGAIN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(WizardGameScreen), findsOneWidget);
    final second = tester.state<WizardGameScreenState>(find.byType(WizardGameScreen)).game;
    expect(identical(second, game), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(StartMenu), findsOneWidget);
    expect(services.leaderboards[wizardShooter.id]!.top, hasLength(1), reason: 'an aborted run is not recorded');

    await teardown(tester);
  });

  testWidgets('hand navigation (always on): hovering PLAY with the hand cursor for the dwell time starts the game once', (tester) async {
    await boot(tester);
    services.settings
      ..dwellSeconds = 1.0
      ..simulatedInput = true; // dev source drives the same hand-input interface as the camera
    await tester.pump();

    final playCenter = tester.getCenter(find.text('PLAY'));
    services.simulated.move(Offset(playCenter.dx / 1400, playCenter.dy / 900));
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 50)); // 0.8 s
    }
    expect(services.navigator.route, isA<StartMenuRoute>(), reason: 'not before the dwell time');
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50)); // 1.2 s
    }
    expect(services.navigator.route, isA<PlayingRoute>());
    await teardown(tester);
  });

  testWidgets('defeating the first night boss in a run unlocks Chain Lightning permanently', (tester) async {
    await boot(tester);
    await tester.tap(find.text('PLAY'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final game = tester.state<WizardGameScreenState>(find.byType(WizardGameScreen)).game;
    expect(services.progression.isUnlocked(SpellIds.chainLightning), isFalse);
    expect(game.availableSpells, [SpellIds.fireball]);
    // Score alone does nothing.
    for (var i = 0; i < 30; i++) {
      game.applyDamage(game.spawn(EnemyKind.goblin, x: 0)..z = 10, 1);
    }
    await tester.pump(const Duration(milliseconds: 20));
    expect(services.progression.isUnlocked(SpellIds.chainLightning), isFalse);
    // A real boss defeat does.
    final boss = game.spawn(EnemyKind.boss, x: 0)..z = 15;
    game.applyDamage(boss, boss.maxHealth);
    await tester.pump(const Duration(milliseconds: 20)); // one game tick drains the event
    expect(services.progression.isUnlocked(SpellIds.chainLightning), isTrue);
    expect(game.availableSpells, contains(SpellIds.chainLightning));
    expect(find.textContaining('UNLOCKED'), findsNothing, reason: 'banner is painted, not a widget');
    // Q switches spells in game.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.pump();
    expect(game.selectedSpell, SpellIds.chainLightning);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 400));
    await teardown(tester);
  });

  testWidgets('mouse navigation works with the glasses disconnected', (tester) async {
    await boot(tester);
    native.controller.add(const CompanionEvent(connected: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.textContaining('Glasses not connected: open MetaRayzer Companion'), findsOneWidget);
    expect(find.textContaining('Hand detection unavailable'), findsOneWidget);
    await tester.tap(find.text('PLAY'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(WizardGameScreen), findsOneWidget);
    await teardown(tester);
  });
}
