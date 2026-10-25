import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'hand_input.dart';
import 'hand_pose.dart';

/// DEVELOPMENT ONLY: a fake hand driven by the mouse and keyboard, for testing gameplay and the
/// hand-controlled menus without glasses. Every frame is flagged [HandInputFrame.simulated] and
/// the UI shows a "SIMULATED HAND" badge while it is active.
///
/// - Pointer position (over the app window) = hand position.
/// - Hold the mouse button or Space/F = closed fist; release = open palm.
/// - Pointer outside the window = no hand.
///
/// Samples are published at a fixed rate like a camera, so frame-based gesture confirmation
/// behaves the same as with real input.
class SimulatedHandInput extends ChangeNotifier implements HandInputSource {
  SimulatedHandInput({this.fps = 30});

  final int fps;
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _timer;
  int _frameId = 0;
  Offset? _position;
  bool _fist = false;
  HandInputFrame _value = HandInputFrame.unavailable;

  @override
  HandInputFrame get value => _value;

  @override
  String get label => 'Simulated hand (mouse/keyboard)';

  @override
  bool get isSimulated => true;

  bool get isFist => _fist;

  /// Start/stop publishing samples (only while selected, so it costs nothing otherwise).
  set active(bool active) {
    if (active && _timer == null) {
      _timer = Timer.periodic(Duration(microseconds: 1000000 ~/ fps), (_) => _emit());
      _emit();
    } else if (!active) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// [normalized] is the pointer position in the app window (0..1), or null when outside.
  void move(Offset? normalized) => _position = normalized;

  void setFist(bool fist) => _fist = fist;

  void _emit() {
    _frameId++;
    final now = _clock.elapsedMicroseconds / 1000;
    final position = _position;
    _value = position == null
        ? HandInputFrame(status: HandTrackingStatus.searching, frameId: _frameId, timestampMs: now, simulated: true)
        : HandInputFrame(
            status: HandTrackingStatus.tracking,
            frameId: _frameId,
            timestampMs: now,
            position: position,
            simulated: true,
            handId: 1,
            classification: PoseClassification(
              pose: _fist ? HandPose.fist : HandPose.open,
              confidence: 1,
              openness: _fist ? 0 : 1,
            ),
          );
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
