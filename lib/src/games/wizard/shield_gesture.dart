import 'dart:math' as math;
import 'dart:ui';

import '../../input/hand_input.dart';

/// Thresholds for the shield's blocking pose. Every value is a starting point validated on
/// synthetic and simulated input only; tune them here after testing with the glasses camera.
///
/// The pose: the forearm raised upright close in front of the face, so the hand shows up in the
/// camera as a large, upright, vertical shape in the middle of the view. It is measured from
/// tracked hand geometry ([HandShape]), not from a single landmark:
/// - coverage: how much of the shield region's HEIGHT the hand spans, counted only while the
///   hand overlaps the region horizontally and its center lies inside it. A vertical line through
///   the region covers it; the hand does not have to fill the camera image.
/// - closeness: the wrist → middle-knuckle length relative to the frame height.
/// - orientation: the hand axis within [maxTilt] of vertical (fingers up).
/// - extension: the hand reaches well above its knuckles ([minReach] × palm length), which
///   rejects a fist. (Height/width does not work: a real upright open palm with a spread thumb is
///   about as wide as it is tall — measured on the real Vision landmarks in test/fixtures.)
/// Separate, looser exit thresholds (hysteresis) keep tracking noise from toggling the pose.
class ShieldGestureConfig {
  const ShieldGestureConfig({
    this.region = const Rect.fromLTRB(0.30, 0.15, 0.70, 0.85),
    this.minCoverage = 0.45,
    this.exitCoverage = 0.30,
    this.minPalmLength = 0.13,
    this.exitPalmLength = 0.10,
    this.maxTilt = 0.61, // 35°
    this.exitTilt = 0.79, // 45°
    this.minReach = 1.5,
    this.minConfidence = 0.45,
    this.confirmFrames = 2,
    this.releaseFrames = 2,
    this.dropoutReleaseMs = 250,
    this.smoothing = 0.5,
  });

  /// The shield-blocking region of the displayed camera view (normalized).
  final Rect region;

  /// Fraction of [region]'s height the hand must span to enter / stay in the pose.
  final double minCoverage;
  final double exitCoverage;
  final double minPalmLength;
  final double exitPalmLength;
  final double maxTilt;
  final double exitTilt;
  final double minReach;

  /// Below this joint confidence a frame is ignored (neither entering nor releasing).
  final double minConfidence;

  /// New frames in a row that must meet the entry thresholds before the pose counts.
  final int confirmFrames;

  /// New frames in a row failing the exit thresholds before the pose counts as released.
  final int releaseFrames;

  /// A hand missing for longer than this counts as released.
  final double dropoutReleaseMs;

  /// Exponential smoothing weight of the newest coverage sample (1 = no smoothing).
  final double smoothing;
}

/// One frame's blocking-pose measurements (for tests and the debug readout).
class BlockPoseMetrics {
  const BlockPoseMetrics({required this.coverage, required this.palmLength, required this.tilt, required this.reach, required this.centered});
  final double coverage;
  final double palmLength;
  final double tilt;
  final double reach;

  /// The hand's center lies horizontally inside the region.
  final bool centered;

  static BlockPoseMetrics measure(HandShape shape, Rect region) {
    final b = shape.bounds;
    final overlapsX = b.right >= region.left && b.left <= region.right;
    final centered = b.center.dx >= region.left && b.center.dx <= region.right;
    final spanned = math.max(0.0, math.min(b.bottom, region.bottom) - math.max(b.top, region.top));
    final coverage = overlapsX && centered ? spanned / region.height : 0.0;
    return BlockPoseMetrics(coverage: coverage, palmLength: shape.palmLength, tilt: shape.tilt, reach: shape.verticalReach, centered: centered);
  }
}

/// Recognizes the deliberate blocking pose with smoothing, hysteresis and short temporal
/// validation. [held] is the debounced pose; [update] returns true only on the frame the pose
/// becomes held (the shield's activation request). The shield itself enforces the 0.5 s window
/// and the release/re-arm rule; this class only says whether the pose is held.
///
/// Fails safe: low-confidence frames and short dropouts change nothing (they never activate);
/// a dropout longer than [ShieldGestureConfig.dropoutReleaseMs] releases the pose.
class ShieldGestureRecognizer {
  ShieldGestureRecognizer({this.config = const ShieldGestureConfig()});

  final ShieldGestureConfig config;

  bool _held = false;
  int _enterCount = 0;
  int _exitCount = 0;
  int _lastFrameId = -1;
  double? _coverage;
  double? _lostSinceMs;
  BlockPoseMetrics? _metrics;

  bool get held => _held;
  BlockPoseMetrics? get metrics => _metrics;

  /// 0..1 progress toward the entry thresholds (for a "raise higher" hint).
  double get readiness => _held ? 1 : ((_coverage ?? 0) / config.minCoverage).clamp(0.0, 1.0);

  /// Whether the current frame looks like the pose (before temporal confirmation). The game uses
  /// it to keep a raised blocking hand from also firing a cast.
  bool candidate = false;

  void reset() {
    _held = false;
    _enterCount = 0;
    _exitCount = 0;
    _coverage = null;
    _lostSinceMs = null;
    _metrics = null;
    candidate = false;
  }

  bool update(HandInputFrame frame) {
    final shape = frame.shape;
    if (frame.status != HandTrackingStatus.tracking || shape == null) {
      candidate = false;
      _enterCount = 0;
      _lostSinceMs ??= frame.timestampMs;
      if (_held && frame.timestampMs - _lostSinceMs! > config.dropoutReleaseMs) _release();
      return false;
    }
    _lostSinceMs = null;
    if (frame.frameId == _lastFrameId) return false; // status-only re-delivery
    _lastFrameId = frame.frameId;
    if (shape.confidence < config.minConfidence) {
      candidate = false;
      return false;
    }

    final m = BlockPoseMetrics.measure(shape, config.region);
    _metrics = m;
    final previous = _coverage;
    _coverage = previous == null ? m.coverage : previous + (m.coverage - previous) * config.smoothing;
    final coverage = _coverage!;

    final entering = coverage >= config.minCoverage && m.palmLength >= config.minPalmLength && m.tilt <= config.maxTilt && m.reach >= config.minReach;
    final holding = coverage >= config.exitCoverage && m.palmLength >= config.exitPalmLength && m.tilt <= config.exitTilt;
    candidate = entering || (_held && holding);

    if (_held) {
      _exitCount = holding ? 0 : _exitCount + 1;
      if (_exitCount >= config.releaseFrames) _release();
      return false;
    }
    _enterCount = entering ? _enterCount + 1 : 0;
    if (_enterCount >= config.confirmFrames) {
      _held = true;
      _exitCount = 0;
      return true;
    }
    return false;
  }

  void _release() {
    _held = false;
    _enterCount = 0;
    _exitCount = 0;
  }
}
