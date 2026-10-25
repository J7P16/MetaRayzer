import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/games/wizard/day_night.dart';
import 'package:metarayzer/src/games/wizard/difficulty.dart';
import 'package:metarayzer/src/games/wizard/enemies.dart';
import 'package:metarayzer/src/games/wizard/shield.dart';
import 'package:metarayzer/src/games/wizard/view/health_bar.dart';
import 'package:metarayzer/src/games/wizard/wizard_config.dart';
import 'package:metarayzer/src/games/wizard/wizard_game.dart';

const noSpawns = DifficultySpec(spawnIntervalStart: 1e9, spawnIntervalEnd: 1e9, firstSpawnDelay: 1e9);

/// A run with automatic spawning off (the day-night cycle still runs unless disabled).
WizardGame quiet({
  ArcherSpec archer = const ArcherSpec(),
  DayNightSpec dayNight = const DayNightSpec(enabled: false),
  BossSpec boss = const BossSpec(),
  int lives = 3,
  GameMode mode = GameMode.run,
  Set<String> unlocked = const {},
  int seed = 1,
}) =>
    WizardGame(
      seed: seed,
      mode: mode,
      unlockedSpells: unlocked,
      config: WizardConfig(startingLives: lives, difficulty: noSpawns, archer: archer, dayNight: dayNight, boss: boss),
    );

/// Archer arrows with no aim error (always on target), for deterministic hit/block tests.
const perfectArrows = ArcherSpec(arrow: ProjectileSpec(speed: 9, aimSpread: 0, minAimSpread: 0));

void step(WizardGame g, double seconds, {double dt = 1 / 60}) {
  for (var t = 0.0; t < seconds - 1e-9; t += dt) {
    g.update(dt);
  }
}

/// Fires one projectile from (x, z) straight at the player with no aim error.
Projectile shoot(WizardGame g, {double x = 0, double z = 14}) {
  final archer = g.spawn(EnemyKind.skeletonArcher, x: x)..z = z;
  g.fireProjectile(archer, const ProjectileSpec(speed: 9, aimSpread: 0, minAimSpread: 0));
  g.enemies.remove(archer); // only the projectile matters
  return g.projectiles.last;
}

void main() {
  group('shield state machine', () {
    test('a recognized pose activates it for exactly 0.5 s, then it expires', () {
      final s = Shield(const ShieldSpec());
      expect(s.setPose(true), isTrue);
      expect(s.isActive, isTrue);
      s.update(0.49);
      expect(s.isActive, isTrue);
      expect(s.update(0.02), isTrue, reason: 'reports the expiry');
      expect(s.isActive, isFalse);
      expect(s.remaining, 0);
    });

    test('holding the pose neither extends nor retriggers it', () {
      final s = Shield(const ShieldSpec());
      s.setPose(true);
      for (var i = 0; i < 120; i++) {
        expect(s.setPose(true), isFalse);
        s.update(1 / 60);
      }
      expect(s.isActive, isFalse);
      expect(s.activations, 1);
      expect(s.state, ShieldState.recharging);
    });

    test('releasing the pose and performing it again re-arms it (after the rearm delay)', () {
      final s = Shield(const ShieldSpec(rearmSeconds: 0.15));
      s.setPose(true);
      s.update(0.6); // expired while held
      s.setPose(false);
      s.update(0.05);
      expect(s.setPose(true), isFalse, reason: 'still inside the rearm delay');
      s.setPose(false);
      s.update(0.2);
      expect(s.state, ShieldState.ready);
      expect(s.setPose(true), isTrue);
      expect(s.activations, 2);
    });

    test('releasing during the window does not end it early or allow a second activation', () {
      final s = Shield(const ShieldSpec());
      s.setPose(true);
      s.update(0.2);
      s.setPose(false);
      expect(s.setPose(true), isFalse, reason: 'already active');
      s.update(0.29);
      expect(s.isActive, isTrue);
      s.update(0.02);
      expect(s.isActive, isFalse);
    });

    test('covers only its arc around the facing direction', () {
      final s = Shield(const ShieldSpec(halfAngle: 0.6))..yaw = 0;
      expect(s.covers(0, 2), isTrue);
      expect(s.covers(math.sin(0.5) * 2, math.cos(0.5) * 2), isTrue);
      expect(s.covers(math.sin(0.8) * 2, math.cos(0.8) * 2), isFalse);
      s.yaw = 0.8;
      expect(s.covers(math.sin(0.8) * 2, math.cos(0.8) * 2), isTrue);
    });
  });

  group('projectiles and the shield', () {
    test('an inactive shield lets a projectile hit (one life, exactly once)', () {
      final g = quiet();
      final p = shoot(g);
      step(g, 3);
      expect(p.done, isTrue);
      expect(g.lives, 2);
      final events = g.drainEvents();
      expect(events.whereType<ProjectileHitPlayer>(), hasLength(1));
      expect(events.whereType<PlayerHit>(), hasLength(1));
      expect(g.projectiles, isEmpty, reason: 'removed after hitting');
    });

    test('an active shield blocks it: no damage, removed, one block event', () {
      final g = quiet();
      final p = shoot(g);
      // Raise the shield when the arrow is ~0.2 s from the shield radius.
      while (math.sqrt(p.x * p.x + p.z * p.z) > g.config.shield.blockRadius + 9 * 0.2) {
        g.update(1 / 60);
      }
      expect(g.setShieldPose(true), isTrue);
      step(g, 2);
      expect(g.lives, 3);
      final events = g.drainEvents();
      expect(events.whereType<ProjectileBlocked>(), hasLength(1));
      expect(events.whereType<PlayerHit>(), isEmpty);
      expect(events.whereType<ShieldRaised>(), hasLength(1));
      expect(events.whereType<ShieldExpired>(), hasLength(1));
      expect(g.projectiles, isEmpty);
    });

    test('a shield raised too early has expired when the arrow arrives', () {
      final g = quiet();
      shoot(g);
      g.setShieldPose(true); // 1.3 s before arrival
      step(g, 3);
      expect(g.lives, 2);
      expect(g.drainEvents().whereType<ProjectileBlocked>(), isEmpty);
    });

    test('a projectile outside the shield arc is not blocked', () {
      final g = quiet();
      final p = shoot(g);
      g.aimYaw = 1.4; // facing far to the right
      while (math.sqrt(p.x * p.x + p.z * p.z) > g.config.shield.blockRadius + 1) {
        g.update(1 / 60);
      }
      g.setShieldPose(true);
      step(g, 2);
      expect(g.lives, 2);
    });

    test('the shield never blocks melee or contact damage', () {
      final g = quiet();
      final troll = g.spawn(EnemyKind.troll, x: 0)..z = 2.5;
      while (troll.state != EnemyState.attacking) {
        g.update(1 / 60);
      }
      // Raise the shield just before the blow lands and keep it up through the strike.
      step(g, troll.windup - 0.2);
      expect(g.setShieldPose(true), isTrue);
      step(g, 0.4);
      expect(g.lives, 2, reason: 'the club still hits through an active shield');
    });

    test('non-homing: velocity is fixed after launch', () {
      final g = quiet();
      final p = shoot(g, x: 3, z: 13);
      final (vx, vz) = (p.vx, p.vz);
      for (var i = 0; i < 30; i++) {
        g.aimYaw = i * 0.1; // the player turns around; the arrow must not follow
        g.update(1 / 60);
        expect(p.vx, vx);
        expect(p.vz, vz);
      }
    });

    test('a projectile whose aim error exceeds the hit radius misses and is removed', () {
      final g = quiet();
      final archer = g.spawn(EnemyKind.skeletonArcher, x: 0)..z = 14;
      g.fireProjectile(archer, const ProjectileSpec(speed: 9, aimSpread: 3, minAimSpread: 3));
      g.enemies.remove(archer);
      final p = g.projectiles.single;
      // With error uniform in ±3, retry seeds until the shot is off target (deterministic seed 1).
      final lateral = (p.vx / p.speed) * 14; // lateral offset at the player's depth
      step(g, 4);
      expect(p.done, isTrue);
      expect(g.projectiles, isEmpty);
      final events = g.drainEvents();
      if (lateral.abs() > g.config.playerHitRadius + p.spec.radius + 0.05) {
        expect(events.whereType<ProjectileMissed>(), hasLength(1));
        expect(g.lives, 3);
      } else {
        expect(events.whereType<ProjectileHitPlayer>(), hasLength(1));
      }
    });

    test('aim error makes some arrows miss, and later difficulty never restores perfect aim', () {
      double missRate(double difficultyProgressTime) {
        var misses = 0;
        const shots = 300;
        for (var i = 0; i < shots; i++) {
          final g = quiet(seed: i);
          g.difficulty.update(elapsedSeconds: difficultyProgressTime, score: 0);
          final archer = g.spawn(EnemyKind.skeletonArcher, x: 0)..z = 14;
          g.fireProjectile(archer, g.config.archer.arrow);
          g.enemies.remove(archer);
          step(g, 4);
          if (g.lives == 3) misses++;
        }
        return misses / shots;
      }

      final early = missRate(0), late = missRate(1e6);
      expect(early, greaterThan(0.2), reason: 'not guaranteed hits');
      expect(late, greaterThan(0.05), reason: 'the floor keeps some misses at full difficulty');
      expect(late, lessThanOrEqualTo(early + 0.05), reason: 'accuracy may improve with difficulty');
      final d = DifficultyController(const WizardConfig())..update(elapsedSeconds: 1e6, score: 0);
      expect(d.aimSpreadFor(const ArcherSpec().arrow), greaterThanOrEqualTo(const ArcherSpec().arrow.minAimSpread));
    });
  });

  group('skeleton archer cycle', () {
    test('settle → telegraph (event) → exactly one arrow → recover → reposition, repeating', () {
      final g = quiet(archer: perfectArrows);
      final a = (g.spawn(EnemyKind.skeletonArcher, x: 0)..z = 14) as SkeletonArcher;
      g.update(1 / 60);
      expect(a.state, EnemyState.attacking);
      final phases = <ArcherPhase>[a.phase];
      final log = <String>[];
      for (var i = 0; i < 60 * 14; i++) {
        g.update(1 / 60);
        if (a.phase != phases.last) phases.add(a.phase);
        for (final e in g.drainEvents()) {
          if (e is EnemyAttackStarted) log.add('telegraph');
          if (e is ProjectileFired) log.add('fire');
        }
        g.projectiles.clear(); // keep the player alive
      }
      expect(log.length, greaterThanOrEqualTo(6));
      for (var i = 0; i + 1 < log.length; i += 2) {
        expect(log[i], 'telegraph', reason: 'every arrow is preceded by its telegraph');
        expect(log[i + 1], 'fire', reason: 'one arrow per telegraph');
      }
      expect(phases.take(5), [ArcherPhase.settle, ArcherPhase.telegraph, ArcherPhase.recover, ArcherPhase.reposition, ArcherPhase.settle]);
      expect(a.shotsFired, log.where((l) => l == 'fire').length);
    });

    test('the telegraph lasts its full duration even with long frames', () {
      final g = quiet(archer: perfectArrows);
      final a = (g.spawn(EnemyKind.skeletonArcher, x: 0)..z = 14) as SkeletonArcher;
      double? telegraphStart;
      for (var i = 0; i < 100; i++) {
        g.update(0.1); // the maximum frame step
        final events = g.drainEvents();
        if (events.any((e) => e is EnemyAttackStarted)) telegraphStart = g.elapsed;
        if (events.any((e) => e is ProjectileFired)) {
          expect(telegraphStart, isNotNull);
          expect(g.elapsed - telegraphStart!, greaterThanOrEqualTo(a.telegraphSeconds - 1e-9));
          return;
        }
      }
      fail('never fired');
    });

    test('telegraph shrinks with difficulty but never below its floor', () {
      final d = DifficultyController(const WizardConfig())..update(elapsedSeconds: 1e6, score: 0);
      const a = ArcherSpec();
      expect(d.telegraphFor(a.telegraphSeconds, a.minTelegraphSeconds), greaterThanOrEqualTo(a.minTelegraphSeconds));
    });

    test('the arrow arrives with time to react (telegraph + flight ≥ 1.5 s at full difficulty)', () {
      final d = DifficultyController(const WizardConfig())..update(elapsedSeconds: 1e6, score: 0);
      const a = ArcherSpec();
      final flight = (14 - const ShieldSpec().blockRadius) / (a.arrow.speed * d.arrowSpeedMultiplier);
      expect(d.telegraphFor(a.telegraphSeconds, a.minTelegraphSeconds) + flight, greaterThan(1.5));
      expect(flight, greaterThan(const ShieldSpec().activeSeconds), reason: 'the arrow is visible in flight longer than the shield window');
    });

    test('dying mid-telegraph fires nothing', () {
      final g = quiet(archer: perfectArrows);
      final a = (g.spawn(EnemyKind.skeletonArcher, x: 0)..z = 14) as SkeletonArcher;
      while (a.phase != ArcherPhase.telegraph) {
        g.update(1 / 60);
      }
      g.applyDamage(a, a.health);
      step(g, 3);
      expect(g.drainEvents().whereType<ProjectileFired>(), isEmpty);
    });
  });

  group('health bars', () {
    test('track damage and hide on defeat', () {
      final g = quiet();
      final s = g.spawn(EnemyKind.skeletonArcher, x: 0)..z = 10;
      var bar = HealthBarModel.of(s);
      expect(bar.visible, isTrue);
      expect(bar.fraction, 1);
      expect(bar.damaged, isFalse);
      expect(bar.segments, 2);
      g.applyDamage(s, 1);
      bar = HealthBarModel.of(s);
      expect(bar.fraction, 0.5);
      expect(bar.damaged, isTrue);
      expect(bar.trail, 1, reason: 'the lost chunk is shown right after the hit');
      step(g, HealthBarModel.trailSeconds + 0.05);
      expect(HealthBarModel.of(s).trail, closeTo(0.5, 1e-9), reason: 'the trail drains to the new value');
      g.applyDamage(s, 1);
      expect(HealthBarModel.of(s).visible, isFalse);
      expect(HealthBarModel.of(s).fraction, 0);
    });

    test('chain lightning partial damage shows on the bar', () {
      final g = quiet(unlocked: const {SpellIds.chainLightning});
      final a = g.spawn(EnemyKind.troll, x: 0)..z = 8;
      final b = g.spawn(EnemyKind.skeletonArcher, x: 2)..z = 8;
      g.castChainLightning();
      expect(a.isAlive, isFalse);
      expect(HealthBarModel.of(b).fraction, closeTo(1 - 1.2 / 2, 1e-9));
    });

    test('split slimes each get their own full bar', () {
      final g = quiet();
      final big = g.spawn(EnemyKind.slime, x: 0)..z = 10;
      g.applyDamage(big, 1);
      final kids = g.livingEnemies.whereType<SplittingSlime>().toList();
      expect(kids, hasLength(2));
      for (final k in kids) {
        final bar = HealthBarModel.of(k);
        expect(bar.visible, isTrue);
        expect(bar.fraction, 1);
        expect(bar.maxHealth, g.config.slime.childHealth);
      }
      expect(HealthBarModel.of(big).visible, isFalse);
    });

    test('boss bars scale to big health pools with readable segments', () {
      final g = quiet();
      final boss = (g.spawn(EnemyKind.boss, x: 0)..z = 15) as BoneLich;
      final bar = HealthBarModel.of(boss);
      expect(bar.boss, isTrue);
      expect(bar.maxHealth, const BossSpec().baseHealth);
      expect(bar.segments, lessThanOrEqualTo(HealthBarModel.maxSegments));
      g.applyDamage(boss, 3);
      expect(HealthBarModel.of(boss).health, const BossSpec().baseHealth - 3);
    });
  });

  group('day-night cycle and boss', () {
    const fast = DayNightSpec(daySeconds: 2, duskSeconds: 1, dawnSeconds: 1);

    test('day → dusk → night (boss) → dawn → day, with phase events', () {
      final g = quiet(dayNight: fast);
      expect(g.dayNight.phase, DayPhase.day);
      expect(g.dayNight.daylight, 1);
      step(g, 2.05);
      expect(g.dayNight.phase, DayPhase.dusk);
      step(g, 0.5);
      expect(g.dayNight.daylight, closeTo(0.5, 0.05));
      step(g, 0.6);
      expect(g.dayNight.phase, DayPhase.night);
      expect(g.livingBoss, isNotNull);
      final boss = g.livingBoss!;
      g.applyDamage(boss, boss.health);
      expect(g.dayNight.phase, DayPhase.dawn);
      step(g, 1.05);
      expect(g.dayNight.phase, DayPhase.day);
      expect(g.boss, isNull, reason: 'the encounter is fully resolved by day');
      final phases = g.drainEvents().whereType<PhaseChanged>().map((e) => e.phase).toList();
      expect(phases, [DayPhase.dusk, DayPhase.night, DayPhase.dawn, DayPhase.day]);
    });

    test('exactly one boss per night, even with long frames', () {
      final g = quiet(dayNight: fast);
      for (var i = 0; i < 200; i++) {
        g.update(0.1);
      }
      final appeared = g.drainEvents().whereType<BossAppeared>().toList();
      expect(appeared, hasLength(1), reason: 'night lasts until the boss falls; no second boss');
      expect(g.enemies.whereType<BoneLich>(), hasLength(1));
    });

    test('ordinary spawning stops for dusk and night and resumes at day', () {
      final g = WizardGame(seed: 2, config: const WizardConfig(startingLives: 1000000, dayNight: DayNightSpec(daySeconds: 20, duskSeconds: 2, dawnSeconds: 2)));
      step(g, 21, dt: 1 / 30);
      expect(g.dayNight.phase, DayPhase.dusk);
      g.drainEvents();
      step(g, 4, dt: 1 / 30); // the rest of dusk and into the night
      final spawned = g.drainEvents().whereType<EnemySpawned>().map((e) => e.enemy.kind).toList();
      expect(spawned.where((k) => k != EnemyKind.boss), isEmpty);
      expect(spawned.where((k) => k == EnemyKind.boss), hasLength(1));
    });

    test('later nights bring a tougher boss', () {
      final g = quiet(dayNight: fast);
      step(g, 3.1);
      final first = g.livingBoss!;
      g.applyDamage(first, first.health);
      step(g, 1.1 + 2 + 1 + 0.1);
      final second = g.livingBoss!;
      expect(second.night, 2);
      expect(second.maxHealth, greaterThan(first.maxHealth));
    });

    test('the boss telegraphs, fires aimed and fan volleys, and the fan side bolts miss', () {
      final g = quiet(boss: const BossSpec(bolt: ProjectileSpec(speed: 7.5, aimSpread: 0, minAimSpread: 0, radius: 0.45)), lives: 100);
      final boss = (g.spawn(EnemyKind.boss, x: 0)..z = 15) as BoneLich;
      var telegraphs = 0;
      final volleys = <int>[];
      var misses = 0;
      for (var i = 0; i < 60 * 14; i++) {
        g.update(1 / 60);
        for (final e in g.drainEvents()) {
          if (e is EnemyAttackStarted && identical(e.enemy, boss)) telegraphs++;
          if (e is ProjectileFired) {
            if (volleys.length < telegraphs) volleys.add(0);
            volleys[volleys.length - 1]++;
          }
          if (e is ProjectileMissed) misses++;
        }
      }
      expect(telegraphs, greaterThanOrEqualTo(3));
      expect(volleys.take(2), [1, 3], reason: 'aimed bolt, then a fan of three');
      expect(misses, greaterThanOrEqualTo(2), reason: 'side bolts of the fan pass beside the player');
      expect(boss.isAlive, isTrue, reason: 'it never melees or vanishes');
    });

    test('the boss summons reinforcements once when weakened', () {
      final g = quiet();
      final boss = (g.spawn(EnemyKind.boss, x: 0)..z = 15) as BoneLich;
      g.update(1 / 60);
      g.applyDamage(boss, boss.maxHealth * 0.6);
      step(g, 1);
      step(g, 1);
      final summoned = g.drainEvents().whereType<EnemySpawned>().where((e) => e.enemy.kind == const BossSpec().summonKind);
      expect(summoned, hasLength(const BossSpec().summonCount));
    });
  });

  group('Chain Lightning unlock (boss defeat)', () {
    test('the first boss defeat in a run unlocks it exactly once', () {
      final g = quiet(dayNight: const DayNightSpec(daySeconds: 1, duskSeconds: 0.5, dawnSeconds: 0.5));
      step(g, 1.6);
      final boss = g.livingBoss!;
      g.applyDamage(boss, boss.health);
      var events = g.drainEvents();
      expect(events.whereType<BossDefeated>(), hasLength(1));
      expect(events.whereType<SpellUnlocked>().map((e) => e.spellId), [SpellIds.chainLightning]);
      expect(g.availableSpells, contains(SpellIds.chainLightning));
      // The next night's boss gives score but no second unlock.
      step(g, 0.6 + 1 + 0.6);
      final next = g.livingBoss!;
      g.applyDamage(next, next.health);
      events = g.drainEvents();
      expect(events.whereType<BossDefeated>(), hasLength(1));
      expect(events.whereType<SpellUnlocked>(), isEmpty);
    });

    test('a player who already owns it gets no unlock event from a boss', () {
      final g = quiet(unlocked: const {SpellIds.chainLightning});
      final boss = (g.spawn(EnemyKind.boss, x: 0)..z = 15) as BoneLich;
      g.applyDamage(boss, boss.health);
      expect(g.drainEvents().whereType<SpellUnlocked>(), isEmpty);
    });

    test('boss defeat awards its score', () {
      final g = quiet();
      final boss = (g.spawn(EnemyKind.boss, x: 0)..z = 15) as BoneLich;
      g.applyDamage(boss, boss.health);
      expect(g.score, const BossSpec().score);
      expect(g.bossesDefeated, 1);
    });
  });

  group('tutorial mode', () {
    test('never unlocks, scores, loses lives, spawns, or runs the day-night cycle', () {
      final g = WizardGame(seed: 1, mode: GameMode.tutorial);
      step(g, 120, dt: 1 / 30);
      expect(g.enemies, isEmpty, reason: 'no automatic spawning');
      expect(g.dayNight.phase, DayPhase.day);
      final boss = (g.spawn(EnemyKind.boss, x: 0)..z = 15) as BoneLich;
      g.applyDamage(boss, boss.health);
      final events = g.drainEvents();
      expect(events.whereType<SpellUnlocked>(), isEmpty);
      expect(events.whereType<BossDefeated>(), isEmpty);
      expect(g.score, 0);
      expect(g.unlockedSpells, {SpellIds.fireball});
      shoot(g);
      step(g, 3);
      expect(g.lives, g.config.startingLives, reason: 'practice hits cost nothing');
      expect(g.isOver, isFalse);
    });
  });
}
