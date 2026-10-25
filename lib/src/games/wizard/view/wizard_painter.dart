import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../input/hand_input.dart';
import '../../../input/head_pose.dart';
import '../aim.dart';
import '../cast_gesture.dart';
import '../day_night.dart';
import '../enemies.dart';
import '../shield.dart';
import '../wizard_config.dart';
import '../wizard_game.dart';
import 'arena_projection.dart';
import 'effects.dart';
import 'enemy_painters.dart';
import 'health_bar.dart';

/// Everything the scene painter needs for one frame.
class WizardSceneState {
  WizardSceneState({required this.game, required this.effects, required this.staff});

  final WizardGame game;
  final WizardEffects effects;
  final StaffAim staff;
  CastGestureFeedback gesture = CastGestureFeedback.initial;
  HandInputFrame hand = HandInputFrame.unavailable;
  HeadView head = HeadView.none;
  bool simulated = false;

  /// 0..1 how close the hand is to the shield's blocking pose (HUD hint).
  double shieldReadiness = 0;

  /// Draw the shield/day HUD chips (off for tutorial steps that don't use them).
  bool showShieldHud = true;

  /// Score, hearts, run clock and day-night chip (off in the tutorial, which has no run).
  bool showRunHud = true;

  /// Top of the warning banners (the tutorial moves them below its own top bar).
  double bannerTop = 18;

  /// Seconds since the screen opened (ambient animation).
  double time = 0;
}

const _fire = Color(0xFFFF8A3D);
const _lightningCyan = Color(0xFF7FE7FF);
const _gold = Color(0xFFFFD27A);

Color spellColor(String spell) => spell == SpellIds.chainLightning ? _lightningCyan : _fire;

/// Renders the arena, enemies, projectiles, effects, the staff and the HUD. Repaints every
/// ticker frame. Purely visual: reads game state, never changes it.
class WizardPainter extends CustomPainter {
  WizardPainter(this.s, {required Listenable repaint}) : super(repaint: repaint);

  final WizardSceneState s;

  @override
  void paint(Canvas canvas, Size size) {
    final game = s.game;
    final fx = s.effects;
    final p = ArenaProjection(size, yaw: s.head.yaw, pitch: s.head.pitch);
    final tip = _staffTip(size);

    canvas.save();
    if (fx.damage > 0) {
      final shake = fx.damage * 10;
      canvas.translate(math.sin(s.time * 90) * shake, math.cos(s.time * 70) * shake * 0.6);
    }
    _paintSky(canvas, size, p);
    _paintFarLayers(canvas, size, p);
    _paintGround(canvas, size, p);
    _paintRuins(canvas, p);
    _paintPortal(canvas, p);
    _paintTorches(canvas, p);
    _paintRangeRunes(canvas, p);
    _paintMist(canvas, p, behind: true);
    _paintAmbientMotes(canvas, p);

    // Enemies far → near (by camera depth).
    final fireballTarget = game.selectedSpell == SpellIds.fireball ? _first(game.targetableEnemies()) : null;
    final sorted = List<Enemy>.of(game.enemies)..sort((a, b) => p.toCamera(b.x, b.z).$2.compareTo(p.toCamera(a.x, a.z).$2));
    final bars = <(HealthBarModel, Offset, double, double)>[];
    for (final e in sorted) {
      if (!p.inFront(e.x, e.z)) continue;
      final feet = p.project(e.x, e.z);
      final u = p.unitsAt(e.x, e.z);
      final fog = ((e.distance - 20) / (game.config.spawnDistance - 20)).clamp(0.0, 1.0) * (1 - 0.5 * _daylight);
      _paintTelegraph(canvas, p, e, feet, u);
      paintEnemy(canvas, e, feet, u, opacity: 1 - 0.55 * fog, death: WizardEffects.deathProgress(e), daylight: _daylight);
      if (identical(e, fireballTarget)) _paintReticle(canvas, feet - Offset(0, (e.elevation + e.height * 0.5) * u), u * e.height * 0.55, _fire);
      if (e.isAlive && e is! BoneLich) bars.add((HealthBarModel.of(e), headAnchor(e, feet, u), u, 1 - 0.4 * fog));
    }
    _paintMist(canvas, p, behind: false);
    // Health bars after all enemies and mist, so a nearer enemy never hides a farther one's bar.
    for (final (model, anchor, u, opacity) in bars) {
      paintEnemyHealthBar(canvas, model, anchor, u, size, opacity: opacity);
    }

    for (final a in game.projectiles) {
      _paintProjectile(canvas, p, a);
    }
    _paintShield(canvas, p);
    for (final particle in fx.particles) {
      _paintWorldParticle(canvas, p, particle);
    }
    for (final e in fx.effects) {
      if (e.age >= 0) _paintEffect(canvas, p, e);
    }
    _paintAim(canvas, size, p, tip);
    for (final f in game.fireballs) {
      _paintFireball(canvas, size, p, f, tip);
    }
    for (final l in fx.lightning) {
      _paintLightning(canvas, p, l, tip);
    }
    for (final sp in fx.screenParticles) {
      final a = 1 - sp.t;
      canvas.drawCircle(sp.position, sp.size * (1 - 0.5 * sp.t), Paint()..color = sp.color.withValues(alpha: a));
    }
    _paintStaff(canvas, size, tip);
    canvas.restore();

    if (fx.skyFlash > 0) {
      canvas.drawRect(Offset.zero & size, Paint()..color = _lightningCyan.withValues(alpha: 0.12 * fx.skyFlash));
    }
    _paintDamageVignette(canvas, size, fx.damage);
    _paintHud(canvas, size);
    _paintIncomingHint(canvas, size);
    _paintBanners(canvas, size);
  }

  double get _daylight => s.game.dayNight.daylight;

  static Enemy? _first(List<Enemy> list) => list.isEmpty ? null : list.first;

  // ---------------------------------------------------------------- staff + aim

  Offset _staffTip(Size size) {
    // Cast recoil: the tip kicks back toward the hand.
    return s.staff.tipOnScreen(size) + const Offset(-14, 24) * s.effects.castFlash;
  }

  /// The wizard's staff, held in the left hand at the lower-left of the view. The tip follows the
  /// tracked hand (smoothed + clamped by [StaffAim]); its crystal shows the selected spell, the
  /// gesture charge and cast flashes.
  void _paintStaff(Canvas canvas, Size size, Offset tip) {
    final fx = s.effects;
    final base = Offset(tip.dx - size.width * 0.07, size.height * 1.12);
    final dir = (tip - base) / (tip - base).distance;
    final normal = Offset(-dir.dy, dir.dx);
    final color = spellColor(s.game.selectedSpell);
    final g = s.gesture;
    final charge = g.phase == CastPhase.charging ? g.charge : (g.phase == CastPhase.ready ? 0.35 : 0.0);
    final live = s.staff.hasHand;

    // Shaft (tapered, wood grain gradient).
    final wBase = size.height * 0.022, wTip = size.height * 0.012;
    final shaft = Path()
      ..moveTo(base.dx + normal.dx * wBase, base.dy + normal.dy * wBase)
      ..lineTo(tip.dx + normal.dx * wTip, tip.dy + normal.dy * wTip)
      ..lineTo(tip.dx - normal.dx * wTip, tip.dy - normal.dy * wTip)
      ..lineTo(base.dx - normal.dx * wBase, base.dy - normal.dy * wBase)
      ..close();
    canvas.drawPath(shaft, Paint()..shader = const LinearGradient(colors: [Color(0xFF5A3A22), Color(0xFF8A5E36), Color(0xFF4A2E1A)]).createShader(Rect.fromPoints(base, tip).inflate(wBase)));
    if (fx.damage > 0) canvas.drawPath(shaft, Paint()..color = const Color(0xFFFF3030).withValues(alpha: 0.35 * fx.damage));

    // Glowing runes along the shaft.
    for (var i = 0; i < 4; i++) {
      final at = Offset.lerp(tip, base, 0.18 + i * 0.1)!;
      final pulse = 0.4 + 0.6 * (0.5 + 0.5 * math.sin(s.time * 3 + i));
      final rune = Path()
        ..moveTo(at.dx + normal.dx * wTip * 0.6, at.dy + normal.dy * wTip * 0.6)
        ..lineTo(at.dx + dir.dx * 6, at.dy + dir.dy * 6)
        ..lineTo(at.dx - normal.dx * wTip * 0.6, at.dy - normal.dy * wTip * 0.6);
      canvas.drawPath(rune, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = color.withValues(alpha: (live ? 0.75 : 0.35) * pulse));
    }

    // Robe sleeve + gloved hand gripping the shaft.
    final grip = Offset.lerp(tip, base, 0.42)!;
    final sleeve = Path()
      ..moveTo(-20, size.height + 20)
      ..lineTo(grip.dx - size.width * 0.05, grip.dy + size.height * 0.05)
      ..quadraticBezierTo(grip.dx - 10, grip.dy - 6, grip.dx + size.width * 0.03, grip.dy + size.height * 0.06)
      ..lineTo(size.width * 0.14, size.height + 20)
      ..close();
    canvas.drawPath(sleeve, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF3B2266), Color(0xFF1E1036)]).createShader(Rect.fromLTWH(0, grip.dy - 40, size.width * 0.3, size.height - grip.dy + 60)));
    canvas.drawPath(sleeve, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = _gold.withValues(alpha: 0.5));
    final handRect = Rect.fromCenter(center: grip, width: size.height * 0.07, height: size.height * 0.055);
    canvas.save();
    canvas.translate(grip.dx, grip.dy);
    canvas.rotate(math.atan2(dir.dy, dir.dx) + math.pi / 2);
    canvas.translate(-grip.dx, -grip.dy);
    canvas.drawRRect(RRect.fromRectAndRadius(handRect, Radius.circular(handRect.height * 0.45)), Paint()..color = const Color(0xFF6E4A2E));
    for (var i = 0; i < 4; i++) {
      final y = handRect.top + handRect.height * (0.2 + i * 0.2);
      canvas.drawLine(Offset(handRect.left + 4, y), Offset(handRect.right - 4, y), Paint()
        ..color = const Color(0xFF4A301C)
        ..strokeWidth = 1.2);
    }
    canvas.restore();

    // Head: two prongs cradling the crystal.
    final prong = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = wTip * 0.9
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF6A4528);
    for (final side in [-1.0, 1.0]) {
      final start = tip - dir * 4;
      final ctrl = tip + normal * side * wTip * 3.2 + dir * wTip * 2;
      final end = tip + dir * wTip * 4.2 + normal * side * wTip * 0.8;
      canvas.drawPath(Path()
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, end.dx, end.dy), prong);
    }
    final crystalCenter = tip + dir * wTip * 2.4;
    final glow = (live ? 0.45 : 0.18) + 0.4 * charge + 0.6 * fx.castFlash;
    final glowR = size.height * (0.05 + 0.04 * charge + 0.05 * fx.castFlash);
    canvas.drawCircle(crystalCenter, glowR, Paint()..shader = RadialGradient(colors: [color.withValues(alpha: glow.clamp(0.0, 1.0)), color.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: crystalCenter, radius: glowR)));
    final cr = wTip * 1.6;
    final crystal = Path()
      ..moveTo(crystalCenter.dx + dir.dx * cr * 1.5, crystalCenter.dy + dir.dy * cr * 1.5)
      ..lineTo(crystalCenter.dx + normal.dx * cr, crystalCenter.dy + normal.dy * cr)
      ..lineTo(crystalCenter.dx - dir.dx * cr * 1.2, crystalCenter.dy - dir.dy * cr * 1.2)
      ..lineTo(crystalCenter.dx - normal.dx * cr, crystalCenter.dy - normal.dy * cr)
      ..close();
    canvas.drawPath(crystal, Paint()..shader = RadialGradient(colors: [Colors.white, color, Color.lerp(color, Colors.black, 0.4)!]).createShader(Rect.fromCircle(center: crystalCenter, radius: cr * 1.5)));
    if (g.phase == CastPhase.charging) {
      canvas.drawArc(Rect.fromCircle(center: crystalCenter, radius: cr * 3), -math.pi / 2, 2 * math.pi * g.charge, false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = color);
    }
    // Gesture label next to the staff (subtle).
    final (String label, Color labelColor) = switch (g.phase) {
      CastPhase.noHand => (g.extendedDropout ? 'Hand not visible' : 'Looking for your hand…', const Color(0xFFB9B3C9)),
      CastPhase.idle => ('Make a fist to ready a spell', const Color(0xFFB98CFF)),
      CastPhase.ready => ('Ready: open your palm to cast', const Color(0xFF9FE6FF)),
      CastPhase.charging => ('Casting…', color),
      CastPhase.spent => ('Close your fist to ready again', _fire),
    };
    _text(canvas, label, Offset(16, size.height - 46), 14, labelColor.withValues(alpha: 0.95));
    if (s.hand.status == HandTrackingStatus.tracking) {
      _text(canvas, 'seen: ${s.hand.pose.name}', Offset(16, size.height - 26), 11, Colors.white.withValues(alpha: 0.6));
    }
  }

  /// Aim indicator: where the staff points in the world. Chain Lightning shows its beam and the
  /// exact enemy it would strike; Fireball (auto-targeting) shows only a faint aim mark.
  void _paintAim(Canvas canvas, Size size, ArenaProjection p, Offset tip) {
    final game = s.game;
    final yaw = game.aimYaw;
    if (game.selectedSpell == SpellIds.chainLightning) {
      final spec = game.config.chainLightning;
      final target = game.chainLightningTarget();
      final aimPoint = target != null
          ? p.project(target.x, target.z, target.height * 0.5 + target.elevation)
          : p.project(math.sin(yaw) * spec.range * 0.6, math.cos(yaw) * spec.range * 0.6, 1.2);
      final ready = game.cooldownRemaining(SpellIds.chainLightning) == 0;
      final beam = Paint()
        ..color = _lightningCyan.withValues(alpha: ready ? 0.28 : 0.1)
        ..strokeWidth = 2;
      _dashedLine(canvas, tip, aimPoint, beam, 10, 8);
      if (target != null) {
        final u = p.unitsAt(target.x, target.z);
        _paintReticle(canvas, aimPoint, math.max(14, u * target.height * 0.55), _lightningCyan.withValues(alpha: ready ? 1 : 0.4));
      } else {
        canvas.drawCircle(aimPoint, 6, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = _lightningCyan.withValues(alpha: 0.5));
      }
    } else {
      final mark = p.project(math.sin(yaw) * 10, math.cos(yaw) * 10, 1.2);
      canvas.drawCircle(mark, 4, Paint()..color = Colors.white.withValues(alpha: 0.35));
      canvas.drawCircle(mark, 9, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.25));
    }
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint, double dash, double gap) {
    final d = (b - a).distance;
    if (d < 1) return;
    final dir = (b - a) / d;
    var t = (s.time * 40) % (dash + gap);
    while (t < d) {
      canvas.drawLine(a + dir * t, a + dir * math.min(d, t + dash), paint);
      t += dash + gap;
    }
  }

  // ---------------------------------------------------------------- scenery

  static Color _mix(Color night, Color day, double t) => Color.lerp(night, day, t)!;

  /// Sky by time of day: the night palette (stars, moon, nebulae) cross-fades through a dusky
  /// orange into a bright day sky with a sun, following [DayNightCycle.daylight].
  void _paintSky(Canvas canvas, Size size, ArenaProjection p) {
    final d = _daylight;
    final dusk = math.sin(d * math.pi); // strongest halfway through dusk/dawn
    final sky = Rect.fromLTWH(-40, -40, size.width + 80, p.horizonY + 40);
    canvas.drawRect(
      sky,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _mix(const Color(0xFF070418), const Color(0xFF3E7FD6), d),
            _mix(const Color(0xFF221046), const Color(0xFF7DB7EC), d),
            Color.lerp(_mix(const Color(0xFF5E2658), const Color(0xFFC9E3F5), d), const Color(0xFFE07A4A), 0.5 * dusk)!,
            Color.lerp(_mix(const Color(0xFF8A3B4E), const Color(0xFFF3E2B8), d), const Color(0xFFFFA45C), 0.6 * dusk)!,
          ],
          stops: const [0, 0.55, 0.9, 1],
        ).createShader(sky),
    );
    final shift = p.farShiftX;
    final w = size.width + 400;
    double wrap(double x) => ((x + shift) % w + w) % w - 200;
    final night = 1 - d;
    if (night > 0.01) {
      // Drifting nebulae and stars fade out with the light.
      for (var i = 0; i < 3; i++) {
        final c = Offset(wrap(size.width * (0.2 + i * 0.33) + s.time * 4), p.horizonY * (0.3 + 0.2 * i));
        final r = size.height * (0.25 + 0.05 * i);
        final color = [const Color(0x2C9B5CFF), const Color(0x22FF6FA8), const Color(0x1E6CF2FF)][i];
        canvas.drawCircle(c, r, Paint()..shader = RadialGradient(colors: [color.withValues(alpha: color.a * night), const Color(0x00000000)]).createShader(Rect.fromCircle(center: c, radius: r)));
      }
      final rng = math.Random(11);
      for (var i = 0; i < 140; i++) {
        final pt = Offset(wrap(rng.nextDouble() * w - 200), rng.nextDouble() * p.horizonY * 0.92);
        final twinkle = 0.4 + 0.6 * (0.5 + 0.5 * math.sin(s.time * (1 + rng.nextDouble() * 2) + i));
        canvas.drawCircle(pt, 0.6 + rng.nextDouble(), Paint()..color = Colors.white.withValues(alpha: 0.6 * twinkle * night));
      }
      final moon = Offset(wrap(size.width * 0.78), p.horizonY * (0.35 + 0.4 * d));
      canvas.drawCircle(moon, 80, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(255, 230, 176, 0.27 * night), const Color(0x00FFE6B0)]).createShader(Rect.fromCircle(center: moon, radius: 80)));
      canvas.drawCircle(moon, 26, Paint()..color = const Color(0xFFFFF1D0).withValues(alpha: night));
    }
    if (d > 0.01) {
      // The sun sinks toward the horizon at dusk and rises at dawn.
      final sun = Offset(wrap(size.width * 0.3), p.horizonY * (0.95 - 0.7 * d));
      canvas.drawCircle(sun, 140, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(255, 236, 170, 0.45 * d), const Color(0x00FFE6A0)]).createShader(Rect.fromCircle(center: sun, radius: 140)));
      canvas.drawCircle(sun, 34, Paint()..color = Color.lerp(const Color(0xFFFF9A50), const Color(0xFFFFF6D8), d)!.withValues(alpha: d));
      // A few soft clouds.
      for (var i = 0; i < 4; i++) {
        final c = Offset(wrap(size.width * (0.1 + i * 0.27) + s.time * 6), p.horizonY * (0.2 + 0.12 * (i % 3)));
        final r = Rect.fromCenter(center: c, width: size.width * 0.22, height: size.height * 0.05);
        canvas.drawOval(r, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(255, 255, 255, 0.5 * d), const Color(0x00FFFFFF)]).createShader(r));
      }
    }
  }

  /// Two mountain ridges at "infinity": they turn with the view, giving parallax against the
  /// world-placed ruins, torches and enemies (which shift by perspective).
  void _paintFarLayers(Canvas canvas, Size size, ArenaProjection p) {
    final w = size.width + 400;
    final d = _daylight;
    for (final (seed, color, height) in [(5, _mix(const Color(0xFF26143F), const Color(0xFF7D93B5), d), 0.17), (9, _mix(const Color(0xFF190D2C), const Color(0xFF5C7192), d), 0.10)]) {
      final r = math.Random(seed);
      final points = <(double, double)>[];
      var x = 0.0;
      while (x < w) {
        x += 30 + r.nextDouble() * 70;
        points.add((x, size.height * height * (0.3 + r.nextDouble() * 0.7)));
      }
      final shift = (p.farShiftX % w + w) % w;
      final path = Path()..moveTo(-200 + shift - w, p.horizonY + 2);
      for (var k = -1; k <= 1; k++) {
        for (final (px, py) in points) {
          path.lineTo(px - 200 + shift + k * w, p.horizonY - py);
        }
      }
      path
        ..lineTo(size.width + 200 + w, p.horizonY + 2)
        ..close();
      canvas.drawPath(path, Paint()..color = color);
    }
  }

  void _paintGround(Canvas canvas, Size size, ArenaProjection p) {
    final ground = Rect.fromLTWH(-40, p.horizonY, size.width + 80, size.height - p.horizonY + 60);
    canvas.drawRect(
      ground,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _mix(const Color(0xFF2B1F3A), const Color(0xFF9A9078), _daylight),
            _mix(const Color(0xFF3B2C3A), const Color(0xFF8A7F66), _daylight),
            _mix(const Color(0xFF1C1522), const Color(0xFF5E5644), _daylight),
          ],
          stops: const [0, 0.35, 1],
        ).createShader(ground),
    );
    // Flagstone grid in world space: it rotates with the view.
    final line = Paint()
      ..color = _mix(const Color(0x2EB9A8D6), const Color(0x3A2E2618), _daylight)
      ..strokeWidth = 1;
    final far = s.game.config.spawnDistance + 8;
    for (var x = -16.0; x <= 16; x += 2) {
      canvas.drawLine(p.project(x, 0.4), p.project(x, far), line);
    }
    for (var z = 1.0; z < far; z *= 1.32) {
      canvas.drawLine(p.project(-18, z), p.project(18, z), line);
    }
    // Warm light pools under the torches.
    for (final (x, z) in _torchPositions) {
      if (!p.inFront(x, z)) continue;
      final c = p.project(x, z);
      final u = p.unitsAt(x, z);
      final flicker = 0.85 + 0.15 * math.sin(s.time * 11 + x);
      final rect = Rect.fromCenter(center: c, width: 9 * u * flicker, height: 3.2 * u * flicker);
      canvas.drawOval(rect, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(255, 154, 61, 0.25 * (1 - 0.7 * _daylight)), const Color(0x00FF9A3D)]).createShader(rect));
    }
  }

  static const _torchPositions = [(-6.5, 9.0), (6.5, 9.0), (-8.0, 18.0), (8.0, 18.0)];

  /// Broken pillars and an arch beyond the arena (world-placed, so they show real parallax).
  void _paintRuins(Canvas canvas, ArenaProjection p) {
    const pillars = [(-14.0, 38.0, 6.0), (-9.0, 44.0, 9.0), (-4.5, 46.0, 9.0), (5.0, 45.0, 7.0), (10.5, 41.0, 10.0), (15.0, 36.0, 5.0)];
    final paint = Paint()..color = _mix(const Color(0xFF241634), const Color(0xFF6E6A70), _daylight);
    for (final (x, z, h) in pillars) {
      if (!p.inFront(x, z)) continue;
      final b = p.project(x, z);
      final u = p.unitsAt(x, z);
      final r = Rect.fromLTRB(b.dx - 0.8 * u, b.dy - h * u, b.dx + 0.8 * u, b.dy);
      canvas.drawRect(r, paint);
      canvas.drawRect(Rect.fromLTRB(r.left - 0.25 * u, r.top, r.right + 0.25 * u, r.top + 0.5 * u), paint);
    }
    if (!p.inFront(-9, 44) || !p.inFront(-4.5, 46)) return;
    final a = p.project(-9, 44, 9), b = p.project(-4.5, 46, 9);
    canvas.drawPath(Path()
      ..moveTo(a.dx, a.dy)
      ..quadraticBezierTo((a.dx + b.dx) / 2, math.min(a.dy, b.dy) - (b.dx - a.dx).abs() * 0.4, b.dx, b.dy), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, p.unitsAt(-7, 45) * 0.9)
      ..color = paint.color);
  }

  void _paintPortal(Canvas canvas, ArenaProjection p) {
    final z = s.game.config.spawnDistance;
    if (!p.inFront(0, z)) return;
    final gate = p.project(0, z, 1.6);
    final gu = p.unitsAt(0, z);
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

  /// Low mist banks drifting across the arena at fixed depths.
  void _paintMist(Canvas canvas, ArenaProjection p, {required bool behind}) {
    final count = behind ? 6 : 3;
    for (var i = 0; i < count; i++) {
      final z = behind ? 16.0 + i * 3 : 5.0 + i * 1.6;
      final x = ((s.time * (0.25 + 0.1 * i) + i * 7) % 30) - 15;
      if (!p.inFront(x, z)) continue;
      final c = p.project(x, z, 0.4);
      final u = p.unitsAt(x, z);
      final rect = Rect.fromCenter(center: c, width: 9 * u, height: 1.6 * u);
      canvas.drawOval(rect, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(185, 168, 214, behind ? 0.10 : 0.06), const Color(0x00B9A8D6)]).createShader(rect));
    }
  }

  /// Drifting embers and magical motes (stateless: positions are a function of time).
  void _paintAmbientMotes(Canvas canvas, ArenaProjection p) {
    for (var i = 0; i < 46; i++) {
      final seed = i * 12.9898;
      final x = ((math.sin(seed) * 43758.5453) % 1).abs() * 24 - 12;
      final z = 3 + ((math.cos(seed) * 24634.6345) % 1).abs() * 26;
      final life = 6.0 + (i % 5);
      final t = ((s.time + i * 0.73) % life) / life;
      final drift = math.sin(s.time * 0.6 + i) * 0.6;
      if (!p.inFront(x + drift, z)) continue;
      final pt = p.project(x + drift, z, t * 5);
      final u = p.unitsAt(x, z);
      final ember = i % 3 != 0;
      final a = math.sin(t * math.pi) * (ember ? 0.7 : 0.45);
      canvas.drawCircle(pt, math.max(1.0, 0.07 * u), Paint()..color = (ember ? const Color(0xFFFFB36B) : const Color(0xFFB9E8FF)).withValues(alpha: a));
    }
  }

  void _paintTorches(Canvas canvas, ArenaProjection p) {
    for (final (x, z) in _torchPositions) {
      if (!p.inFront(x, z)) continue;
      final base = p.project(x, z);
      final u = p.unitsAt(x, z);
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

  /// Glowing rune line at the selected spell's maximum range (same distance the game uses).
  void _paintRangeRunes(Canvas canvas, ArenaProjection p) {
    final lightning = s.game.selectedSpell == SpellIds.chainLightning;
    final r = lightning ? s.game.config.chainLightning.range : s.game.config.fireballRange;
    final color = lightning ? _lightningCyan : _fire;
    final pulse = 0.55 + 0.25 * math.sin(s.time * 2.5);
    final path = Path();
    var started = false;
    for (var i = 0; i <= 48; i++) {
      final a = -0.7 + 1.4 * i / 48;
      final (x, z) = (math.sin(a) * r, math.cos(a) * r);
      if (!p.inFront(x, z)) {
        started = false;
        continue;
      }
      final pt = p.project(x, z);
      if (!started) {
        path.moveTo(pt.dx, pt.dy);
        started = true;
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = color.withValues(alpha: 0.18 * pulse)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = color.withValues(alpha: 0.75 * pulse));
  }

  // ---------------------------------------------------------------- actors & effects

  void _paintReticle(Canvas canvas, Offset c, double r, Color color) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color.withValues(alpha: color.a * 0.85);
    final spin = s.time * 1.5;
    for (var i = 0; i < 4; i++) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: math.max(r, 10)), spin + i * math.pi / 2, math.pi / 4, false, paint);
    }
  }

  /// Arrows and boss bolts, drawn along their fixed flight direction (they never steer).
  void _paintProjectile(Canvas canvas, ArenaProjection p, Projectile a) {
    if (a.done || !p.inFront(a.x, a.z)) return;
    final speed = a.speed;
    if (speed <= 1e-9) return;
    final (dx, dz) = (a.vx / speed, a.vz / speed);
    final head = p.project(a.x, a.z, a.elevation);
    final u = p.unitsAt(a.x, a.z);
    final pulse = 0.5 + 0.5 * math.sin(s.time * 14);
    if (a.kind == ProjectileKind.bossBolt) {
      final r = math.max(8.0, a.spec.radius * u);
      for (var i = 1; i <= 5; i++) {
        final t = p.project(a.x - dx * i * 0.5, a.z - dz * i * 0.5, a.elevation + 0.05 * i);
        canvas.drawCircle(t, r * (1 - i * 0.14), Paint()..color = const Color(0xFF9BFFB8).withValues(alpha: 0.18 * (1 - i / 6)));
      }
      canvas.drawCircle(head, r * 2.4, Paint()..shader = RadialGradient(colors: [const Color(0x889BFFB8), const Color(0x009BFFB8)]).createShader(Rect.fromCircle(center: head, radius: r * 2.4)));
      canvas.drawCircle(head, r, Paint()..shader = const RadialGradient(colors: [Color(0xFFFFFFFF), Color(0xFF9BFFB8), Color(0xFF6A3FD0)], stops: [0, 0.5, 1]).createShader(Rect.fromCircle(center: head, radius: r)));
      return;
    }
    final tail = p.project(a.x - dx * 1.6, a.z - dz * 1.6, a.elevation);
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
    final back = tail - head;
    final n = Offset(-back.dy, back.dx) / math.max(back.distance, 1) * w * 2;
    canvas.drawLine(tail, tail + n - back * 0.12, Paint()
      ..color = const Color(0xFFC94040)
      ..strokeWidth = w * 0.8);
    canvas.drawLine(tail, tail - n - back * 0.12, Paint()
      ..color = const Color(0xFFC94040)
      ..strokeWidth = w * 0.8);
    canvas.drawCircle(head, math.max(5.0, 0.18 * u), Paint()..color = const Color(0xFFFF3B3B));
    canvas.drawCircle(head, math.max(12.0, 0.5 * u) * (1 + 0.25 * pulse), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = const Color(0xFFFF3B3B).withValues(alpha: 0.5 + 0.4 * pulse));
  }

  /// Telegraphs for ranged attacks: the intended line of fire toward the player while the
  /// skeleton draws or the boss charges (the shot is aimed when released, so this shows intent,
  /// not a guaranteed path), plus a ring filling over the telegraph's fixed duration.
  void _paintTelegraph(Canvas canvas, ArenaProjection p, Enemy e, Offset feet, double u) {
    final progress = switch (e) {
      SkeletonArcher(:final drawProgress) => drawProgress,
      BoneLich(:final chargeProgress) => chargeProgress,
      _ => 0.0,
    };
    if (progress <= 0 || !e.isAlive) return;
    final color = e is BoneLich ? const Color(0xFF9BFFB8) : const Color(0xFFFF4D4D);
    final offsets = e is BoneLich && e.nextAttack == BossAttack.fan ? [-e.boss.fanAngle, 0.0, e.boss.fanAngle] : [0.0];
    for (final off in offsets) {
      final d = e.distance;
      if (d <= 1e-9) continue;
      var (dx, dz) = (-e.x / d, -e.z / d);
      if (off != 0) (dx, dz) = (dx * math.cos(off) + dz * math.sin(off), -dx * math.sin(off) + dz * math.cos(off));
      final from = p.project(e.x, e.z, e.height * 0.65 + e.elevation);
      final reach = math.max(0.0, d - 2.5);
      if (!p.inFront(e.x + dx * reach, e.z + dz * reach)) continue;
      final to = p.project(e.x + dx * reach, e.z + dz * reach, 1.2);
      _dashedLine(canvas, from, to, Paint()
        ..color = color.withValues(alpha: 0.25 + 0.5 * progress)
        ..strokeWidth = 1.5 + 2 * progress, 12, 9);
    }
    final top = headAnchor(e, feet, u) - const Offset(0, 36); // above the health bar
    canvas.drawCircle(top, 11, Paint()..color = const Color(0xCC120B26));
    canvas.drawArc(Rect.fromCircle(center: top, radius: 11), -math.pi / 2, 2 * math.pi * progress, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = color);
    _text(canvas, '!', top, 13, Colors.white, bold: true, center: true);
  }

  /// The shield, drawn exactly where it blocks: an arc at [ShieldSpec.blockRadius] spanning
  /// ±[ShieldSpec.halfAngle] around the shield direction. Bright while active, flashing on each
  /// block, and fading out briefly when the window ends.
  void _paintShield(Canvas canvas, ArenaProjection p) {
    final shield = s.game.shield;
    final fx = s.effects;
    final active = shield.isActive;
    final strength = active ? 0.55 + 0.45 * shield.activeFraction : fx.shieldFade * 0.6;
    if (strength <= 0.01) return;
    final spec = shield.spec;
    const segments = 24;
    const low = 0.15, high = 2.5;
    final top = <Offset>[], bottom = <Offset>[];
    for (var i = 0; i <= segments; i++) {
      final a = shield.yaw - spec.halfAngle + 2 * spec.halfAngle * i / segments;
      final (x, z) = (math.sin(a) * spec.blockRadius, math.cos(a) * spec.blockRadius);
      if (!p.inFront(x, z)) return;
      top.add(p.project(x, z, high));
      bottom.add(p.project(x, z, low));
    }
    final path = Path()..moveTo(top.first.dx, top.first.dy);
    for (final pt in top.skip(1)) {
      path.lineTo(pt.dx, pt.dy);
    }
    for (final pt in bottom.reversed) {
      path.lineTo(pt.dx, pt.dy);
    }
    path.close();
    final bounds = path.getBounds();
    final flash = math.max(fx.shieldFlash, fx.blockFlash);
    canvas.drawPath(path, Paint()
      ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
        const Color(0xFF6CF2FF).withValues(alpha: (0.10 + 0.25 * flash) * strength),
        const Color(0xFFBFF4FF).withValues(alpha: (0.22 + 0.3 * flash) * strength),
        const Color(0xFF6CF2FF).withValues(alpha: (0.08 + 0.2 * flash) * strength),
      ]).createShader(bounds));
    // Rune lattice and a bright rim (readable on both day and night skies).
    final rune = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFFE6FBFF).withValues(alpha: 0.45 * strength);
    for (var i = 2; i < segments; i += 4) {
      canvas.drawLine(top[i], bottom[i], rune);
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = const Color(0xFF0B3A4A).withValues(alpha: 0.35 * strength));
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 + 2 * flash
      ..color = Colors.white.withValues(alpha: 0.85 * strength));
    if (active) {
      // Remaining-time bar along the shield's lower edge.
      final n = (segments * shield.activeFraction).round();
      final timer = Path()..moveTo(bottom.first.dx, bottom.first.dy);
      for (final pt in bottom.take(n + 1).skip(1)) {
        timer.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(timer, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF6CF2FF));
    }
  }

  /// "Shield now!" assist: shown when a blockable projectile on a hitting course will arrive
  /// within the next 0.9 s (computed from its fixed straight path) and the shield is ready.
  void _paintIncomingHint(Canvas canvas, Size size) {
    final game = s.game;
    if (!s.showShieldHud || game.isOver) return;
    double? soonest;
    for (final a in game.projectiles) {
      if (a.done || !a.spec.blockable) continue;
      final speed = a.speed;
      if (speed <= 1e-9) continue;
      final along = -(a.x * a.vx + a.z * a.vz) / speed; // distance to closest approach
      if (along <= 0) continue;
      final cx = a.x + a.vx / speed * along, cz = a.z + a.vz / speed * along;
      if (math.sqrt(cx * cx + cz * cz) > game.config.playerHitRadius + a.spec.radius) continue;
      final eta = math.max(0.0, along - game.config.shield.blockRadius) / speed;
      if (soonest == null || eta < soonest) soonest = eta;
    }
    if (soonest == null || soonest > 0.9) return;
    final ready = game.shield.state == ShieldState.ready;
    final active = game.shield.isActive;
    final text = active ? 'BLOCKING' : (ready ? 'INCOMING · RAISE SHIELD' : 'INCOMING');
    final color = active ? const Color(0xFF6CF2FF) : const Color(0xFFFF6B6B);
    final pulse = 0.75 + 0.25 * math.sin(s.time * 20);
    final tp = _layout(text, 18, Colors.black, bold: true, letterSpacing: 2);
    // Upper middle: clear of the horizon (where shooters stand) and of the shield itself.
    final rect = Rect.fromCenter(center: Offset(size.width / 2, size.height * 0.17), width: tp.width + 32, height: 34);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(17)), Paint()..color = color.withValues(alpha: 0.85 * pulse));
    tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
  }

  void _paintWorldParticle(Canvas canvas, ArenaProjection p, WorldParticle q) {
    if (!p.inFront(q.x, q.z)) return;
    final pt = p.project(q.x, q.z, q.elevation);
    final u = p.unitsAt(q.x, q.z);
    final a = (1 - q.t) * (q.t < 0.1 ? q.t * 10 : 1);
    final r = math.max(1.2, q.size * u * (1 - 0.4 * q.t));
    canvas.drawCircle(pt, r * 2.2, Paint()..color = q.color.withValues(alpha: 0.18 * a));
    canvas.drawCircle(pt, r, Paint()..color = q.color.withValues(alpha: a));
  }

  /// Fireball: a flickering layered core flying from the staff tip toward the target's current
  /// on-screen position (the model homes on the target, so the visual always ends on it).
  void _paintFireball(Canvas canvas, Size size, ArenaProjection p, Fireball f, Offset tip) {
    final t = f.progress;
    final end = p.project(f.toX, f.toZ, f.toElevation);
    final e = 1 - math.pow(1 - t, 2).toDouble();
    Offset at(double tt) {
      final ee = 1 - math.pow(1 - tt, 2).toDouble();
      return Offset.lerp(tip, end, ee)! - Offset(0, math.sin(tt * math.pi) * size.height * 0.07);
    }

    final pos = at(t);
    final radius = ui.lerpDouble(26, math.max(9, p.unitsAt(f.toX, f.toZ) * 0.55), e)!;
    for (var i = 1; i <= 6; i++) {
      final tp = at(math.max(0, t - i * 0.035));
      canvas.drawCircle(tp, radius * (1 - i * 0.12), Paint()..color = _fire.withValues(alpha: 0.16 * (1 - i / 7)));
    }
    canvas.drawCircle(pos, radius * 2.2, Paint()..shader = RadialGradient(colors: [const Color(0x99FF8A3D), const Color(0x00FF8A3D)]).createShader(Rect.fromCircle(center: pos, radius: radius * 2.2)));
    // Flickering core: three offset blobs.
    for (var i = 0; i < 3; i++) {
      final wobble = Offset(math.sin(s.time * 40 + i * 2.1), math.cos(s.time * 37 + i * 1.7)) * radius * 0.18;
      canvas.drawCircle(pos + wobble, radius * (0.95 - i * 0.18), Paint()..shader = const RadialGradient(colors: [Color(0xFFFFF6D0), Color(0xFFFFB347), Color(0xFFE0451F)], stops: [0, 0.45, 1]).createShader(Rect.fromCircle(center: pos + wobble, radius: radius)));
    }
  }

  /// Screen position of a fireball (for the trail emitter, run by the game screen each tick).
  static Offset fireballScreenPosition(Size size, ArenaProjection p, Fireball f, Offset tip) {
    final t = f.progress;
    final end = p.project(f.toX, f.toZ, f.toElevation);
    final ee = 1 - math.pow(1 - t, 2).toDouble();
    return Offset.lerp(tip, end, ee)! - Offset(0, math.sin(t * math.pi) * size.height * 0.07);
  }

  void _paintLightning(Canvas canvas, ArenaProjection p, LightningVisual l, Offset tip) {
    final hits = l.cast.hits;
    final points = <Offset>[tip];
    if (hits.isEmpty) {
      points.add(p.project(l.cast.endX, l.cast.endZ, 1.2));
    } else {
      for (final h in hits) {
        points.add(p.project(h.x, h.z, h.elevation));
      }
    }
    final rng = math.Random((s.time * 30).floor() * 31 + identityHashCode(l)); // flicker
    for (var i = 0; i + 1 < points.length; i++) {
      final age = l.age - i * LightningVisual.linkStep;
      if (age < 0) continue;
      final alpha = (1 - age / 0.35).clamp(0.0, 1.0);
      if (alpha <= 0) continue;
      final path = _jagged(points[i], points[i + 1], rng, segments: 12, amp: (points[i + 1] - points[i]).distance * 0.08);
      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..color = _lightningCyan.withValues(alpha: 0.35 * alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = i == 0 ? 3.4 : 2.4
        ..color = Colors.white.withValues(alpha: alpha));
      for (var b = 0; b < 2; b++) {
        final from = Offset.lerp(points[i], points[i + 1], 0.3 + rng.nextDouble() * 0.4)!;
        final to = from + Offset((rng.nextDouble() - 0.5) * 60, (rng.nextDouble() - 0.5) * 60);
        canvas.drawPath(_jagged(from, to, rng, segments: 4, amp: 8), Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = _lightningCyan.withValues(alpha: 0.7 * alpha));
      }
      // Target markers: big ring on the primary target, smaller ones on chain links.
      if (hits.isNotEmpty) {
        canvas.drawCircle(points[i + 1], (i == 0 ? 26 : 16) * (0.6 + 0.4 * alpha), Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = i == 0 ? 3 : 2
          ..color = _lightningCyan.withValues(alpha: alpha));
      }
    }
  }

  Path _jagged(Offset a, Offset b, math.Random rng, {required int segments, required double amp}) {
    final dir = b - a;
    final normal = Offset(-dir.dy, dir.dx) / math.max(dir.distance, 1e-6);
    final path = Path()..moveTo(a.dx, a.dy);
    for (var k = 1; k < segments; k++) {
      final t = k / segments;
      final pt = Offset.lerp(a, b, t)! + normal * ((rng.nextDouble() - 0.5) * 2 * amp * math.sin(t * math.pi));
      path.lineTo(pt.dx, pt.dy);
    }
    path.lineTo(b.dx, b.dy);
    return path;
  }

  void _paintEffect(Canvas canvas, ArenaProjection p, WorldEffect e) {
    if (!p.inFront(e.x, e.z)) return;
    final c = p.project(e.x, e.z, e.elevation);
    final ground = p.project(e.x, e.z);
    final u = p.unitsAt(e.x, e.z);
    final t = e.t;
    switch (e.kind) {
      case EffectKind.impact:
        canvas.drawOval(Rect.fromCenter(center: ground, width: 5 * u * (0.5 + t), height: 1.6 * u * (0.5 + t)), Paint()..color = const Color(0xFFFF9A3D).withValues(alpha: 0.35 * (1 - t)));
        canvas.drawCircle(c, (0.4 + 2.2 * t) * u, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, 0.25 * u * (1 - t))
          ..color = const Color(0xFFFFD27A).withValues(alpha: 1 - t));
        final r = (0.6 + 1.4 * t) * u;
        canvas.drawCircle(c, r, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(255, 245, 210, 1 - t), Color.fromRGBO(255, 120, 40, 0.8 * (1 - t)), const Color(0x00FF5020)]).createShader(Rect.fromCircle(center: c, radius: r)));
      case EffectKind.defeat:
        // Kept light so it never hides the enemies behind it.
        final color = e.color ?? Colors.white;
        canvas.drawCircle(c, (0.5 + 1.8 * t) * u, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, 0.12 * u * (1 - t))
          ..color = color.withValues(alpha: 0.8 * (1 - t)));
        canvas.drawCircle(c, (0.3 + 0.6 * t) * u, Paint()..color = color.withValues(alpha: 0.18 * (1 - t)));
      case EffectKind.fizzle:
        canvas.drawCircle(c, (0.3 + 1.0 * t) * u + 4, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFB9A8D6).withValues(alpha: 0.7 * (1 - t)));
        canvas.drawCircle(c - Offset(0, t * u), (0.5 + 0.8 * t) * u, Paint()..color = const Color(0xFF6E6680).withValues(alpha: 0.35 * (1 - t)));
      case EffectKind.scorePopup:
        _text(canvas, e.text ?? '', c - Offset(0, t * 40), 22, _gold.withValues(alpha: 1 - t * t), center: true);
      case EffectKind.spawnFlash:
        canvas.drawCircle(c - Offset(0, u), (0.5 + 1.5 * t) * u + 2, Paint()..color = const Color(0xFFB98CFF).withValues(alpha: 0.5 * (1 - t)));
      case EffectKind.slimeSplat:
        canvas.drawOval(Rect.fromCenter(center: ground, width: (1 + 3 * t) * u, height: (0.4 + 1 * t) * u), Paint()..color = const Color(0xFF3BC46B).withValues(alpha: 0.5 * (1 - t)));
      case EffectKind.lightningImpact:
        final r = (0.4 + 1.1 * t) * u;
        canvas.drawCircle(c, r, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(255, 255, 255, 1 - t), Color.fromRGBO(127, 231, 255, 0.7 * (1 - t)), const Color(0x007FE7FF)]).createShader(Rect.fromCircle(center: c, radius: r)));
        canvas.drawOval(Rect.fromCenter(center: ground, width: 4 * u, height: 1.3 * u), Paint()..color = _lightningCyan.withValues(alpha: 0.3 * (1 - t)));
      case EffectKind.shieldBlock:
        canvas.drawCircle(c, (0.3 + 1.6 * t) * u, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2, 0.2 * u * (1 - t))
          ..color = const Color(0xFFBFF4FF).withValues(alpha: 1 - t));
        final r = (0.3 + 0.8 * t) * u;
        canvas.drawCircle(c, r, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(255, 255, 255, 1 - t), Color.fromRGBO(108, 242, 255, 0.6 * (1 - t)), const Color(0x006CF2FF)]).createShader(Rect.fromCircle(center: c, radius: r)));
      case EffectKind.bossDefeat:
        for (var i = 0; i < 3; i++) {
          final tt = (t - i * 0.15).clamp(0.0, 1.0);
          canvas.drawCircle(c, (0.5 + 5 * tt) * u, Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(2, 0.3 * u * (1 - tt))
            ..color = const Color(0xFF9BFFB8).withValues(alpha: 0.9 * (1 - tt)));
        }
      case EffectKind.strike:
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

  void _paintHud(Canvas canvas, Size size) {
    final game = s.game;
    if (s.showShieldHud) _paintShieldChip(canvas, size);
    if (!s.showRunHud) return;
    _text(canvas, 'SCORE', const Offset(28, 22), 13, const Color(0xFFB9A8D6), letterSpacing: 3);
    _text(canvas, '${game.score}', const Offset(26, 38), 40, _gold, bold: true);
    final secs = game.elapsed.floor();
    _text(canvas, '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}  ·  ${game.enemiesDefeated} slain  ·  threat ${(game.difficultyLevel * 100).round()}%', const Offset(28, 88), 13, Colors.white.withValues(alpha: 0.6));
    final headText = switch (s.head.status) {
      HeadTrackingStatus.tracking => s.head.simulated ? 'Head: simulated (arrow keys)' : 'Head: tracking',
      HeadTrackingStatus.lost => 'Head: re-acquiring…',
      HeadTrackingStatus.unavailable => 'Head: not available (hand aim only)',
    };
    _text(canvas, headText, const Offset(28, 108), 11, Colors.white.withValues(alpha: 0.45));

    _paintCycleChip(canvas, size);
    final boss = game.livingBoss;
    if (boss != null) paintBossHealthBar(canvas, HealthBarModel.of(boss), size, boss.spec.name, charge: boss.chargeProgress);

    for (var i = 0; i < game.config.startingLives; i++) {
      final alive = i < game.lives;
      final pulse = (!alive && s.effects.lostHeart == i) ? s.effects.heartPulse : 0.0;
      final c = Offset(size.width - 40 - (game.config.startingLives - 1 - i) * 46, 44);
      _heart(canvas, c, 17 * (1 + 0.4 * pulse), alive ? const Color(0xFFFF4D6D) : const Color(0x55FFFFFF));
    }
    _text(canvas, 'Esc: leave run   ·   R: recenter head', Offset(size.width / 2, size.height - 14), 11, Colors.white.withValues(alpha: 0.35), center: true);
  }

  /// Time of day, top-right under the hearts: sun/moon icon, day number and what comes next.
  void _paintCycleChip(Canvas canvas, Size size) {
    final cycle = s.game.dayNight;
    if (!cycle.spec.enabled) return;
    final night = cycle.nights;
    final (String text, Color color) = switch (cycle.phase) {
      DayPhase.day => ('Day ${night + 1} · night in ${cycle.dayRemaining.ceil()} s', const Color(0xFFFFD27A)),
      DayPhase.dusk => ('Dusk · the light fades', const Color(0xFFFFA45C)),
      DayPhase.night => ('Night $night · defeat the ${s.game.config.boss.name}', const Color(0xFF9BFFB8)),
      DayPhase.dawn => ('Dawn', const Color(0xFFFFD27A)),
    };
    final c = Offset(size.width - 40 - (s.game.config.startingLives - 1) * 46 - 8, 92);
    final d = cycle.daylight;
    canvas.drawCircle(c, 9, Paint()..color = Color.lerp(const Color(0xFFDDE6FF), const Color(0xFFFFD27A), d)!);
    if (d < 0.5) canvas.drawCircle(c + const Offset(4, -3), 8, Paint()..color = const Color(0xFF120B26));
    _text(canvas, text, c + const Offset(16, -9), 13, color.withValues(alpha: 0.95), bold: true);
  }

  /// Shield status above the spell bar: always available, independent of the selected spell.
  void _paintShieldChip(Canvas canvas, Size size) {
    final shield = s.game.shield;
    final (String text, Color color) = switch (shield.state) {
      ShieldState.active => ('SHIELD UP ${(shield.remaining * 1000).round()} ms', const Color(0xFF6CF2FF)),
      ShieldState.recharging => ('Shield · lower your hand to re-arm', const Color(0xFF8A84A0)),
      ShieldState.ready => ('Shield ready · raise your hand upright in front of your face', const Color(0xFFBFF4FF)),
    };
    final tp = _layout(text, 12, color, bold: shield.isActive);
    final rect = Rect.fromCenter(center: Offset(size.width / 2, size.height - 96), width: tp.width + 44, height: 24);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(12)), Paint()..color = const Color(0xCC120B26));
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(12)), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.6));
    // Readiness pip: fills as the hand approaches the blocking pose.
    final pip = Offset(rect.left + 14, rect.center.dy);
    final fill = shield.isActive ? shield.activeFraction : (shield.state == ShieldState.ready ? s.shieldReadiness : 0.0);
    canvas.drawCircle(pip, 6, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color);
    canvas.drawArc(Rect.fromCircle(center: pip, radius: 6), -math.pi / 2, 2 * math.pi * fill, true, Paint()..color = color);
    tp.paint(canvas, Offset(rect.left + 26, rect.center.dy - tp.height / 2));
  }

  void _paintBanners(Canvas canvas, Size size) {
    final banners = <(String, Color)>[];
    if (s.simulated) banners.add(('SIMULATED INPUT (dev) · mouse = hand · hold button/Space = fist · V key = V sign · B = shield · arrows = head', const Color(0xFFFFC857)));
    if (s.hand.status == HandTrackingStatus.unavailable && !s.simulated) {
      banners.add(('Hand tracking unavailable: ${s.hand.message ?? 'no camera'}', const Color(0xFFFF6B6B)));
    } else if (s.gesture.extendedDropout) {
      banners.add(("Can't see your hand. Raise your left hand into the glasses' view.", const Color(0xFFFF9F6B)));
    }
    var y = s.bannerTop;
    for (final (text, color) in banners) {
      final tp = _layout(text, 14, Colors.black, bold: true);
      final rect = Rect.fromCenter(center: Offset(size.width / 2, y + 14), width: tp.width + 28, height: 28);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(8)), Paint()..color = color.withValues(alpha: 0.9));
      tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
      y += 36;
    }

    final fx = s.effects;
    if (fx.banner > 0 && fx.unlockBanner <= 0) {
      // Quick fade in, hold, fade out over the last half second.
      final alpha = math.min(((fx.bannerSeconds - fx.banner) * 3).clamp(0.0, 1.0), math.min(1.0, fx.banner * 2));
      final c = Offset(size.width / 2, size.height * 0.27);
      _text(canvas, fx.bannerTitle, c, 38, fx.bannerColor.withValues(alpha: alpha), bold: true, center: true, letterSpacing: 4);
      _text(canvas, fx.bannerSubtitle, c + const Offset(0, 38), 16, Colors.white.withValues(alpha: 0.9 * alpha), center: true);
    }
    if (fx.unlockBanner > 0 && fx.unlockedSpell != null) {
      final a = math.min(1.0, math.min(fx.unlockBanner, 4.5 - fx.unlockBanner) * 2);
      final c = Offset(size.width / 2, size.height * 0.3);
      canvas.drawCircle(c, size.height * 0.25, Paint()..shader = RadialGradient(colors: [_lightningCyan.withValues(alpha: 0.25 * a), _lightningCyan.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: c, radius: size.height * 0.25)));
      _text(canvas, '${WizardEffects.spellName(fx.unlockedSpell!).toUpperCase()} UNLOCKED', c, 34, _lightningCyan.withValues(alpha: a), bold: true, center: true, letterSpacing: 3);
      _text(canvas, 'Permanently yours. Hold a V sign (two fingers up) or press Q to switch spells.', c + const Offset(0, 36), 15, Colors.white.withValues(alpha: 0.9 * a), center: true);
    } else if (fx.switchToast > 0 && fx.switchedTo != null) {
      final a = math.min(1.0, fx.switchToast * 2);
      _text(canvas, WizardEffects.spellName(fx.switchedTo!), Offset(size.width / 2, size.height * 0.22), 26, spellColor(fx.switchedTo!).withValues(alpha: a), bold: true, center: true, letterSpacing: 2);
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
