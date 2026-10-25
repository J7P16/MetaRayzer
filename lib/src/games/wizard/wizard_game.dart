import 'dart:math' as math;

import 'enemies.dart';
import 'wizard_config.dart';

/// Things that happened during an update, for effects and sound. Drained by the view.
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

class EnemyDefeated extends GameEvent {
  const EnemyDefeated(this.enemy, this.points);
  final Enemy enemy;
  final int points;
}

class PlayerHit extends GameEvent {
  const PlayerHit({required this.source, required this.livesLeft, required this.lifeLost});
  final EnemyKind source;
  final int livesLeft;

  /// False when the hit landed during the post-hit grace period.
  final bool lifeLost;
}

class ArrowFired extends GameEvent {
  const ArrowFired(this.arrow);
  final Arrow arrow;
}

class EnemySpawned extends GameEvent {
  const EnemySpawned(this.enemy);
  final Enemy enemy;
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

  /// Starts at hand height (~1.2 below eye level is handled by the renderer) and arcs slightly.
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
enum CastResult { launched, noTargetInRange, gameOver }

/// The complete wizard-shooter simulation. Pure Dart: no Flutter, no camera, no wall clock
/// (time only advances through [update]), seeded randomness. Rendering, input and persistence
/// live elsewhere.
class WizardGame implements EnemyContext {
  WizardGame({this.config = const WizardConfig(), int? seed}) : random = math.Random(seed) {
    lives = config.startingLives;
    _spawnTimer = config.difficulty.spawnIntervalStart - config.difficulty.firstSpawnDelay;
  }

  @override
  final WizardConfig config;
  @override
  final math.Random random;

  final List<Enemy> enemies = [];
  final List<Fireball> fireballs = [];
  final List<Arrow> arrows = [];
  final List<GameEvent> _events = [];

  late int lives;
  int score = 0;
  int enemiesDefeated = 0;
  int castsMade = 0;
  double elapsed = 0;
  bool isOver = false;
  double _spawnTimer = 0;
  double _graceTimer = 0;
  int _nextId = 1;

  /// Seconds since the player was last hit (for damage flash), large if never.
  double timeSinceHit = 999;

  // ---- Difficulty ----

  /// 0..1, smoothstep over [DifficultySpec.rampSeconds] of survival time.
  double get difficulty {
    final t = (elapsed / config.difficulty.rampSeconds).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  double _lerp(double a, double b) => a + (b - a) * difficulty;

  double get spawnInterval => _lerp(config.difficulty.spawnIntervalStart, config.difficulty.spawnIntervalEnd);
  int get maxEnemies => _lerp(config.difficulty.maxEnemiesStart.toDouble(), config.difficulty.maxEnemiesEnd.toDouble()).round();
  @override
  double get speedMultiplier => _lerp(config.difficulty.speedMultiplierStart, config.difficulty.speedMultiplierEnd);

  double spawnWeight(EnemyKind kind) {
    final s = config.spec(kind);
    return _lerp(s.spawnWeightStart, s.spawnWeightEnd);
  }

  List<Enemy> get livingEnemies => enemies.where((e) => e.isAlive).toList();

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

    _updateSpawning(dt);
    for (final e in List.of(enemies)) {
      e.update(dt, this);
      if (isOver) return;
    }
    _updateFireballs(dt);
    _updateArrows(dt);
    if (isOver) return;

    // Cleanup: defeated enemies linger briefly for their death animation.
    enemies.removeWhere((e) => e.state == EnemyState.resolved || (e.state == EnemyState.defeated && e.stateTime > 0.6));
    fireballs.removeWhere((f) => f.done);
    arrows.removeWhere((a) => a.done);
  }

  void _updateSpawning(double dt) {
    _spawnTimer += dt;
    if (_spawnTimer < spawnInterval) return;
    if (livingEnemies.length >= maxEnemies) return; // wait for room; keep the timer full
    _spawnTimer = 0;
    spawn(_pickKind());
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
    final enemy = createEnemy(
      kind,
      id: _nextId++,
      config: config,
      x: x ?? (random.nextDouble() * 2 - 1) * config.spawnHalfWidth,
      random: random,
    );
    enemies.add(enemy);
    _events.add(EnemySpawned(enemy));
    return enemy;
  }

  // ---- Player actions ----

  /// Living enemies a fireball can target: within range and not already doomed by fireballs in
  /// flight. Nearest first.
  List<Enemy> targetableEnemies() {
    final list = enemies
        .where((e) => e.isAlive && e.distance <= config.fireballRange && e.incomingDamage < e.health)
        .toList()
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
    final toX = target?.x ?? 0;
    final toZ = target?.z ?? config.fireballRange;
    final dist = math.sqrt(math.pow(toX - fromX, 2) + math.pow(toZ - fromZ, 2));
    final fireball = Fireball(
      target: target,
      fromX: fromX,
      fromZ: fromZ,
      toX: toX,
      toZ: toZ,
      toElevation: target == null ? 0.8 : target.spec.height * 0.5 + target.elevation,
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
        f.toElevation = target.spec.height * 0.5 + target.elevation;
      }
      if (f.time < f.duration) continue;
      f.done = true;
      if (target == null) {
        _events.add(FireballImpact(x: f.toX, z: f.toZ, elevation: f.toElevation, defeated: false));
        continue;
      }
      target.incomingDamage = math.max(0, target.incomingDamage - config.fireballDamage);
      if (!target.isAlive) {
        // It already struck the player (or died) before the fireball arrived: fizzle.
        _events.add(FireballImpact(x: f.toX, z: f.toZ, elevation: f.toElevation, defeated: false));
        continue;
      }
      final defeated = target.takeDamage(config.fireballDamage);
      _events.add(FireballImpact(x: target.x, z: target.z, elevation: f.toElevation, enemy: target, defeated: defeated));
      if (defeated) _award(target);
    }
  }

  void _award(Enemy enemy) {
    if (enemy.scored) return;
    enemy.scored = true;
    score += enemy.spec.score;
    enemiesDefeated++;
    _events.add(EnemyDefeated(enemy, enemy.spec.score));
  }

  void _updateArrows(double dt) {
    for (final a in arrows) {
      if (a.done) continue;
      final d = math.sqrt(a.x * a.x + a.z * a.z);
      final step = a.speed * dt;
      if (d <= step + 0.4) {
        a.done = true;
        _damagePlayer(EnemyKind.skeletonArcher);
        if (isOver) return;
        continue;
      }
      a.x -= a.x / d * step;
      a.z -= a.z / d * step;
    }
  }

  // ---- EnemyContext ----

  @override
  void meleeHit(Enemy attacker) => _damagePlayer(attacker.kind);

  @override
  void fireArrow(Enemy shooter) {
    final arrow = Arrow(x: shooter.x, z: shooter.z, speed: config.archer.arrowSpeed);
    arrows.add(arrow);
    _events.add(ArrowFired(arrow));
  }

  void _damagePlayer(EnemyKind source) {
    if (isOver) return;
    final lifeLost = _graceTimer <= 0;
    if (lifeLost) {
      lives = math.max(0, lives - 1);
      _graceTimer = config.hitGraceSeconds;
      timeSinceHit = 0;
    }
    _events.add(PlayerHit(source: source, livesLeft: lives, lifeLost: lifeLost));
    if (lives == 0) {
      isOver = true;
      _events.add(GameEnded(score));
    }
  }
}
