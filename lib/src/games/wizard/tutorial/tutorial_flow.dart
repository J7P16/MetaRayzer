import '../../../input/head_pose.dart';
import '../wizard_config.dart';
import '../wizard_game.dart';

enum TutorialStep {
  /// The camera view and head movement.
  look,

  /// The fist → open-palm cast, on a practice target.
  cast,

  /// The shield, timed against a slow telegraphed arrow.
  shield,

  /// Summary: play or return to the menu.
  done,
}

/// Feedback for the shield step after an arrow arrives.
enum ShieldAttempt { none, blocked, tooEarly, tooLate }

/// The tutorial's step logic, independent of widgets and hardware. The screen feeds it head
/// views and game events and shows what it reports.
class TutorialFlow {
  TutorialFlow({this.lookThreshold = 0.15, this.blocksNeeded = 1});

  /// Head yaw (radians, after sensitivity) that counts as "looked left/right".
  final double lookThreshold;
  final int blocksNeeded;

  TutorialStep step = TutorialStep.look;
  bool lookedLeft = false;
  bool lookedRight = false;
  bool castHit = false;
  int blocks = 0;
  ShieldAttempt lastAttempt = ShieldAttempt.none;

  /// Steps skipped by the player (shown in the summary).
  final Set<TutorialStep> skipped = {};

  /// When the shield last expired (game time), to tell "too early" from "too late".
  double? _shieldEndedAt;

  bool get stepComplete => switch (step) {
        TutorialStep.look => lookedLeft && lookedRight,
        TutorialStep.cast => castHit,
        TutorialStep.shield => blocks >= blocksNeeded,
        TutorialStep.done => true,
      };

  /// Step number for the progress indicator (1-based; the summary counts as finished).
  int get number => step.index + 1;
  static int get practiceSteps => TutorialStep.values.length - 1;

  void onHead(HeadView head) {
    if (step != TutorialStep.look || head.status == HeadTrackingStatus.unavailable) return;
    if (head.yaw <= -lookThreshold) lookedLeft = true;
    if (head.yaw >= lookThreshold) lookedRight = true;
  }

  /// Applies the practice game's events of one frame. [time] is the game clock.
  void onEvents(List<GameEvent> events, double time) {
    for (final e in events) {
      switch (e) {
        case EnemyDefeated(:final enemy) when step == TutorialStep.cast && enemy.kind == EnemyKind.troll:
          castHit = true;
        case ShieldExpired():
          _shieldEndedAt = time;
        case ProjectileBlocked() when step == TutorialStep.shield:
          blocks++;
          lastAttempt = ShieldAttempt.blocked;
        case ProjectileHitPlayer() when step == TutorialStep.shield:
          final ended = _shieldEndedAt;
          lastAttempt = ended != null && time - ended < 1.5 ? ShieldAttempt.tooEarly : ShieldAttempt.tooLate;
        default:
          break;
      }
    }
  }

  void next() {
    if (step == TutorialStep.done) return;
    step = TutorialStep.values[step.index + 1];
    lastAttempt = ShieldAttempt.none;
  }

  void skip() {
    if (step == TutorialStep.done) return;
    if (!stepComplete) skipped.add(step);
    next();
  }

  /// The practice sandbox's tuning: a stationary target, and a stationary archer with a long,
  /// fixed telegraph and slow, perfectly aimed arrows (so the lesson is timing, not luck).
  static WizardConfig practiceConfig() {
    const base = WizardConfig.defaultEnemies;
    EnemySpec stationary(EnemySpec s, {double? health}) => EnemySpec(
          kind: s.kind,
          name: s.name,
          speed: 0,
          score: s.score,
          attackDistance: s.attackDistance,
          attackWindup: s.attackWindup,
          spawnWeightStart: 0,
          spawnWeightEnd: 0,
          height: s.height,
          health: health ?? s.health,
        );
    return WizardConfig(
      startingLives: 3,
      enemies: {
        ...base,
        EnemyKind.troll: stationary(base[EnemyKind.troll]!),
        EnemyKind.skeletonArcher: stationary(base[EnemyKind.skeletonArcher]!, health: 999),
      },
      archer: const ArcherSpec(
        repositionStep: 0,
        settleSeconds: 0.8,
        telegraphSeconds: 1.6,
        minTelegraphSeconds: 1.6,
        recoverSeconds: 2.2,
        arrow: ProjectileSpec(speed: 4.5, aimSpread: 0, minAimSpread: 0),
      ),
      difficulty: const DifficultySpec(spawnIntervalStart: 1e9, spawnIntervalEnd: 1e9, firstSpawnDelay: 1e9),
      dayNight: const DayNightSpec(enabled: false),
    );
  }
}
