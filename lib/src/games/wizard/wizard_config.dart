/// ALL gameplay tuning for the wizard shooter lives in this file.
///
/// World units: the player stands at the origin looking down +z. `z` is distance ahead (enemies
/// spawn at [WizardConfig.spawnDistance] and walk toward the player), `x` is lateral offset
/// (negative = left). Every gameplay distance (ranges, reach, chain radius) is Euclidean:
/// sqrt(x² + z²).
library;

enum EnemyKind { troll, goblin, frog, skeletonArcher, slime }

/// Spell identifiers (also the keys used for permanent unlocks).
abstract final class SpellIds {
  static const fireball = 'fireball';
  static const chainLightning = 'chain_lightning';
  static const all = [fireball, chainLightning];
}

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

  /// Points awarded when defeated by the player. For the slime: the family bonus (see [SlimeSpec]).
  final int score;

  /// Melee: distance at which the enemy stops and starts its attack.
  /// Archer: distance at which it stops and starts shooting.
  final double attackDistance;

  /// Melee: seconds between starting the attack (telegraphed) and the hit landing; the player
  /// can still kill the enemy during this window. Archer: bow-draw time before each arrow.
  /// Scaled by the difficulty's wind-up multiplier, never below [DifficultySpec.minWindupSeconds].
  final double attackWindup;

  /// Relative spawn weight at difficulty 0 and at full difficulty (interpolated in between).
  final double spawnWeightStart;
  final double spawnWeightEnd;

  /// Visual height in world units (rendering scale only).
  final double height;
  final double health;
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

  /// Seconds between arrows once in position (includes the draw/windup). Scaled by difficulty.
  final double shotInterval;

  /// Arrow speed, world units per second. Scaled by difficulty.
  final double arrowSpeed;
  final double firstShotDelay;
}

/// Splitting Slime.
///
/// Scoring rule: the slime family (the original slime and every slime split from it) awards
/// [EnemySpec.score] exactly once, when its LAST member is defeated by the player. Splitting
/// awards nothing. If any family member reaches the player and strikes, the family awards
/// nothing. Small slimes still count as "enemies defeated".
class SlimeSpec {
  const SlimeSpec({
    this.maxSplitDepth = 1,
    this.childrenPerSplit = 2,
    this.childScale = 0.6,
    this.childSpeedMultiplier = 1.35,
    this.childHealth = 1,
    this.maxActiveSlimes = 8,
    this.childSpread = 1.2,
    this.knockback = 1.5,
  });

  /// How many times a slime line can split. 1 = big slime → 2 small slimes (which die normally).
  final int maxSplitDepth;
  final int childrenPerSplit;

  /// Each generation's size relative to its parent.
  final double childScale;
  final double childSpeedMultiplier;
  final double childHealth;

  /// Hard cap on simultaneously alive slimes. A hit that would exceed it kills the slime
  /// outright instead of splitting, so splitting can never spawn without bound.
  final int maxActiveSlimes;

  /// Lateral distance between the two children (world units).
  final double childSpread;

  /// Children land this much farther from the player than their parent.
  final double knockback;
}

/// The centralized difficulty progression (see [DifficultyController]).
///
/// progress = smoothstep(max(elapsed / rampSeconds, score / scoreForFullDifficulty)), 0..1,
/// then every parameter is interpolated start → end. Values never go past their end values, so
/// difficulty is bounded; the run stays endless until the player loses all lives.
class DifficultySpec {
  const DifficultySpec({
    this.rampSeconds = 210,
    this.scoreForFullDifficulty = 1500,
    this.spawnIntervalStart = 2.4,
    this.spawnIntervalEnd = 0.7,
    this.maxEnemiesStart = 3,
    this.maxEnemiesEnd = 9,
    this.speedMultiplierStart = 1.0,
    this.speedMultiplierEnd = 1.55,
    this.windupMultiplierStart = 1.0,
    this.windupMultiplierEnd = 0.75,
    this.minWindupSeconds = 0.35,
    this.archerIntervalMultiplierStart = 1.0,
    this.archerIntervalMultiplierEnd = 0.65,
    this.arrowSpeedMultiplierStart = 1.0,
    this.arrowSpeedMultiplierEnd = 1.25,
    this.firstSpawnDelay = 1.2,
  });

  /// Seconds of survival to reach full difficulty by time alone.
  final double rampSeconds;

  /// Score that reaches full difficulty by itself (strong players ramp up faster).
  final double scoreForFullDifficulty;
  final double spawnIntervalStart;
  final double spawnIntervalEnd;
  final int maxEnemiesStart;
  final int maxEnemiesEnd;
  final double speedMultiplierStart;
  final double speedMultiplierEnd;

  /// Attack telegraph duration multiplier (less reaction time as the run goes on)...
  final double windupMultiplierStart;
  final double windupMultiplierEnd;

  /// ...but never shorter than this, so attacks always stay reactable.
  final double minWindupSeconds;
  final double archerIntervalMultiplierStart;
  final double archerIntervalMultiplierEnd;
  final double arrowSpeedMultiplierStart;
  final double arrowSpeedMultiplierEnd;
  final double firstSpawnDelay;
}

class ChainLightningSpec {
  const ChainLightningSpec({
    this.unlockScore = 300,
    this.range = 24,
    this.beamHalfWidth = 1.4,
    this.primaryDamage = 2.0,
    this.chainRadius = 5.0,
    this.maxTargets = 4,
    this.maxJumps = 3,
    this.damageFalloff = 0.6,
    this.cooldownSeconds = 1.5,
    this.effectIntensity = 1.0,
  });

  /// Reaching this score within a single run unlocks Chain Lightning permanently.
  final int unlockScore;

  /// Maximum distance along the aim ray for the primary target.
  final double range;

  /// How far (perpendicular) from the aim ray an enemy can be and still be hit first.
  final double beamHalfWidth;
  final double primaryDamage;

  /// Max distance from one chained enemy to the next.
  final double chainRadius;

  /// Total enemies one cast can hit (primary included).
  final int maxTargets;

  /// Maximum number of arcs after the primary strike.
  final int maxJumps;

  /// Each successive target takes this fraction of the previous target's damage.
  final double damageFalloff;
  final double cooldownSeconds;

  /// Scales the visual (bolt thickness, flash) and audio intensity.
  final double effectIntensity;
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
    this.slime = const SlimeSpec(),
    this.difficulty = const DifficultySpec(),
    this.chainLightning = const ChainLightningSpec(),
  });

  final int startingLives;
  final double spawnDistance;

  /// Enemies spawn at x in [-spawnHalfWidth, spawnHalfWidth].
  final double spawnHalfWidth;

  /// Fireball (the default spell, auto-targets the nearest enemy in range, unchanged from v2).
  final double fireballRange;
  final double fireballSpeed;
  final double fireballDamage;

  /// After losing a life, further hits within this many seconds still resolve the attacking
  /// enemy but don't cost another life (prevents losing two lives to one simultaneous swarm).
  final double hitGraceSeconds;

  final Map<EnemyKind, EnemySpec> enemies;
  final FrogSpec frog;
  final ArcherSpec archer;
  final SlimeSpec slime;
  final DifficultySpec difficulty;
  final ChainLightningSpec chainLightning;

  EnemySpec spec(EnemyKind kind) => enemies[kind]!;

  static const defaultEnemies = {
    EnemyKind.troll: EnemySpec(
      kind: EnemyKind.troll,
      name: 'Troll',
      speed: 1.9,
      score: 10,
      attackDistance: 2.4,
      attackWindup: 0.9,
      spawnWeightStart: 0.5,
      spawnWeightEnd: 0.16,
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
      spawnWeightEnd: 0.28,
      height: 1.5,
    ),
    EnemyKind.frog: EnemySpec(
      kind: EnemyKind.frog,
      name: 'Hopping Frog',
      speed: 3.2,
      score: 20,
      attackDistance: 1.9,
      attackWindup: 0.5,
      spawnWeightStart: 0.22,
      spawnWeightEnd: 0.18,
      height: 1.1,
    ),
    EnemyKind.skeletonArcher: EnemySpec(
      kind: EnemyKind.skeletonArcher,
      name: 'Skeleton Archer',
      speed: 1.5,
      score: 30,
      attackDistance: 14, // stops inside fireball range so it can always be killed
      attackWindup: 0.9,
      spawnWeightStart: 0.06,
      spawnWeightEnd: 0.2,
      height: 2.2,
    ),
    EnemyKind.slime: EnemySpec(
      kind: EnemyKind.slime,
      name: 'Splitting Slime',
      speed: 2.2,
      score: 60, // family bonus, see SlimeSpec
      attackDistance: 1.9,
      attackWindup: 0.6,
      spawnWeightStart: 0.1,
      spawnWeightEnd: 0.18,
      height: 1.4,
    ),
  };
}
