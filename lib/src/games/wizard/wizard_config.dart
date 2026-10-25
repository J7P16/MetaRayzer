/// ALL gameplay tuning for the wizard shooter lives in this file.
///
/// World units: the player stands at the origin looking down +z. `z` is distance ahead (enemies
/// spawn at [WizardConfig.spawnDistance] and walk toward 0), `x` is lateral offset (negative =
/// left). Distances to the player are Euclidean: sqrt(x² + z²).
library;

enum EnemyKind { troll, goblin, frog, skeletonArcher }

class EnemySpec {
  const EnemySpec({
    required this.kind,
    required this.name,
    required this.speed,
    required this.score,
    required this.attackDistance,
    required this.attackWindup,
    required this.spawnWeightStart,
    required this.spawnWeightEnd,
    required this.height,
    this.health = 1,
  });

  final EnemyKind kind;
  final String name;

  /// Average approach speed, world units per second (before the difficulty speed multiplier).
  final double speed;

  /// Points awarded when defeated by the player.
  final int score;

  /// Melee: distance at which the enemy stops and starts its attack.
  /// Archer: distance at which it stops and starts shooting.
  final double attackDistance;

  /// Melee: seconds between starting the attack (telegraphed) and the hit landing; the player
  /// can still kill the enemy during this window. Archer: bow-draw time before each arrow.
  final double attackWindup;

  /// Relative spawn weight at difficulty 0 and at full difficulty (interpolated in between).
  final double spawnWeightStart;
  final double spawnWeightEnd;

  /// Visual height in world units (rendering scale only).
  final double height;
  final int health;
}

class FrogSpec {
  const FrogSpec({this.hopDuration = 0.45, this.restDuration = 0.55, this.hopHeight = 1.2, this.maxLateralStep = 1.2});

  /// Seconds airborne per hop (the frog advances only while airborne).
  final double hopDuration;

  /// Seconds sitting between hops.
  final double restDuration;
  final double hopHeight;

  /// Random sideways shift per hop (world units), for unpredictable paths.
  final double maxLateralStep;
}

class ArcherSpec {
  const ArcherSpec({this.shotInterval = 3.4, this.arrowSpeed = 10, this.firstShotDelay = 0.6});

  /// Seconds between arrows once in position (includes the draw/windup).
  final double shotInterval;

  /// Arrow speed, world units per second. Arrows are visible and take ~1.3 s to arrive.
  final double arrowSpeed;
  final double firstShotDelay;
}

class DifficultySpec {
  const DifficultySpec({
    this.rampSeconds = 180,
    this.spawnIntervalStart = 2.6,
    this.spawnIntervalEnd = 0.95,
    this.maxEnemiesStart = 3,
    this.maxEnemiesEnd = 7,
    this.speedMultiplierStart = 1.0,
    this.speedMultiplierEnd = 1.35,
    this.firstSpawnDelay = 1.2,
  });

  /// Seconds of survival to reach full difficulty. Progress follows a smoothstep curve so there
  /// are no sudden jumps; after that, difficulty stays at its maximum.
  final double rampSeconds;
  final double spawnIntervalStart;
  final double spawnIntervalEnd;
  final int maxEnemiesStart;
  final int maxEnemiesEnd;
  final double speedMultiplierStart;
  final double speedMultiplierEnd;
  final double firstSpawnDelay;
}

class WizardConfig {
  const WizardConfig({
    this.startingLives = 3,
    this.spawnDistance = 32,
    this.spawnHalfWidth = 5,
    this.fireballRange = 20,
    this.fireballSpeed = 48,
    this.fireballDamage = 1,
    this.hitGraceSeconds = 0.6,
    this.enemies = defaultEnemies,
    this.frog = const FrogSpec(),
    this.archer = const ArcherSpec(),
    this.difficulty = const DifficultySpec(),
  });

  final int startingLives;
  final double spawnDistance;

  /// Enemies spawn at x in [-spawnHalfWidth, spawnHalfWidth].
  final double spawnHalfWidth;

  /// Maximum distance (sqrt(x²+z²)) at which a fireball can target an enemy. Shown in the
  /// arena as a glowing rune line.
  final double fireballRange;
  final double fireballSpeed;
  final int fireballDamage;

  /// After losing a life, further hits within this many seconds still resolve the attacking
  /// enemy but don't cost another life (prevents losing two lives to one simultaneous swarm).
  final double hitGraceSeconds;

  final Map<EnemyKind, EnemySpec> enemies;
  final FrogSpec frog;
  final ArcherSpec archer;
  final DifficultySpec difficulty;

  EnemySpec spec(EnemyKind kind) => enemies[kind]!;

  static const defaultEnemies = {
    EnemyKind.troll: EnemySpec(
      kind: EnemyKind.troll,
      name: 'Troll',
      speed: 1.9,
      score: 10,
      attackDistance: 2.4,
      attackWindup: 0.9,
      spawnWeightStart: 0.55,
      spawnWeightEnd: 0.2,
      height: 2.8,
    ),
    EnemyKind.goblin: EnemySpec(
      kind: EnemyKind.goblin,
      name: 'Goblin',
      speed: 5.2,
      score: 25,
      attackDistance: 1.9,
      attackWindup: 0.45,
      spawnWeightStart: 0.12,
      spawnWeightEnd: 0.32,
      height: 1.5,
    ),
    EnemyKind.frog: EnemySpec(
      kind: EnemyKind.frog,
      name: 'Hopping Frog',
      speed: 3.2,
      score: 20,
      attackDistance: 1.9,
      attackWindup: 0.5,
      spawnWeightStart: 0.25,
      spawnWeightEnd: 0.25,
      height: 1.1,
    ),
    EnemyKind.skeletonArcher: EnemySpec(
      kind: EnemyKind.skeletonArcher,
      name: 'Skeleton Archer',
      speed: 1.5,
      score: 30,
      attackDistance: 14, // stops inside fireball range so it can always be killed
      attackWindup: 0.9,
      spawnWeightStart: 0.08,
      spawnWeightEnd: 0.23,
      height: 2.2,
    ),
  };
}
