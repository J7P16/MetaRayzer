import 'dart:math' as math;
import 'dart:ui';

import '../enemies.dart';
import '../wizard_config.dart';

/// Procedural vector art for each enemy type. [feet] is the screen point under the enemy on the
/// ground, [u] the pixels-per-world-unit at its distance. Everything is drawn relative to those
/// two values so enemies scale correctly with distance.
void paintEnemy(Canvas canvas, Enemy e, Offset feet, double u, {required double opacity, required double death}) {
  final alpha = (opacity * (1 - death)).clamp(0.0, 1.0);
  if (alpha <= 0) return;
  canvas.save();
  // Death: shrink toward the ground and flare orange.
  if (death > 0) {
    canvas.translate(feet.dx, feet.dy);
    canvas.scale(1 - 0.4 * death, 1 - 0.7 * death);
    canvas.translate(-feet.dx, -feet.dy);
  }
  final elevated = feet - Offset(0, e.elevation * u);
  switch (e.kind) {
    case EnemyKind.troll:
      _troll(canvas, e, elevated, u, alpha);
    case EnemyKind.goblin:
      _goblin(canvas, e, elevated, u, alpha);
    case EnemyKind.frog:
      _frog(canvas, e, elevated, u, alpha);
    case EnemyKind.skeletonArcher:
      _archer(canvas, e as SkeletonArcher, elevated, u, alpha);
  }
  if (death > 0) {
    final c = elevated - Offset(0, e.spec.height * 0.5 * u);
    canvas.drawCircle(c, e.spec.height * 0.6 * u, Paint()..color = const Color(0xFFFF9A3D).withValues(alpha: 0.5 * (1 - death)));
  }
  canvas.restore();

  // Melee wind-up telegraph: a pulsing red warning above the head.
  if (e.state == EnemyState.attacking && e.kind != EnemyKind.skeletonArcher) {
    final p = e.attackProgress;
    final top = elevated - Offset(0, (e.spec.height + 0.5) * u);
    final pulse = 0.6 + 0.4 * math.sin(e.age * 18);
    canvas.drawCircle(top, (0.25 + 0.15 * p) * u, Paint()..color = const Color(0xFFFF3B3B).withValues(alpha: alpha * pulse));
    _bang(canvas, top, 0.22 * u, alpha);
  }
}

Paint _fill(Color c, double a) => Paint()..color = c.withValues(alpha: c.a * a);

void _bang(Canvas canvas, Offset c, double s, double a) {
  final p = _fill(const Color(0xFFFFFFFF), a);
  canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: c - Offset(0, s * 0.25), width: s * 0.28, height: s * 0.9), Radius.circular(s * 0.14)), p);
  canvas.drawCircle(c + Offset(0, s * 0.45), s * 0.16, p);
}

void _shadow(Canvas canvas, Offset feet, double w, double u, double a, double elevation) {
  final shrink = 1 / (1 + elevation * 0.6);
  canvas.drawOval(Rect.fromCenter(center: feet + Offset(0, elevation * u), width: w * u * shrink, height: w * 0.28 * u * shrink), _fill(const Color(0xFF000000), 0.35 * a));
}

void _troll(Canvas canvas, Enemy e, Offset f, double u, double a) {
  final bob = math.sin(e.age * 4) * 0.05 * u;
  _shadow(canvas, f, 1.9, u, a, 0);
  final skin = const Color(0xFF6E8A55), dark = const Color(0xFF4A5E39);
  // Legs.
  for (final dx in [-0.38, 0.38]) {
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(f.dx + (dx - 0.22) * u, f.dy - 0.85 * u, 0.44 * u, 0.85 * u), Radius.circular(0.15 * u)), _fill(dark, a));
  }
  // Body.
  final body = Rect.fromCenter(center: f - Offset(0, 1.45 * u - bob), width: 1.7 * u, height: 1.4 * u);
  canvas.drawRRect(RRect.fromRectAndRadius(body, Radius.circular(0.55 * u)), _fill(skin, a));
  canvas.drawOval(Rect.fromCenter(center: body.center + Offset(0, 0.2 * u), width: 1.0 * u, height: 0.8 * u), _fill(const Color(0xFF8FA873), a));
  // Loincloth.
  canvas.drawRect(Rect.fromLTWH(body.left + 0.3 * u, body.bottom - 0.25 * u, 1.1 * u, 0.35 * u), _fill(const Color(0xFF5B3A22), a));
  // Head.
  final head = f - Offset(0, 2.4 * u - bob);
  canvas.drawCircle(head, 0.42 * u, _fill(skin, a));
  canvas.drawCircle(head + Offset(-0.15 * u, -0.05 * u), 0.07 * u, _fill(const Color(0xFFFFE066), a));
  canvas.drawCircle(head + Offset(0.15 * u, -0.05 * u), 0.07 * u, _fill(const Color(0xFFFFE066), a));
  for (final s in [-1.0, 1.0]) {
    final tusk = Path()
      ..moveTo(head.dx + s * 0.18 * u, head.dy + 0.15 * u)
      ..lineTo(head.dx + s * 0.25 * u, head.dy - 0.05 * u)
      ..lineTo(head.dx + s * 0.1 * u, head.dy + 0.2 * u)
      ..close();
    canvas.drawPath(tusk, _fill(const Color(0xFFF5EBD0), a));
  }
  // Club arm: swings back during the wind-up.
  final shoulder = body.topRight + Offset(-0.15 * u, 0.25 * u);
  final angle = -0.5 - e.attackProgress * 1.6;
  final hand = shoulder + Offset(math.cos(angle) * 0.9 * u, -math.sin(angle) * -0.9 * u);
  canvas.drawLine(shoulder, hand, _fill(skin, a)..strokeWidth = 0.32 * u..strokeCap = StrokeCap.round);
  final clubEnd = hand + Offset(math.cos(angle - 1.2) * 1.0 * u, math.sin(angle - 1.2) * 1.0 * u);
  canvas.drawLine(hand, clubEnd, _fill(const Color(0xFF7A4B2A), a)..strokeWidth = 0.22 * u..strokeCap = StrokeCap.round);
  canvas.drawCircle(clubEnd, 0.24 * u, _fill(const Color(0xFF6A3F22), a));
}

void _goblin(Canvas canvas, Enemy e, Offset f, double u, double a) {
  final bob = (math.sin(e.age * 16)).abs() * 0.12 * u;
  _shadow(canvas, f, 1.0, u, a, 0);
  final skin = const Color(0xFF63B84D);
  final stride = math.sin(e.age * 16) * 0.25 * u;
  final legPaint = _fill(const Color(0xFF3F7A31), a)..strokeWidth = 0.16 * u..strokeCap = StrokeCap.round;
  canvas.drawLine(f - Offset(0, 0.55 * u), f + Offset(stride, 0), legPaint);
  canvas.drawLine(f - Offset(0, 0.55 * u), f + Offset(-stride, 0), legPaint);
  final body = Rect.fromCenter(center: f - Offset(0, 0.8 * u + bob), width: 0.7 * u, height: 0.6 * u);
  canvas.drawRRect(RRect.fromRectAndRadius(body, Radius.circular(0.25 * u)), _fill(const Color(0xFF7B4A2A), a)); // tunic
  final head = f - Offset(0, 1.25 * u + bob);
  canvas.drawCircle(head, 0.3 * u, _fill(skin, a));
  for (final s in [-1.0, 1.0]) {
    final ear = Path()
      ..moveTo(head.dx + s * 0.22 * u, head.dy - 0.05 * u)
      ..lineTo(head.dx + s * 0.62 * u, head.dy - 0.22 * u)
      ..lineTo(head.dx + s * 0.24 * u, head.dy + 0.1 * u)
      ..close();
    canvas.drawPath(ear, _fill(skin, a));
    canvas.drawCircle(head + Offset(s * 0.11 * u, -0.03 * u), 0.06 * u, _fill(const Color(0xFFFF3030), a));
  }
  // Dagger.
  final handPos = body.centerRight + Offset(0.1 * u, 0);
  canvas.drawLine(handPos, handPos + Offset(0.25 * u, -0.45 * u), _fill(const Color(0xFFD8DEE8), a)..strokeWidth = 0.08 * u);
}

void _frog(Canvas canvas, Enemy e, Offset f, double u, double a) {
  final ground = f + Offset(0, e.elevation * u);
  _shadow(canvas, ground, 1.3, u, a, e.elevation);
  final airborne = e.elevation > 0.02;
  final squash = airborne ? 0.85 : 1.15;
  final body = Rect.fromCenter(center: f - Offset(0, 0.4 * u), width: 1.3 * u * squash, height: 0.75 * u / squash);
  // Back legs stretch out while airborne.
  final legPaint = _fill(const Color(0xFF2F8F4C), a)..strokeWidth = 0.18 * u..strokeCap = StrokeCap.round;
  for (final s in [-1.0, 1.0]) {
    final hip = body.center + Offset(s * 0.45 * u, 0.15 * u);
    canvas.drawLine(hip, hip + Offset(s * (airborne ? 0.55 : 0.35) * u, airborne ? 0.5 * u : 0.22 * u), legPaint);
  }
  canvas.drawOval(body, _fill(const Color(0xFF45C268), a));
  canvas.drawOval(Rect.fromCenter(center: body.center + Offset(0, 0.15 * u), width: body.width * 0.6, height: body.height * 0.45), _fill(const Color(0xFFE8E070), a));
  for (final s in [-1.0, 1.0]) {
    final eye = Offset(body.center.dx + s * 0.32 * u, body.top + 0.02 * u);
    canvas.drawCircle(eye, 0.2 * u, _fill(const Color(0xFF45C268), a));
    canvas.drawCircle(eye, 0.14 * u, _fill(const Color(0xFFFFFFFF), a));
    canvas.drawCircle(eye + Offset(0, 0.02 * u), 0.07 * u, _fill(const Color(0xFF111111), a));
  }
  canvas.drawArc(Rect.fromCenter(center: body.center + Offset(0, -0.02 * u), width: 0.6 * u, height: 0.25 * u), 0.2, math.pi - 0.4, false,
      _fill(const Color(0xFF1C5A2E), a)..style = PaintingStyle.stroke..strokeWidth = 0.05 * u);
}

void _archer(Canvas canvas, SkeletonArcher e, Offset f, double u, double a) {
  _shadow(canvas, f, 1.1, u, a, 0);
  const bone = Color(0xFFE9E4D4);
  final bonePaint = _fill(bone, a)..strokeWidth = 0.1 * u..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
  final sway = e.state == EnemyState.approaching ? math.sin(e.age * 5) * 0.08 * u : 0.0;
  final hip = f - Offset(0, 0.9 * u);
  canvas.drawLine(hip, f + Offset(-0.25 * u + sway, 0), bonePaint);
  canvas.drawLine(hip, f + Offset(0.25 * u - sway, 0), bonePaint);
  final neck = f - Offset(0, 1.75 * u);
  canvas.drawLine(hip, neck, bonePaint);
  for (var i = 0; i < 3; i++) {
    final y = neck.dy + (0.18 + i * 0.18) * u;
    canvas.drawArc(Rect.fromCenter(center: Offset(neck.dx, y), width: (0.7 - i * 0.1) * u, height: 0.25 * u), 0, math.pi, false, bonePaint);
  }
  final skull = neck - Offset(0, 0.3 * u);
  canvas.drawCircle(skull, 0.27 * u, _fill(bone, a));
  final glow = 0.5 + 0.5 * e.drawProgress;
  for (final s in [-1.0, 1.0]) {
    canvas.drawCircle(skull + Offset(s * 0.1 * u, -0.02 * u), 0.07 * u, _fill(const Color(0xFF1A1A2E), a));
    canvas.drawCircle(skull + Offset(s * 0.1 * u, -0.02 * u), 0.035 * u, _fill(const Color(0xFF6CF2FF), a * glow));
  }
  // Bow on the left, string pulled back by drawProgress.
  final bowCenter = neck + Offset(-0.55 * u, 0.35 * u);
  final bowRect = Rect.fromCenter(center: bowCenter, width: 0.5 * u, height: 1.3 * u);
  canvas.drawArc(bowRect, math.pi / 2, math.pi, false, _fill(const Color(0xFF8A5A2B), a)..style = PaintingStyle.stroke..strokeWidth = 0.09 * u);
  final pull = e.drawProgress * 0.45 * u;
  final top = Offset(bowCenter.dx, bowRect.top), bottom = Offset(bowCenter.dx, bowRect.bottom);
  final nock = Offset(bowCenter.dx + pull, bowCenter.dy);
  final string = _fill(const Color(0xFFDDDDDD), a)..strokeWidth = 0.03 * u;
  canvas.drawLine(top, nock, string);
  canvas.drawLine(nock, bottom, string);
  canvas.drawLine(neck + Offset(0, 0.2 * u), nock, bonePaint..strokeWidth = 0.08 * u);
  if (e.drawProgress > 0) {
    canvas.drawLine(nock, nock - Offset(0.85 * u, 0), _fill(const Color(0xFFB0B8C8), a)..strokeWidth = 0.05 * u);
    canvas.drawCircle(nock - Offset(0.85 * u, 0), 0.08 * u, _fill(const Color(0xFFFF4040), a * e.drawProgress));
  }
}
