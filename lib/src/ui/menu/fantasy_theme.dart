import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../dwell/dwell_scope.dart';
import '../menu_camera_backdrop.dart';

/// Shared look for the menus: night-sky purples, parchment text, gold trim.
abstract final class Fantasy {
  static const gold = Color(0xFFFFD27A);
  static const goldDeep = Color(0xFFC9932E);
  static const ember = Color(0xFFFF8A3D);
  static const parchment = Color(0xFFF3E6C8);
  static const mist = Color(0xFFB9A8D6);
  static const night = Color(0xFF120B26);
  static const plum = Color(0xFF2A1748);
  static const ok = Color(0xFF7CE8A3);
  static const warn = Color(0xFFFFC857);
  static const bad = Color(0xFFFF6B6B);

  static const serif = 'Georgia';

  static TextStyle title(double size) => TextStyle(
    fontFamily: serif,
    fontSize: size,
    fontWeight: FontWeight.w700,
    letterSpacing: size * 0.08,
    color: gold,
    shadows: const [
      Shadow(color: Color(0xAAFF8A3D), blurRadius: 24),
      Shadow(color: Colors.black, blurRadius: 4, offset: Offset(0, 2)),
    ],
  );

  static const TextStyle body = TextStyle(fontFamily: serif, fontSize: 15, color: parchment, height: 1.35);
  static TextStyle label = TextStyle(
    fontFamily: serif,
    fontSize: 12,
    letterSpacing: 2,
    color: mist.withValues(alpha: 0.9),
    fontWeight: FontWeight.w600,
  );
}

/// Starry night background with a glowing horizon, shared by all menu screens. While the live
/// glasses camera shows behind the menus ([MenuBackdropScope]), it becomes a light translucent
/// tint so the player sees the same view the game uses.
class FantasyBackground extends StatelessWidget {
  const FantasyBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MenuBackdropScope.activeOf(context)) {
      return DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x660B0720), Color(0x22231343), Color(0x554A1F4F)]),
        ),
        child: child,
      );
    }
    return CustomPaint(painter: _SkyPainter(), child: child);
  }
}

class _SkyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B0720), Color(0xFF231343), Color(0xFF4A1F4F), Color(0xFF7A3A3A)],
          stops: [0, 0.5, 0.82, 1],
        ).createShader(rect),
    );
    final rng = math.Random(7);
    final star = Paint()..color = Colors.white;
    for (var i = 0; i < 160; i++) {
      final p = Offset(rng.nextDouble() * size.width, rng.nextDouble() * size.height * 0.75);
      star.color = Colors.white.withValues(alpha: 0.25 + rng.nextDouble() * 0.6);
      canvas.drawCircle(p, rng.nextDouble() * 1.4 + 0.3, star);
    }
    final moon = Offset(size.width * 0.82, size.height * 0.18);
    canvas.drawCircle(
      moon,
      90,
      Paint()
        ..shader = RadialGradient(colors: [const Color(0x55FFE6B0), const Color(0x00FFE6B0)])
            .createShader(Rect.fromCircle(center: moon, radius: 90)),
    );
    canvas.drawCircle(moon, 34, Paint()..color = const Color(0xFFFFF1D0));
    canvas.drawCircle(moon + const Offset(11, -7), 30, Paint()..color = const Color(0xFF1A0F33).withValues(alpha: 0.92));
    // Distant mountains.
    final path = Path()..moveTo(0, size.height);
    final mrng = math.Random(3);
    var x = 0.0;
    path.lineTo(0, size.height * 0.84);
    while (x < size.width) {
      x += 40 + mrng.nextDouble() * 80;
      path.lineTo(x, size.height * (0.72 + mrng.nextDouble() * 0.14));
    }
    path
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF140A26));
  }

  @override
  bool shouldRepaint(_SkyPainter old) => false;
}

/// Translucent framed panel.
class FantasyPanel extends StatelessWidget {
  const FantasyPanel({super.key, required this.child, this.padding = const EdgeInsets.all(20)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xCC160C2C),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Fantasy.goldDeep.withValues(alpha: 0.6), width: 1.5),
      boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 30, offset: Offset(0, 10))],
    ),
    child: Padding(padding: padding, child: child),
  );
}

/// Large gold button; hand-dwell selectable via [DwellTarget], mouse/keyboard via InkWell.
class FantasyButton extends StatelessWidget {
  const FantasyButton({super.key, required this.label, required this.onPressed, this.icon, this.primary = false, this.compact = false});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool primary;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final radius = BorderRadius.circular(compact ? 10 : 14);
    return DwellTarget(
      onActivate: onPressed,
      borderRadius: compact ? 10 : 14,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: primary
                ? const LinearGradient(colors: [Color(0xFFFFB347), Color(0xFFE0652B)])
                : const LinearGradient(colors: [Color(0xFF3A2266), Color(0xFF26154A)]),
            border: Border.all(color: (primary ? Fantasy.gold : Fantasy.goldDeep).withValues(alpha: enabled ? 0.9 : 0.3), width: 1.5),
            boxShadow: primary && enabled ? const [BoxShadow(color: Color(0x88FF8A3D), blurRadius: 22)] : null,
          ),
          child: Builder(
            builder: (inner) => InkWell(
              borderRadius: radius,
              onTap: enabled ? () => DwellTarget.activateFromPointer(inner) : null,
              child: Padding(
                padding: compact
                    ? const EdgeInsets.symmetric(horizontal: 14, vertical: 9)
                    : const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: compact ? 18 : 24, color: primary ? const Color(0xFF2A1205) : Fantasy.gold),
                      SizedBox(width: compact ? 6 : 10),
                    ],
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: Fantasy.serif,
                        fontSize: compact ? 14 : 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: compact ? 0.5 : 1.5,
                        color: primary ? const Color(0xFF2A1205) : Fantasy.parchment.withValues(alpha: enabled ? 1 : 0.4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of mutually exclusive options (each one dwell-selectable).
class FantasyChoice<T> extends StatelessWidget {
  const FantasyChoice({super.key, required this.options, required this.selected, required this.onSelected});

  final Map<T, String> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final MapEntry(:key, :value) in options.entries)
        DwellTarget(
          onActivate: () => onSelected(key),
          borderRadius: 10,
          child: Material(
            color: Colors.transparent,
            child: Builder(
              builder: (inner) => InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => DwellTarget.activateFromPointer(inner),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: key == selected ? Fantasy.gold.withValues(alpha: 0.18) : Colors.transparent,
                    border: Border.all(color: key == selected ? Fantasy.gold : Fantasy.mist.withValues(alpha: 0.35)),
                  ),
                  child: Text(value, style: Fantasy.body.copyWith(fontSize: 14, color: key == selected ? Fantasy.gold : Fantasy.parchment)),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// Top-3 list.
class LeaderboardList extends StatelessWidget {
  const LeaderboardList({super.key, required this.scores, this.highlightRank});

  final List<int> scores;
  final int? highlightRank;

  @override
  Widget build(BuildContext context) {
    if (scores.isEmpty) {
      return Text('No scores yet. Be the first wizard to hold the line.', style: Fantasy.body.copyWith(color: Fantasy.mist));
    }
    const medals = [Color(0xFFFFD27A), Color(0xFFD9DDE6), Color(0xFFD6955B)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < scores.length; i++)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: highlightRank == i + 1 ? Fantasy.gold.withValues(alpha: 0.16) : const Color(0x22FFFFFF),
              border: highlightRank == i + 1 ? Border.all(color: Fantasy.gold) : null,
            ),
            child: Row(
              children: [
                Icon(Icons.local_fire_department, color: medals[i % 3], size: 20),
                const SizedBox(width: 10),
                Text(
                  '#${i + 1}',
                  style: Fantasy.body.copyWith(color: medals[i % 3], fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text('${scores[i]}', style: Fantasy.body.copyWith(fontSize: 18, fontWeight: FontWeight.w700)),
                if (highlightRank == i + 1) ...[const SizedBox(width: 8), Text('this run', style: Fantasy.label)],
              ],
            ),
          ),
      ],
    );
  }
}
