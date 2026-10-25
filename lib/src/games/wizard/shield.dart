import 'dart:math' as math;

import 'wizard_config.dart';

enum ShieldState {
  /// Can be raised by the next shield pose.
  ready,

  /// Blocking projectiles for [ShieldSpec.activeSeconds].
  active,

  /// The window ended (or the pose is still held): waiting for the pose to be released and for
  /// [ShieldSpec.rearmSeconds] to pass.
  recharging,
}

/// The base-kit shield's activation state machine. Pure logic: time advances only through
/// [update]; the pose comes from the gesture recognizer through [setPose].
///
///   ready ──pose rising──▶ active ──0.5 s──▶ recharging ──pose released + rearm time──▶ ready
///
/// - A held pose never extends or retriggers the window (activation needs a released pose).
/// - Releasing the pose during the window does not end it early; the block lasts exactly
///   [ShieldSpec.activeSeconds].
///
/// With the gesture recognizer (`ShieldGestureRecognizer`) the whole cycle is
/// Idle (recognizer idle, shield ready) → Recognizing (recognizer) → Active (shield, 0.5 s) →
/// Awaiting Release (shield recharging until the recognizer reports the release) → Idle.
/// Neither side can keep the shield up: the window is timed here, whatever the input does.
class Shield {
  Shield(this.spec);

  final ShieldSpec spec;

  ShieldState _state = ShieldState.ready;
  double _remaining = 0;
  double _sinceEnded = double.infinity;
  bool _poseHeld = false;

  /// True once the pose has been released since the last activation.
  bool _released = true;

  /// Direction the shield faces (world yaw, radians), set by the game each frame.
  double yaw = 0;
  int activations = 0;

  ShieldState get state => _state;
  bool get isActive => _state == ShieldState.active;

  /// Seconds left in the active window (0 when inactive).
  double get remaining => _state == ShieldState.active ? _remaining : 0;

  /// 1 at activation → 0 at expiry.
  double get activeFraction => spec.activeSeconds <= 0 ? 0 : remaining / spec.activeSeconds;

  /// Reports whether the shield pose is held right now. Returns true when this call activated
  /// the shield.
  bool setPose(bool held) {
    final rising = held && !_poseHeld;
    _poseHeld = held;
    if (!held) _released = true;
    if (rising && _state == ShieldState.ready && _released) {
      _state = ShieldState.active;
      _remaining = spec.activeSeconds;
      _released = false;
      activations++;
      return true;
    }
    return false;
  }

  /// Advances time. Returns true when the active window ended during this step.
  bool update(double dt) {
    switch (_state) {
      case ShieldState.active:
        _remaining -= dt;
        if (_remaining <= 1e-9) {
          _remaining = 0;
          _state = ShieldState.recharging;
          _sinceEnded = 0;
          return true;
        }
      case ShieldState.recharging:
        _sinceEnded += dt;
        if (_released && !_poseHeld && _sinceEnded >= spec.rearmSeconds) _state = ShieldState.ready;
      case ShieldState.ready:
        break;
    }
    return false;
  }

  /// Whether a projectile at (x, z) is inside the covered arc (direction only; the caller checks
  /// the distance).
  bool covers(double x, double z) {
    final bearing = math.atan2(x, z);
    var diff = bearing - yaw;
    while (diff > math.pi) {
      diff -= 2 * math.pi;
    }
    while (diff < -math.pi) {
      diff += 2 * math.pi;
    }
    return diff.abs() <= spec.halfAngle;
  }

  void reset() {
    _state = ShieldState.ready;
    _remaining = 0;
    _sinceEnded = double.infinity;
    _poseHeld = false;
    _released = true;
  }
}
