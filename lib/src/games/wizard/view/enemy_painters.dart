import 'dart:math' as math;
import 'package:flutter/painting.dart';

import '../enemies.dart';
import '../wizard_config.dart';

/// Procedural vector art for each enemy type. [feet] is the screen point under the enemy on the
/// ground, [u] the pixels-per-world-unit at its distance. Everything is drawn relative to those
/// two values so enemies scale correctly with distance.
///
/// Shared look (v4): forms are filled with a light-from-upper-left gradient, get a dark outline
/// for a clear silhouette, a soft contact shadow, and a rim light on the shadow side. A hit
/// flashes the enemy white and knocks it back slightly; attacks squash/stretch the body.
/// [daylight] (0 night … 1 day) shifts the rim light from moonlit blue to warm sun.
void paintEnemy(Canvas canvas, Enemy e, Offset feet, double u, {required double opacity, required double death, double daylight = 0}) {
  final alpha = (opacity * (1 - death)).clamp(0.0, 1.0);
  if (alpha <= 0) return;
  final hitFlash = e.timeSinceDamage < 0.18 ? 1 - e.timeSinceDamage / 0.18 : 0.0;
  final knock = e.timeSinceDamage < 0.25 ? math.sin(e.timeSinceDamage / 0.25 * math.pi) * 0.12 * u : 0.0;
  final bounds = Rect.fromCenter(center: feet - Offset(0, e.height * 0.55 * u + e.elevation * u), width: e.height * 2.6 * u + 40, height: e.height * 1.6 * u + 40);

  canvas.save();
  if (hitFlash > 0) canvas.saveLayer(bounds, Paint());
  // Death: shrink toward the ground.
  if (death > 0) {
    canvas.translate(feet.dx, feet.dy);
    canvas.scale(1 - 0.4 * death, 1 - 0.7 * death);
    canvas.translate(-feet.dx, -feet.dy);
  }
  final elevated = feet - Offset(0, e.elevation * u) - Offset(0, knock);
  final look = _Look(alpha, daylight);
  switch (e) {
    case Troll():
      _troll(canvas, e, elevated, u, look);
    case Goblin():
      _goblin(canvas, e, elevated, u, look);
    case HoppingFrog():
      _frog(canvas, e, elevated, u, look);
    case SkeletonArcher():
      _archer(canvas, e, elevated, u, look);
    case SplittingSlime():
      _slime(canvas, e, elevated, u, look);
    case BoneLich():
      _lich(canvas, e, elevated, u, look);
    default:
      break;
  }
  if (hitFlash > 0) {
    canvas.drawRect(bounds, Paint()
      ..blendMode = BlendMode.srcATop
      ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.75 * hitFlash));
    canvas.restore();
  }
  if (death > 0) {
    final c = elevated - Offset(0, e.height * 0.5 * u);
    canvas.drawCircle(c, e.height * 0.6 * u, Paint()..color = const Color(0xFFFF9A3D).withValues(alpha: 0.5 * (1 - death)));
  }
  canvas.restore();

  // Melee wind-up telegraph: a pulsing red warning above the head with a filling ring.
  if (e.state == EnemyState.attacking && e is! SkeletonArcher && e is! BoneLich) {
    final p = e.attackProgress;
    // Stacked above the health bar (which sits just over the head), never on top of it.
    final top = elevated - Offset(0, (e.height + 0.25) * u + 30 + 0.5 * u);
    final pulse = 0.6 + 0.4 * math.sin(e.age * 18);
    canvas.drawCircle(top, (0.25 + 0.15 * p) * u, Paint()..color = const Color(0xFFFF3B3B).withValues(alpha: alpha * pulse));
    _progressRing(canvas, top, (0.34 + 0.15 * p) * u, p, const Color(0xFFFFD0D0), alpha);
    _bang(canvas, top, 0.22 * u, alpha);
  }
}

/// Lighting context for one enemy.
class _Look {
  _Look(this.a, this.daylight);
  final double a;
  final double daylight;

  Color get rim => Color.lerp(const Color(0xFF9FD8FF), const Color(0xFFFFE7B0), daylight)!;
  Color get outline => const Color(0xFF120A18);

  Paint fill(Color c) => Paint()..color = c.withValues(alpha: c.a * a);

  /// Body gradient: lit from the upper left.
  Paint shade(Rect r, Color base, {double light = 0.28, double dark = 0.38}) => Paint()
    ..shader = RadialGradient(
      center: const Alignment(-0.45, -0.55),
      radius: 1.05,
      colors: [
        Color.lerp(base, const Color(0xFFFFFFFF), light)!.withValues(alpha: a),
        base.withValues(alpha: a),
        Color.lerp(base, const Color(0xFF000000), dark)!.withValues(alpha: a),
      ],
      stops: const [0, 0.5, 1],
    ).createShader(r);

  Paint stroke(double width, {Color? color, double alpha = 0.85}) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round
    ..color = (color ?? outline).withValues(alpha: alpha * a);

  /// Thin rim light along the right (shadow) side of an oval/rounded shape.
  void rimLight(Canvas canvas, Rect r, double u) {
    canvas.drawArc(r.deflate(0.04 * u), -0.9, 1.5, false, stroke(math.max(1.0, 0.05 * u), color: rim, alpha: 0.55));
  }
}

void _progressRing(Canvas canvas, Offset c, double r, double p, Color color, double a) {
  canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, 2 * math.pi * p, false, Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(2, r * 0.18)
    ..strokeCap = StrokeCap.round
    ..color = color.withValues(alpha: a));
}

void _bang(Canvas canvas, Offset c, double s, double a) {
  final p = Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: a);
  canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: c - Offset(0, s * 0.25), width: s * 0.28, height: s * 0.9), Radius.circular(s * 0.14)), p);
  canvas.drawCircle(c + Offset(0, s * 0.45), s * 0.16, p);
}

/// Soft contact shadow (smaller and fainter when airborne).
void _shadow(Canvas canvas, Offset feet, double w, double u, double a, double elevation) {
  final shrink = 1 / (1 + elevation * 0.6);
  final rect = Rect.fromCenter(center: feet + Offset(0, elevation * u), width: w * u * shrink, height: w * 0.3 * u * shrink);
  canvas.drawOval(rect, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(0, 0, 0, 0.5 * a * shrink), const Color(0x00000000)]).createShader(rect));
}

void _eye(Canvas canvas, Offset c, double r, Color iris, _Look l, {double lookX = 0}) {
  canvas.drawCircle(c, r, l.fill(const Color(0xFFF7F1DE)));
  canvas.drawCircle(c + Offset(lookX * r * 0.3, r * 0.1), r * 0.55, l.fill(iris));
  canvas.drawCircle(c + Offset(lookX * r * 0.3, r * 0.1), r * 0.28, l.fill(const Color(0xFF0B0B10)));
  canvas.drawCircle(c + Offset(-r * 0.3, -r * 0.35), r * 0.22, l.fill(const Color(0xFFFFFFFF)));
}

void _troll(Canvas canvas, Enemy e, Offset f, double u, _Look l) {
  final windup = e.attackProgress;
  final bob = math.sin(e.age * 4) * 0.05 * u;
  final stride = e.state == EnemyState.approaching ? math.sin(e.age * 4) * 0.12 * u : 0.0;
  _shadow(canvas, f, 2.0, u, l.a, 0);
  const skin = Color(0xFF6E8A55), dark = Color(0xFF465A35);
  // Legs with feet.
  for (final (dx, s) in [(-0.38, 1.0), (0.38, -1.0)]) {
    final leg = Rect.fromLTWH(f.dx + (dx - 0.22) * u, f.dy - 0.85 * u - stride * s, 0.44 * u, 0.85 * u + stride * s);
    canvas.drawRRect(RRect.fromRectAndRadius(leg, Radius.circular(0.15 * u)), l.shade(leg, dark));
    final foot = Rect.fromCenter(center: Offset(leg.center.dx, f.dy - 0.06 * u), width: 0.62 * u, height: 0.2 * u);
    canvas.drawOval(foot, l.fill(const Color(0xFF3A4A2C)));
  }
  // Body leans forward and squashes during the wind-up.
  final squash = 1 + 0.08 * windup;
  final body = Rect.fromCenter(center: f - Offset(0, 1.45 * u - bob), width: 1.75 * u * squash, height: 1.45 * u / squash);
  final bodyR = RRect.fromRectAndRadius(body, Radius.circular(0.6 * u));
  canvas.drawRRect(bodyR, l.shade(body, skin));
  canvas.drawOval(Rect.fromCenter(center: body.center + Offset(0, 0.22 * u), width: 1.0 * u, height: 0.8 * u), l.shade(body, const Color(0xFF8FA873), light: 0.2, dark: 0.15));
  canvas.drawRRect(bodyR, l.stroke(math.max(1, 0.05 * u)));
  l.rimLight(canvas, body, u);
  // Loincloth with a belt.
  final cloth = Rect.fromLTWH(body.left + 0.3 * u, body.bottom - 0.28 * u, 1.15 * u, 0.4 * u);
  canvas.drawRect(cloth, l.shade(cloth, const Color(0xFF5B3A22)));
  canvas.drawRect(Rect.fromLTWH(cloth.left - 0.05 * u, cloth.top, cloth.width + 0.1 * u, 0.1 * u), l.fill(const Color(0xFF2E1D10)));
  // Off arm.
  final offShoulder = body.topLeft + Offset(0.18 * u, 0.3 * u);
  canvas.drawLine(offShoulder, offShoulder + Offset(-0.35 * u, 0.75 * u), l.stroke(0.3 * u, color: dark, alpha: 1));
  // Head with brow, eyes, nose, tusks.
  final head = f - Offset(0, 2.45 * u - bob);
  final headRect = Rect.fromCircle(center: head, radius: 0.44 * u);
  canvas.drawOval(headRect, l.shade(headRect, skin));
  canvas.drawOval(headRect, l.stroke(math.max(1, 0.045 * u)));
  canvas.drawArc(Rect.fromCenter(center: head + Offset(0, -0.08 * u), width: 0.6 * u, height: 0.2 * u), math.pi, math.pi, false, l.stroke(0.07 * u, color: dark, alpha: 1));
  for (final s in [-1.0, 1.0]) {
    _eye(canvas, head + Offset(s * 0.15 * u, -0.02 * u), 0.075 * u, const Color(0xFFE0B020), l);
  }
  canvas.drawOval(Rect.fromCenter(center: head + Offset(0, 0.1 * u), width: 0.16 * u, height: 0.12 * u), l.fill(dark));
  for (final s in [-1.0, 1.0]) {
    final tusk = Path()
      ..moveTo(head.dx + s * 0.18 * u, head.dy + 0.18 * u)
      ..lineTo(head.dx + s * 0.26 * u, head.dy - 0.04 * u)
      ..lineTo(head.dx + s * 0.1 * u, head.dy + 0.22 * u)
      ..close();
    canvas.drawPath(tusk, l.fill(const Color(0xFFF5EBD0)));
  }
  // Club arm: swings back during the wind-up.
  final shoulder = body.topRight + Offset(-0.15 * u, 0.25 * u);
  final angle = -0.5 - windup * 1.6;
  final hand = shoulder + Offset(math.cos(angle) * 0.9 * u, math.sin(angle) * 0.9 * u);
  canvas.drawLine(shoulder, hand, l.stroke(0.34 * u, color: skin, alpha: 1));
  final clubEnd = hand + Offset(math.cos(angle - 1.2) * 1.0 * u, math.sin(angle - 1.2) * 1.0 * u);
  canvas.drawLine(hand, clubEnd, l.stroke(0.22 * u, color: const Color(0xFF7A4B2A), alpha: 1));
  final clubHead = Rect.fromCircle(center: clubEnd, radius: 0.26 * u);
  canvas.drawOval(clubHead, l.shade(clubHead, const Color(0xFF6A3F22)));
  for (var i = 0; i < 3; i++) {
    final a = i * 2.1 + 0.4;
    canvas.drawCircle(clubEnd + Offset(math.cos(a), math.sin(a)) * 0.2 * u, 0.05 * u, l.fill(const Color(0xFFD9D2C0)));
  }
}

void _goblin(Canvas canvas, Enemy e, Offset f, double u, _Look l) {
  final bob = (math.sin(e.age * 16)).abs() * 0.12 * u;
  _shadow(canvas, f, 1.05, u, l.a, 0);
  const skin = Color(0xFF63B84D);
  final stride = math.sin(e.age * 16) * 0.25 * u;
  final legPaint = l.stroke(0.16 * u, color: const Color(0xFF3F7A31), alpha: 1);
  canvas.drawLine(f - Offset(0, 0.55 * u), f + Offset(stride, 0), legPaint);
  canvas.drawLine(f - Offset(0, 0.55 * u), f + Offset(-stride, 0), legPaint);
  final body = Rect.fromCenter(center: f - Offset(0, 0.82 * u + bob), width: 0.72 * u, height: 0.62 * u);
  final bodyR = RRect.fromRectAndRadius(body, Radius.circular(0.25 * u));
  canvas.drawRRect(bodyR, l.shade(body, const Color(0xFF7B4A2A))); // tunic
  canvas.drawRect(Rect.fromLTWH(body.left, body.center.dy + 0.04 * u, body.width, 0.08 * u), l.fill(const Color(0xFF3A2414)));
  canvas.drawRRect(bodyR, l.stroke(math.max(1, 0.04 * u)));
  final head = f - Offset(0, 1.28 * u + bob);
  for (final s in [-1.0, 1.0]) {
    final ear = Path()
      ..moveTo(head.dx + s * 0.22 * u, head.dy - 0.05 * u)
      ..lineTo(head.dx + s * 0.64 * u, head.dy - 0.24 * u)
      ..lineTo(head.dx + s * 0.24 * u, head.dy + 0.1 * u)
      ..close();
    canvas.drawPath(ear, l.shade(Rect.fromCircle(center: head, radius: 0.6 * u), skin));
    canvas.drawPath(ear, l.stroke(math.max(1, 0.03 * u)));
    final inner = Path()
      ..moveTo(head.dx + s * 0.27 * u, head.dy - 0.03 * u)
      ..lineTo(head.dx + s * 0.52 * u, head.dy - 0.17 * u)
      ..lineTo(head.dx + s * 0.28 * u, head.dy + 0.05 * u)
      ..close();
    canvas.drawPath(inner, l.fill(const Color(0xFFB0596A)));
  }
  final headRect = Rect.fromCircle(center: head, radius: 0.31 * u);
  canvas.drawOval(headRect, l.shade(headRect, skin));
  canvas.drawOval(headRect, l.stroke(math.max(1, 0.035 * u)));
  l.rimLight(canvas, headRect, u);
  for (final s in [-1.0, 1.0]) {
    _eye(canvas, head + Offset(s * 0.11 * u, -0.03 * u), 0.065 * u, const Color(0xFFFF3030), l);
  }
  canvas.drawArc(Rect.fromCenter(center: head + Offset(0, 0.13 * u), width: 0.24 * u, height: 0.1 * u), 0.2, math.pi - 0.4, false, l.stroke(0.03 * u));
  // Dagger: raised during the wind-up.
  final raise = e.attackProgress;
  final handPos = body.centerRight + Offset(0.1 * u, -raise * 0.3 * u);
  final tip = handPos + Offset(0.25 * u, -0.45 * u - raise * 0.15 * u);
  canvas.drawLine(handPos, tip, l.stroke(0.09 * u, color: const Color(0xFFD8DEE8), alpha: 1));
  canvas.drawLine(handPos + Offset(-0.06 * u, 0.04 * u), handPos + Offset(0.08 * u, -0.06 * u), l.stroke(0.05 * u, color: const Color(0xFF5A3A22), alpha: 1));
}

void _frog(Canvas canvas, HoppingFrog e, Offset f, double u, _Look l) {
  final ground = f + Offset(0, e.elevation * u);
  _shadow(canvas, ground, 1.35, u, l.a, e.elevation);
  final airborne = e.elevation > 0.02;
  final squash = airborne ? 0.85 : 1.15;
  final body = Rect.fromCenter(center: f - Offset(0, 0.4 * u), width: 1.3 * u * squash, height: 0.75 * u / squash);
  // Back legs stretch out while airborne.
  final legPaint = l.stroke(0.2 * u, color: const Color(0xFF2F8F4C), alpha: 1);
  for (final s in [-1.0, 1.0]) {
    final hip = body.center + Offset(s * 0.45 * u, 0.15 * u);
    final knee = hip + Offset(s * (airborne ? 0.55 : 0.35) * u, airborne ? 0.5 * u : 0.22 * u);
    canvas.drawLine(hip, knee, legPaint);
    canvas.drawOval(Rect.fromCenter(center: knee + Offset(s * 0.08 * u, 0.04 * u), width: 0.32 * u, height: 0.12 * u), l.fill(const Color(0xFF247A3E)));
  }
  canvas.drawOval(body, l.shade(body, const Color(0xFF45C268)));
  canvas.drawOval(Rect.fromCenter(center: body.center + Offset(0, 0.16 * u), width: body.width * 0.6, height: body.height * 0.45), l.shade(body, const Color(0xFFE8E070), light: 0.15, dark: 0.1));
  for (final (dx, dy, r) in [(-0.3, -0.05, 0.07), (0.22, -0.12, 0.05), (0.35, 0.05, 0.06)]) {
    canvas.drawCircle(body.center + Offset(dx * u, dy * u), r * u, l.fill(const Color(0xFF2F8F4C)));
  }
  canvas.drawOval(body, l.stroke(math.max(1, 0.04 * u)));
  l.rimLight(canvas, body, u);
  for (final s in [-1.0, 1.0]) {
    final eye = Offset(body.center.dx + s * 0.32 * u, body.top + 0.02 * u);
    final socket = Rect.fromCircle(center: eye, radius: 0.21 * u);
    canvas.drawOval(socket, l.shade(socket, const Color(0xFF45C268)));
    _eye(canvas, eye, 0.14 * u, const Color(0xFFE0A020), l);
  }
  canvas.drawArc(Rect.fromCenter(center: body.center + Offset(0, -0.02 * u), width: 0.6 * u, height: 0.25 * u), 0.2, math.pi - 0.4, false, l.stroke(0.05 * u, color: const Color(0xFF1C5A2E), alpha: 1));
}

void _archer(Canvas canvas, SkeletonArcher e, Offset f, double u, _Look l) {
  _shadow(canvas, f, 1.15, u, l.a, 0);
  const bone = Color(0xFFE9E4D4), boneDark = Color(0xFFA79F8A);
  final outline = l.stroke(0.15 * u, alpha: 0.7);
  final bonePaint = l.stroke(0.1 * u, color: bone, alpha: 1);
  final walking = e.state == EnemyState.approaching || e.phase == ArcherPhase.reposition;
  final sway = walking ? math.sin(e.age * 6) * 0.08 * u : 0.0;
  final draw = e.drawProgress;
  final hip = f - Offset(0, 0.9 * u);
  for (final s in [-1.0, 1.0]) {
    final foot = f + Offset(s * (0.25 * u) + s * sway, 0);
    canvas.drawLine(hip, foot, outline);
    canvas.drawLine(hip, foot, bonePaint);
    canvas.drawCircle(Offset.lerp(hip, foot, 0.5)!, 0.07 * u, l.fill(bone));
  }
  // Pelvis.
  canvas.drawOval(Rect.fromCenter(center: hip, width: 0.45 * u, height: 0.2 * u), l.shade(Rect.fromCenter(center: hip, width: 0.45 * u, height: 0.2 * u), bone));
  final neck = f - Offset(0, 1.75 * u);
  canvas.drawLine(hip, neck, outline);
  canvas.drawLine(hip, neck, bonePaint);
  for (var i = 0; i < 3; i++) {
    final y = neck.dy + (0.18 + i * 0.18) * u;
    final rib = Rect.fromCenter(center: Offset(neck.dx, y), width: (0.72 - i * 0.1) * u, height: 0.25 * u);
    canvas.drawArc(rib, 0, math.pi, false, outline);
    canvas.drawArc(rib, 0, math.pi, false, l.stroke(0.08 * u, color: i == 2 ? boneDark : bone, alpha: 1));
  }
  // Quiver on the back.
  final quiver = Rect.fromCenter(center: neck + Offset(0.3 * u, 0.4 * u), width: 0.2 * u, height: 0.7 * u);
  canvas.drawRRect(RRect.fromRectAndRadius(quiver, Radius.circular(0.06 * u)), l.shade(quiver, const Color(0xFF6A4528)));
  for (var i = 0; i < 3; i++) {
    canvas.drawLine(Offset(quiver.left + 0.05 * u + i * 0.05 * u, quiver.top), Offset(quiver.left + i * 0.06 * u, quiver.top - 0.2 * u), l.stroke(0.03 * u, color: const Color(0xFFB0B8C8), alpha: 1));
  }
  // Skull with jaw and glowing eye sockets (brighter while drawing).
  final skull = neck - Offset(0, 0.3 * u);
  final skullRect = Rect.fromCircle(center: skull, radius: 0.28 * u);
  canvas.drawOval(skullRect, l.shade(skullRect, bone, light: 0.25, dark: 0.3));
  canvas.drawOval(skullRect, l.stroke(math.max(1, 0.035 * u)));
  canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: skull + Offset(0, 0.25 * u), width: 0.3 * u, height: 0.12 * u), Radius.circular(0.04 * u)), l.fill(boneDark));
  final glow = 0.5 + 0.5 * draw;
  for (final s in [-1.0, 1.0]) {
    final socket = skull + Offset(s * 0.1 * u, -0.02 * u);
    canvas.drawCircle(socket, 0.075 * u, l.fill(const Color(0xFF1A1A2E)));
    canvas.drawCircle(socket, 0.13 * u * glow, Paint()..shader = RadialGradient(colors: [const Color(0xFF6CF2FF).withValues(alpha: 0.5 * l.a * glow), const Color(0x006CF2FF)]).createShader(Rect.fromCircle(center: socket, radius: 0.13 * u)));
    canvas.drawCircle(socket, 0.035 * u, l.fill(Color.lerp(const Color(0xFF6CF2FF), const Color(0xFFFF4040), draw)!));
  }
  // Bow on the left, string pulled back by the draw.
  final bowCenter = neck + Offset(-0.55 * u, 0.35 * u);
  final bowRect = Rect.fromCenter(center: bowCenter, width: 0.5 * u, height: 1.3 * u);
  canvas.drawArc(bowRect, math.pi / 2, math.pi, false, l.stroke(0.14 * u, alpha: 0.6));
  canvas.drawArc(bowRect, math.pi / 2, math.pi, false, l.stroke(0.09 * u, color: const Color(0xFF8A5A2B), alpha: 1));
  final pull = draw * 0.45 * u;
  final top = Offset(bowCenter.dx, bowRect.top), bottom = Offset(bowCenter.dx, bowRect.bottom);
  final nock = Offset(bowCenter.dx + pull, bowCenter.dy);
  final string = l.stroke(0.03 * u, color: const Color(0xFFDDDDDD), alpha: 1);
  canvas.drawLine(top, nock, string);
  canvas.drawLine(nock, bottom, string);
  canvas.drawLine(neck + Offset(0, 0.2 * u), nock, l.stroke(0.08 * u, color: bone, alpha: 1));
  if (draw > 0) {
    canvas.drawLine(nock, nock - Offset(0.85 * u, 0), l.stroke(0.05 * u, color: const Color(0xFFB0B8C8), alpha: 1));
    final head = nock - Offset(0.85 * u, 0);
    canvas.drawCircle(head, 0.22 * u * draw, Paint()..shader = RadialGradient(colors: [const Color(0xFFFF4040).withValues(alpha: 0.8 * l.a * draw), const Color(0x00FF4040)]).createShader(Rect.fromCircle(center: head, radius: 0.22 * u)));
    canvas.drawCircle(head, 0.08 * u, l.fill(const Color(0xFFFF4040)));
  }
}

void _slime(Canvas canvas, SplittingSlime e, Offset f, double u, _Look l) {
  final s = e.scale;
  final squish = e.squish; // 0..1 ooze cycle
  final w = (1.5 + 0.25 * squish) * s * u;
  final h = (1.25 - 0.25 * squish) * s * u;
  _shadow(canvas, f, 1.55 * s, u, l.a, 0);
  final body = Rect.fromLTWH(f.dx - w / 2, f.dy - h, w, h);
  final path = Path()
    ..moveTo(body.left, body.bottom)
    ..cubicTo(body.left - w * 0.05, body.top + h * 0.35, body.left + w * 0.15, body.top, body.center.dx, body.top)
    ..cubicTo(body.right - w * 0.15, body.top, body.right + w * 0.05, body.top + h * 0.35, body.right, body.bottom)
    ..close();
  // Smaller generations glow brighter so they read as "split" children.
  final tint = Color.lerp(const Color(0xFF3BC46B), const Color(0xFF9BFFB8), e.generation * 0.5)!;
  canvas.drawPath(path, Paint()..shader = RadialGradient(center: const Alignment(-0.3, -0.4), colors: [Color.lerp(tint, const Color(0xFFFFFFFF), 0.2)!.withValues(alpha: 0.95 * l.a), tint.withValues(alpha: 0.9 * l.a), const Color(0xFF145C33).withValues(alpha: 0.9 * l.a)], stops: const [0, 0.55, 1]).createShader(body));
  // Translucent depth: nucleus and drifting bubbles inside.
  canvas.drawCircle(body.center + Offset(0, h * 0.12), w * 0.14, l.fill(const Color(0xFF145C33).withValues(alpha: 0.6)));
  for (var i = 0; i < 3; i++) {
    final t = (e.age * 0.4 + i / 3) % 1;
    canvas.drawCircle(Offset(body.left + w * (0.3 + 0.2 * i), body.bottom - h * (0.15 + 0.6 * t)), w * 0.03, l.fill(const Color(0xFFFFFFFF).withValues(alpha: 0.35 * (1 - t))));
  }
  canvas.drawPath(path, l.stroke(math.max(1, 0.04 * u * s), color: const Color(0xFF0E3A20)));
  canvas.drawOval(Rect.fromCenter(center: body.topCenter + Offset(-w * 0.18, h * 0.22), width: w * 0.22, height: h * 0.14), l.fill(const Color(0xFFFFFFFF).withValues(alpha: 0.5)));
  l.rimLight(canvas, body, u);
  for (final dx in [-0.17, 0.17]) {
    final eye = Offset(body.center.dx + dx * w, body.top + h * 0.4);
    _eye(canvas, eye, w * 0.075, const Color(0xFF0E2A18), l);
  }
}

/// The night boss: a hovering, robed lich with a crowned skull, skeletal hands and a soul orb
/// that swells while it charges a volley.
void _lich(Canvas canvas, BoneLich e, Offset f, double u, _Look l) {
  final charge = e.chargeProgress;
  final ground = f + Offset(0, e.elevation * u);
  _shadow(canvas, ground, 2.6, u, l.a * 0.8, e.elevation);
  // Aura.
  final auraC = f - Offset(0, 1.9 * u);
  final auraR = (2.4 + 0.6 * charge + 0.15 * math.sin(e.age * 3)) * u;
  canvas.drawCircle(auraC, auraR, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(155, 255, 184, 0.22 * l.a * (0.6 + charge)), const Color(0x009BFFB8)]).createShader(Rect.fromCircle(center: auraC, radius: auraR)));
  // Tattered robe: wide at the hem, ragged edge flutters.
  final hemY = f.dy - 0.15 * u;
  final robe = Path()..moveTo(f.dx - 0.55 * u, f.dy - 2.9 * u);
  robe.quadraticBezierTo(f.dx - 1.4 * u, f.dy - 1.4 * u, f.dx - 1.25 * u, hemY);
  const tatters = 7;
  for (var i = 0; i <= tatters; i++) {
    final x = f.dx - 1.25 * u + 2.5 * u * i / tatters;
    final drop = (i.isEven ? 0.35 : 0.0) * u + math.sin(e.age * 5 + i) * 0.08 * u;
    robe.lineTo(x, hemY + drop);
  }
  robe
    ..quadraticBezierTo(f.dx + 1.4 * u, f.dy - 1.4 * u, f.dx + 0.55 * u, f.dy - 2.9 * u)
    ..close();
  final robeRect = Rect.fromLTRB(f.dx - 1.4 * u, f.dy - 3.0 * u, f.dx + 1.4 * u, hemY + 0.4 * u);
  canvas.drawPath(robe, l.shade(robeRect, const Color(0xFF2A1B46), light: 0.18, dark: 0.55));
  canvas.drawPath(robe, l.stroke(math.max(1.2, 0.05 * u)));
  // Gold trim and a glowing sigil.
  canvas.drawLine(Offset(f.dx, f.dy - 2.8 * u), Offset(f.dx, hemY), l.stroke(0.06 * u, color: const Color(0xFFC9932E), alpha: 0.8));
  canvas.drawCircle(Offset(f.dx, f.dy - 1.7 * u), 0.22 * u, l.stroke(0.05 * u, color: const Color(0xFF9BFFB8), alpha: 0.6 + 0.4 * charge));
  // Hood and skull.
  final skull = f - Offset(0, 3.2 * u);
  final hood = Rect.fromCenter(center: skull + Offset(0, 0.05 * u), width: 1.15 * u, height: 1.2 * u);
  canvas.drawOval(hood, l.shade(hood, const Color(0xFF1E1236), light: 0.1, dark: 0.6));
  final skullRect = Rect.fromCircle(center: skull, radius: 0.36 * u);
  canvas.drawOval(skullRect, l.shade(skullRect, const Color(0xFFE6E0CC), light: 0.25, dark: 0.35));
  canvas.drawOval(skullRect, l.stroke(math.max(1, 0.04 * u)));
  for (final s in [-1.0, 1.0]) {
    final socket = skull + Offset(s * 0.13 * u, -0.02 * u);
    canvas.drawCircle(socket, 0.1 * u, l.fill(const Color(0xFF0B0716)));
    final eyeGlow = 0.6 + 0.4 * charge;
    canvas.drawCircle(socket, 0.2 * u, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(155, 255, 184, 0.7 * l.a * eyeGlow), const Color(0x009BFFB8)]).createShader(Rect.fromCircle(center: socket, radius: 0.2 * u)));
    canvas.drawCircle(socket, 0.045 * u, l.fill(const Color(0xFFD8FFE6)));
  }
  canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: skull + Offset(0, 0.3 * u), width: 0.34 * u, height: 0.12 * u), Radius.circular(0.04 * u)), l.fill(const Color(0xFFB5AE98)));
  // Crown.
  final crown = Path()..moveTo(skull.dx - 0.34 * u, skull.dy - 0.22 * u);
  for (var i = 0; i <= 4; i++) {
    final x = skull.dx - 0.34 * u + 0.68 * u * i / 4;
    crown.lineTo(x - 0.085 * u, skull.dy - 0.32 * u);
    crown.lineTo(x, skull.dy - (i.isEven ? 0.62 : 0.48) * u);
  }
  crown
    ..lineTo(skull.dx + 0.34 * u, skull.dy - 0.22 * u)
    ..close();
  canvas.drawPath(crown, l.shade(Rect.fromCenter(center: skull - Offset(0, 0.4 * u), width: 0.7 * u, height: 0.45 * u), const Color(0xFFD9A93A)));
  canvas.drawPath(crown, l.stroke(math.max(1, 0.03 * u)));
  // Skeletal hands raised around the soul orb; the orb swells while charging.
  final orb = f - Offset(0, 2.0 * u) + Offset(0, -0.4 * u * charge);
  for (final s in [-1.0, 1.0]) {
    final wrist = Offset(f.dx + s * 0.95 * u, f.dy - 1.7 * u);
    final hand = Offset.lerp(wrist, orb + Offset(s * 0.45 * u, 0), 0.6 + 0.3 * charge)!;
    canvas.drawLine(wrist, hand, l.stroke(0.12 * u, color: const Color(0xFFE6E0CC), alpha: 1));
    for (var k = -1; k <= 1; k++) {
      canvas.drawLine(hand, hand + Offset(-s * 0.18 * u, k * 0.1 * u - 0.08 * u), l.stroke(0.05 * u, color: const Color(0xFFE6E0CC), alpha: 1));
    }
  }
  final orbR = (0.28 + 0.35 * charge + 0.04 * math.sin(e.age * 9)) * u;
  canvas.drawCircle(orb, orbR * 2.2, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(155, 255, 184, 0.45 * l.a), const Color(0x009BFFB8)]).createShader(Rect.fromCircle(center: orb, radius: orbR * 2.2)));
  canvas.drawCircle(orb, orbR, Paint()..shader = RadialGradient(colors: [const Color(0xFFFFFFFF).withValues(alpha: l.a), const Color(0xFF9BFFB8).withValues(alpha: l.a), const Color(0xFF2E8F5A).withValues(alpha: l.a)], stops: const [0, 0.45, 1]).createShader(Rect.fromCircle(center: orb, radius: orbR)));
  if (charge > 0) _progressRing(canvas, orb, orbR + 0.25 * u, charge, const Color(0xFFD8FFE6), l.a);
}

/// Screen point just above an enemy's head (anchor for the health bar and telegraph icons).
Offset headAnchor(Enemy e, Offset feet, double u) => feet - Offset(0, (e.elevation + e.height + (e.kind == EnemyKind.boss ? 0.8 : 0.25)) * u);
