import '../enemies.dart';
import '../wizard_config.dart';
import '../wizard_game.dart';

/// A short-lived visual effect anchored in world space.
class WorldEffect {
  WorldEffect({required this.kind, required this.x, required this.z, required this.elevation, required this.duration, this.text, this.seed = 0});

  final EffectKind kind;
  final double x;
  final double z;
  final double elevation;
  final double duration;
  final String? text;
  final int seed;
  double age = 0;

  double get t => (age / duration).clamp(0.0, 1.0);
}

enum EffectKind { explosion, fizzle, scorePopup, spawnFlash, strike }

/// View-only effect state derived from [GameEvent]s. Has no influence on gameplay.
class WizardEffects {
  final List<WorldEffect> effects = [];

  /// 1 right after a successful cast gesture, fading (hand orb flash).
  double castFlash = 0;

  /// 1 right after losing a life, fading (red vignette + shake).
  double damage = 0;

  /// Index of the most recently lost heart, for a pulse in the HUD.
  int? lostHeart;
  double heartPulse = 0;
  int _seed = 0;

  void onCast() => castFlash = 1;

  void consume(List<GameEvent> events) {
    for (final e in events) {
      switch (e) {
        case FireballImpact(:final x, :final z, :final elevation, :final enemy, :final defeated):
          effects.add(WorldEffect(
            kind: enemy == null ? EffectKind.fizzle : EffectKind.explosion,
            x: x,
            z: z,
            elevation: elevation,
            duration: defeated ? 0.6 : 0.4,
            seed: _seed++,
          ));
        case EnemyDefeated(:final enemy, :final points):
          effects.add(WorldEffect(kind: EffectKind.scorePopup, x: enemy.x, z: enemy.z, elevation: enemy.spec.height + 0.4, duration: 1.0, text: '+$points'));
        case EnemySpawned(:final enemy):
          effects.add(WorldEffect(kind: EffectKind.spawnFlash, x: enemy.x, z: enemy.z, elevation: 0, duration: 0.5));
        case PlayerHit(:final lifeLost, :final livesLeft, :final source):
          if (lifeLost) {
            damage = 1;
            lostHeart = livesLeft;
            heartPulse = 1;
          }
          if (source != EnemyKind.skeletonArcher) {
            effects.add(WorldEffect(kind: EffectKind.strike, x: 0, z: 1.2, elevation: 1.2, duration: 0.35));
          }
        case FireballLaunched() || ArrowFired() || GameEnded():
          break;
      }
    }
  }

  void update(double dt) {
    for (final e in effects) {
      e.age += dt;
    }
    effects.removeWhere((e) => e.age >= e.duration);
    castFlash = (castFlash - dt * 3).clamp(0.0, 1.0);
    damage = (damage - dt * 1.6).clamp(0.0, 1.0);
    heartPulse = (heartPulse - dt * 1.5).clamp(0.0, 1.0);
  }

  /// Enemies' death animation progress, 0..1.
  static double deathProgress(Enemy e) => e.state == EnemyState.defeated ? (e.stateTime / 0.6).clamp(0.0, 1.0) : 0;
}
