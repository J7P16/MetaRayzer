import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../tracking/one_euro_filter.dart';

/// Unit quaternion (x, y, z, w).
@immutable
class Quat {
  const Quat(this.x, this.y, this.z, this.w);
  static const identity = Quat(0, 0, 0, 1);

  final double x, y, z, w;

  Quat normalized() {
    final n = math.sqrt(x * x + y * y + z * z + w * w);
    return n < 1e-9 ? identity : Quat(x / n, y / n, z / n, w / n);
  }

  Quat get conjugate => Quat(-x, -y, -z, w);

  Quat operator *(Quat b) => Quat(
        w * b.x + x * b.w + y * b.z - z * b.y,
        w * b.y - x * b.z + y * b.w + z * b.x,
        w * b.z + x * b.y - y * b.x + z * b.w,
        w * b.w - x * b.x - y * b.y - z * b.z,
      );

  /// Rotates vector v by this quaternion.
  (double, double, double) rotate(double vx, double vy, double vz) {
    final p = this * Quat(vx, vy, vz, 0) * conjugate;
    return (p.x, p.y, p.z);
  }

  /// Rotation of [angle] radians about a unit axis.
  factory Quat.axisAngle(double ax, double ay, double az, double angle) {
    final s = math.sin(angle / 2);
    return Quat(ax * s, ay * s, az * s, math.cos(angle / 2));
  }
}

/// Assumed axes of the glasses' orientation quaternion. Meta's Motion API (experimental, DAT
/// 1.0.x) does not document its frame, so the defaults follow the common right-handed
/// "x right, y up, z backward" convention and can be flipped in settings (invert yaw).
class HeadAxisConvention {
  const HeadAxisConvention({this.forward = const (0.0, 0.0, -1.0), this.yawSign = 1, this.pitchSign = 1});
  final (double, double, double) forward;
  final double yawSign;
  final double pitchSign;
}

enum HeadTrackingStatus {
  /// No orientation source (no glasses motion stream, or the capability isn't enabled).
  unavailable,

  /// Fresh samples are arriving.
  tracking,

  /// Samples stopped recently; the view is easing back toward center.
  lost,
}

class HeadTrackerConfig {
  const HeadTrackerConfig({
    this.lostAfterMs = 300,
    this.unavailableAfterMs = 3000,
    this.recenterTimeConstantS = 0.8,
    this.offsetDecayTimeConstantS = 2.5,
    this.filterMinCutoff = 1.0,
    this.filterBeta = 0.6,
  });

  /// No sample for this long → [HeadTrackingStatus.lost].
  final double lostAfterMs;

  /// No sample for this long → [HeadTrackingStatus.unavailable].
  final double unavailableAfterMs;

  /// While lost, the output decays toward 0 with this time constant (no frozen off-center view).
  final double recenterTimeConstantS;

  /// After (re)acquiring, any continuity offset fades out with this time constant.
  final double offsetDecayTimeConstantS;
  final double filterMinCutoff;
  final double filterBeta;
}

/// Turns raw orientation samples into a smooth head yaw/pitch **relative to a baseline**:
/// - the first sample (and each re-acquisition after a dropout) becomes the baseline, with a
///   continuity offset so the output never jumps;
/// - while samples are missing the output eases back to center;
/// - [recenter] makes the current pose the new "straight ahead" smoothly.
///
/// Pure Dart: driven by sample timestamps and an explicit clock, unit-tested.
class HeadPoseTracker {
  HeadPoseTracker({this.config = const HeadTrackerConfig(), this.axes = const HeadAxisConvention()});

  final HeadTrackerConfig config;
  HeadAxisConvention axes;

  Quat? _baseline;
  double? _lastSampleMs;
  double? _lastUpdateMs;
  double _yaw = 0, _pitch = 0; // output, radians
  double _offsetYaw = 0, _offsetPitch = 0;
  bool _needsRebaseline = true;
  late OneEuroFilter _fy = _filter(), _fp = _filter();

  OneEuroFilter _filter() => OneEuroFilter(minCutoff: config.filterMinCutoff, beta: config.filterBeta);

  double get yaw => _yaw;
  double get pitch => _pitch;

  HeadTrackingStatus statusAt(double nowMs) {
    final last = _lastSampleMs;
    if (last == null || nowMs - last > config.unavailableAfterMs) return HeadTrackingStatus.unavailable;
    if (nowMs - last > config.lostAfterMs) return HeadTrackingStatus.lost;
    return HeadTrackingStatus.tracking;
  }

  /// Relative yaw/pitch of [q] against [base], in radians (+yaw = turned right, +pitch = up).
  (double, double) relativeAngles(Quat base, Quat q) {
    final rel = base.conjugate * q;
    final (fx, fy, fz) = axes.forward;
    final (x, y, z) = rel.rotate(fx, fy, fz);
    // Yaw: angle of the rotated forward vector in the horizontal (x-z) plane, measured toward
    // the right vector r0 = forward × up. Pitch: elevation of the rotated forward vector.
    final (rx, rz) = (-fz, fx);
    final yaw = math.atan2(x * rx + z * rz, x * fx + z * fz);
    final pitch = math.asin(y.clamp(-1.0, 1.0));
    return (yaw * axes.yawSign, pitch * axes.pitchSign);
  }

  void addSample(Quat q, double tMs) {
    q = q.normalized();
    if (_needsRebaseline || _baseline == null) {
      // Re-acquire: new baseline, but keep the current output via an offset (no jump).
      _baseline = q;
      _offsetYaw = _yaw;
      _offsetPitch = _pitch;
      _fy = _filter();
      _fp = _filter();
      _needsRebaseline = false;
    }
    final (ry, rp) = relativeAngles(_baseline!, q);
    final dt = _lastUpdateMs == null ? 0.0 : (tMs - _lastUpdateMs!).clamp(0.0, 1000.0) / 1000;
    _decayOffset(dt);
    _yaw = _fy.filter(ry + _offsetYaw, tMs / 1000);
    _pitch = _fp.filter(rp + _offsetPitch, tMs / 1000);
    _lastSampleMs = tMs;
    _lastUpdateMs = tMs;
  }

  /// Advances time without a sample (call every frame). Handles dropouts.
  void tick(double nowMs) {
    final status = statusAt(nowMs);
    final dt = _lastUpdateMs == null ? 0.0 : (nowMs - _lastUpdateMs!).clamp(0.0, 1000.0) / 1000;
    if (status != HeadTrackingStatus.tracking && _lastSampleMs != null) {
      final k = math.exp(-dt / config.recenterTimeConstantS);
      _yaw *= k;
      _pitch *= k;
      _needsRebaseline = true;
      _lastUpdateMs = nowMs;
    }
  }

  /// Makes the current head pose "straight ahead", easing the view there instead of snapping.
  void recenter() => _needsRebaseline = true; // offset captured at re-baseline then fades out

  void _decayOffset(double dt) {
    if (dt <= 0) return;
    final k = math.exp(-dt / config.offsetDecayTimeConstantS);
    _offsetYaw *= k;
    _offsetPitch *= k;
  }
}

/// What the game uses: the head pose scaled by the user's sensitivity and clamped.
/// effective = measured × sensitivity, in radians (an angular transformation, not pixels).
class HeadView {
  const HeadView({required this.yaw, required this.pitch, required this.status, this.simulated = false});
  static const none = HeadView(yaw: 0, pitch: 0, status: HeadTrackingStatus.unavailable);

  final double yaw;
  final double pitch;
  final HeadTrackingStatus status;
  final bool simulated;

  static HeadView fromMeasured({
    required double yaw,
    required double pitch,
    required double sensitivity,
    required HeadTrackingStatus status,
    double maxYaw = 40 * math.pi / 180,
    double maxPitch = 12 * math.pi / 180,
    bool invertYaw = false,
    bool simulated = false,
  }) =>
      HeadView(
        yaw: ((invertYaw ? -yaw : yaw) * sensitivity).clamp(-maxYaw, maxYaw),
        pitch: (pitch * sensitivity).clamp(-maxPitch, maxPitch),
        status: status,
        simulated: simulated,
      );
}
