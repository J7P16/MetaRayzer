import 'wizard_config.dart';

/// The single place difficulty is computed. Enemies and the spawner read the current values
/// from here instead of embedding their own formulas.
class DifficultyController {
  DifficultyController(this.config);

  final WizardConfig config;
  DifficultySpec get spec => config.difficulty;

  double _progress = 0;

  /// 0..1. Monotonic within a run: it never decreases, even if the score formula would allow it.
  double get progress => _progress;

  void update({required double elapsedSeconds, required int score}) {
    final byTime = (elapsedSeconds / spec.rampSeconds).clamp(0.0, 1.0);
    final byScore = (score / spec.scoreForFullDifficulty).clamp(0.0, 1.0);
    final t = byTime > byScore ? byTime : byScore;
    final eased = t * t * (3 - 2 * t); // smoothstep: gentle start and plateau, no sudden jumps
    if (eased > _progress) _progress = eased;
  }

  double _lerp(double a, double b) => a + (b - a) * _progress;

  double get spawnInterval => _lerp(spec.spawnIntervalStart, spec.spawnIntervalEnd);
  int get maxEnemies => _lerp(spec.maxEnemiesStart.toDouble(), spec.maxEnemiesEnd.toDouble()).round();
  double get speedMultiplier => _lerp(spec.speedMultiplierStart, spec.speedMultiplierEnd);
  double get archerIntervalMultiplier => _lerp(spec.archerIntervalMultiplierStart, spec.archerIntervalMultiplierEnd);
  double get arrowSpeedMultiplier => _lerp(spec.arrowSpeedMultiplierStart, spec.arrowSpeedMultiplierEnd);

  /// Telegraph (wind-up) duration for an enemy, with a floor so attacks stay reactable.
  double windupFor(EnemySpec enemy) {
    final scaled = enemy.attackWindup * _lerp(spec.windupMultiplierStart, spec.windupMultiplierEnd);
    return scaled < spec.minWindupSeconds ? spec.minWindupSeconds : scaled;
  }

  double spawnWeight(EnemyKind kind) {
    final s = config.spec(kind);
    return _lerp(s.spawnWeightStart, s.spawnWeightEnd);
  }
}
