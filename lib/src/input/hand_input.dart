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
