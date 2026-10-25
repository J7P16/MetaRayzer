import 'dart:math' as math;

import 'aim.dart';
import 'difficulty.dart';
import 'enemies.dart';
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

class ArrowFired extends GameEvent {
  const ArrowFired(this.arrow, this.shooter);
  final Arrow arrow;
  final Enemy shooter;
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

/// An enemy projectile flying toward the player.
class Arrow {
  Arrow({required this.x, required this.z, required this.speed});
  double x;
  double z;
  final double speed;
  bool done = false;
}

/// Outcome of a cast, for feedback.
enum CastResult { launched, noTargetInRange, onCooldown, locked, gameOver }

class _SlimeFamily {
  int alive = 1;
  bool broken = false;
  bool awarded = false;
}

/// The complete wizard-shooter simulation. Pure Dart: no Flutter, no camera, no wall clock
/// (time only advances through [update]), seeded randomness. Rendering, input, audio and
/// persistence live elsewhere.
class WizardGame implements EnemyContext {
  WizardGame({this.config = const WizardConfig(), int? seed, Set<String> unlockedSpells = const {}})
      : random = math.Random(seed),
        unlockedSpells = {SpellIds.fireball, ...unlockedSpells} {
    lives = config.startingLives;
    difficulty = DifficultyController(config);
    _spawnTimer = config.difficulty.spawnIntervalStart - config.difficulty.firstSpawnDelay;
  }

  @override
  final WizardConfig config;
  @override
  final math.Random random;
  @override
  late final DifficultyController difficulty;

  final List<Enemy> enemies = [];
  final List<Fireball> fireballs = [];
  final List<Arrow> arrows = [];
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
  /// staff/hand and head pose each frame. Used by directional spells.
  double aimYaw = 0;

  /// Seconds since the player was last hit (for damage flash), large if never.
  double timeSinceHit = 999;

  // ---- Difficulty (delegated to the central controller) ----

  double get difficultyLevel => difficulty.progress;
  double get spawnInterval => difficulty.spawnInterval;
  int get maxEnemies => difficulty.maxEnemies;
  double get speedMultiplier => difficulty.speedMultiplier;
  double spawnWeight(EnemyKind kind) => difficulty.spawnWeight(kind);

  List<Enemy> get livingEnemies => enemies.where((e) => e.isAlive).toList();
  int get activeSlimes => enemies.where((e) => e.isAlive && e is SplittingSlime).length;

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

    _updateSpawning(dt);
    for (final e in List.of(enemies)) {
      e.update(dt, this);
      if (isOver) return;
    }
    _updateFireballs(dt);
    _updateArrows(dt);
    if (isOver) return;

    // Cleanup: defeated enemies linger briefly for their death animation.
    enemies.removeWhere((e) =>
        e.state == EnemyState.resolved || e.state == EnemyState.split || (e.state == EnemyState.defeated && e.stateTime > 0.6));
    fireballs.removeWhere((f) => f.done);
    arrows.removeWhere((a) => a.done);
  }

  void _updateSpawning(double dt) {
    _spawnTimer += dt;
    if (_spawnTimer < spawnInterval) return;
    if (livingEnemies.length >= maxEnemies) return; // wait for room; keep the timer full
    _spawnTimer = 0;
    var kind = _pickKind();
    // Respect the slime cap at spawn time too (a big slime can become several enemies).
    if (kind == EnemyKind.slime && activeSlimes + config.slime.childrenPerSplit > config.slime.maxActiveSlimes) kind = EnemyKind.troll;
    spawn(kind);
  }

  EnemyKind _pickKind() {
    final kinds = EnemyKind.values;
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
    if (enemy is SplittingSlime) {
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

  void _addScore(int points) {
    score += points;
    final lightning = config.chainLightning;
    if (score >= lightning.unlockScore && unlockedSpells.add(SpellIds.chainLightning)) {
      _events.add(const SpellUnlocked(SpellIds.chainLightning));
    }
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

  void _updateArrows(double dt) {
    for (final a in arrows) {
      if (a.done) continue;
      final d = math.sqrt(a.x * a.x + a.z * a.z);
      final step = a.speed * dt;
      if (d <= step + 0.4) {
        a.done = true;
        _damagePlayer(EnemyKind.skeletonArcher, a.x, a.z);
        if (isOver) return;
        continue;
      }
      a.x -= a.x / d * step;
      a.z -= a.z / d * step;
    }
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

  @override
  void fireArrow(Enemy shooter) {
    final arrow = Arrow(x: shooter.x, z: shooter.z, speed: config.archer.arrowSpeed * difficulty.arrowSpeedMultiplier);
    arrows.add(arrow);
    _events.add(ArrowFired(arrow, shooter));
  }

  @override
  void attackStarted(Enemy enemy) => _events.add(EnemyAttackStarted(enemy));

  void _damagePlayer(EnemyKind source, double x, double z) {
    if (isOver) return;
    final lifeLost = _graceTimer <= 0;
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
