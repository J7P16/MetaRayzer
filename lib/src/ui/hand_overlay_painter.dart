import 'package:flutter/material.dart';

import '../geometry/view_mapping.dart';
import '../tracking/hand_tracker.dart';

const List<Color> kHandColors = [Color(0xFF00E5FF), Color(0xFFFF9100), Color(0xFF76FF03), Color(0xFFFF4081)];

Color colorForHand(int id) => kHandColors[(id - 1) % kHandColors.length];

/// Bone connections in MediaPipe joint order.
const List<(int, int)> kHandBones = [
  (0, 1), (1, 2), (2, 3), (3, 4), //
  (0, 5), (5, 6), (6, 7), (7, 8),
  (5, 9), (9, 10), (10, 11), (11, 12),
  (9, 13), (13, 14), (14, 15), (15, 16),
  (13, 17), (0, 17), (17, 18), (18, 19), (19, 20),
];

/// Draws the frame-center crosshair and one indicator per tracked hand.
class HandOverlayPainter extends CustomPainter {
  HandOverlayPainter({required this.mapping, required this.hands, this.showLandmarks = false, this.showLabels = true});

  final FrameViewMapping mapping;
  final List<TrackedHand> hands;
  final bool showLandmarks;
  final bool showLabels;

  @override
  void paint(Canvas canvas, Size size) {
    _paintCenter(canvas);
    for (final hand in hands) {
      _paintHand(canvas, hand);
    }
  }

  void _paintCenter(Canvas canvas) {
    final c = mapping.frameCenterInView;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 1.5;
    const arm = 14.0;
    canvas.drawLine(c - const Offset(arm, 0), c + const Offset(arm, 0), paint);
    canvas.drawLine(c - const Offset(0, arm), c + const Offset(0, arm), paint);
    canvas.drawCircle(c, 3, paint..style = PaintingStyle.stroke);
  }

  void _paintHand(Canvas canvas, TrackedHand hand) {
    final color = colorForHand(hand.id);
    final coasting = hand.status == TrackStatus.coasting;
    final alpha = coasting ? 0.45 : 1.0;

    final landmarks = hand.landmarks;
    if (showLandmarks && landmarks != null && !coasting) {
      final bone = Paint()
        ..color = color.withValues(alpha: 0.7)
        ..strokeWidth = 2;
      Offset? jointAt(int j) => landmarks[j * 3 + 2] > 0.3 ? mapping.toView(landmarks[j * 3], landmarks[j * 3 + 1]) : null;
      for (final (a, b) in kHandBones) {
        final pa = jointAt(a), pb = jointAt(b);
        if (pa != null && pb != null) canvas.drawLine(pa, pb, bone);
      }
      final joint = Paint()..color = Colors.white.withValues(alpha: 0.9);
      for (var j = 0; j < 21; j++) {
        final p = jointAt(j);
        if (p != null) canvas.drawCircle(p, 2.5, joint);
      }
    }

    final p = mapping.toView(hand.smoothed.x, hand.smoothed.y);
    if (!mapping.isVisible(p)) return; // cropped away by "cover" fit

    // Line from frame center to the hand: visualizes the center-relative offset.
    canvas.drawLine(
      mapping.frameCenterInView,
      p,
      Paint()
        ..color = color.withValues(alpha: 0.35 * alpha)
        ..strokeWidth = 1.5,
    );

    final dot = Paint()..color = color.withValues(alpha: alpha);
    if (coasting) {
      // Lost: hollow ring at the last known position until the hold timeout removes it.
      canvas.drawCircle(p, 12, dot..style = PaintingStyle.stroke..strokeWidth = 3);
    } else {
      canvas.drawCircle(p, 13, Paint()..color = Colors.black.withValues(alpha: 0.5));
      canvas.drawCircle(p, 11, dot);
    }

    if (showLabels) {
      final label = '#${hand.id}${hand.identityUncertain ? '?' : ''}${coasting ? ' lost' : ''}';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(color: Colors.white.withValues(alpha: alpha), fontSize: 13, fontWeight: FontWeight.w700, shadows: const [Shadow(blurRadius: 3)]),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, p + const Offset(15, -22));
    }
  }

  @override
  bool shouldRepaint(HandOverlayPainter old) => true; // hands mutate in place every frame
}
