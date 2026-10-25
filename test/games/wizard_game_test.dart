import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/games/wizard/enemies.dart';
import 'package:metarayzer/src/games/wizard/wizard_config.dart';
import 'package:metarayzer/src/games/wizard/wizard_game.dart';

/// A game with automatic spawning effectively disabled, for scripted scenarios.
WizardGame quietGame({WizardConfig? config}) {
  final base = config ?? const WizardConfig();
  return WizardGame(
    seed: 1,
    config: WizardConfig(
      startingLives: base.startingLives,
      fireballRange: base.fireballRange,
      hitGraceSeconds: base.hitGraceSeconds,
      difficulty: const DifficultySpec(spawnIntervalStart: 1e9, spawnIntervalEnd: 1e9, firstSpawnDelay: 1e9),
    ),
  );
}

void step(WizardGame g, double seconds, {double dt = 1 / 60}) {
  for (var t = 0.0; t < seconds; t += dt) {
    g.update(dt);
  }
}

void main() {
  test('player starts with three lives and zero score', () {
    final g = WizardGame(seed: 1);
    expect(g.lives, 3);
    expect(g.score, 0);
    expect(g.isOver, isFalse);
  });

  test('enemies spawn over time in the distance and approach', () {
    final g = WizardGame(seed: 2);
    step(g, 3);
    expect(g.enemies, isNotEmpty);
    final e = g.enemies.first;
    expect(e.distance, lessThanOrEqualTo(g.config.spawnDistance + g.config.spawnHalfWidth));
    final before = e.distance;
    step(g, 1);
    expect(e.distance, lessThan(before));
  });

  test('simultaneous enemies are capped', () {
    final g = WizardGame(seed: 3);
    for (var i = 0; i < 600; i++) {
      g.update(1 / 30);
      expect(g.livingEnemies.length, lessThanOrEqualTo(g.maxEnemies));
      if (g.isOver) break;
    }
  });

  group('enemy types', () {
    test('troll walks slowly and steadily', () {
      final g = quietGame();
      final t = g.spawn(EnemyKind.troll, x: 0);
      step(g, 2);
      expect(g.config.spawnDistance - t.z, closeTo(2 * g.config.spec(EnemyKind.troll).speed, 0.1));
    });

    test('goblin is much faster than the troll', () {
      final g = quietGame();
      final t = g.spawn(EnemyKind.troll, x: 0);
      final gob = g.spawn(EnemyKind.goblin, x: 0);
      step(g, 2);
      expect(g.config.spawnDistance - gob.z, greaterThan(2.5 * (g.config.spawnDistance - t.z)));
    });

    test('frog advances only while airborne, in hops', () {
      final g = quietGame();
      final f = g.spawn(EnemyKind.frog, x: 0) as HoppingFrog;
      var sawRestAfterHop = false, sawAir = false;
      var restZ = f.z;
      for (var i = 0; i < 240; i++) {
        final wasAirborne = f.airborne;
        final z0 = f.z;
        g.update(1 / 60);
        if (!f.airborne && !wasAirborne) {
          expect(f.z, closeTo(z0, 1e-9), reason: 'no progress while sitting');
          if (sawAir && f.z < restZ) sawRestAfterHop = true;
          restZ = f.z;
        }
        if (f.airborne) {
          sawAir = true;
          expect(f.elevation, greaterThanOrEqualTo(0));
        }
      }
      expect(sawRestAfterHop, isTrue);
      // Average speed matches its spec (within one hop's worth).
      final spec = g.config.spec(EnemyKind.frog);
      expect(g.config.spawnDistance - f.distance, closeTo(4 * spec.speed, spec.speed * 1.0));
    });

    test('skeleton archer stops at its range and fires telegraphed arrows that cost a life', () {
      final g = quietGame();
      final a = g.spawn(EnemyKind.skeletonArcher, x: 0) as SkeletonArcher;
      step(g, 40);
      expect(a.distance, closeTo(a.spec.attackDistance, 1e-6));
      expect(a.distance, lessThan(g.config.fireballRange), reason: 'archers must be killable');
      expect(g.lives, lessThan(3), reason: 'its arrows hit the player');
      expect(a.isAlive, isTrue, reason: 'archers keep shooting rather than vanishing');
    });

    test('every melee enemy telegraphs, strikes once, and is resolved', () {
      for (final kind in [EnemyKind.troll, EnemyKind.goblin, EnemyKind.frog]) {
        final g = quietGame();
        final e = g.spawn(kind, x: 0);
        var sawAttacking = false;
        for (var i = 0; i < 60 * 30 && g.enemies.contains(e); i++) {
          g.update(1 / 60);
          if (e.state == EnemyState.attacking) sawAttacking = true;
        }
        expect(sawAttacking, isTrue, reason: '$kind wind-up');
        expect(g.lives, 2, reason: '$kind hits exactly once');
        expect(g.enemies, isNot(contains(e)), reason: '$kind removed after striking');
      }
    });
  });

  group('fireballs', () {
    test('target the nearest eligible enemy in range', () {
      final g = quietGame();
      final far = g.spawn(EnemyKind.troll, x: 0)..z = 15;
      final near = g.spawn(EnemyKind.troll, x: 0)..z = 8;
      final outOfRange = g.spawn(EnemyKind.troll, x: 0)..z = 25;
      expect(g.castFireball(), CastResult.launched);
      expect(g.fireballs.single.target, same(near));
      step(g, 0.5);
      expect(near.state, EnemyState.defeated);
      expect(far.isAlive, isTrue);
      expect(outOfRange.isAlive, isTrue);
    });

    test('enemies beyond range are never hit', () {
      final g = quietGame();
      final e = g.spawn(EnemyKind.troll, x: 0)..z = g.config.fireballRange + 0.5;
      expect(g.castFireball(), CastResult.noTargetInRange);
      step(g, 1);
      expect(e.isAlive, isTrue);
      expect(g.score, 0);
    });

    test('range uses the same Euclidean distance as everything else', () {
      final g = quietGame();
      final e = g.spawn(EnemyKind.troll, x: 0)
        ..z = 19
        ..x = 7; // sqrt(19² + 7²) ≈ 20.2 > 20
      expect(g.targetableEnemies(), isEmpty);
      e.x = 5; // ≈ 19.6
      expect(g.targetableEnemies(), [e]);
    });

    test('defeating an enemy awards its points exactly once', () {
      final g = quietGame();
      final e = g.spawn(EnemyKind.goblin, x: 0)..z = 10;
      g.castFireball();
      step(g, 1);
      expect(g.score, g.config.spec(EnemyKind.goblin).score);
      expect(e.scored, isTrue);
      // Hitting the corpse again (if anything tried) gives nothing.
      expect(e.takeDamage(1), isFalse);
      g.castFireball();
      step(g, 1);
      expect(g.score, g.config.spec(EnemyKind.goblin).score);
      expect(g.enemiesDefeated, 1);
    });

    test('each enemy type awards its configured score', () {
      for (final kind in EnemyKind.values.where((k) => k != EnemyKind.slime)) { // slimes: see wizard_v3_test
        final g = quietGame();
        g.spawn(kind, x: 0).z = 10;
        g.castFireball();
        step(g, 1);
        expect(g.score, g.config.spec(kind).score, reason: '$kind');
      }
    });

    test('a second quick cast picks the next enemy instead of the doomed one', () {
      final g = quietGame();
      final a = g.spawn(EnemyKind.troll, x: 0)..z = 8;
      final b = g.spawn(EnemyKind.troll, x: 0)..z = 12;
      g.castFireball();
      g.castFireball();
      expect(g.fireballs.map((f) => f.target), [a, b]);
      step(g, 1);
      expect(a.isAlive || b.isAlive, isFalse);
    });

    test('killing an enemy during its wind-up prevents its hit', () {
      final g = quietGame();
      final e = g.spawn(EnemyKind.troll, x: 0);
      while (e.state != EnemyState.attacking) {
        g.update(1 / 60);
      }
      g.castFireball();
      step(g, 2);
      expect(g.lives, 3);
      expect(g.score, e.spec.score);
    });

    test('cast with no enemies fizzles harmlessly', () {
      final g = quietGame();
      expect(g.castFireball(), CastResult.noTargetInRange);
      step(g, 1);
      final impacts = g.drainEvents().whereType<FireballImpact>().toList();
      expect(impacts.single.enemy, isNull);
      expect(g.score, 0);
    });
  });

  group('lives and game over', () {
    test('three hits end the game; nothing changes afterwards', () {
      final g = quietGame(config: const WizardConfig(hitGraceSeconds: 0));
      for (var i = 0; i < 3; i++) {
        g.spawn(EnemyKind.goblin, x: 0);
        step(g, 10);
      }
      expect(g.lives, 0);
      expect(g.isOver, isTrue);
      expect(g.drainEvents().whereType<GameEnded>(), hasLength(1));
      final elapsed = g.elapsed;
      g.spawn(EnemyKind.troll);
      step(g, 5);
      expect(g.elapsed, elapsed, reason: 'simulation is frozen once over');
      expect(g.castFireball(), CastResult.gameOver);
    });

    test('simultaneous hits within the grace period cost only one life', () {
      final g = quietGame();
      g.spawn(EnemyKind.troll, x: 0);
      g.spawn(EnemyKind.troll, x: 0.01);
      step(g, 30);
      expect(g.lives, 2);
      final hits = g.drainEvents().whereType<PlayerHit>().toList();
      expect(hits, hasLength(2));
      expect(hits.where((h) => h.lifeLost), hasLength(1));
    });
  });

  group('difficulty', () {
    test('ramps smoothly and monotonically, then plateaus', () {
      final g = WizardGame(seed: 5, config: const WizardConfig(startingLives: 1000000));
      var prevInterval = g.spawnInterval, prevSpeed = g.speedMultiplier, prevMax = g.maxEnemies;
      expect(g.difficultyLevel, 0);
      for (var i = 0; i < 300 * 10; i++) {
        g.update(0.1);
        expect(g.spawnInterval, lessThanOrEqualTo(prevInterval + 1e-12));
        expect(g.speedMultiplier, greaterThanOrEqualTo(prevSpeed - 1e-12));
        expect(g.maxEnemies, greaterThanOrEqualTo(prevMax));
        expect((g.speedMultiplier - prevSpeed).abs(), lessThan(0.01), reason: 'no spikes');
        prevInterval = g.spawnInterval;
        prevSpeed = g.speedMultiplier;
        prevMax = g.maxEnemies;
      }
      expect(g.difficultyLevel, 1);
      expect(g.spawnWeight(EnemyKind.goblin), greaterThan(g.config.spec(EnemyKind.goblin).spawnWeightStart));
    });

    test('a long endless run keeps working', () {
      final g = WizardGame(seed: 9, config: const WizardConfig(startingLives: 1000000));
      for (var i = 0; i < 20 * 60 * 30; i++) {
        g.update(1 / 30);
        if (i % 15 == 0) g.castFireball();
      }
      expect(g.score, greaterThan(0));
      expect(g.enemies.length, lessThan(30), reason: 'enemies are cleaned up');
      expect(g.fireballs.length, lessThan(30));
    });
  });
}
