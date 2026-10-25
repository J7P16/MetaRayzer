import 'dart:math' as math;

import 'difficulty.dart';
import 'wizard_config.dart';

enum EnemyState {
  /// Moving toward the player.
  approaching,

  /// In position and winding up / performing its attack (telegraphed).
  attacking,

  /// Killed by the player; plays a death effect, then is removed.
  defeated,

  /// Split into smaller enemies (slime); removed next tick. Not a defeat: awards nothing.
  split,

  /// Its attack landed (melee enemies vanish after striking); removed next tick.
  resolved,
}

/// What enemies may do to the world. Implemented by the game; keeps enemies decoupled from it.
abstract class EnemyContext {
  WizardConfig get config;
  math.Random get random;

  /// The central difficulty values (speed, wind-up, attack frequency).
  DifficultyController get difficulty;

  /// A melee strike reaches the player.
  void meleeHit(Enemy attacker);

  /// A ranged enemy releases a straight, non-homing projectile aimed at the player's position
  /// at this moment (plus the projectile's aim error), optionally rotated by [yawOffset].
  void fireProjectile(Enemy shooter, ProjectileSpec spec, {double yawOffset = 0, double speedMultiplier = 1});

  /// An enemy started its telegraphed attack (for sound/visual cues).
  void attackStarted(Enemy enemy);

  /// A boss calls [count] reinforcements of [kind] near itself.
  void summon(EnemyKind kind, int count, Enemy near);
}

/// Shared enemy behavior, built from small overridable parts:
/// - movement: [move]
/// - attack: [onReachedAttackDistance] / [attackUpdate]
/// - health/damage: [health], [takeDamage]
/// - defeat/split: [EnemyState], handled by the game's damage pipeline
/// - score: [EnemySpec.score] (slimes use family scoring)
/// - visuals/audio: chosen by [kind] in the view and audio layers
/// Adding an enemy type = a subclass + an [EnemySpec] + one line in [createEnemy].
abstract class Enemy {
  Enemy({required this.id, required this.spec, required this.x, required this.z})
      : health = spec.health,
        maxHealth = spec.health;

  final int id;
  final EnemySpec spec;
  double x;
  double z;
  double health;

  /// Health at full strength (health bars show [health] / [maxHealth]).
  double maxHealth;

  /// Seconds since this enemy last took damage (hit flash, health-bar damage trail).
  double timeSinceDamage = double.infinity;

  /// [health] as it was right before the most recent hit (for the health bar's damage trail).
  double healthBeforeHit = 0;
  EnemyState state = EnemyState.approaching;

  /// Seconds spent in the current [state].
  double stateTime = 0;

  /// Seconds since spawn (for animation).
  double age = 0;

  /// Damage from fireballs already in flight toward this enemy (so the next cast picks
  /// another target instead of wasting a fireball on a doomed enemy).
  double incomingDamage = 0;

  /// Guards against awarding points twice.
  bool scored = false;

  /// Wind-up duration for the current attack (set by the difficulty controller).
  double windup = 0;

  EnemyKind get kind => spec.kind;

  /// 0..1 remaining health (0 once defeated).
  double get healthFraction => isAlive && maxHealth > 0 ? (health / maxHealth).clamp(0.0, 1.0) : 0;
  double get distance => math.sqrt(x * x + z * z);
  bool get isAlive => state == EnemyState.approaching || state == EnemyState.attacking;

  /// Visual scale relative to [EnemySpec.height] (smaller slimes).
  double get scale => 1;
  double get height => spec.height * scale;

  /// Speed multiplier specific to this individual (smaller slimes are quicker).
  double get speedFactor => 1;

  /// Height above the ground (frogs hop); rendering only.
  double get elevation => 0;

  /// 0..1 progress of the current attack wind-up, for telegraph visuals.
  double get attackProgress => state == EnemyState.attacking && windup > 0 ? (stateTime / windup).clamp(0.0, 1.0) : 0;

  void update(double dt, EnemyContext ctx) {
    age += dt;
    stateTime += dt;
    timeSinceDamage += dt;
    switch (state) {
      case EnemyState.approaching:
        move(dt, ctx);
        if (distance <= spec.attackDistance + 1e-9) {
          enter(EnemyState.attacking);
          windup = ctx.difficulty.windupFor(spec);
          onReachedAttackDistance(ctx);
        }
      case EnemyState.attacking:
        attackUpdate(dt, ctx);
      case EnemyState.defeated:
      case EnemyState.split:
      case EnemyState.resolved:
        break;
    }
  }

  void move(double dt, EnemyContext ctx);

  void onReachedAttackDistance(EnemyContext ctx) => ctx.attackStarted(this);

  /// Default melee: after the wind-up the blow lands once, then the enemy is resolved.
  void attackUpdate(double dt, EnemyContext ctx) {
    if (stateTime >= windup) {
      ctx.meleeHit(this);
      enter(EnemyState.resolved);
    }
  }

  /// Applies damage. Returns true if this hit defeated the enemy. (The game's damage pipeline
  /// decides about splitting before calling this.)
  bool takeDamage(double amount) {
    if (!isAlive || amount <= 0) return false;
    healthBeforeHit = health;
    timeSinceDamage = 0;
    health -= amount;
    if (health <= 1e-9) {
      health = 0;
      enter(EnemyState.defeated);
      return true;
    }
    return false;
  }

  void enter(EnemyState s) {
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

  double stepSpeed(EnemyContext ctx) => spec.speed * speedFactor * ctx.difficulty.speedMultiplier;
}

/// Slow, steady walker.
class Troll extends Enemy {
  Troll({required super.id, required super.spec, required super.x, required super.z});

  @override
  void move(double dt, EnemyContext ctx) => advance(stepSpeed(ctx) * dt);
}

/// Fast runner with a slight weave.
class Goblin extends Enemy {
  Goblin({required super.id, required super.spec, required super.x, required super.z, this.phase = 0});

  final double phase;

  @override
  void move(double dt, EnemyContext ctx) {
    advance(stepSpeed(ctx) * dt);
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
  double _hopHeight = 0;

  @override
  double get elevation => _hopHeight;

  @override
  void move(double dt, EnemyContext ctx) {
    final f = ctx.config.frog;
    final speed = ctx.difficulty.speedMultiplier;
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
      final p = (_phaseTime / f.hopDuration).clamp(0.0, 1.0);
      _hopHeight = 4 * p * (1 - p) * f.hopHeight;
    } else {
      _hopHeight = 0;
    }
  }
}

enum ArcherPhase { reposition, settle, telegraph, recover }

/// Ranged enemy and the shield's teacher. Walks in slowly, stops at its attack distance (inside
/// fireball range), then repeats a readable cycle:
///   reposition (short sideways walk) → settle (still) → telegraph (bow draw + warning sound)
///   → fire ONE arrow → recover → reposition …
/// Each update performs at most one phase change, so the telegraph is never skipped by a long
/// frame, and an arrow can only be released on the telegraph → recover transition (exactly one
/// per cycle).
class SkeletonArcher extends Enemy {
  SkeletonArcher({required super.id, required super.spec, required super.x, required super.z});

  ArcherPhase phase = ArcherPhase.settle;
  double phaseTime = 0;

  /// Duration of the current telegraph (fixed when it starts).
  double telegraphSeconds = 0;
  double _phaseDuration = 0;
  double _fromX = 0;
  double _toX = 0;
  int shotsFired = 0;

  /// 0..1 while drawing the bow (telegraph).
  double get drawProgress => phase == ArcherPhase.telegraph && telegraphSeconds > 0 ? (phaseTime / telegraphSeconds).clamp(0.0, 1.0) : 0;

  @override
  double get attackProgress => drawProgress;

  @override
  void move(double dt, EnemyContext ctx) => advance(stepSpeed(ctx) * dt);

  @override
  void onReachedAttackDistance(EnemyContext ctx) => _enter(ArcherPhase.settle, ctx);

  void _enter(ArcherPhase next, EnemyContext ctx) {
    final a = ctx.config.archer;
    phase = next;
    phaseTime = 0;
    switch (next) {
      case ArcherPhase.reposition:
        _phaseDuration = a.repositionSeconds;
        _fromX = x;
        final limit = ctx.config.spawnHalfWidth * math.max(z / ctx.config.spawnDistance, 0.1);
        _toX = (x + (ctx.random.nextDouble() * 2 - 1) * a.repositionStep).clamp(-limit, limit);
      case ArcherPhase.settle:
        _phaseDuration = a.settleSeconds;
      case ArcherPhase.telegraph:
        telegraphSeconds = ctx.difficulty.telegraphFor(a.telegraphSeconds, a.minTelegraphSeconds);
        _phaseDuration = telegraphSeconds;
        ctx.attackStarted(this);
      case ArcherPhase.recover:
        _phaseDuration = a.recoverSeconds * ctx.difficulty.archerIntervalMultiplier;
    }
  }

  @override
  void attackUpdate(double dt, EnemyContext ctx) {
    phaseTime += dt;
    if (phase == ArcherPhase.reposition) {
      final p = (phaseTime / _phaseDuration).clamp(0.0, 1.0);
      x = _fromX + (_toX - _fromX) * (p * p * (3 - 2 * p));
    }
    if (phaseTime < _phaseDuration) return;
    switch (phase) {
      case ArcherPhase.reposition:
        _enter(ArcherPhase.settle, ctx);
      case ArcherPhase.settle:
        _enter(ArcherPhase.telegraph, ctx);
      case ArcherPhase.telegraph:
        shotsFired++;
        ctx.fireProjectile(this, ctx.config.archer.arrow, speedMultiplier: ctx.difficulty.arrowSpeedMultiplier);
        _enter(ArcherPhase.recover, ctx);
      case ArcherPhase.recover:
        _enter(ArcherPhase.reposition, ctx);
    }
  }
}

enum BossPhase { hover, telegraph, recover }

enum BossAttack {
  /// One large bolt aimed at the player.
  aimedBolt,

  /// Three bolts: the middle aims at the player, the side bolts pass beside them.
  fan,
}

/// The night boss: glides in, hovers sideways at [BossSpec.standDistance], and alternates
/// telegraphed, shield-blockable bolt volleys. Summons reinforcements once when weakened. Not a
/// melee enemy: it never reaches the player.
class BoneLich extends Enemy {
  BoneLich({required super.id, required super.spec, required super.x, required super.z, required this.boss, required double health, required this.night}) {
    this.health = health;
    maxHealth = health;
  }

  final BossSpec boss;

  /// The night (1-based) this boss belongs to.
  final int night;

  BossPhase phase = BossPhase.hover;
  double phaseTime = 0;
  double telegraphSeconds = 0;
  BossAttack nextAttack = BossAttack.aimedBolt;
  int volleys = 0;
  bool summoned = false;
  double _hover = 0;
  double _phaseDuration = 0;

  /// 0..1 while charging a volley.
  double get chargeProgress => phase == BossPhase.telegraph && telegraphSeconds > 0 ? (phaseTime / telegraphSeconds).clamp(0.0, 1.0) : 0;

  @override
  double get attackProgress => chargeProgress;

  @override
  double get elevation => 0.6 + 0.25 * math.sin(age * 1.7);

  @override
  void move(double dt, EnemyContext ctx) => advance(boss.approachSpeed * dt);

  @override
  void onReachedAttackDistance(EnemyContext ctx) {
    phase = BossPhase.hover;
    phaseTime = 0;
    _phaseDuration = boss.firstAttackDelay;
  }

  @override
  void attackUpdate(double dt, EnemyContext ctx) {
    phaseTime += dt;
    if (!summoned && healthFraction < boss.summonBelowHealthFraction) {
      summoned = true;
      ctx.summon(boss.summonKind, boss.summonCount, this);
    }
    // Drift sideways between volleys; hold still while charging so the attack reads clearly.
    if (phase != BossPhase.telegraph) {
      _hover += dt * boss.hoverSpeed;
      final targetX = math.sin(_hover) * boss.hoverAmplitude;
      x += (targetX - x) * math.min(1, dt * 2);
    }
    if (phaseTime < _phaseDuration) return;
    switch (phase) {
      case BossPhase.hover || BossPhase.recover:
        phase = BossPhase.telegraph;
        phaseTime = 0;
        telegraphSeconds = ctx.difficulty.telegraphFor(boss.telegraphSeconds, boss.minTelegraphSeconds);
        _phaseDuration = telegraphSeconds;
        ctx.attackStarted(this);
      case BossPhase.telegraph:
        switch (nextAttack) {
          case BossAttack.aimedBolt:
            ctx.fireProjectile(this, boss.bolt);
          case BossAttack.fan:
            for (final offset in [-boss.fanAngle, 0.0, boss.fanAngle]) {
              ctx.fireProjectile(this, boss.bolt, yawOffset: offset);
            }
        }
        volleys++;
        nextAttack = nextAttack == BossAttack.aimedBolt ? BossAttack.fan : BossAttack.aimedBolt;
        phase = BossPhase.recover;
        phaseTime = 0;
        _phaseDuration = boss.recoverSeconds;
    }
  }
}

/// Splitting Slime: oozes forward in squishy pulses. When hit, the game's damage pipeline splits
/// it into [SlimeSpec.childrenPerSplit] smaller, quicker slimes (up to [SlimeSpec.maxSplitDepth]
/// generations); the smallest generation dies normally. See [SlimeSpec] for the scoring rule.
class SplittingSlime extends Enemy {
  SplittingSlime({
    required super.id,
    required super.spec,
    required super.x,
    required super.z,
    required this.familyId,
    this.generation = 0,
    required SlimeSpec slime,
  })  : _scale = math.pow(slime.childScale, generation).toDouble(),
        _speedFactor = math.pow(slime.childSpeedMultiplier, generation).toDouble() {
    if (generation > 0) health = maxHealth = slime.childHealth;
  }

  final int familyId;

  /// 0 = original slime, 1 = first split, ...
  final int generation;
  final double _scale;
  final double _speedFactor;

  @override
  double get scale => _scale;

  @override
  double get speedFactor => _speedFactor;

  bool canSplit(SlimeSpec slime) => generation < slime.maxSplitDepth;

  /// 0..1 squash phase of the ooze cycle (for rendering).
  double get squish => 0.5 + 0.5 * math.sin(age * 6 + id);

  @override
  void move(double dt, EnemyContext ctx) {
    // Pulsing ooze: faster while stretching forward, slower while gathering.
    final pulse = 0.55 + 0.9 * math.max(0, math.sin(age * 6 + id));
    advance(stepSpeed(ctx) * pulse * dt);
  }
}

Enemy createEnemy(EnemyKind kind, {required int id, required WizardConfig config, required double x, required math.Random random, int familyId = 0}) {
  final spec = config.spec(kind);
  final z = config.spawnDistance;
  return switch (kind) {
    EnemyKind.troll => Troll(id: id, spec: spec, x: x, z: z),
    EnemyKind.goblin => Goblin(id: id, spec: spec, x: x, z: z, phase: random.nextDouble() * math.pi * 2),
    EnemyKind.frog => HoppingFrog(id: id, spec: spec, x: x, z: z),
    EnemyKind.skeletonArcher => SkeletonArcher(id: id, spec: spec, x: x, z: z),
    EnemyKind.slime => SplittingSlime(id: id, spec: spec, x: x, z: z, familyId: familyId, slime: config.slime),
    EnemyKind.boss => BoneLich(id: id, spec: spec, x: x, z: z, boss: config.boss, health: config.boss.baseHealth, night: 1),
  };
}
