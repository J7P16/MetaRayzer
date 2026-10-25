/// ALL gameplay tuning for the wizard shooter lives in this file.
///
/// World units: the player stands at the origin looking down +z. `z` is distance ahead (enemies
/// spawn at [WizardConfig.spawnDistance] and walk toward the player), `x` is lateral offset
/// (negative = left). Every gameplay distance (ranges, reach, chain radius) is Euclidean:
/// sqrt(x² + z²).
library;

enum EnemyKind {
  troll,
  goblin,
  frog,
  skeletonArcher,
  slime,

  /// The night boss (see [BossSpec]). Never chosen by the ordinary spawner.
  boss;

  /// Kinds the ordinary (daytime) spawner may pick.
  static const List<EnemyKind> spawnable = [troll, goblin, frog, skeletonArcher, slime];
}

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
  /// can still kill the enemy during this window. (The archer uses [ArcherSpec.telegraphSeconds].)
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

/// A non-homing enemy projectile (arrow, boss bolt).
///
/// Aim: the shooter picks its target point once, when the projectile is released: the player's
/// position plus a random lateral error of up to ±[aimSpread] world units (scaled by the
/// difficulty's aim multiplier, never below [minAimSpread]). After launch it flies in a straight
/// line and never corrects its course. It damages the player only if its path passes within
/// [WizardConfig.playerHitRadius] + [radius] of the player.
class ProjectileSpec {
  const ProjectileSpec({required this.speed, required this.aimSpread, required this.minAimSpread, this.radius = 0.15, this.blockable = true, this.maxRange = 40});

  /// World units per second.
  final double speed;

  /// Maximum lateral aim error at the player (world units). 0 = perfect aim.
  final double aimSpread;

  /// Floor for [aimSpread] after difficulty scaling, so later waves never return to perfect aim.
  final double minAimSpread;

  /// Collision radius of the projectile itself.
  final double radius;

  /// Whether the shield can block it.
  final bool blockable;

  /// Removed after travelling this far (it missed and left the arena).
  final double maxRange;
}

/// Skeleton Archer attack cycle: reposition → settle → telegraph → fire → recover → repeat.
class ArcherSpec {
  const ArcherSpec({
    this.repositionSeconds = 0.9,
    this.repositionStep = 1.6,
    this.settleSeconds = 0.45,
    this.telegraphSeconds = 1.1,
    this.minTelegraphSeconds = 0.75,
    this.recoverSeconds = 1.3,
    this.arrow = const ProjectileSpec(speed: 9, aimSpread: 1.3, minAimSpread: 0.9),
  });

  /// Short sideways walk between shots (seconds, and the maximum lateral distance).
  final double repositionSeconds;
  final double repositionStep;

  /// Standing still before the telegraph starts.
  final double settleSeconds;

  /// Bow draw before the arrow is released (scaled by the difficulty's wind-up multiplier, never
  /// below [minTelegraphSeconds]), with a warning sound at its start.
  final double telegraphSeconds;
  final double minTelegraphSeconds;

  /// Pause after a shot (scaled by the difficulty's archer interval multiplier).
  final double recoverSeconds;

  /// Arrow speed is additionally scaled by the difficulty's arrow speed multiplier.
  final ProjectileSpec arrow;
}

/// The base-kit shield: a 0.5 s projectile block triggered by a deliberate one-finger pose.
///
/// It blocks only [ProjectileSpec.blockable] projectiles that reach [blockRadius] from the player
/// within ±[halfAngle] of the shield direction (the player's aim/view direction). It never
/// affects melee or contact damage. Holding the pose does not extend or retrigger it: the pose
/// must be released before the next activation.
class ShieldSpec {
  const ShieldSpec({this.activeSeconds = 0.5, this.rearmSeconds = 0.15, this.blockRadius = 2.2, this.halfAngle = 0.62});

  final double activeSeconds;

  /// Minimum time after a shield ends before a new one can start (even after a release).
  final double rearmSeconds;

  /// Distance from the player at which projectiles meet the shield (world units).
  final double blockRadius;

  /// Half-width of the covered arc (radians) around the shield direction.
  final double halfAngle;
}

/// Day → dusk → night (boss encounter) → dawn → day, repeating. Night lasts until the boss is
/// defeated. Ordinary spawning runs only during the day.
class DayNightSpec {
  const DayNightSpec({this.enabled = true, this.daySeconds = 75, this.duskSeconds = 4, this.dawnSeconds = 5});

  final bool enabled;
  final double daySeconds;

  /// Light fades over the dusk; no new ordinary enemies spawn.
  final double duskSeconds;

  /// Light returns over the dawn; ordinary spawning resumes when day begins.
  final double dawnSeconds;
}

/// The night boss: a hovering lich with telegraphed, shield-blockable bolt attacks.
class BossSpec {
  const BossSpec({
    this.name = 'Bone Lich',
    this.baseHealth = 18,
    this.healthGrowthPerCycle = 0.35,
    this.standDistance = 15,
    this.approachSpeed = 3.2,
    this.hoverAmplitude = 3.2,
    this.hoverSpeed = 0.55,
    this.score = 250,
    this.firstAttackDelay = 1.2,
    this.telegraphSeconds = 1.3,
    this.minTelegraphSeconds = 0.9,
    this.recoverSeconds = 2.0,
    this.fanAngle = 0.32,
    this.summonBelowHealthFraction = 0.5,
    this.summonCount = 2,
    this.summonKind = EnemyKind.goblin,
    this.bolt = const ProjectileSpec(speed: 7.5, aimSpread: 0.45, minAimSpread: 0.3, radius: 0.45),
  });

  final String name;

  /// Health in the first night; each later night adds [healthGrowthPerCycle] × base.
  final double baseHealth;
  final double healthGrowthPerCycle;

  /// Hovers at this distance (inside fireball range) and drifts sideways.
  final double standDistance;
  final double approachSpeed;
  final double hoverAmplitude;
  final double hoverSpeed;
  final int score;
  final double firstAttackDelay;

  /// Glow + rising tone before each volley (scaled by the wind-up multiplier, floored).
  final double telegraphSeconds;
  final double minTelegraphSeconds;
  final double recoverSeconds;

  /// Fan volley: the middle bolt aims at the player, the side bolts this far off (radians) and
  /// pass beside the player.
  final double fanAngle;

  /// Below this health fraction the boss summons [summonCount] [summonKind]s, once per night.
  final double summonBelowHealthFraction;
  final int summonCount;
  final EnemyKind summonKind;
  final ProjectileSpec bolt;
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
    this.aimSpreadMultiplierStart = 1.0,
    this.aimSpreadMultiplierEnd = 0.8,
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

  /// Enemy aim error multiplier (< 1 = more accurate). Each projectile keeps its own
  /// [ProjectileSpec.minAimSpread] floor, so accuracy never returns to perfect.
  final double aimSpreadMultiplierStart;
  final double aimSpreadMultiplierEnd;
  final double firstSpawnDelay;
}

/// Chain Lightning. Unlocked permanently by defeating the first night boss (see [BossSpec]);
/// score alone never unlocks it.
class ChainLightningSpec {
  const ChainLightningSpec({
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
    this.playerHitRadius = 0.7,
    this.enemies = defaultEnemies,
    this.frog = const FrogSpec(),
    this.archer = const ArcherSpec(),
    this.slime = const SlimeSpec(),
    this.difficulty = const DifficultySpec(),
    this.chainLightning = const ChainLightningSpec(),
    this.shield = const ShieldSpec(),
    this.dayNight = const DayNightSpec(),
    this.boss = const BossSpec(),
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

  /// A projectile damages the player only if its straight path passes this close to the origin.
  final double playerHitRadius;

  final Map<EnemyKind, EnemySpec> enemies;
  final FrogSpec frog;
  final ArcherSpec archer;
  final SlimeSpec slime;
  final DifficultySpec difficulty;
  final ChainLightningSpec chainLightning;
  final ShieldSpec shield;
  final DayNightSpec dayNight;
  final BossSpec boss;

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
      health: 2, // survives one fireball, so its telegraphed arrows teach the shield
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
    EnemyKind.boss: EnemySpec(
      kind: EnemyKind.boss,
      name: 'Bone Lich',
      speed: 3.2,
      score: 250,
      attackDistance: 15,
      attackWindup: 1.3,
      spawnWeightStart: 0,
      spawnWeightEnd: 0,
      height: 3.6,
      health: 18, // the actual health comes from BossSpec (it grows each night)
    ),
  };
}
