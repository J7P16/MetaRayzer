import 'dart:math' as math;
import 'dart:ui';

import '../enemies.dart';
import '../wizard_config.dart';
import '../wizard_game.dart';

/// A short-lived visual effect anchored in world space.
class WorldEffect {
  WorldEffect({required this.kind, required this.x, required this.z, required this.elevation, required this.duration, this.text, this.seed = 0, this.color});

  final EffectKind kind;
  final double x;
  final double z;
  final double elevation;
  final double duration;
  final String? text;
  final int seed;
  final Color? color;
  double age = 0;

  double get t => (age / duration).clamp(0.0, 1.0);
}

enum EffectKind { impact, defeat, fizzle, scorePopup, spawnFlash, strike, slimeSplat, lightningImpact }

/// A particle in world space (projected every frame, so it moves with the view).
class WorldParticle {
  WorldParticle({required this.x, required this.z, required this.elevation, required this.vx, required this.vz, required this.ve, required this.life, required this.size, required this.color, this.gravity = 0, this.drag = 0});
  double x, z, elevation, vx, vz, ve;
  final double life;
  final double size;
  final Color color;
  final double gravity;
  final double drag;
  double age = 0;
  double get t => (age / life).clamp(0.0, 1.0);
}

/// A particle in screen space (fireball trails, staff sparks).
class ScreenParticle {
  ScreenParticle({required this.position, required this.velocity, required this.life, required this.size, required this.color});
  Offset position;
  Offset velocity;
  final double life;
  final double size;
  final Color color;
  double age = 0;
  double get t => (age / life).clamp(0.0, 1.0);
}

/// One Chain Lightning cast being drawn: arcs appear link by link.
class LightningVisual {
  LightningVisual(this.cast, {required this.intensity});
  final ChainLightningCast cast;
  final double intensity;
  double age = 0;
  static const double duration = 0.55;
  static const double linkStep = 0.07; // same timing as the zap sounds
  double get t => (age / duration).clamp(0.0, 1.0);
}

/// View-only effect state derived from [GameEvent]s. It never touches the simulation, so visual
/// effects cannot apply damage or score.
class WizardEffects {
  WizardEffects({int seed = 7}) : _rng = math.Random(seed);

  final math.Random _rng;
  final List<WorldEffect> effects = [];
  final List<WorldParticle> particles = [];
  final List<ScreenParticle> screenParticles = [];
  final List<LightningVisual> lightning = [];

  static const int maxParticles = 450;

  /// 1 right after a successful cast gesture, fading (staff flash + recoil).
  double castFlash = 0;

  /// Color of the last cast (staff flash).
  Color castColor = const Color(0xFFFF8A3D);

  /// 1 right after losing a life, fading (red vignette + shake).
  double damage = 0;

  /// Brief full-scene flash (lightning).
  double skyFlash = 0;

  /// Index of the most recently lost heart, for a pulse in the HUD.
  int? lostHeart;
  double heartPulse = 0;

  /// Unlock banner: remaining seconds and spell id.
  double unlockBanner = 0;
  String? unlockedSpell;

  /// Spell switch toast.
  double switchToast = 0;
  String? switchedTo;
  int _seed = 0;

  void onCast(Color color) {
    castFlash = 1;
    castColor = color;
  }

  void consume(List<GameEvent> events) {
    for (final e in events) {
      switch (e) {
        case FireballImpact(:final x, :final z, :final elevation, :final enemy, :final defeated):
          if (enemy == null) {
            effects.add(WorldEffect(kind: EffectKind.fizzle, x: x, z: z, elevation: elevation, duration: 0.6, seed: _seed++));
            _burst(x, z, elevation, count: 10, speed: 1.5, life: 0.6, colors: const [Color(0xFF8A7F99), Color(0xFFB9A8D6)], size: 0.12, gravity: -0.6);
          } else {
            effects.add(WorldEffect(kind: EffectKind.impact, x: x, z: z, elevation: elevation, duration: 0.45, seed: _seed++));
            _burst(x, z, elevation, count: defeated ? 34 : 18, speed: defeated ? 6 : 4, life: 0.7, colors: const [Color(0xFFFFE08A), Color(0xFFFF9A3D), Color(0xFFFF5A1F)], size: 0.1, gravity: 5);
          }
        case EnemyDefeated(:final enemy, :final points):
          effects.add(WorldEffect(kind: EffectKind.defeat, x: enemy.x, z: enemy.z, elevation: enemy.height * 0.5 + enemy.elevation, duration: 0.9, seed: _seed++, color: _enemyColor(enemy.kind)));
          if (points > 0) {
            effects.add(WorldEffect(kind: EffectKind.scorePopup, x: enemy.x, z: enemy.z, elevation: enemy.height + 0.6, duration: 1.1, text: '+$points'));
          }
          // Rising soul wisps.
          for (var i = 0; i < 6; i++) {
            particles.add(WorldParticle(
              x: enemy.x + (_rng.nextDouble() - 0.5) * 0.6,
              z: enemy.z,
              elevation: enemy.height * 0.4,
              vx: (_rng.nextDouble() - 0.5) * 0.4,
              vz: 0,
              ve: 1.2 + _rng.nextDouble(),
              life: 1.0 + _rng.nextDouble() * 0.5,
              size: 0.18,
              color: const Color(0xFFCFF6FF),
              drag: 0.5,
            ));
          }
        case SlimeSplit(:final parent):
          effects.add(WorldEffect(kind: EffectKind.slimeSplat, x: parent.x, z: parent.z, elevation: 0.5, duration: 0.5, seed: _seed++));
          _burst(parent.x, parent.z, 0.6, count: 16, speed: 3, life: 0.6, colors: const [Color(0xFF7CF29A), Color(0xFF3BC46B)], size: 0.14, gravity: 8);
        case EnemySpawned(:final enemy):
          effects.add(WorldEffect(kind: EffectKind.spawnFlash, x: enemy.x, z: enemy.z, elevation: 0, duration: 0.6));
        case PlayerHit(:final lifeLost, :final livesLeft, :final source):
          if (lifeLost) {
            damage = 1;
            lostHeart = livesLeft;
            heartPulse = 1;
          }
          if (source != EnemyKind.skeletonArcher) {
            effects.add(WorldEffect(kind: EffectKind.strike, x: 0, z: 1.2, elevation: 1.2, duration: 0.35));
          }
        case ChainLightningCast(:final hits):
          lightning.add(LightningVisual(e, intensity: 1));
          skyFlash = 1;
          for (var i = 0; i < hits.length; i++) {
            final h = hits[i];
            effects.add(WorldEffect(kind: EffectKind.lightningImpact, x: h.x, z: h.z, elevation: h.elevation, duration: 0.45, seed: _seed++)..age = -i * LightningVisual.linkStep);
          }
        case SpellUnlocked(:final spellId):
          unlockBanner = 4.5;
          unlockedSpell = spellId;
        case SpellSelected(:final spellId):
          switchToast = 1.6;
          switchedTo = spellId;
        case FireballLaunched() || ArrowFired() || GameEnded() || EnemyAttackStarted():
          break;
      }
    }
  }

  static Color _enemyColor(EnemyKind k) => switch (k) {
        EnemyKind.troll => const Color(0xFF8FB86A),
        EnemyKind.goblin => const Color(0xFF7FD45F),
        EnemyKind.frog => const Color(0xFF55D27C),
        EnemyKind.skeletonArcher => const Color(0xFFE9E4D4),
        EnemyKind.slime => const Color(0xFF7CF29A),
      };

  void _burst(double x, double z, double elevation, {required int count, required double speed, required double life, required List<Color> colors, required double size, double gravity = 0}) {
    for (var i = 0; i < count; i++) {
      final a = _rng.nextDouble() * math.pi * 2;
      final up = _rng.nextDouble();
      final s = speed * (0.4 + _rng.nextDouble() * 0.8);
      particles.add(WorldParticle(
        x: x,
        z: z,
        elevation: elevation,
        vx: math.cos(a) * s,
        vz: math.sin(a) * s * 0.6,
        ve: up * s,
        life: life * (0.6 + _rng.nextDouble() * 0.6),
        size: size * (0.6 + _rng.nextDouble()),
        color: colors[_rng.nextInt(colors.length)],
        gravity: gravity,
        drag: 1.5,
      ));
    }
  }

  /// Fireball trail embers (screen space).
  void emitTrail(Offset at, double radius, {required double dt}) {
    final n = (dt * 90).round().clamp(1, 4);
    for (var i = 0; i < n; i++) {
      screenParticles.add(ScreenParticle(
        position: at + Offset((_rng.nextDouble() - 0.5) * radius, (_rng.nextDouble() - 0.5) * radius),
        velocity: Offset((_rng.nextDouble() - 0.5) * 40, -20 - _rng.nextDouble() * 50),
        life: 0.35 + _rng.nextDouble() * 0.35,
        size: 2 + _rng.nextDouble() * radius * 0.25,
        color: [const Color(0xFFFFE08A), const Color(0xFFFF9A3D), const Color(0xFFFF5A1F)][_rng.nextInt(3)],
      ));
    }
  }

  /// Sparks from the staff tip (casting, charging).
  void emitStaffSparks(Offset tip, Color color, {int count = 10, double speed = 160}) {
    for (var i = 0; i < count; i++) {
      final a = _rng.nextDouble() * math.pi * 2;
      screenParticles.add(ScreenParticle(
        position: tip,
        velocity: Offset(math.cos(a), math.sin(a)) * (speed * (0.3 + _rng.nextDouble())),
        life: 0.25 + _rng.nextDouble() * 0.3,
        size: 1.5 + _rng.nextDouble() * 2.5,
        color: color,
      ));
    }
  }

  void update(double dt) {
    for (final e in effects) {
      e.age += dt;
    }
    effects.removeWhere((e) => e.age >= e.duration);
    for (final p in particles) {
      p.age += dt;
      final damp = math.exp(-p.drag * dt);
      p.vx *= damp;
      p.vz *= damp;
      p.ve = p.ve * damp - p.gravity * dt;
      p.x += p.vx * dt;
      p.z += p.vz * dt;
      p.elevation = math.max(0, p.elevation + p.ve * dt);
    }
    particles.removeWhere((p) => p.age >= p.life);
    for (final p in screenParticles) {
      p.age += dt;
      p.position += p.velocity * dt;
      p.velocity *= math.exp(-2.5 * dt);
    }
    screenParticles.removeWhere((p) => p.age >= p.life);
    if (particles.length > maxParticles) particles.removeRange(0, particles.length - maxParticles);
    if (screenParticles.length > maxParticles) screenParticles.removeRange(0, screenParticles.length - maxParticles);
    for (final l in lightning) {
      l.age += dt;
    }
    lightning.removeWhere((l) => l.age >= LightningVisual.duration + l.cast.hits.length * LightningVisual.linkStep);
    castFlash = (castFlash - dt * 3).clamp(0.0, 1.0);
    damage = (damage - dt * 1.6).clamp(0.0, 1.0);
    heartPulse = (heartPulse - dt * 1.5).clamp(0.0, 1.0);
    skyFlash = (skyFlash - dt * 4).clamp(0.0, 1.0);
    unlockBanner = math.max(0, unlockBanner - dt);
    switchToast = math.max(0, switchToast - dt);
  }

  /// Enemies' death animation progress, 0..1.
  static double deathProgress(Enemy e) => e.state == EnemyState.defeated ? (e.stateTime / 0.6).clamp(0.0, 1.0) : 0;

  static String spellName(String id) => id == SpellIds.chainLightning ? 'Chain Lightning' : 'Fireball';
}
