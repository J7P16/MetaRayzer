import 'dart:math' as math;

import 'wizard_config.dart';

enum EnemyState {
  /// Moving toward the player.
  approaching,

  /// In position and winding up / performing its attack (telegraphed).
  attacking,

  /// Killed by the player; plays a death effect, then is removed.
  defeated,

  /// Its attack landed (melee enemies vanish after striking); removed next tick.
  resolved,
}

/// What enemies may do to the world. Implemented by the game; keeps enemies decoupled from it.
abstract class EnemyContext {
  WizardConfig get config;
  math.Random get random;

  /// Current difficulty speed multiplier.
  double get speedMultiplier;

  /// A melee strike reaches the player.
  void meleeHit(Enemy attacker);

  /// A ranged enemy releases a projectile toward the player.
  void fireArrow(Enemy shooter);
}

/// Shared enemy behavior. Subclasses implement [move] (approach pattern) and may override
/// [attackUpdate]. Adding an enemy type = new subclass + an [EnemySpec] + a spawn factory entry.
abstract class Enemy {
  Enemy({required this.id, required this.spec, required this.x, required this.z}) : health = spec.health;

  final int id;
  final EnemySpec spec;
  double x;
  double z;
  int health;
  EnemyState state = EnemyState.approaching;

  /// Seconds spent in the current [state].
  double stateTime = 0;

  /// Seconds since spawn (for animation).
  double age = 0;

  /// Damage from fireballs already in flight toward this enemy (so the next cast picks
  /// another target instead of wasting a fireball on a doomed enemy).
  int incomingDamage = 0;

  /// Guards against awarding points twice.
  bool scored = false;

  EnemyKind get kind => spec.kind;
  double get distance => math.sqrt(x * x + z * z);
  bool get isAlive => state == EnemyState.approaching || state == EnemyState.attacking;

  /// Height above the ground (frogs hop); rendering only.
  double get elevation => 0;

  /// 0..1 progress of the current attack wind-up, for telegraph visuals.
  double get attackProgress => state == EnemyState.attacking ? (stateTime / spec.attackWindup).clamp(0.0, 1.0) : 0;

  void update(double dt, EnemyContext ctx) {
    age += dt;
    stateTime += dt;
    switch (state) {
      case EnemyState.approaching:
        move(dt, ctx);
        if (distance <= spec.attackDistance + 1e-9) {
          _enter(EnemyState.attacking);
          onReachedAttackDistance(ctx);
        }
      case EnemyState.attacking:
        attackUpdate(dt, ctx);
      case EnemyState.defeated:
      case EnemyState.resolved:
        break;
    }
  }

  void move(double dt, EnemyContext ctx);

  void onReachedAttackDistance(EnemyContext ctx) {}

  /// Default melee: after the wind-up the blow lands once, then the enemy is resolved.
  void attackUpdate(double dt, EnemyContext ctx) {
    if (stateTime >= spec.attackWindup) {
      ctx.meleeHit(this);
      _enter(EnemyState.resolved);
    }
  }

  /// Applies damage. Returns true if this hit defeated the enemy.
  bool takeDamage(int amount) {
    if (!isAlive) return false;
    health -= amount;
    if (health <= 0) {
      _enter(EnemyState.defeated);
      return true;
    }
    return false;
  }

  void _enter(EnemyState s) {
    state = s;
    stateTime = 0;
  }

  /// Walks [step] world units straight toward the player (radially), never closer than the
  /// attack distance. Lateral offset shrinks as the enemy converges on the player.
  void advance(double step) {
    final d = distance;
    if (d <= 1e-9) return;
    final f = math.max(spec.attackDistance, d - step) / d;
    x *= f;
    z *= f;
  }

  /// Sideways shift (weaving/hopping) limited to a corridor that narrows near the player.
  void shiftSideways(double dx, EnemyContext ctx) {
    final limit = ctx.config.spawnHalfWidth * math.max(z / ctx.config.spawnDistance, 0.1);
    x = (x + dx).clamp(-limit, limit);
  }
}

/// Slow, steady walker.
class Troll extends Enemy {
  Troll({required super.id, required super.spec, required super.x, required super.z});

  @override
  void move(double dt, EnemyContext ctx) => advance(spec.speed * ctx.speedMultiplier * dt);
}

/// Fast runner with a slight weave.
class Goblin extends Enemy {
  Goblin({required super.id, required super.spec, required super.x, required super.z, this.phase = 0});

  final double phase;

  @override
  void move(double dt, EnemyContext ctx) {
    advance(spec.speed * ctx.speedMultiplier * dt);
    shiftSideways(math.cos(age * 5 + phase) * 1.2 * dt, ctx);
  }
}

/// Advances only during hops (alternating airborne/landed), with a random sideways shift per
/// hop: same average speed as [EnemySpec.speed] but bursty and less predictable.
class HoppingFrog extends Enemy {
  HoppingFrog({required super.id, required super.spec, required super.x, required super.z});

  double _phaseTime = 0;
  bool airborne = false;
  double _hopLateral = 0;

  double _hopProgress(FrogSpec f) => airborne ? (_phaseTime / f.hopDuration).clamp(0.0, 1.0) : 0;
  double? _hopHeight;

  @override
  double get elevation => _hopHeight ?? 0;

  @override
  void move(double dt, EnemyContext ctx) {
    final f = ctx.config.frog;
    final speed = ctx.speedMultiplier;
    _phaseTime += dt * speed;
    if (!airborne && _phaseTime >= f.restDuration) {
      airborne = true;
      _phaseTime = 0;
      _hopLateral = (ctx.random.nextDouble() * 2 - 1) * f.maxLateralStep;
    } else if (airborne && _phaseTime >= f.hopDuration) {
      airborne = false;
      _phaseTime = 0;
    }
    if (airborne) {
      // Distance per hop chosen so the long-run average equals spec.speed.
      final hopDistance = spec.speed * (f.hopDuration + f.restDuration);
      advance(hopDistance / f.hopDuration * dt * speed);
      shiftSideways(_hopLateral / f.hopDuration * dt * speed, ctx);
      final p = _hopProgress(f);
      _hopHeight = 4 * p * (1 - p) * f.hopHeight;
    } else {
      _hopHeight = 0;
    }
  }
}

/// Ranged enemy: walks in slowly, stops at its attack distance (inside fireball range) and
/// fires a visible arrow every [ArcherSpec.shotInterval] seconds, with a bow-draw telegraph.
class SkeletonArcher extends Enemy {
  SkeletonArcher({required super.id, required super.spec, required super.x, required super.z});

  double _shotTimer = 0;

  /// 0..1 while drawing the bow (telegraph).
  double drawProgress = 0;

  @override
  void move(double dt, EnemyContext ctx) => advance(spec.speed * ctx.speedMultiplier * dt);

  @override
  void onReachedAttackDistance(EnemyContext ctx) {
    _shotTimer = ctx.config.archer.shotInterval - spec.attackWindup - ctx.config.archer.firstShotDelay;
  }

  @override
  double get attackProgress => drawProgress;

  @override
  void attackUpdate(double dt, EnemyContext ctx) {
    final a = ctx.config.archer;
    _shotTimer += dt;
    final drawStart = a.shotInterval - spec.attackWindup;
    drawProgress = _shotTimer <= drawStart ? 0 : ((_shotTimer - drawStart) / spec.attackWindup).clamp(0.0, 1.0);
    if (_shotTimer >= a.shotInterval) {
      _shotTimer = 0;
      drawProgress = 0;
      ctx.fireArrow(this);
    }
  }
}

Enemy createEnemy(EnemyKind kind, {required int id, required WizardConfig config, required double x, required math.Random random}) {
  final spec = config.spec(kind);
  final z = config.spawnDistance;
  return switch (kind) {
    EnemyKind.troll => Troll(id: id, spec: spec, x: x, z: z),
    EnemyKind.goblin => Goblin(id: id, spec: spec, x: x, z: z, phase: random.nextDouble() * math.pi * 2),
    EnemyKind.frog => HoppingFrog(id: id, spec: spec, x: x, z: z),
    EnemyKind.skeletonArcher => SkeletonArcher(id: id, spec: spec, x: x, z: z),
  };
}
