import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../input/hand_input.dart';
import '../cast_gesture.dart';
import '../enemies.dart';
import '../wizard_game.dart';
import 'arena_projection.dart';
import 'effects.dart';
import 'enemy_painters.dart';

/// Everything the scene painter needs for one frame.
class WizardSceneState {
  WizardSceneState({required this.game, required this.effects});

  final WizardGame game;
  final WizardEffects effects;
  CastGestureFeedback gesture = CastGestureFeedback.initial;
  HandInputFrame hand = HandInputFrame.unavailable;
  bool simulated = false;

  /// Seconds since the screen opened (ambient animation).
  double time = 0;
}

/// Renders the arena, enemies, projectiles, effects and HUD. Repaints every ticker frame.
class WizardPainter extends CustomPainter {
  WizardPainter(this.s, {required Listenable repaint}) : super(repaint: repaint);

  final WizardSceneState s;

  static const _gold = Color(0xFFFFD27A);
  static const _ember = Color(0xFFFF8A3D);

  @override
  void paint(Canvas canvas, Size size) {
    final p = ArenaProjection(size);
    final game = s.game;
    final fx = s.effects;

    canvas.save();
    if (fx.damage > 0) {
      final shake = fx.damage * 10;
      canvas.translate(math.sin(s.time * 90) * shake, math.cos(s.time * 70) * shake * 0.6);
    }
    _paintSky(canvas, size, p);
    _paintGround(canvas, size, p);
    _paintRangeRunes(canvas, p);
    _paintTorches(canvas, p);

    // Enemies far → near; the next fireball's target gets a reticle.
    final targets = game.targetableEnemies();
    final nextTarget = targets.isEmpty ? null : targets.first;
    final sorted = List<Enemy>.of(game.enemies)..sort((a, b) => b.z.compareTo(a.z));
    for (final e in sorted) {
      final feet = p.project(e.x, e.z);
      final u = p.pixelsPerUnit(e.z);
      // Distant enemies emerge from the mist.
      final fog = ((e.z - 20) / (game.config.spawnDistance - 20)).clamp(0.0, 1.0);
      paintEnemy(canvas, e, feet, u, opacity: 1 - 0.55 * fog, death: WizardEffects.deathProgress(e));
      if (identical(e, nextTarget)) _paintReticle(canvas, feet - Offset(0, (e.elevation + e.spec.height * 0.5) * u), u * e.spec.height * 0.55);
    }

    for (final a in game.arrows) {
      _paintArrow(canvas, p, a);
    }
    for (final f in game.fireballs) {
      _paintFireball(canvas, size, p, f);
    }
    for (final e in fx.effects) {
      _paintEffect(canvas, p, e);
    }
    canvas.restore();

    _paintDamageVignette(canvas, size, fx.damage);
    _paintHandOrb(canvas, size);
    _paintHud(canvas, size);
    _paintBanners(canvas, size);
  }

  // ---------------------------------------------------------------- scenery

  void _paintSky(Canvas canvas, Size size, ArenaProjection p) {
    final sky = Rect.fromLTWH(-20, -20, size.width + 40, p.horizonY + 20);
    canvas.drawRect(
      sky,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0A0620), Color(0xFF2A1450), Color(0xFF6B2C5C)],
          stops: [0, 0.6, 1],
        ).createShader(sky),
    );
    final rng = math.Random(11);
    for (var i = 0; i < 120; i++) {
      final pt = Offset(rng.nextDouble() * size.width, rng.nextDouble() * p.horizonY * 0.9);
      final twinkle = 0.4 + 0.6 * (0.5 + 0.5 * math.sin(s.time * (1 + rng.nextDouble() * 2) + i));
      canvas.drawCircle(pt, 0.6 + rng.nextDouble(), Paint()..color = Colors.white.withValues(alpha: 0.6 * twinkle));
    }
    final moon = Offset(size.width * 0.78, p.horizonY * 0.35);
    canvas.drawCircle(moon, 70, Paint()..shader = RadialGradient(colors: [const Color(0x44FFE6B0), const Color(0x00FFE6B0)]).createShader(Rect.fromCircle(center: moon, radius: 70)));
    canvas.drawCircle(moon, 26, Paint()..color = const Color(0xFFFFF1D0));

    // Mountains at the horizon.
    for (final (seed, color, height) in [(5, const Color(0xFF26143F), 0.16), (9, const Color(0xFF1A0E2E), 0.09)]) {
      final r = math.Random(seed);
      final path = Path()..moveTo(-20, p.horizonY);
      var x = -20.0;
      while (x < size.width + 20) {
        x += 30 + r.nextDouble() * 70;
        path.lineTo(x, p.horizonY - size.height * height * (0.3 + r.nextDouble() * 0.7));
      }
      path
        ..lineTo(size.width + 20, p.horizonY + 2)
        ..lineTo(-20, p.horizonY + 2)
        ..close();
      canvas.drawPath(path, Paint()..color = color);
    }

    // The spawn portal: a swirling violet gate at the far end of the arena.
    final gate = p.project(0, s.game.config.spawnDistance, 1.6);
    final gu = p.pixelsPerUnit(s.game.config.spawnDistance);
    final gateRect = Rect.fromCenter(center: gate, width: 14 * gu, height: 4.2 * gu);
    canvas.drawOval(gateRect.inflate(gu * 2), Paint()..shader = RadialGradient(colors: [const Color(0x889B5CFF), const Color(0x009B5CFF)]).createShader(gateRect.inflate(gu * 2)));
    canvas.drawOval(gateRect, Paint()..color = const Color(0xFF1B0B33));
    for (var i = 0; i < 3; i++) {
      final phase = s.time * (0.8 + i * 0.3) + i;
      canvas.drawArc(gateRect.deflate(i * gu * 0.5), phase, math.pi * 1.2, false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, gu * 0.25)
        ..color = Color.lerp(const Color(0xFFB98CFF), const Color(0xFF6CF2FF), i / 2)!.withValues(alpha: 0.7));
    }
  }

  void _paintGround(Canvas canvas, Size size, ArenaProjection p) {
    final ground = Rect.fromLTWH(-20, p.horizonY, size.width + 40, size.height - p.horizonY + 20);
    canvas.drawRect(
      ground,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2B1F3A), Color(0xFF3B2C3A), Color(0xFF1E1724)],
          stops: [0, 0.35, 1],
        ).createShader(ground),
    );
    // Flagstone grid in perspective.
    final line = Paint()
      ..color = const Color(0x33B9A8D6)
      ..strokeWidth = 1;
    for (var x = -12.0; x <= 12; x += 2) {
      canvas.drawLine(p.project(x, 0.2), p.project(x, s.game.config.spawnDistance), line);
    }
    for (var z = 1.0; z < s.game.config.spawnDistance; z *= 1.35) {
      canvas.drawLine(p.project(-14, z), p.project(14, z), line);
    }
    // Mist band at the horizon.
    final mist = Rect.fromLTWH(-20, p.horizonY - 10, size.width + 40, size.height * 0.08);
    canvas.drawRect(mist, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x009B7FC0), Color(0x449B7FC0), Color(0x009B7FC0)]).createShader(mist));
  }

  /// Glowing rune line at the fireball's maximum range: enemies past it can't be hit yet.
  void _paintRangeRunes(Canvas canvas, ArenaProjection p) {
    final r = s.game.config.fireballRange;
    final pulse = 0.55 + 0.25 * math.sin(s.time * 2.5);
    final path = Path();
    for (var i = 0; i <= 40; i++) {
      final a = -0.55 + 1.1 * i / 40; // arc in front of the player
      final pt = p.project(math.sin(a) * r, math.cos(a) * r);
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = _ember.withValues(alpha: 0.18 * pulse)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = _ember.withValues(alpha: 0.75 * pulse));
    for (var i = 0; i <= 10; i++) {
      final a = -0.5 + i / 10;
      final pt = p.project(math.sin(a) * r, math.cos(a) * r);
      final rune = Path()
        ..moveTo(pt.dx, pt.dy - 5)
        ..lineTo(pt.dx + 3, pt.dy)
        ..lineTo(pt.dx, pt.dy + 5)
        ..lineTo(pt.dx - 3, pt.dy)
        ..close();
      canvas.drawPath(rune, Paint()..color = _gold.withValues(alpha: 0.8 * pulse));
    }
  }

  void _paintTorches(Canvas canvas, ArenaProjection p) {
    for (final (x, z) in [(-6.5, 9.0), (6.5, 9.0), (-8.0, 18.0), (8.0, 18.0)]) {
      final base = p.project(x, z);
      final u = p.pixelsPerUnit(z);
      final top = p.project(x, z, 2.4);
      canvas.drawLine(base, top, Paint()
        ..color = const Color(0xFF3A2A2A)
        ..strokeWidth = 0.25 * u);
      final flicker = 0.85 + 0.15 * math.sin(s.time * 13 + x);
      final flame = top - Offset(0, 0.35 * u);
      canvas.drawCircle(flame, 1.1 * u * flicker, Paint()..shader = RadialGradient(colors: [const Color(0x66FF9A3D), const Color(0x00FF9A3D)]).createShader(Rect.fromCircle(center: flame, radius: 1.1 * u)));
      canvas.drawOval(Rect.fromCenter(center: flame, width: 0.35 * u, height: 0.6 * u * flicker), Paint()..color = const Color(0xFFFFC266));
    }
  }

  // ---------------------------------------------------------------- actors

  void _paintReticle(Canvas canvas, Offset c, double r) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = _ember.withValues(alpha: 0.85);
    final spin = s.time * 1.5;
    for (var i = 0; i < 4; i++) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: math.max(r, 10)), spin + i * math.pi / 2, math.pi / 4, false, paint);
    }
  }

  void _paintArrow(Canvas canvas, ArenaProjection p, Arrow a) {
    // Arrows fly at chest height toward the camera; a glowing red tip makes them readable even
    // when small and far away.
    final d = math.sqrt(a.x * a.x + a.z * a.z);
    final back = d <= 1e-6 ? 1.0 : 1 + 1.6 / d;
    final head = p.project(a.x, a.z, 1.3);
    final tail = p.project(a.x * back, a.z * back, 1.3);
    final u = p.pixelsPerUnit(a.z);
    final w = math.max(3.0, 0.1 * u);
    canvas.drawLine(tail, head, Paint()
      ..color = const Color(0x55FF4040)
      ..strokeWidth = w * 4
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawLine(tail, head, Paint()
      ..color = const Color(0xFFE8DCC0)
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round);
    // Fletching.
    final dir = (head - tail) / math.max((head - tail).distance, 1e-6);
    final normal = Offset(-dir.dy, dir.dx);
    final fl = math.max(6.0, 0.25 * u);
    for (final s in [-1.0, 1.0]) {
      canvas.drawLine(tail, tail + dir * fl + normal * s * fl * 0.6, Paint()
        ..color = const Color(0xFFB03030)
        ..strokeWidth = w * 0.8);
    }
    canvas.drawCircle(head, math.max(5.0, 0.18 * u), Paint()..color = const Color(0xFFFF3B3B));
    // Pulsing warning ring: an arrow flying straight at you is foreshortened to a point.
    final pulse = 0.5 + 0.5 * math.sin(s.time * 14);
    canvas.drawCircle(head, math.max(12.0, 0.5 * u) * (1 + 0.25 * pulse), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = const Color(0xFFFF3B3B).withValues(alpha: 0.5 + 0.4 * pulse));
  }

  /// The casting hand position on screen (bottom-left, where the left hand is).
  Offset _handAnchor(Size size) => Offset(size.width * 0.12, size.height * 0.84);

  void _paintFireball(Canvas canvas, Size size, ArenaProjection p, Fireball f) {
    final t = f.progress;
    final start = _handAnchor(size);
    final end = p.project(f.toX, f.toZ, f.toElevation);
    // Screen-space arc from the hand to the target, eased so it feels thrown.
    final e = 1 - math.pow(1 - t, 2).toDouble();
    final pos = Offset.lerp(start, end, e)! - Offset(0, math.sin(t * math.pi) * size.height * 0.08);
    final radius = ui.lerpDouble(38, math.max(10, p.pixelsPerUnit(f.toZ) * 0.6), e)!;
    for (var i = 1; i <= 5; i++) {
      final te = 1 - math.pow(1 - math.max(0, t - i * 0.04), 2).toDouble();
      final tp = Offset.lerp(start, end, te)! - Offset(0, math.sin(math.max(0, t - i * 0.04) * math.pi) * size.height * 0.08);
      canvas.drawCircle(tp, radius * (1 - i * 0.15), Paint()..color = _ember.withValues(alpha: 0.18 * (1 - i / 6)));
    }
    canvas.drawCircle(pos, radius * 1.8, Paint()..shader = RadialGradient(colors: [const Color(0x99FF8A3D), const Color(0x00FF8A3D)]).createShader(Rect.fromCircle(center: pos, radius: radius * 1.8)));
    canvas.drawCircle(pos, radius, Paint()..shader = const RadialGradient(colors: [Color(0xFFFFF6D0), Color(0xFFFFB347), Color(0xFFE0451F)], stops: [0, 0.45, 1]).createShader(Rect.fromCircle(center: pos, radius: radius)));
  }

  void _paintEffect(Canvas canvas, ArenaProjection p, WorldEffect e) {
    final c = p.project(e.x, e.z, e.elevation);
    final u = p.pixelsPerUnit(e.z);
    final t = e.t;
    switch (e.kind) {
      case EffectKind.explosion:
        final r = (0.6 + 1.8 * t) * u;
        canvas.drawCircle(c, r, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(255, 240, 200, 1 - t), Color.fromRGBO(255, 120, 40, 0.8 * (1 - t)), const Color(0x00FF5020)]).createShader(Rect.fromCircle(center: c, radius: r)));
        final rng = math.Random(e.seed);
        for (var i = 0; i < 10; i++) {
          final a = rng.nextDouble() * math.pi * 2;
          final d = (0.5 + rng.nextDouble()) * 2.2 * u * t;
          canvas.drawCircle(c + Offset(math.cos(a) * d, math.sin(a) * d), math.max(1.5, 0.08 * u * (1 - t)), Paint()..color = _gold.withValues(alpha: 1 - t));
        }
      case EffectKind.fizzle:
        canvas.drawCircle(c, (0.3 + 0.8 * t) * u + 4, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFB9A8D6).withValues(alpha: 0.7 * (1 - t)));
      case EffectKind.scorePopup:
        _text(canvas, e.text ?? '', c - Offset(0, t * 40), 22, _gold.withValues(alpha: 1 - t * t), center: true);
      case EffectKind.spawnFlash:
        canvas.drawCircle(c - Offset(0, u), (0.5 + 1.5 * t) * u + 2, Paint()..color = const Color(0xFFB98CFF).withValues(alpha: 0.5 * (1 - t)));
      case EffectKind.strike:
        // A slash across the view for melee hits.
        final paint = Paint()
          ..color = const Color(0xFFFF4040).withValues(alpha: 1 - t)
          ..strokeWidth = 10
          ..strokeCap = StrokeCap.round;
        final w = p.size.width, h = p.size.height;
        canvas.drawLine(Offset(w * 0.3, h * 0.25), Offset(w * (0.3 + 0.4 * (t + 0.2)), h * (0.25 + 0.5 * (t + 0.2))), paint);
    }
  }

  // ---------------------------------------------------------------- HUD

  void _paintDamageVignette(Canvas canvas, Size size, double damage) {
    final low = s.game.lives == 1 ? 0.25 + 0.1 * math.sin(s.time * 4) : 0.0;
    final strength = math.max(damage * 0.75, low);
    if (strength <= 0) return;
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = RadialGradient(radius: 0.9, colors: [const Color(0x00FF0000), Color.fromRGBO(200, 0, 0, strength)], stops: const [0.55, 1]).createShader(rect));
  }

  /// Gesture feedback at the casting hand: subtle, bottom-left, never over the enemies.
  void _paintHandOrb(Canvas canvas, Size size) {
    final c = _handAnchor(size);
    final g = s.gesture;
    final flash = s.effects.castFlash;
    final (Color color, double intensity, String label) = switch (g.phase) {
      CastPhase.noHand => (const Color(0xFF8A84A0), 0.25, g.extendedDropout ? 'Hand not visible' : 'Looking for your hand…'),
      CastPhase.idle => (const Color(0xFFB98CFF), 0.4, 'Make a fist to ready a spell'),
      CastPhase.ready => (const Color(0xFF9FE6FF), 0.75, 'Ready: open your palm to cast'),
      CastPhase.charging => (Color.lerp(const Color(0xFF9FE6FF), _ember, g.charge)!, 0.75 + 0.25 * g.charge, 'Casting…'),
      CastPhase.spent => (_ember, 0.35, 'Close your fist to ready again'),
    };
    final r = 30.0 + 10 * (g.phase == CastPhase.charging ? g.charge : 0) + 14 * flash;
    canvas.drawCircle(c, r * 2.2, Paint()..shader = RadialGradient(colors: [color.withValues(alpha: 0.45 * intensity + 0.4 * flash), color.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: c, radius: r * 2.2)));
    canvas.drawCircle(c, r * 0.55, Paint()..color = Color.lerp(color, Colors.white, 0.5)!.withValues(alpha: 0.5 + 0.5 * intensity));
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = color.withValues(alpha: 0.9);
    if (g.phase == CastPhase.noHand) {
      // Dashed ring = no reliable hand.
      for (var i = 0; i < 8; i++) {
        canvas.drawArc(Rect.fromCircle(center: c, radius: r), i * math.pi / 4 + s.time, math.pi / 8, false, ring);
      }
    } else {
      canvas.drawCircle(c, r, ring);
      if (g.phase == CastPhase.charging) {
        canvas.drawArc(Rect.fromCircle(center: c, radius: r + 7), -math.pi / 2, 2 * math.pi * g.charge, false, ring..color = _ember..strokeWidth = 4);
      }
    }
    _text(canvas, label, c + Offset(-c.dx + 16, r + 18), 14, Colors.white.withValues(alpha: 0.85));
    if (s.hand.status == HandTrackingStatus.tracking) {
      // Raw per-frame pose, so the player can see what the camera thinks their hand is doing.
      _text(canvas, 'seen: ${s.hand.pose.name}', c + Offset(-c.dx + 16, r + 38), 11, color.withValues(alpha: 0.8));
    }
  }

  void _paintHud(Canvas canvas, Size size) {
    final game = s.game;
    _text(canvas, 'SCORE', const Offset(28, 22), 13, const Color(0xFFB9A8D6), letterSpacing: 3);
    _text(canvas, '${game.score}', const Offset(26, 38), 40, _gold, bold: true);
    final secs = game.elapsed.floor();
    _text(canvas, '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}  ·  ${game.enemiesDefeated} slain', const Offset(28, 88), 13, Colors.white.withValues(alpha: 0.6));

    // Lives as hearts, top-right.
    for (var i = 0; i < game.config.startingLives; i++) {
      final alive = i < game.lives;
      final pulse = (!alive && s.effects.lostHeart == i) ? s.effects.heartPulse : 0.0;
      final c = Offset(size.width - 40 - (game.config.startingLives - 1 - i) * 46, 44);
      _heart(canvas, c, 17 * (1 + 0.4 * pulse), alive ? const Color(0xFFFF4D6D) : const Color(0x55FFFFFF));
    }
    _text(canvas, 'Esc: leave run', Offset(size.width / 2, size.height - 24), 11, Colors.white.withValues(alpha: 0.35), center: true);
  }

  void _paintBanners(Canvas canvas, Size size) {
    final banners = <(String, Color)>[];
    if (s.simulated) banners.add(('SIMULATED HAND (dev) · mouse = hand, hold button/Space = fist', const Color(0xFFFFC857)));
    if (s.hand.status == HandTrackingStatus.unavailable && !s.simulated) {
      banners.add(('Hand tracking unavailable: ${s.hand.message ?? 'no camera'}', const Color(0xFFFF6B6B)));
    } else if (s.gesture.extendedDropout) {
      banners.add(("Can't see your hand. Raise your left hand into the glasses' view.", const Color(0xFFFF9F6B)));
    }
    var y = 18.0;
    for (final (text, color) in banners) {
      final tp = _layout(text, 14, Colors.black, bold: true);
      final rect = Rect.fromCenter(center: Offset(size.width / 2, y + 14), width: tp.width + 28, height: 28);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(8)), Paint()..color = color.withValues(alpha: 0.9));
      tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
      y += 36;
    }
  }

  void _heart(Canvas canvas, Offset c, double r, Color color) {
    final path = Path()
      ..moveTo(c.dx, c.dy + r * 0.9)
      ..cubicTo(c.dx - r * 1.6, c.dy - r * 0.1, c.dx - r * 0.7, c.dy - r * 1.2, c.dx, c.dy - r * 0.35)
      ..cubicTo(c.dx + r * 0.7, c.dy - r * 1.2, c.dx + r * 1.6, c.dy - r * 0.1, c.dx, c.dy + r * 0.9)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.black.withValues(alpha: 0.4));
  }

  TextPainter _layout(String text, double size, Color color, {bool bold = false, double letterSpacing = 0}) => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: 'Georgia',
            fontSize: size,
            color: color,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: letterSpacing,
            shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  void _text(Canvas canvas, String text, Offset at, double size, Color color, {bool bold = false, bool center = false, double letterSpacing = 0}) {
    final tp = _layout(text, size, color, bold: bold, letterSpacing: letterSpacing);
    tp.paint(canvas, center ? at - Offset(tp.width / 2, tp.height / 2) : at);
  }

  @override
  bool shouldRepaint(WizardPainter old) => true;
}
