import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import 'head_pose.dart';

/// Head orientation input for the game view and aim.
///
/// Real source: the glasses' orientation quaternion from Meta's experimental Motion capability,
/// relayed by the iPhone companion ([TrackingController.headMotion]). Development source:
/// arrow keys (only while simulated input is on, clearly labeled). Hand movement is never used
/// as a stand-in for head movement.
class HeadInput extends ChangeNotifier {
  HeadInput(this._samples, {double Function()? nowMs}) : _nowMs = nowMs ?? _defaultClock {
    _samples.addListener(_onSample);
  }

  final ValueListenable<MotionEvent?> _samples;
  final double Function() _nowMs;
  final HeadPoseTracker tracker = HeadPoseTracker();

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static double _defaultClock() => _stopwatch.elapsedMicroseconds / 1000;

  bool simulated = false;
  double _simYaw = 0;
  double _simPitch = 0;
  double _simYawRate = 0;
  double _simPitchRate = 0;
  double? _lastTickMs;
  HeadTrackingStatus? _lastStatus;

  void _onSample() {
    final m = _samples.value;
    if (m == null || simulated) return;
    tracker.addSample(Quat(m.x, m.y, m.z, m.w), _nowMs());
  }

  /// Dev keys: −1/0/+1 turning rate per axis (left/right, down/up).
  void setSimulatedTurn({double yaw = 0, double pitch = 0}) {
    _simYawRate = yaw;
    _simPitchRate = pitch;
  }

  void recenter() {
    tracker.recenter();
    _simYaw = 0;
    _simPitch = 0;
  }

  /// The head pose to apply this frame, after sensitivity. Call once per game tick.
  HeadView view({required double sensitivity, required bool invertYaw}) {
    final now = _nowMs();
    final dt = _lastTickMs == null ? 0.0 : ((now - _lastTickMs!) / 1000).clamp(0.0, 0.1);
    _lastTickMs = now;
    if (simulated) {
      const speed = 50 * math.pi / 180; // rad/s while a key is held
      _simYaw = (_simYaw + _simYawRate * speed * dt).clamp(-0.6, 0.6);
      _simPitch = (_simPitch + _simPitchRate * speed * dt).clamp(-0.3, 0.3);
      if (_simYawRate == 0) _simYaw *= math.exp(-dt / 1.5); // drift back to center
      if (_simPitchRate == 0) _simPitch *= math.exp(-dt / 1.5);
      return HeadView.fromMeasured(yaw: _simYaw, pitch: _simPitch, sensitivity: sensitivity, status: HeadTrackingStatus.tracking, invertYaw: invertYaw, simulated: true);
    }
    tracker.tick(now);
    final status = tracker.statusAt(now);
    if (status != _lastStatus) {
      debugPrint('[metarayzer] head tracking: ${status.name}');
      _lastStatus = status;
    }
    return HeadView.fromMeasured(yaw: tracker.yaw, pitch: tracker.pitch, sensitivity: sensitivity, status: tracker.statusAt(now), invertYaw: invertYaw);
  }

  HeadTrackingStatus get status => simulated ? HeadTrackingStatus.tracking : tracker.statusAt(_nowMs());

  @override
  void dispose() {
    _samples.removeListener(_onSample);
    super.dispose();
  }
}
