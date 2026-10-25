import 'dart:math' as math;
import 'dart:ui';

import '../../input/hand_input.dart';
import '../../tracking/one_euro_filter.dart';
import '../../ui/dwell/dwell_selector.dart';

/// Tuning for the staff and aiming (see README > Staff and aiming).
class AimConfig {
  const AimConfig({
    this.interactionBox = const Rect.fromLTRB(0.2, 0.15, 0.8, 0.85),
    this.handYawRange = 32 * math.pi / 180,
    this.staffRegion = const Rect.fromLTRB(0.10, 0.40, 0.60, 0.80),
    this.restPosition = const Offset(0.2, 0.75),
    this.filterMinCutoff = 1.5,
    this.filterBeta = 4.0,
    this.restAfterLostMs = 500,
  });

  /// Part of the camera view (display-normalized) that spans the full aim/staff range. Same box
  /// as the menu cursor, so "hand in the middle" means the same thing everywhere.
  final Rect interactionBox;

  /// Aim yaw at the left/right edge of the interaction box (± this, radians).
  final double handYawRange;

  /// Where the staff tip may move on screen (fractions of the game viewport): the lower-left of
  /// the first-person view, clear of the HUD and the center of the arena.
  final Rect staffRegion;

  /// Staff tip position (0..1 within [staffRegion]) when no hand is tracked.
  final Offset restPosition;

  /// One Euro smoothing of the staff tip: higher beta = less lag on fast motion.
  final double filterMinCutoff;
  final double filterBeta;

  /// After losing the hand this long, the staff drifts back to its rest pose.
  final double restAfterLostMs;
}

/// Hand + head → staff pose and a world aim direction.
///
/// Coordinate chain (one consistent pipeline):
///   camera frame → display-normalized hand position (preview mirror/rotation already applied
///   by [CameraHandInput]) → normalized within [AimConfig.interactionBox] (0..1, clamped)
///   → staff tip in [AimConfig.staffRegion] (screen), and
///   → hand yaw = (u − 0.5) × 2 × handYawRange; world aim yaw = head view yaw + hand yaw.
/// The renderer rotates the world by the head view yaw, so the aim stays attached to the staff
/// whichever way the player looks.
class StaffAim {
  StaffAim({this.config = const AimConfig()});

  final AimConfig config;
  late final OneEuroFilter _fx = OneEuroFilter(minCutoff: config.filterMinCutoff, beta: config.filterBeta);
  late final OneEuroFilter _fy = OneEuroFilter(minCutoff: config.filterMinCutoff, beta: config.filterBeta);

  Offset _tip = const Offset(0.2, 0.75);
  double? _lostSinceMs;
  bool _hasHand = false;

  /// Staff tip within the staff region, 0..1 (smoothed, clamped).
  Offset get tip => _tip;

  /// Whether the staff is currently driven by a tracked hand.
  bool get hasHand => _hasHand;

  /// Hand-relative aim yaw (radians), derived from the smoothed staff position.
  double get handYaw => (_tip.dx - 0.5) * 2 * config.handYawRange;

  /// World aim direction: where Chain Lightning goes and the reticle points.
  double worldAimYaw(double headYaw) => headYaw + handYaw;

  /// Maps a display-normalized hand position into the 0..1 interaction box.
  Offset boxNormalized(Offset hand) => const CursorMapper().copyWithBox(config.interactionBox).normalize(hand);

  void update(HandInputFrame frame, double nowMs) {
    final position = frame.position;
    if (frame.status == HandTrackingStatus.tracking && position != null) {
      _lostSinceMs = null;
      _hasHand = true;
      final target = frame.simulated ? Offset(position.dx.clamp(0.0, 1.0), position.dy.clamp(0.0, 1.0)) : boxNormalized(position);
      _setTip(target, nowMs);
      return;
    }
    // No reliable hand: hold the staff where it was briefly, then let it sink to its rest pose.
    _hasHand = false;
    _lostSinceMs ??= nowMs;
    if (nowMs - _lostSinceMs! >= config.restAfterLostMs) _setTip(config.restPosition, nowMs);
  }

  void _setTip(Offset target, double nowMs) {
    final t = nowMs / 1000;
    _tip = Offset(_fx.filter(target.dx, t).clamp(0.0, 1.0), _fy.filter(target.dy, t).clamp(0.0, 1.0));
  }

  /// Staff tip in viewport pixels.
  Offset tipOnScreen(Size viewport) {
    final r = config.staffRegion;
    return Offset((r.left + r.width * _tip.dx) * viewport.width, (r.top + r.height * _tip.dy) * viewport.height);
  }
}

/// Ray test used by directional spells: is a world point within [halfWidth] of the aim ray
/// (from the origin along [yaw]) and in front of the player? Returns the distance along the ray.
double? distanceAlongAim(double yaw, double x, double z, {required double halfWidth, required double range}) {
  final dx = math.sin(yaw), dz = math.cos(yaw);
  final along = x * dx + z * dz;
  if (along <= 0 || along > range) return null;
  final perpendicular = (x * dz - z * dx).abs();
  return perpendicular <= halfWidth ? along : null;
}
