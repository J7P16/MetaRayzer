import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'hand_pose.dart';

/// How reliable hand input is right now.
enum HandTrackingStatus {
  /// No usable source: glasses/companion not streaming, detection off, or stream stalled.
  unavailable,

  /// Frames are arriving but no hand is in view.
  searching,

  /// A hand is detected in the current frame.
  tracking,

  /// The hand was just lost; [HandInputFrame.position] is its last known position.
  lost,
}

/// Coarse geometry of the tracked hand in display-normalized coordinates (same space as
/// [HandInputFrame.position]), derived from the landmarks by the input adapter so consumers
/// (the shield gesture) never handle raw landmarks.
@immutable
class HandShape {
  const HandShape({required this.bounds, required this.wrist, required this.middleKnuckle, required this.aspect, this.confidence = 1});

  /// Bounding box of the confident joints (0..1 of the displayed frame).
  final Rect bounds;
  final Offset wrist;

  /// Middle-finger knuckle (MCP): wrist → knuckle is the hand's main axis.
  final Offset middleKnuckle;

  /// Displayed frame width / height, to measure angles and lengths in square units.
  final double aspect;

  /// Mean confidence of the joints used.
  final double confidence;

  /// Wrist → middle knuckle length as a fraction of the frame height: grows as the hand comes
  /// closer to the camera.
  double get palmLength {
    final d = middleKnuckle - wrist;
    return math.sqrt(math.pow(d.dx * aspect, 2) + d.dy * d.dy);
  }

  /// Angle between the hand axis and straight up (radians, 0 = fingers pointing up).
  double get tilt {
    final d = middleKnuckle - wrist;
    return math.atan2((d.dx * aspect).abs(), -d.dy).abs();
  }

  /// Vertical extent of the hand relative to its palm length: ~2 for an upright hand with the
  /// fingers extended (fingertips well above the knuckles), ~1.2 for a fist. Unlike height/width
  /// it is not fooled by a spread thumb.
  double get verticalReach {
    final palm = palmLength;
    return palm <= 1e-9 ? 0 : bounds.height / palm;
  }
}

/// Which hand the player controls with.
enum HandPreference { left, right, any }

/// One update of the game/UI-facing hand input. This is the ONLY thing gameplay and menus see
/// of the camera pipeline: no frames, no landmarks, no camera coordinates beyond a normalized
/// position.
@immutable
class HandInputFrame {
  const HandInputFrame({
    required this.status,
    required this.frameId,
    required this.timestampMs,
    this.position,
    this.classification = PoseClassification.none,
    this.handId,
    this.simulated = false,
    this.message,
    this.shape,
  });

  static const unavailable = HandInputFrame(status: HandTrackingStatus.unavailable, frameId: -1, timestampMs: 0);

  final HandTrackingStatus status;

  /// Increases by one for each new camera frame (or simulated sample). Consumers that count
  /// frames (gesture confirmation) must only count frames with a new id.
  final int frameId;

  /// Monotonic milliseconds.
  final double timestampMs;

  /// Hand center in *display-normalized* coordinates (0..1, top-left origin, after the preview's
  /// mirroring/rotation), or null when there is no hand.
  final Offset? position;
  final PoseClassification classification;

  /// Temporary tracking id of the selected hand.
  final int? handId;

  /// True for the development mouse/keyboard source. Never true for camera input.
  final bool simulated;

  /// Human-readable reason for [HandTrackingStatus.unavailable], for status UI.
  final String? message;

  /// Hand geometry (only while [HandTrackingStatus.tracking] with usable landmarks).
  final HandShape? shape;

  HandPose get pose => classification.pose;
  bool get hasHand => status == HandTrackingStatus.tracking;
}

/// A source of [HandInputFrame]s. Implementations: [CameraHandInput] (real pipeline) and
/// [SimulatedHandInput] (development only).
abstract class HandInputSource implements ValueListenable<HandInputFrame> {
  String get label;
  bool get isSimulated;
  void dispose();
}
