import 'dart:math' as math;

import 'aim.dart';
import 'day_night.dart';
import 'difficulty.dart';
import 'enemies.dart';
import 'shield.dart';
import 'wizard_config.dart';

/// Things that happened during an update, for effects and sound. Drained by the view. Events
/// describe outcomes that ALREADY happened in the simulation; nothing in the view or audio layer
/// applies damage.
sealed class GameEvent {
  const GameEvent();
}

class FireballLaunched extends GameEvent {
  const FireballLaunched(this.fireball);
  final Fireball fireball;
}

/// A fireball reached its target (or the end of its range with no target).
class FireballImpact extends GameEvent {
  const FireballImpact({required this.x, required this.z, required this.elevation, this.enemy, required this.defeated});
  final double x;
  final double z;
  final double elevation;
  final Enemy? enemy;
  final bool defeated;
}

/// [points] is 0 for slime family members other than the last one (see [SlimeSpec]).
class EnemyDefeated extends GameEvent {
  const EnemyDefeated(this.enemy, this.points);
  final Enemy enemy;
  final int points;
}

class SlimeSplit extends GameEvent {
  const SlimeSplit(this.parent, this.children);
  final SplittingSlime parent;
  final List<SplittingSlime> children;
}

class PlayerHit extends GameEvent {
  const PlayerHit({required this.source, required this.livesLeft, required this.lifeLost, this.x = 0, this.z = 1});
  final EnemyKind source;
  final int livesLeft;

  /// False when the hit landed during the post-hit grace period.
  final bool lifeLost;
  final double x;
  final double z;
}

class ProjectileFired extends GameEvent {
  const ProjectileFired(this.projectile, this.shooter);
  final Projectile projectile;
  final Enemy shooter;
}

/// The shield stopped a projectile at ([x], [z]).
class ProjectileBlocked extends GameEvent {
  const ProjectileBlocked(this.projectile, {required this.x, required this.z});
  final Projectile projectile;
  final double x;
  final double z;
}

/// A projectile reached the player (a [PlayerHit] follows in the same step).
class ProjectileHitPlayer extends GameEvent {
  const ProjectileHitPlayer(this.projectile);
  final Projectile projectile;
}

/// A projectile passed the player without hitting and was removed.
class ProjectileMissed extends GameEvent {
  const ProjectileMissed(this.projectile);
  final Projectile projectile;
}

class ShieldRaised extends GameEvent {
  const ShieldRaised(this.yaw);
  final double yaw;
}

class ShieldExpired extends GameEvent {
  const ShieldExpired();
}

/// The day-night cycle entered [phase]. [night] is the number of nights so far.
class PhaseChanged extends GameEvent {
  const PhaseChanged(this.phase, this.night);
  final DayPhase phase;
  final int night;
}

class BossAppeared extends GameEvent {
  const BossAppeared(this.boss);
  final BoneLich boss;
}

/// A night boss was defeated by the player (a run reward; never emitted in tutorial mode).
class BossDefeated extends GameEvent {
  const BossDefeated(this.boss, this.points);
  final BoneLich boss;
  final int points;
}

class EnemySpawned extends GameEvent {
  const EnemySpawned(this.enemy);
  final Enemy enemy;
}

/// An enemy began its telegraphed attack (melee wind-up or bow draw).
class EnemyAttackStarted extends GameEvent {
  const EnemyAttackStarted(this.enemy);
  final Enemy enemy;
}

class ChainHit {
  const ChainHit({required this.enemy, required this.x, required this.z, required this.elevation, required this.damage, required this.defeated, required this.split});
  final Enemy enemy;
  final double x;
  final double z;
  final double elevation;
  final double damage;
  final bool defeated;
  final bool split;
}

/// One Chain Lightning cast, already resolved. [hits] is ordered primary → last chain link.
/// When [hits] is empty the bolt ended at ([endX], [endZ]) without hitting anything.
class ChainLightningCast extends GameEvent {
  const ChainLightningCast({required this.aimYaw, required this.hits, required this.endX, required this.endZ});
  final double aimYaw;
  final List<ChainHit> hits;
  final double endX;
  final double endZ;
}

class SpellUnlocked extends GameEvent {
  const SpellUnlocked(this.spellId);
  final String spellId;
}

class SpellSelected extends GameEvent {
  const SpellSelected(this.spellId);
  final String spellId;
}

class GameEnded extends GameEvent {
  const GameEnded(this.finalScore);
  final int finalScore;
}

/// A cast fireball travelling from the player's hand to [target] (or straight ahead if null).
class Fireball {
  Fireball({required this.target, required this.fromX, required this.fromZ, required this.toX, required this.toZ, required this.toElevation, required this.duration});

  final Enemy? target;
  final double fromX;
  final double fromZ;
  double toX;
  double toZ;
  double toElevation;
  final double duration;
  double time = 0;
  bool done = false;

  double get progress => (time / duration).clamp(0.0, 1.0);
  double get x => fromX + (toX - fromX) * progress;
  double get z => fromZ + (toZ - fromZ) * progress;
  double get elevation => toElevation * progress + math.sin(progress * math.pi) * 0.6;
}

enum ProjectileKind { arrow, bossBolt }

/// An enemy projectile. Its velocity is fixed at launch (aimed once, at release): it never
/// steers toward the player afterwards.
class Projectile {
  Projectile({required this.kind, required this.spec, required this.source, required this.x, required this.z, required this.vx, required this.vz, required this.startElevation})
      : fromX = x,
        fromZ = z;

  final ProjectileKind kind;
  final ProjectileSpec spec;
  final EnemyKind source;
  final double fromX;
  final double fromZ;
  double x;
  double z;

  /// World units per second (constant).
  final double vx;
  final double vz;

  /// Launch height (rendering only; it descends toward chest height at the player).
  final double startElevation;
  double traveled = 0;
  bool done = false;

  double get speed => math.sqrt(vx * vx + vz * vz);

  /// Rendering height: from the launch height down to chest height near the player.
  double get elevation {
    final total = math.sqrt(fromX * fromX + fromZ * fromZ);
    final t = total <= 1e-9 ? 1.0 : (traveled / total).clamp(0.0, 1.0);
    return startElevation + (1.2 - startElevation) * t;
  }
}

/// Outcome of a cast, for feedback.
enum CastResult { launched, noTargetInRange, onCooldown, locked, gameOver }

/// [run]: a real run (spawning, day-night, rewards). [tutorial]: a scripted practice sandbox: no
/// automatic spawning, no day-night cycle, no lives lost, no score and never any permanent reward.
enum GameMode { run, tutorial }

class _SlimeFamily {
  int alive = 1;
  bool broken = false;
  bool awarded = false;
}

/// The complete wizard-shooter simulation. Pure Dart: no Flutter, no camera, no wall clock
/// (time only advances through [update]), seeded randomness. Rendering, input, audio and
/// persistence live elsewhere.
class WizardGame implements EnemyContext {
  WizardGame({this.config = const WizardConfig(), int? seed, Set<String> unlockedSpells = const {}, this.mode = GameMode.run})
      : random = math.Random(seed),
        unlockedSpells = {SpellIds.fireball, ...unlockedSpells},
        shield = Shield(config.shield),
        dayNight = DayNightCycle(mode == GameMode.run ? config.dayNight : const DayNightSpec(enabled: false)) {
    lives = config.startingLives;
    difficulty = DifficultyController(config);
    _spawnTimer = config.difficulty.spawnIntervalStart - config.difficulty.firstSpawnDelay;
  }

  final GameMode mode;

  /// The base-kit shield (always available, independent of the selected spell).
  final Shield shield;
  final DayNightCycle dayNight;

  /// The current night's boss, from its appearance until the next day begins (so a new boss can
  /// never start while the previous encounter is still resolving).
  BoneLich? boss;
  int bossesDefeated = 0;

  @override
  final WizardConfig config;
  @override
  final math.Random random;
  @override
  late final DifficultyController difficulty;

  final List<Enemy> enemies = [];
  final List<Fireball> fireballs = [];
  final List<Projectile> projectiles = [];
  final List<GameEvent> _events = [];
  final Map<int, _SlimeFamily> _families = {};

  late int lives;
  int score = 0;
  int enemiesDefeated = 0;
  int castsMade = 0;
  double elapsed = 0;
  bool isOver = false;
  double _spawnTimer = 0;
  double _graceTimer = 0;
  int _nextId = 1;

  /// Spells usable this run (Fireball always; others once unlocked).
  final Set<String> unlockedSpells;
  String selectedSpell = SpellIds.fireball;
  final Map<String, double> _cooldownUntil = {};

  /// World aim direction (radians, 0 = straight ahead, + = right), set by the screen from the
  /// staff/hand and head pose each frame. Used by directional spells and as the shield's facing.
  double aimYaw = 0;

  /// Seconds since the player was last hit (for damage flash), large if never.
  double timeSinceHit = 999;

  // ---- Difficulty (delegated to the central controller) ----

  double get difficultyLevel => difficulty.progress;
  bool get rewardsEnabled => mode == GameMode.run;
  double get spawnInterval => difficulty.spawnInterval;
  int get maxEnemies => difficulty.maxEnemies;
  double get speedMultiplier => difficulty.speedMultiplier;
  double spawnWeight(EnemyKind kind) => difficulty.spawnWeight(kind);

  List<Enemy> get livingEnemies => enemies.where((e) => e.isAlive).toList();
  int get activeSlimes => enemies.where((e) => e.isAlive && e is SplittingSlime).length;

  /// The boss while it is alive (for the boss health bar).
  BoneLich? get livingBoss => boss != null && boss!.isAlive ? boss : null;

  /// Returns and clears the events produced since the last call.
  List<GameEvent> drainEvents() {
    final out = List<GameEvent>.of(_events);
    _events.clear();
    return out;
  }

  // ---- Simulation ----

  /// Advances the world by [dt] seconds. Does nothing once the game is over.
  void update(double dt) {
    if (isOver) return;
    dt = dt.clamp(0.0, 0.1); // a long hitch must not teleport enemies past the player
    elapsed += dt;
    timeSinceHit += dt;
    if (_graceTimer > 0) _graceTimer -= dt;
    difficulty.update(elapsedSeconds: elapsed, score: score);
    shield.yaw = aimYaw;
    if (shield.update(dt)) _events.add(const ShieldExpired());

    final entered = dayNight.update(dt);
    if (entered != null) _onPhase(entered);
    if (mode == GameMode.run && dayNight.ordinarySpawning) _updateSpawning(dt);
    for (final e in List.of(enemies)) {
      e.update(dt, this);
      if (isOver) return;
    }
    _updateFireballs(dt);
    _updateProjectiles(dt);
    if (isOver) return;

    // Cleanup: defeated enemies linger briefly for their death animation.
    enemies.removeWhere((e) =>
        e.state == EnemyState.resolved || e.state == EnemyState.split || (e.state == EnemyState.defeated && e.stateTime > 0.6));
    fireballs.removeWhere((f) => f.done);
    projectiles.removeWhere((a) => a.done);
  }

  void _onPhase(DayPhase phase) {
    _events.add(PhaseChanged(phase, dayNight.nights));
    switch (phase) {
      case DayPhase.night when boss == null:
        _spawnBoss();
      case DayPhase.day:
        boss = null; // the encounter is fully resolved
      default:
        break;
    }
  }

  void _spawnBoss() {
    final b = config.boss;
    final health = b.baseHealth * (1 + b.healthGrowthPerCycle * math.max(0, dayNight.nights - 1));
    final lich = BoneLich(id: _nextId++, spec: config.spec(EnemyKind.boss), x: 0, z: config.spawnDistance, boss: b, health: health, night: dayNight.nights);
    boss = lich;
    enemies.add(lich);
    _events.add(EnemySpawned(lich));
    _events.add(BossAppeared(lich));
  }

  // ---- Shield ----

  /// Reports the shield pose (from the shield gesture recognizer). Returns true when this
  /// raised the shield. Holding the pose never retriggers or extends it.
  bool setShieldPose(bool held) {
    if (isOver) return false;
    shield.yaw = aimYaw;
    final raised = shield.setPose(held);
    if (raised) _events.add(ShieldRaised(shield.yaw));
    return raised;
  }

  void _updateSpawning(double dt) {
    _spawnTimer += dt;
    if (_spawnTimer < spawnInterval) return;
    if (livingEnemies.length >= maxEnemies) return; // wait for room; keep the timer full
    _spawnTimer = 0;
    var kind = _pickKind();
    assert(kind != EnemyKind.boss);
    // Respect the slime cap at spawn time too (a big slime can become several enemies).
    if (kind == EnemyKind.slime && activeSlimes + config.slime.childrenPerSplit > config.slime.maxActiveSlimes) kind = EnemyKind.troll;
    spawn(kind);
  }

  EnemyKind _pickKind() {
    const kinds = EnemyKind.spawnable;
    final weights = kinds.map(spawnWeight).toList();
    var r = random.nextDouble() * weights.reduce((a, b) => a + b);
    for (var i = 0; i < kinds.length; i++) {
      r -= weights[i];
      if (r <= 0) return kinds[i];
    }
    return kinds.last;
  }

  /// Spawns an enemy of [kind] in the distance (public for tests and future scripted waves).
  Enemy spawn(EnemyKind kind, {double? x}) {
    final id = _nextId++;
    final enemy = createEnemy(
      kind,
      id: id,
      config: config,
      x: x ?? (random.nextDouble() * 2 - 1) * config.spawnHalfWidth,
      random: random,
      familyId: id,
    );
    if (enemy is SplittingSlime) _families[enemy.familyId] = _SlimeFamily();
    enemies.add(enemy);
    _events.add(EnemySpawned(enemy));
    return enemy;
  }

  // ---- Damage pipeline (the ONLY place enemies take damage, split, die and award score) ----

  /// Applies [amount] damage to [enemy] once. Returns what happened.
  ({bool defeated, bool split}) applyDamage(Enemy enemy, double amount) {
    if (!enemy.isAlive || amount <= 0) return (defeated: false, split: false);
    if (enemy is SplittingSlime && enemy.canSplit(config.slime)) {
      final room = config.slime.maxActiveSlimes - activeSlimes + 1; // +1: the parent goes away
      if (room >= config.slime.childrenPerSplit) {
        _split(enemy);
        return (defeated: false, split: true);
      }
      // At the cap: no split, the slime simply dies.
      enemy.enter(EnemyState.defeated);
      _onDefeated(enemy);
      return (defeated: true, split: false);
    }
    final defeated = enemy.takeDamage(amount);
    if (defeated) _onDefeated(enemy);
    return (defeated: defeated, split: false);
  }

  void _split(SplittingSlime parent) {
    final s = config.slime;
    parent.enter(EnemyState.split);
    final children = <SplittingSlime>[];
    final d = parent.distance;
    final back = d <= 1e-9 ? 1.0 : (d + s.knockback) / d;
    for (var i = 0; i < s.childrenPerSplit; i++) {
      final offset = (i - (s.childrenPerSplit - 1) / 2) * s.childSpread;
      final child = SplittingSlime(
        id: _nextId++,
        spec: parent.spec,
        x: parent.x * back + offset,
        z: parent.z * back,
        familyId: parent.familyId,
        generation: parent.generation + 1,
        slime: s,
      );
      children.add(child);
      enemies.add(child);
    }
    final family = _families[parent.familyId];
    if (family != null) family.alive += children.length - 1;
    _events.add(SlimeSplit(parent, children));
  }

  void _onDefeated(Enemy enemy) {
    if (enemy.scored) return;
    enemy.scored = true;
    enemiesDefeated++;
    var points = 0;
    if (enemy is BoneLich) {
      points = config.boss.score;
      bossesDefeated++;
      if (dayNight.bossDefeated()) _onPhase(DayPhase.dawn);
      if (rewardsEnabled) {
        _events.add(BossDefeated(enemy, points));
        // The permanent Chain Lightning unlock: the first boss defeat in a real run.
        if (unlockedSpells.add(SpellIds.chainLightning)) _events.add(const SpellUnlocked(SpellIds.chainLightning));
      }
    } else if (enemy is SplittingSlime) {
      final family = _families[enemy.familyId];
      if (family != null) {
        family.alive--;
        if (family.alive <= 0 && !family.broken && !family.awarded) {
          family.awarded = true;
          points = enemy.spec.score;
        }
      }
    } else {
      points = enemy.spec.score;
    }
    if (points > 0) _addScore(points);
    _events.add(EnemyDefeated(enemy, points));
  }

  /// Score never unlocks anything (Chain Lightning comes from the first boss defeat). Tutorial
  /// practice never scores.
  void _addScore(int points) {
    if (mode == GameMode.tutorial) return;
    score += points;
  }

  // ---- Spells ----

  /// Spells available this run, in cycling order.
  List<String> get availableSpells => SpellIds.all.where(unlockedSpells.contains).toList();

  bool selectSpell(String id) {
    if (!unlockedSpells.contains(id) || selectedSpell == id) return false;
    selectedSpell = id;
    _events.add(SpellSelected(id));
    return true;
  }

  /// Switches to the next unlocked spell. Returns false if only one spell is available.
  bool cycleSpell() {
    final spells = availableSpells;
    if (spells.length < 2) return false;
    return selectSpell(spells[(spells.indexOf(selectedSpell) + 1) % spells.length]);
  }

  /// 0..1 remaining cooldown of [id].
  double cooldownRemaining(String id) {
    final until = _cooldownUntil[id];
    if (until == null || until <= elapsed) return 0;
    final total = id == SpellIds.chainLightning ? config.chainLightning.cooldownSeconds : 1;
    return ((until - elapsed) / total).clamp(0.0, 1.0);
  }

  /// Casts the selected spell (the cast gesture calls this).
  CastResult cast() => switch (selectedSpell) {
        SpellIds.chainLightning => castChainLightning(),
        _ => castFireball(),
      };

  /// Living enemies a fireball can target: within range and not already doomed by fireballs in
  /// flight. Nearest first. (Fireball targeting is unchanged from v2: it ignores the aim.)
  List<Enemy> targetableEnemies() {
    final list = enemies.where((e) => e.isAlive && e.distance <= config.fireballRange && e.incomingDamage < e.health).toList()
      ..sort((a, b) => a.distance.compareTo(b.distance));
    return list;
  }

  /// Casts one fireball at the nearest eligible enemy. Without an eligible enemy the fireball
  /// flies to the edge of its range and fizzles (no damage, no points).
  CastResult castFireball() {
    if (isOver) return CastResult.gameOver;
    castsMade++;
    final targets = targetableEnemies();
    final target = targets.isEmpty ? null : targets.first;
    const fromX = -0.6, fromZ = 0.6; // the player's left hand
    final toX = target?.x ?? math.sin(aimYaw) * config.fireballRange;
    final toZ = target?.z ?? math.cos(aimYaw) * config.fireballRange;
    final dist = math.sqrt(math.pow(toX - fromX, 2) + math.pow(toZ - fromZ, 2));
    final fireball = Fireball(
      target: target,
      fromX: fromX,
      fromZ: fromZ,
      toX: toX,
      toZ: toZ,
      toElevation: target == null ? 0.8 : target.height * 0.5 + target.elevation,
      duration: math.max(0.12, dist / config.fireballSpeed),
    );
    target?.incomingDamage += config.fireballDamage;
    fireballs.add(fireball);
    _events.add(FireballLaunched(fireball));
    return target == null ? CastResult.noTargetInRange : CastResult.launched;
  }

  void _updateFireballs(double dt) {
    for (final f in fireballs) {
      if (f.done) continue;
      f.time += dt;
      final target = f.target;
      if (target != null && target.isAlive) {
        // Home in on the moving target so the trajectory always ends on it.
        f.toX = target.x;
        f.toZ = target.z;
        f.toElevation = target.height * 0.5 + target.elevation;
      }
      if (f.time < f.duration) continue;
      f.done = true; // resolved exactly once
      if (target == null) {
        _events.add(FireballImpact(x: f.toX, z: f.toZ, elevation: f.toElevation, defeated: false));
        continue;
      }
      target.incomingDamage = math.max(0, target.incomingDamage - config.fireballDamage);
      if (!target.isAlive) {
        // It already struck the player (or died/split) before the fireball arrived: fizzle.
        _events.add(FireballImpact(x: f.toX, z: f.toZ, elevation: f.toElevation, defeated: false));
        continue;
      }
      final outcome = applyDamage(target, config.fireballDamage);
      _events.add(FireballImpact(x: target.x, z: target.z, elevation: f.toElevation, enemy: target, defeated: outcome.defeated));
    }
  }

  /// Directional spell: hits the first enemy on the aim ray, then arcs to nearby enemies with
  /// decreasing damage. Damage is applied immediately and exactly once per enemy per cast; the
  /// returned [ChainLightningCast] event only describes it for effects.
  CastResult castChainLightning() {
    if (isOver) return CastResult.gameOver;
    if (!unlockedSpells.contains(SpellIds.chainLightning)) return CastResult.locked;
    if (cooldownRemaining(SpellIds.chainLightning) > 0) return CastResult.onCooldown;
    final spec = config.chainLightning;
    castsMade++;
    _cooldownUntil[SpellIds.chainLightning] = elapsed + spec.cooldownSeconds;

    // Snapshot: enemies spawned during this cast (slime children) can't be chained to.
    final eligible = enemies.where((e) => e.isAlive).toList();
    final primary = chainLightningTarget();
    if (primary == null) {
      _events.add(ChainLightningCast(aimYaw: aimYaw, hits: const [], endX: math.sin(aimYaw) * spec.range, endZ: math.cos(aimYaw) * spec.range));
      return CastResult.noTargetInRange;
    }

    final hits = <ChainHit>[];
    final visited = <Enemy>{};
    var current = primary;
    var damage = spec.primaryDamage;
    for (var i = 0; i < spec.maxTargets && i <= spec.maxJumps; i++) {
      visited.add(current);
      final (x, z, elevation) = (current.x, current.z, current.height * 0.5 + current.elevation);
      final outcome = applyDamage(current, damage);
      hits.add(ChainHit(enemy: current, x: x, z: z, elevation: elevation, damage: damage, defeated: outcome.defeated, split: outcome.split));
      // Next link: nearest not-yet-hit eligible enemy within the chain radius of this one.
      Enemy? next;
      var nearest = double.infinity;
      for (final e in eligible) {
        if (visited.contains(e) || !e.isAlive) continue;
        final d = math.sqrt(math.pow(e.x - x, 2) + math.pow(e.z - z, 2));
        if (d <= spec.chainRadius && d < nearest) {
          nearest = d;
          next = e;
        }
      }
      if (next == null) break;
      current = next;
      damage *= spec.damageFalloff;
    }
    _events.add(ChainLightningCast(aimYaw: aimYaw, hits: hits, endX: primary.x, endZ: primary.z));
    return CastResult.launched;
  }

  /// The enemy Chain Lightning would hit first along the current aim (also used for the aim
  /// preview, so what the player sees is exactly what the cast will do).
  Enemy? chainLightningTarget() {
    final spec = config.chainLightning;
    Enemy? primary;
    var best = double.infinity;
    for (final e in enemies) {
      if (!e.isAlive) continue;
      final along = distanceAlongAim(aimYaw, e.x, e.z, halfWidth: spec.beamHalfWidth, range: spec.range);
      if (along != null && along < best) {
        best = along;
        primary = e;
      }
    }
    return primary;
  }

  /// Moves projectiles along their fixed straight paths. Per step, on the segment travelled:
  /// 1. an active shield blocks a blockable projectile that is within [ShieldSpec.blockRadius]
  ///    inside the shield's arc (checked first, so a block always wins over a hit);
  /// 2. otherwise it hits the player if the segment passes within the hit radius;
  /// 3. otherwise it is removed once it has passed the player or flown its maximum range.
  /// Each projectile resolves exactly once.
  void _updateProjectiles(double dt) {
    for (final p in projectiles) {
      if (p.done) continue;
      final (x0, z0) = (p.x, p.z);
      final (x1, z1) = (x0 + p.vx * dt, z0 + p.vz * dt);
      final (closest, cx, cz) = _closestToOrigin(x0, z0, x1, z1);
      final s = config.shield;
      if (shield.isActive && p.spec.blockable && closest <= s.blockRadius) {
        final (bx, bz) = _entryPoint(x0, z0, x1, z1, s.blockRadius) ?? (cx, cz);
        if (shield.covers(bx, bz)) {
          p
            ..done = true
            ..x = bx
            ..z = bz;
          _events.add(ProjectileBlocked(p, x: bx, z: bz));
          continue;
        }
      }
      if (closest <= config.playerHitRadius + p.spec.radius) {
        p
          ..done = true
          ..x = cx
          ..z = cz;
        _events.add(ProjectileHitPlayer(p));
        _damagePlayer(p.source, cx, cz);
        if (isOver) return;
        continue;
      }
      p
        ..x = x1
        ..z = z1
        ..traveled += p.speed * dt;
      final movingAway = x1 * p.vx + z1 * p.vz > 0;
      if (p.traveled >= p.spec.maxRange || (movingAway && math.sqrt(x1 * x1 + z1 * z1) > config.shield.blockRadius + 1)) {
        p.done = true;
        _events.add(ProjectileMissed(p));
      }
    }
  }

  /// Closest point to the player (origin) on the segment a → b: (distance, x, z).
  static (double, double, double) _closestToOrigin(double ax, double az, double bx, double bz) {
    final dx = bx - ax, dz = bz - az;
    final len2 = dx * dx + dz * dz;
    final t = len2 <= 1e-12 ? 0.0 : (-(ax * dx + az * dz) / len2).clamp(0.0, 1.0);
    final x = ax + dx * t, z = az + dz * t;
    return (math.sqrt(x * x + z * z), x, z);
  }

  /// Where the segment a → b first comes within [radius] of the origin (a itself if already
  /// inside), or null if it never does.
  static (double, double)? _entryPoint(double ax, double az, double bx, double bz, double radius) {
    if (ax * ax + az * az <= radius * radius) return (ax, az);
    final dx = bx - ax, dz = bz - az;
    final a = dx * dx + dz * dz;
    final b = 2 * (ax * dx + az * dz);
    final c = ax * ax + az * az - radius * radius;
    final disc = b * b - 4 * a * c;
    if (a <= 1e-12 || disc < 0) return null;
    final t = (-b - math.sqrt(disc)) / (2 * a);
    if (t < 0 || t > 1) return null;
    return (ax + dx * t, az + dz * t);
  }

  // ---- EnemyContext ----

  @override
  void meleeHit(Enemy attacker) {
    if (attacker is SplittingSlime) {
      final family = _families[attacker.familyId];
      if (family != null) {
        family.broken = true; // a member reached the player: the family awards nothing
        family.alive--;
      }
    }
    _damagePlayer(attacker.kind, attacker.x, attacker.z);
  }

  /// Aims ONCE, now: at the player's position (the origin) plus a random lateral error of up to
  /// ± the difficulty-scaled aim spread, then rotated by [yawOffset]. The velocity is fixed.
  @override
  void fireProjectile(Enemy shooter, ProjectileSpec spec, {double yawOffset = 0, double speedMultiplier = 1}) {
    final d = shooter.distance;
    if (d <= 1e-9) return;
    final (ux, uz) = (-shooter.x / d, -shooter.z / d); // toward the player
    final spread = difficulty.aimSpreadFor(spec);
    final error = (random.nextDouble() * 2 - 1) * spread;
    // Target point: the player plus the error, perpendicular to the line of fire.
    final (tx, tz) = (uz * error, -ux * error);
    var (dx, dz) = (tx - shooter.x, tz - shooter.z);
    final len = math.sqrt(dx * dx + dz * dz);
    (dx, dz) = (dx / len, dz / len);
    if (yawOffset != 0) {
      final (c, s) = (math.cos(yawOffset), math.sin(yawOffset));
      (dx, dz) = (dx * c + dz * s, -dx * s + dz * c);
    }
    final speed = spec.speed * speedMultiplier;
    final projectile = Projectile(
      kind: shooter is BoneLich ? ProjectileKind.bossBolt : ProjectileKind.arrow,
      spec: spec,
      source: shooter.kind,
      x: shooter.x,
      z: shooter.z,
      vx: dx * speed,
      vz: dz * speed,
      startElevation: shooter.height * 0.65 + shooter.elevation,
    );
    projectiles.add(projectile);
    _events.add(ProjectileFired(projectile, shooter));
  }

  @override
  void attackStarted(Enemy enemy) => _events.add(EnemyAttackStarted(enemy));

  @override
  void summon(EnemyKind kind, int count, Enemy near) {
    for (var i = 0; i < count; i++) {
      final offset = (i - (count - 1) / 2) * 2.4;
      final e = spawn(kind, x: (near.x + offset).clamp(-config.spawnHalfWidth, config.spawnHalfWidth));
      e.z = near.z + 1.5;
    }
  }

  /// The only place the player takes damage (melee strikes and projectile hits). The shield is
  /// not consulted here: it can only stop projectiles before they arrive.
  void _damagePlayer(EnemyKind source, double x, double z) {
    if (isOver) return;
    final lifeLost = mode == GameMode.run && _graceTimer <= 0;
    if (lifeLost) {
      lives = math.max(0, lives - 1);
      _graceTimer = config.hitGraceSeconds;
      timeSinceHit = 0;
    }
    _events.add(PlayerHit(source: source, livesLeft: lives, lifeLost: lifeLost, x: x, z: z));
    if (lives == 0) {
      isOver = true;
      _events.add(GameEnded(score));
    }
  }
}
