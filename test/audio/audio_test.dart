import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/app/app_settings.dart';
import 'package:metarayzer/src/app/key_value_store.dart';
import 'package:metarayzer/src/audio/audio_service.dart';
import 'package:metarayzer/src/games/wizard/wizard_audio.dart';
import 'package:metarayzer/src/games/wizard/wizard_config.dart';
import 'package:metarayzer/src/games/wizard/wizard_game.dart';

import '../app/tracking_controller_test.dart' show FakeNative;

void main() {
  late FakeNative native;
  late AppSettings settings;
  late AudioService audio;
  late double now;

  setUp(() {
    native = FakeNative();
    settings = AppSettings(store: MemoryStore());
    now = 0;
    audio = AudioService(native: native, settings: settings, nowMs: () => now);
  });

  tearDown(() => audio.dispose());

  test('settings changes are applied to the native engine immediately', () async {
    await Future<void>.delayed(Duration.zero);
    final before = native.configs.length;
    settings.sfxVolume = 0.25;
    settings.spatialMode = SpatialMode.binaural;
    settings.audioOutput = AudioOutputChoice.companion;
    await Future<void>.delayed(Duration.zero);
    expect(native.configs.length, greaterThan(before));
    expect(native.configs.last, containsPair('sfx', 0.25));
    expect(native.configs.last, containsPair('mode', 'binaural'));
    expect(native.configs.last, containsPair('output', 'companion'));
  });

  test('duplicate triggers of the same sound within its window are suppressed', () {
    expect(audio.play(Sounds.fireballCast), isTrue);
    now += 10;
    expect(audio.play(Sounds.fireballCast), isFalse, reason: 'repeated gesture detection');
    expect(audio.play(Sounds.zap), isTrue, reason: 'other sounds unaffected');
    now += 50;
    expect(audio.play(Sounds.fireballCast), isTrue);
    expect(native.plays.map((p) => p.sound), [Sounds.fireballCast, Sounds.zap, Sounds.fireballCast]);
  });

  group('WizardAudio', () {
    WizardGame quiet({Set<String> unlocked = const {}}) => WizardGame(
          seed: 1,
          unlockedSpells: unlocked,
          config: const WizardConfig(difficulty: DifficultySpec(spawnIntervalStart: 1e9, spawnIntervalEnd: 1e9, firstSpawnDelay: 1e9)),
        );

    test('enemy sounds are positioned at the enemy (direction + distance from game state)', () {
      final w = WizardAudio(audio);
      final g = quiet();
      final left = g.spawn(EnemyKind.troll, x: -4)..z = 9;
      w.consume(g.drainEvents()); // spawn
      g.applyDamage(left, 1);
      now += 100;
      w.consume(g.drainEvents());
      final defeat = native.plays.firstWhere((p) => p.sound == Sounds.defeatTroll);
      expect(defeat.x, closeTo(left.x, 1e-9));
      expect(defeat.z, closeTo(left.z, 1e-9));
      expect(defeat.positional, isTrue);
    });

    test('one fireball = one cast sound and one impact sound', () {
      final w = WizardAudio(audio);
      final g = quiet();
      g.spawn(EnemyKind.goblin, x: 0).z = 8;
      g.drainEvents();
      g.castFireball();
      for (var i = 0; i < 60; i++) {
        g.update(1 / 60);
        now += 16;
        w.consume(g.drainEvents());
      }
      expect(native.plays.where((p) => p.sound == Sounds.fireballCast), hasLength(1));
      expect(native.plays.where((p) => p.sound == Sounds.fireballImpact), hasLength(1));
      expect(native.plays.where((p) => p.sound == Sounds.defeatGoblin), hasLength(1));
    });

    test('chain lightning zaps follow the chain, one per target, staggered in time', () {
      final w = WizardAudio(audio);
      final g = quiet(unlocked: {SpellIds.chainLightning});
      for (final x in [0.0, 2.0, 4.0]) {
        g.spawn(EnemyKind.troll, x: x)
          ..x = x
          ..z = 10
          ..health = 10;
      }
      g.drainEvents();
      g.castChainLightning();
      w.consume(g.drainEvents());
      expect(native.plays.where((p) => p.sound == Sounds.zap), isEmpty, reason: 'zaps are scheduled, not immediate');
      for (var i = 0; i < 20; i++) {
        now += 16;
        w.tick(1 / 60);
      }
      final zaps = native.plays.where((p) => p.sound == Sounds.zap).toList();
      expect(zaps.map((z) => z.x), [0.0, 2.0, 4.0]);
    });
  });
}
