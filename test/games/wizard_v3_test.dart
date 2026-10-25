import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/games/wizard/aim.dart';
import 'package:metarayzer/src/games/wizard/difficulty.dart';
import 'package:metarayzer/src/games/wizard/enemies.dart';
import 'package:metarayzer/src/games/wizard/wizard_config.dart';
import 'package:metarayzer/src/games/wizard/wizard_game.dart';

/// A game with automatic spawning disabled, for scripted scenarios.
WizardGame quietGame({Set<String> unlocked = const {}, SlimeSpec slime = const SlimeSpec(), ChainLightningSpec lightning = const ChainLightningSpec()}) => WizardGame(
      seed: 1,
      unlockedSpells: unlocked,
      config: WizardConfig(
        slime: slime,
        chainLightning: lightning,
        difficulty: const DifficultySpec(spawnIntervalStart: 1e9, spawnIntervalEnd: 1e9, firstSpawnDelay: 1e9),
      ),
    );

void step(WizardGame g, double seconds, {double dt = 1 / 60}) {
  for (var t = 0.0; t < seconds; t += dt) {
    g.update(dt);
  }
}

Enemy place(WizardGame g, EnemyKind kind, double x, double z) => g.spawn(kind, x: x)
  ..x = x
  ..z = z;

void main() {
  group('difficulty controller', () {
    test('starts manageable, ramps by time, and is capped', () {
      final d = DifficultyController(const WizardConfig());
      d.update(elapsedSeconds: 0, score: 0);
      expect(d.spawnInterval, 2.4);
      expect(d.maxEnemies, 3);
      expect(d.speedMultiplier, 1.0);
      d.update(elapsedSeconds: 10000, score: 0);
      expect(d.progress, 1);
      expect(d.spawnInterval, closeTo(0.7, 1e-9));
      expect(d.maxEnemies, 9);
      expect(d.speedMultiplier, closeTo(1.55, 1e-9));
    });

    test('a high score ramps difficulty faster than time alone', () {
      final byTime = DifficultyController(const WizardConfig())..update(elapsedSeconds: 60, score: 0);
      final byScore = DifficultyController(const WizardConfig())..update(elapsedSeconds: 60, score: 900);
      expect(byScore.progress, greaterThan(byTime.progress));
    });

    test('progress never decreases', () {
      final d = DifficultyController(const WizardConfig())..update(elapsedSeconds: 0, score: 1200);
      final p = d.progress;
      d.update(elapsedSeconds: 1, score: 0);
      expect(d.progress, p);
    });

    test('wind-ups shrink with difficulty but never below the floor', () {
      const config = WizardConfig();
      final d = DifficultyController(config);
      final troll = config.spec(EnemyKind.troll), goblin = config.spec(EnemyKind.goblin);
      expect(d.windupFor(troll), troll.attackWindup);
      d.update(elapsedSeconds: 1e6, score: 0);
      expect(d.windupFor(troll), closeTo(troll.attackWindup * 0.75, 1e-9));
      expect(d.windupFor(goblin), greaterThanOrEqualTo(config.difficulty.minWindupSeconds));
    });

    test('spawn mix shifts toward dangerous enemies', () {
      final d = DifficultyController(const WizardConfig());
      final goblinStart = d.spawnWeight(EnemyKind.goblin), trollStart = d.spawnWeight(EnemyKind.troll);
      d.update(elapsedSeconds: 1e6, score: 0);
      expect(d.spawnWeight(EnemyKind.goblin), greaterThan(goblinStart));
      expect(d.spawnWeight(EnemyKind.troll), lessThan(trollStart));
    });

    test('a long run respects all caps and never stops', () {
      final g = WizardGame(seed: 3, config: const WizardConfig(startingLives: 1000000));
      for (var i = 0; i < 15 * 60 * 30; i++) {
        g.update(1 / 30);
        if (i % 10 == 0) g.cast();
        expect(g.livingEnemies.length, lessThanOrEqualTo(g.maxEnemies + g.config.slime.childrenPerSplit));
        expect(g.activeSlimes, lessThanOrEqualTo(g.config.slime.maxActiveSlimes));
      }
      expect(g.isOver, isFalse);
      expect(g.difficultyLevel, 1);
    });
  });

  group('Splitting Slime', () {
    test('a hit splits it into two smaller, faster, independent slimes', () {
      final g = quietGame();
      final big = place(g, EnemyKind.slime, 0, 12) as SplittingSlime;
      g.castFireball();
      step(g, 0.5);
      expect(big.state, isNot(EnemyState.approaching));
      final kids = g.enemies.whereType<SplittingSlime>().where((s) => s.isAlive).toList();
      expect(kids, hasLength(2));
      expect(kids.every((k) => k.generation == 1 && k.scale < big.scale && k.speedFactor > 1), isTrue);
      expect(kids.every((k) => k.familyId == big.familyId), isTrue);
      expect(kids[0].x, isNot(kids[1].x), reason: 'children spread apart');
      expect(g.score, 0, reason: 'splitting awards nothing');
      final z0 = kids.first.z;
      step(g, 1);
      expect(kids.first.z, lessThan(z0), reason: 'children keep approaching');
    });

    test('family awards its score exactly once, when the last member falls', () {
      final g = quietGame();
      place(g, EnemyKind.slime, 0, 12);
      g.castFireball();
      step(g, 0.5);
      final kids = g.enemies.whereType<SplittingSlime>().where((s) => s.isAlive).toList();
      g.applyDamage(kids[0], 1);
      expect(g.score, 0);
      g.applyDamage(kids[1], 1);
      expect(g.score, g.config.spec(EnemyKind.slime).score);
      // Repeated damage on dead members changes nothing.
      g.applyDamage(kids[1], 1);
      g.applyDamage(kids[0], 5);
      expect(g.score, g.config.spec(EnemyKind.slime).score);
      expect(g.enemiesDefeated, 2);
    });

    test('if a family member reaches the player, the family awards nothing', () {
      final g = quietGame();
      place(g, EnemyKind.slime, 0, 6);
      g.castFireball();
      step(g, 0.3);
      final kids = g.enemies.whereType<SplittingSlime>().where((s) => s.isAlive).toList();
      // Let one child reach the player and strike; kill the other.
      g.applyDamage(kids[1], 1);
      while (kids[0].isAlive && !g.isOver) {
        g.update(1 / 60);
      }
      expect(g.lives, 2);
      expect(g.score, 0);
    });

    test('split depth is limited: the smallest generation dies normally', () {
      final g = quietGame();
      place(g, EnemyKind.slime, 0, 12);
      g.applyDamage(g.enemies.single, 1);
      final kid = g.enemies.whereType<SplittingSlime>().firstWhere((s) => s.isAlive);
      final r = g.applyDamage(kid, 1);
      expect(r.defeated, isTrue);
      expect(r.split, isFalse);
    });

    test('deeper split depth is configurable and still bounded by the active-slime cap', () {
      final g = quietGame(slime: const SlimeSpec(maxSplitDepth: 3, maxActiveSlimes: 5));
      place(g, EnemyKind.slime, 0, 20);
      // Keep hitting the first alive slime; the population must never exceed the cap.
      for (var i = 0; i < 40; i++) {
        final alive = g.enemies.where((e) => e.isAlive).toList();
        if (alive.isEmpty) break;
        g.applyDamage(alive.first, 1);
        expect(g.activeSlimes, lessThanOrEqualTo(5));
      }
      expect(g.enemies.where((e) => e.isAlive), isEmpty, reason: 'the family can always be finished');
      expect(g.score, g.config.spec(EnemyKind.slime).score);
    });
  });

  group('Chain Lightning', () {
    const unlocked = {SpellIds.chainLightning};

    test('is locked until unlocked', () {
      final g = quietGame();
      expect(g.castChainLightning(), CastResult.locked);
      expect(g.availableSpells, [SpellIds.fireball]);
      expect(g.cycleSpell(), isFalse);
    });

    test('hits the first enemy on the aim path, not the nearest overall', () {
      final g = quietGame(unlocked: unlocked);
      final offPath = place(g, EnemyKind.troll, -3, 5); // nearest, but left of the aim
      final onPath = place(g, EnemyKind.troll, 0, 15);
      g.aimYaw = 0;
      expect(g.castChainLightning(), CastResult.launched);
      expect(onPath.state, EnemyState.defeated);
      expect(offPath.isAlive, isTrue, reason: 'too far from the primary (chain radius) and off the beam');
    });

    test('aiming sideways hits an enemy in that direction', () {
      final g = quietGame(unlocked: unlocked);
      final right = place(g, EnemyKind.troll, 6, 10);
      place(g, EnemyKind.troll, -6, 10);
      g.aimYaw = math.atan2(6, 10);
      g.castChainLightning();
      final cast = g.drainEvents().whereType<ChainLightningCast>().single;
      expect(cast.hits.first.enemy, same(right));
    });

    test('no enemy on the path: no damage anywhere', () {
      final g = quietGame(unlocked: unlocked);
      final a = place(g, EnemyKind.troll, 8, 8);
      g.aimYaw = -0.6;
      expect(g.castChainLightning(), CastResult.noTargetInRange);
      expect(a.isAlive, isTrue);
      expect(g.drainEvents().whereType<ChainLightningCast>().single.hits, isEmpty);
    });

    test('enemies beyond the spell range are not hit', () {
      final g = quietGame(unlocked: unlocked);
      final far = place(g, EnemyKind.troll, 0, 26);
      g.castChainLightning();
      expect(far.isAlive, isTrue);
    });

    test('chains to nearby enemies with decreasing damage, each hit once', () {
      final g = quietGame(unlocked: unlocked, lightning: const ChainLightningSpec(primaryDamage: 2, damageFalloff: 0.5, maxTargets: 4, maxJumps: 3));
      // Tough targets so we can read the damage they took.
      final a = place(g, EnemyKind.troll, 0, 10)..health = 10;
      final b = place(g, EnemyKind.troll, 2, 10)..health = 10;
      final c = place(g, EnemyKind.troll, 4, 10)..health = 10;
      final d = place(g, EnemyKind.troll, 6, 10)..health = 10;
      final e = place(g, EnemyKind.troll, 8, 10)..health = 10; // 5th: over maxTargets
      g.castChainLightning();
      expect(10 - a.health, closeTo(2, 1e-9));
      expect(10 - b.health, closeTo(1, 1e-9));
      expect(10 - c.health, closeTo(0.5, 1e-9));
      expect(10 - d.health, closeTo(0.25, 1e-9));
      expect(e.health, 10);
      final hits = g.drainEvents().whereType<ChainLightningCast>().single.hits;
      expect(hits.map((h) => h.enemy).toSet(), hasLength(hits.length), reason: 'no enemy twice');
    });

    test('chain radius limits arcs; maxJumps limits chain length', () {
      final g = quietGame(unlocked: unlocked, lightning: const ChainLightningSpec(chainRadius: 3, maxJumps: 1));
      place(g, EnemyKind.troll, 0, 10);
      final near = place(g, EnemyKind.troll, 2, 10);
      final next = place(g, EnemyKind.troll, 4, 10);
      final distant = place(g, EnemyKind.troll, -6, 10);
      g.castChainLightning();
      expect(near.isAlive, isFalse);
      expect(next.isAlive, isTrue, reason: 'maxJumps = 1');
      expect(distant.isAlive, isTrue, reason: 'outside chain radius');
    });

    test('awards score only for defeated enemies, once', () {
      final g = quietGame(unlocked: unlocked, lightning: const ChainLightningSpec(primaryDamage: 1, damageFalloff: 0.5));
      final a = place(g, EnemyKind.goblin, 0, 10);
      final b = place(g, EnemyKind.goblin, 2, 10); // takes 0.5: survives
      g.castChainLightning();
      expect(a.isAlive, isFalse);
      expect(b.isAlive, isTrue);
      expect(g.score, g.config.spec(EnemyKind.goblin).score);
    });

    test('splitting slime children are not hit by the cast that created them', () {
      final g = quietGame(unlocked: unlocked);
      place(g, EnemyKind.slime, 0, 10);
      g.castChainLightning();
      final kids = g.enemies.whereType<SplittingSlime>().where((s) => s.isAlive);
      expect(kids, hasLength(2));
    });

    test('has a cooldown', () {
      final g = quietGame(unlocked: unlocked);
      g.castChainLightning();
      expect(g.castChainLightning(), CastResult.onCooldown);
      step(g, g.config.chainLightning.cooldownSeconds + 0.05);
      expect(g.castChainLightning(), isNot(CastResult.onCooldown));
    });
  });

  group('spells and unlocks', () {
    test('score alone never unlocks Chain Lightning (v4: the first boss defeat does)', () {
      final g = quietGame();
      for (var i = 0; i < 40 && g.score < 1000; i++) {
        g.applyDamage(place(g, EnemyKind.goblin, 0, 10), 1);
      }
      expect(g.score, greaterThanOrEqualTo(1000));
      expect(g.drainEvents().whereType<SpellUnlocked>(), isEmpty);
      expect(g.availableSpells, [SpellIds.fireball]);
    });

    test('a run that starts unlocked never fires the unlock event', () {
      final g = quietGame(unlocked: const {SpellIds.chainLightning});
      for (var i = 0; i < 15; i++) {
        g.applyDamage(place(g, EnemyKind.goblin, 0, 10), 1);
      }
      expect(g.drainEvents().whereType<SpellUnlocked>(), isEmpty);
    });

    test('cycling switches the cast between spells; fireball targeting is unchanged', () {
      final g = quietGame(unlocked: const {SpellIds.chainLightning});
      final nearestOffAim = place(g, EnemyKind.troll, -3, 5);
      expect(g.selectedSpell, SpellIds.fireball);
      g.aimYaw = 0.8; // fireball ignores aim
      g.cast();
      expect(g.fireballs.single.target, same(nearestOffAim));
      expect(g.cycleSpell(), isTrue);
      expect(g.selectedSpell, SpellIds.chainLightning);
      expect(g.cycleSpell(), isTrue);
      expect(g.selectedSpell, SpellIds.fireball);
    });
  });

  group('aim', () {
    test('distanceAlongAim: on-path, off-path, behind, beyond range', () {
      expect(distanceAlongAim(0, 0, 10, halfWidth: 1, range: 20), closeTo(10, 1e-9));
      expect(distanceAlongAim(0, 2, 10, halfWidth: 1, range: 20), isNull);
      expect(distanceAlongAim(0, 0, -5, halfWidth: 1, range: 20), isNull);
      expect(distanceAlongAim(0, 0, 25, halfWidth: 1, range: 20), isNull);
      final yaw = math.atan2(5, 5);
      expect(distanceAlongAim(yaw, 5, 5, halfWidth: 0.1, range: 20), closeTo(math.sqrt(50), 1e-9));
    });
  });
}
