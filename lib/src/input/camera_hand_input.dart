import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import '../app/tracking_controller.dart';
import '../geometry/view_mapping.dart';
import '../tracking/hand_tracker.dart';
import 'hand_input.dart';
import 'hand_pose.dart';

/// Adapts the existing camera pipeline ([TrackingController]: glasses via the iPhone companion,
/// or the Mac-webcam dev source) to the small [HandInputFrame] interface.
///
/// Responsibilities: decide availability, pick ONE player hand (sticky across frames, honoring
/// [HandPreference]), classify its pose from landmarks, and convert its position to
/// display-normalized coordinates (respecting the preview's mirror/rotation settings).
class CameraHandInput extends ChangeNotifier implements HandInputSource {
  CameraHandInput(this._controller, {HandPreference Function()? preference, this.classifier = const PoseClassifier()})
      : _preference = preference ?? (() => HandPreference.left) {
    _controller.addListener(_onControllerChanged);
    _value = _compute(_controller.frame);
  }

  final TrackingController _controller;
  final HandPreference Function() _preference;
  final PoseClassifier classifier;
  final Stopwatch _clock = Stopwatch()..start();

  HandInputFrame _value = HandInputFrame.unavailable;
  FrameEvent? _lastFrame;
  int _frameId = 0;
  int? _selectedHandId;

  @override
  HandInputFrame get value => _value;

  @override
  String get label => _controller.source == FrameSource.webcam ? 'Mac webcam (dev)' : 'Glasses camera';

  @override
  bool get isSimulated => false;

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final frame = _controller.frame;
    final newFrame = frame != null && !identical(frame, _lastFrame);
    if (newFrame) {
      _lastFrame = frame;
      _frameId++;
    }
    final next = _compute(frame);
    // Publish on every new camera frame, and on status changes between frames (e.g. the hand
    // expiring or the stream stalling), but not for unrelated controller notifications.
    if (newFrame || next.status != _value.status || next.handId != _value.handId || next.message != _value.message) {
      if (next.status != _value.status || next.message != _value.message) {
        debugPrint('[metarayzer] hand input: ${next.status.name}${next.message != null ? ' (${next.message})' : ''}');
      }
      _value = next;
      notifyListeners();
    }
  }

  HandInputFrame _compute(FrameEvent? frame) {
    final now = _clock.elapsedMicroseconds / 1000;
    HandInputFrame unavailable(String message) =>
        HandInputFrame(status: HandTrackingStatus.unavailable, frameId: _frameId, timestampMs: now, message: message);

    if (!_controller.detectionEnabled) return unavailable('Hand detection is turned off');
    if (frame == null) {
      if (_controller.source == FrameSource.companion) {
        return unavailable(_controller.companionConnected ? 'Glasses camera not streaming' : 'Glasses not connected');
      }
      return unavailable('Waiting for the Mac webcam');
    }
    if (_controller.streamStalled) return unavailable('Camera stream stalled');

    final hand = _selectHand(_controller.hands);
    if (hand == null) {
      _selectedHandId = null;
      return HandInputFrame(status: HandTrackingStatus.searching, frameId: _frameId, timestampMs: now);
    }
    _selectedHandId = hand.id;

    final mapping = FrameViewMapping(
      frameSize: Size(frame.width.toDouble(), frame.height.toDouble()),
      viewSize: const Size(1, 1),
      mirrored: _controller.mirrored,
      quarterTurns: _controller.quarterTurns,
    );
    final position = mapping.displayNormalized(hand.smoothed.x, hand.smoothed.y);
    final tracking = hand.status == TrackStatus.active;
    final landmarks = hand.landmarks;
    final classification = tracking && landmarks != null
        ? classifier.classify(landmarks, aspect: frame.width / frame.height, handConfidence: hand.confidence)
        : PoseClassification.none; // a lost hand's landmarks are stale: never classify them
    return HandInputFrame(
      status: tracking ? HandTrackingStatus.tracking : HandTrackingStatus.lost,
      frameId: _frameId,
      timestampMs: now,
      position: position,
      classification: classification,
      handId: hand.id,
      shape: tracking && landmarks != null ? handShape(landmarks, mapping) : null,
    );
  }

  /// Hand geometry in display-normalized coordinates (after the preview's mirror/rotation, like
  /// the position). Null without a confident wrist and middle knuckle or fewer than 8 joints.
  static HandShape? handShape(Float64List landmarks, FrameViewMapping mapping, {double minJointConfidence = 0.3}) {
    if (landmarks.length < 63) return null;
    Offset point(int j) => mapping.displayNormalized(landmarks[j * 3], landmarks[j * 3 + 1]);
    double conf(int j) => landmarks[j * 3 + 2];
    const wrist = 0, middleMcp = 9;
    if (conf(wrist) < minJointConfidence || conf(middleMcp) < minJointConfidence) return null;
    var (minX, minY, maxX, maxY) = (double.infinity, double.infinity, -double.infinity, -double.infinity);
    var used = 0;
    var confidence = 0.0;
    for (var j = 0; j < 21; j++) {
      if (conf(j) < minJointConfidence) continue;
      final p = point(j);
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
      confidence += conf(j);
      used++;
    }
    if (used < 8) return null;
    final shown = mapping.displayedFrameSize;
    return HandShape(
      bounds: Rect.fromLTRB(minX, minY, maxX, maxY),
      wrist: point(wrist),
      middleKnuckle: point(middleMcp),
      aspect: shown.height <= 0 ? 1 : shown.width / shown.height,
      confidence: (confidence / used).clamp(0.0, 1.0),
    );
  }

  /// Keeps following the same hand while it is visible; otherwise picks the preferred hand,
  /// falling back to any hand (Vision's left/right label is not always reliable), choosing the
  /// largest (closest) one.
  TrackedHand? _selectHand(List<TrackedHand> hands) {
    if (hands.isEmpty) return null;
    for (final h in hands) {
      if (h.id == _selectedHandId) return h;
    }
    final preference = _preference();
    final wanted = switch (preference) {
      HandPreference.left => 'left',
      HandPreference.right => 'right',
      HandPreference.any => null,
    };
    final active = hands.where((h) => h.status == TrackStatus.active).toList();
    final pool = active.isEmpty ? hands : active;
    final matching = wanted == null ? pool : pool.where((h) => h.chirality == wanted).toList();
    final candidates = matching.isEmpty ? pool : matching;
    double size(TrackedHand h) => h.box?.area ?? 0;
    return candidates.reduce((a, b) => size(b) > size(a) ? b : a);
  }
}
