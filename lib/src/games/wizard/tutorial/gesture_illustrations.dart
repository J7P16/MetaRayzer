import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Looping, procedurally drawn illustrations of the real controls (no image assets):
/// - [GestureKind.look]: glasses turning left and right (head movement turns the view);
/// - [GestureKind.cast]: the LEFT hand, fingers up, closing into a fist and snapping open;
/// - [GestureKind.shield]: the forearm raised upright close in front of the face, a short shield
///   flash meeting an incoming arrow.
/// Shared visual language: gold = the player's hand/head, cyan = shield, orange = fire.
enum GestureKind { look, cast, shield }

class GestureIllustration extends StatefulWidget {
  const GestureIllustration({super.key, required this.kind, this.size = 150});
  final GestureKind kind;
  final double size;

  @override
  State<GestureIllustration> createState() => _GestureIllustrationState();
}

class _GestureIllustrationState extends State<GestureIllustration> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(animation: _c, builder: (_, _) => CustomPaint(painter: _IllustrationPainter(widget.kind, _c.value))),
      );
}

const _gold = Color(0xFFFFD27A);
const _skin = Color(0xFFE8C9A8);
const _cyan = Color(0xFF6CF2FF);

class _IllustrationPainter extends CustomPainter {
  _IllustrationPainter(this.kind, this.t);
  final GestureKind kind;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.width * 0.12));
    canvas.drawRRect(r, Paint()..color = const Color(0xFF1A1030));
    canvas.drawRRect(r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = _gold.withValues(alpha: 0.4));
    canvas.save();
    canvas.clipRRect(r);
    switch (kind) {
      case GestureKind.look:
        _look(canvas, size);
      case GestureKind.cast:
        _cast(canvas, size);
      case GestureKind.shield:
        _shield(canvas, size);
    }
    canvas.restore();
  }

  /// Top-down head with glasses swinging left ↔ right, and the view cone following.
  void _look(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.62);
    final yaw = math.sin(t * 2 * math.pi) * 0.6;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(yaw);
    final cone = Path()
      ..moveTo(0, -size.height * 0.12)
      ..lineTo(-size.width * 0.32, -size.height * 0.55)
      ..lineTo(size.width * 0.32, -size.height * 0.55)
      ..close();
    canvas.drawPath(cone, Paint()..shader = LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [_gold.withValues(alpha: 0.35), _gold.withValues(alpha: 0)]).createShader(cone.getBounds()));
    canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: size.width * 0.3, height: size.width * 0.34), Paint()..color = const Color(0xFF6A4A3A));
    canvas.drawOval(Rect.fromCenter(center: Offset(0, size.width * 0.02), width: size.width * 0.26, height: size.width * 0.26), Paint()..color = _skin);
    // Glasses frame across the face.
    final frame = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.03
      ..color = const Color(0xFF111111);
    canvas.drawLine(Offset(-size.width * 0.16, -size.width * 0.1), Offset(size.width * 0.16, -size.width * 0.1), frame);
    for (final s in [-1.0, 1.0]) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(s * size.width * 0.07, -size.width * 0.11), width: size.width * 0.11, height: size.width * 0.06), const Radius.circular(3)), Paint()..color = const Color(0xFF111111));
    }
    canvas.restore();
    // Arrows.
    for (final s in [-1.0, 1.0]) {
      final active = (s < 0 && yaw < -0.3) || (s > 0 && yaw > 0.3);
      _arrow(canvas, Offset(size.width * (0.5 + s * 0.36), size.height * 0.28), s, size.width * 0.1, active ? _gold : _gold.withValues(alpha: 0.3));
    }
  }

  void _arrow(Canvas canvas, Offset at, double dir, double s, Color color) {
    final p = Path()
      ..moveTo(at.dx + dir * s, at.dy)
      ..lineTo(at.dx - dir * s * 0.2, at.dy - s * 0.6)
      ..lineTo(at.dx - dir * s * 0.2, at.dy + s * 0.6)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  /// The left hand seen from behind (as the glasses see it), fingers up: open → fist (ready) →
  /// snap open (cast, with a burst of fire from the staff crystal).
  void _cast(Canvas canvas, Size size) {
    // 0–0.35 open, 0.35–0.7 fist, 0.7+ snap open + burst.
    final closed = t < 0.3 ? 0.0 : (t < 0.4 ? (t - 0.3) / 0.1 : (t < 0.7 ? 1.0 : (t < 0.74 ? 1 - (t - 0.7) / 0.04 : 0.0)));
    final c = Offset(size.width * 0.5, size.height * 0.7);
    _hand(canvas, c, size.width * 0.5, closed, mirrorLeft: true);
    final label = t < 0.3 ? '' : (t < 0.7 ? 'FIST · ready' : 'OPEN · cast!');
    if (t >= 0.7) {
      final burst = (t - 0.7) / 0.3;
      final b = Offset(size.width * 0.5, size.height * (0.28 - 0.12 * burst));
      canvas.drawCircle(b, size.width * (0.08 + 0.1 * burst), Paint()..shader = RadialGradient(colors: [const Color(0xFFFFF6D0).withValues(alpha: 1 - burst), const Color(0xFFFF8A3D).withValues(alpha: 0.8 * (1 - burst)), const Color(0x00FF5020)]).createShader(Rect.fromCircle(center: b, radius: size.width * 0.18)));
    }
    _caption(canvas, size, label, t >= 0.7 ? const Color(0xFFFF8A3D) : _gold);
  }

  /// A simple back-of-hand drawing: palm, four fingers (curling with [closed]) and a thumb.
  void _hand(Canvas canvas, Offset wrist, double s, double closed, {bool mirrorLeft = false}) {
    final skin = Paint()..color = _skin;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFF6A4A3A);
    final palm = Rect.fromCenter(center: wrist - Offset(0, s * 0.32), width: s * 0.62, height: s * 0.52);
    canvas.drawRect(Rect.fromCenter(center: wrist + Offset(0, s * 0.12), width: s * 0.4, height: s * 0.3), skin); // wrist
    for (var i = 0; i < 4; i++) {
      final x = palm.left + palm.width * (0.14 + i * 0.24);
      final len = s * [0.42, 0.48, 0.45, 0.36][i] * (1 - 0.72 * closed);
      final finger = RRect.fromRectAndRadius(Rect.fromLTWH(x - s * 0.06, palm.top - len, s * 0.12, len + s * 0.06), Radius.circular(s * 0.06));
      canvas.drawRRect(finger, skin);
      canvas.drawRRect(finger, outline);
    }
    final palmR = RRect.fromRectAndRadius(palm, Radius.circular(s * 0.12));
    canvas.drawRRect(palmR, skin);
    canvas.drawRRect(palmR, outline);
    if (closed > 0.5) {
      // Knuckle line of a fist.
      canvas.drawLine(Offset(palm.left + s * 0.06, palm.top + s * 0.08), Offset(palm.right - s * 0.06, palm.top + s * 0.08), outline);
    }
    // Thumb on the right side for a left hand seen from behind.
    final side = mirrorLeft ? 1.0 : -1.0;
    final thumbBase = Offset(palm.center.dx + side * palm.width * 0.48, palm.bottom - s * 0.12);
    final thumbTip = thumbBase + Offset(side * s * (0.2 - 0.12 * closed), -s * (0.22 - 0.08 * closed));
    canvas.drawLine(thumbBase, thumbTip, Paint()
      ..strokeWidth = s * 0.12
      ..strokeCap = StrokeCap.round
      ..color = _skin);
  }

  /// Front view of the player: the forearm comes up close in front of the face as an upright
  /// "vertical line", the shield flashes for a moment, and an arrow arriving at that moment is
  /// deflected.
  void _shield(Canvas canvas, Size size) {
    final face = Offset(size.width * 0.5, size.height * 0.42);
    // Head with glasses.
    canvas.drawCircle(face, size.width * 0.17, Paint()..color = _skin.withValues(alpha: 0.5));
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: face - Offset(0, size.width * 0.03), width: size.width * 0.28, height: size.width * 0.07), const Radius.circular(4)), Paint()..color = const Color(0xCC111111));
    // Arm rises (0.15–0.35), holds (0.35–0.75), lowers (0.75–0.95).
    final up = t < 0.15 ? 0.0 : (t < 0.35 ? (t - 0.15) / 0.2 : (t < 0.75 ? 1.0 : (t < 0.95 ? 1 - (t - 0.75) / 0.2 : 0.0)));
    final elbow = Offset(size.width * 0.5, size.height * (1.15 - 0.18 * up));
    final wrist = Offset(size.width * 0.5, size.height * (1.05 - 0.6 * up));
    canvas.drawLine(elbow, wrist, Paint()
      ..strokeWidth = size.width * 0.13
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF3B2266));
    _hand(canvas, wrist, size.width * 0.38, 0, mirrorLeft: true);
    // Arrow flying in from the distance; it meets the shield during the active window.
    final arrowT = ((t - 0.2) / 0.3).clamp(0.0, 1.0);
    final shieldOn = t > 0.38 && t < 0.58;
    final blocked = t >= 0.5;
    if (t > 0.2 && !blocked) {
      final a = Offset.lerp(Offset(size.width * 0.9, size.height * 0.15), Offset(size.width * 0.56, size.height * 0.4), arrowT)!;
      canvas.drawLine(a, a + Offset(size.width * 0.12, -size.height * 0.05), Paint()
        ..strokeWidth = 2.5
        ..color = const Color(0xFFE8DCC0));
      canvas.drawCircle(a, 3.5, Paint()..color = const Color(0xFFFF3B3B));
    }
    if (shieldOn) {
      final rect = Rect.fromCenter(center: Offset(size.width * 0.5, size.height * 0.45), width: size.width * 0.62, height: size.height * 0.56);
      canvas.drawArc(rect, -math.pi * 0.85, math.pi * 0.7, false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..color = _cyan);
      canvas.drawOval(rect, Paint()..color = _cyan.withValues(alpha: 0.12));
    }
    if (blocked && t < 0.66) {
      final k = (t - 0.5) / 0.16;
      canvas.drawCircle(Offset(size.width * 0.6, size.height * 0.36), size.width * (0.05 + 0.12 * k), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white.withValues(alpha: 1 - k));
    }
    _caption(canvas, size, shieldOn ? 'SHIELD · 0.5 s' : (up > 0.9 ? 'raise · hold still' : ''), _cyan);
  }

  void _caption(Canvas canvas, Size size, String text, Color color) {
    if (text.isEmpty) return;
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontFamily: 'Georgia', fontSize: size.width * 0.085, fontWeight: FontWeight.w700, color: color, shadows: const [Shadow(color: Colors.black, blurRadius: 4)])),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    tp.paint(canvas, Offset((size.width - tp.width) / 2, size.height * 0.06));
  }

  @override
  bool shouldRepaint(_IllustrationPainter old) => old.t != t || old.kind != kind;
}
