import '../../audio/audio_service.dart';
import 'enemies.dart';
import 'wizard_config.dart';
import 'wizard_game.dart';

/// Turns [GameEvent]s into positioned sounds. Positions are the enemies' game-world coordinates,
/// so direction and distance come from the same state the gameplay uses. Each event plays its
/// sound once (events are produced once per simulation outcome); [AudioService] additionally
/// suppresses rapid duplicates.
class WizardAudio {
  WizardAudio(this.audio);

  final AudioService audio;

  /// Staggered sounds (chain lightning links), as (dueAtSeconds, play).
  final List<(double, void Function())> _scheduled = [];
  double _time = 0;

  /// Seconds between successive chain-lightning zaps (matches the visual arc timing).
  static const double chainStep = 0.07;

  static String defeatSound(EnemyKind kind) => switch (kind) {
        EnemyKind.troll => Sounds.defeatTroll,
        EnemyKind.goblin => Sounds.defeatGoblin,
        EnemyKind.frog => Sounds.defeatFrog,
        EnemyKind.skeletonArcher => Sounds.defeatSkeleton,
        EnemyKind.slime => Sounds.defeatSlime,
      };

  void tick(double dt) {
    _time += dt;
    _scheduled.removeWhere((s) {
      if (s.$1 > _time) return false;
      s.$2();
      return true;
    });
  }

  void consume(List<GameEvent> events) {
    for (final e in events) {
      switch (e) {
        case FireballLaunched():
          audio.play(Sounds.fireballCast, x: -0.6, y: 1, z: 0.8);
        case FireballImpact(:final x, :final z, :final elevation, :final enemy):
          audio.play(enemy == null ? Sounds.fizzle : Sounds.fireballImpact, x: x, y: elevation, z: z);
        case EnemyDefeated(:final enemy):
          audio.play(defeatSound(enemy.kind), x: enemy.x, y: enemy.height * 0.6, z: enemy.z);
        case SlimeSplit(:final parent):
          audio.play(Sounds.slimeSplit, x: parent.x, y: 0.6, z: parent.z);
        case EnemySpawned(:final enemy):
          audio.play(Sounds.spawn, x: enemy.x, y: 1, z: enemy.z, gain: 0.7);
        case EnemyAttackStarted(:final enemy):
          audio.play(enemy is SkeletonArcher ? Sounds.bowDraw : Sounds.telegraph, x: enemy.x, y: enemy.height * 0.7, z: enemy.z);
        case ArrowFired(:final shooter):
          audio.play(Sounds.arrowRelease, x: shooter.x, y: 1.4, z: shooter.z);
        case PlayerHit(:final lifeLost):
          if (lifeLost) audio.play(Sounds.playerHurt, positional: false);
        case ChainLightningCast(:final hits, :final endX, :final endZ):
          audio.play(Sounds.lightningCast, x: -0.6, y: 1, z: 0.8);
          if (hits.isEmpty) {
            audio.play(Sounds.fizzle, x: endX, y: 1, z: endZ);
          }
          for (var i = 0; i < hits.length; i++) {
            final h = hits[i];
            final gain = 1.0 - 0.15 * i;
            _scheduled.add((_time + i * chainStep, () => audio.play(Sounds.zap, x: h.x, y: h.elevation, z: h.z, gain: gain)));
          }
        case SpellUnlocked():
          audio.play(Sounds.unlock, positional: false);
        case SpellSelected():
          audio.play(Sounds.spellSwitch, positional: false);
        case GameEnded():
          audio.play(Sounds.gameOver, positional: false);
      }
    }
  }
}
