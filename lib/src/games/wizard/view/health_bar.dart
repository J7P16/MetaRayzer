import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../enemies.dart';

/// What a health bar shows for one enemy. Pure data derived from the enemy's state, so the same
/// rules apply to every enemy type (regular, split slimes, skeletons, the boss) and can be
/// tested without rendering.
@immutable
class HealthBarModel {
  const HealthBarModel({required this.visible, required this.fraction, required this.trail, required this.segments, required this.damaged, required this.boss, required this.health, required this.maxHealth});

  /// Seconds the "just lost" chunk lingers before it drains into the bar.
  static const double trailSeconds = 0.6;

  /// Above this many points of health, segment marks are drawn every [segmentSize] points
  /// instead of every point, so big health pools stay readable.
  static const int maxSegments = 12;

  final bool visible;

  /// 0..1 remaining health.
  final double fraction;

  /// 0..1 health right before the latest hit, draining down to [fraction] (the damage trail).
  final double trail;

  /// Number of segment cells (each one or [segmentSize] points of health).
  final int segments;

  /// Below full health: drawn fully opaque with an empty, outlined remainder (not color alone).
  final bool damaged;
  final bool boss;
  final double health;
  final double maxHealth;

  static double segmentSize(double maxHealth) => maxHealth <= maxSegments ? 1 : (maxHealth / maxSegments).ceilToDouble();

  factory HealthBarModel.of(Enemy e) {
    final alive = e.isAlive;
    final max = e.maxHealth <= 0 ? 1.0 : e.maxHealth;
    final fraction = alive ? (e.health / max).clamp(0.0, 1.0) : 0.0;
    final drain = (e.timeSinceDamage / trailSeconds).clamp(0.0, 1.0);
    final before = (e.healthBeforeHit / max).clamp(0.0, 1.0);
    final trail = e.timeSinceDamage.isFinite ? math.max(fraction, before + (fraction - before) * drain) : fraction;
    return HealthBarModel(
      visible: alive && e.maxHealth > 0,
      fraction: fraction,
      trail: trail,
      segments: (max / segmentSize(max)).ceil().clamp(1, maxSegments),
      damaged: fraction < 1 - 1e-9,
      boss: e is BoneLich,
      health: alive ? e.health : 0,
      maxHealth: max,
    );
  }
}

/// Paints the compact bar above an enemy. [anchor] is the screen point just above its head and
/// [u] the pixels per world unit there; the bar is kept inside [viewport] so it is never clipped.
void paintEnemyHealthBar(Canvas canvas, HealthBarModel m, Offset anchor, double u, Size viewport, {double opacity = 1}) {
  if (!m.visible) return;
  final width = (u * 1.5).clamp(34.0, 120.0);
  final height = (u * 0.13).clamp(5.0, 9.0);
  final cx = anchor.dx.clamp(width / 2 + 4, viewport.width - width / 2 - 4);
  final cy = (anchor.dy - height - 6).clamp(height + 4, viewport.height - height - 4);
  final rect = Rect.fromCenter(center: Offset(cx, cy), width: width, height: height);
  // Full-health bars are quieter so a crowd stays readable; damaged ones are fully visible.
  final a = opacity * (m.damaged ? 1.0 : 0.6);
  _paintBar(canvas, rect, m, a, fill: const Color(0xFFE5484D), fillLight: const Color(0xFFFF8A80));
}

/// Paints the boss's large bar (top-center of the screen) with its name and numbers.
void paintBossHealthBar(Canvas canvas, HealthBarModel m, Size viewport, String name, {double opacity = 1, double charge = 0}) {
  if (!m.visible) return;
  final width = math.min(viewport.width * 0.5, 620.0);
  final rect = Rect.fromCenter(center: Offset(viewport.width / 2, 74), width: width, height: 16);
  final frame = rect.inflate(5);
  canvas.drawRRect(RRect.fromRectAndRadius(frame, const Radius.circular(8)), Paint()..color = const Color(0xCC0B0618).withValues(alpha: 0.8 * opacity));
  canvas.drawRRect(
    RRect.fromRectAndRadius(frame, const Radius.circular(8)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Color.lerp(const Color(0xFF9BFFB8), const Color(0xFFFFFFFF), charge)!.withValues(alpha: 0.85 * opacity),
  );
  _paintBar(canvas, rect, m, opacity, fill: const Color(0xFF3FD07A), fillLight: const Color(0xFFB6FFD0));
  final label = TextPainter(
    text: TextSpan(
      text: '${name.toUpperCase()}   ${m.health.ceil()} / ${m.maxHealth.round()}',
      style: TextStyle(fontFamily: 'Georgia', fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 2, color: const Color(0xFFE8FFF0).withValues(alpha: opacity), shadows: const [Shadow(color: Color(0xFF000000), blurRadius: 4)]),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  label.paint(canvas, Offset(rect.center.dx - label.width / 2, rect.top - label.height - 8));
}

void _paintBar(Canvas canvas, Rect rect, HealthBarModel m, double a, {required Color fill, required Color fillLight}) {
  final r = Radius.circular(rect.height / 2);
  // Empty track: dark with a light outline, so the missing part reads as "empty", not a color.
  canvas.drawRRect(RRect.fromRectAndRadius(rect.inflate(1.5), r), Paint()..color = const Color(0xFF000000).withValues(alpha: 0.65 * a));
  canvas.drawRRect(RRect.fromRectAndRadius(rect, r), Paint()..color = const Color(0xFF2A2233).withValues(alpha: 0.9 * a));
  // Damage trail: the chunk just lost, in white, draining down.
  if (m.trail > m.fraction + 1e-3) {
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(rect.left, rect.top, rect.width * m.trail, rect.height), r), Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.85 * a));
  }
  if (m.fraction > 0) {
    final filled = Rect.fromLTWH(rect.left, rect.top, rect.width * m.fraction, rect.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(filled, r),
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [fillLight.withValues(alpha: a), fill.withValues(alpha: a)]).createShader(filled),
    );
  }
  // Segment marks: one per point of health (or per segmentSize points for big pools).
  final tick = Paint()
    ..color = const Color(0xFF000000).withValues(alpha: 0.55 * a)
    ..strokeWidth = 1;
  for (var i = 1; i < m.segments; i++) {
    final x = rect.left + rect.width * i / m.segments;
    canvas.drawLine(Offset(x, rect.top + 1), Offset(x, rect.bottom - 1), tick);
  }
  canvas.drawRRect(
    RRect.fromRectAndRadius(rect, r),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.45 * a),
  );
}
