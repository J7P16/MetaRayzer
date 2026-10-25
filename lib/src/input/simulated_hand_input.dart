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
/// - Hold V key = V sign (spell-switch pose).
/// - Hold B key = shield blocking pose (an upright hand filling the middle of the view).
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
  bool _victory = false;
  bool _block = false;
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

  void setVictory(bool victory) => _victory = victory;

  void setBlock(bool block) => _block = block;

  /// The geometry a real upright hand raised close in front of the camera produces.
  static const blockShape = HandShape(
    bounds: Rect.fromLTRB(0.36, 0.14, 0.62, 0.84),
    wrist: Offset(0.49, 0.80),
    middleKnuckle: Offset(0.49, 0.52),
    aspect: 504 / 896,
  );

  /// An ordinary hand at arm's length (for casting).
  static HandShape _castShape(Offset at) => HandShape(
        bounds: Rect.fromCenter(center: at, width: 0.14, height: 0.2),
        wrist: at + const Offset(0, 0.08),
        middleKnuckle: at + const Offset(0, 0.0),
        aspect: 504 / 896,
      );

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
            position: _block ? blockShape.bounds.center : position,
            simulated: true,
            handId: 1,
            shape: _block ? blockShape : _castShape(position),
            classification: PoseClassification(
              pose: _block ? HandPose.open : (_victory ? HandPose.victory : (_fist ? HandPose.fist : HandPose.open)),
              confidence: 1,
              openness: _fist ? 0 : (_victory ? 0.5 : 1),
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
