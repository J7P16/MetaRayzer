import 'dart:math' as math;

import '../../input/hand_input.dart';
import '../../input/hand_pose.dart';

/// Thresholds for the shield's one-finger pose. Values were chosen from the real Apple Vision
/// landmarks in test/fixtures (pointing_up.jpg: index straight at 175–179° with a tip 2.0× the
/// knuckle distance from the wrist; the other fingers bent to 26–50° at the middle joint and
/// folded to 0.65–0.75×) and checked against synthetic and simulated input only. Tune them here
/// after testing with the glasses camera.
///
/// The pose: the index finger held up (extended), middle, ring and little fingers curled. Each
/// finger is measured from tracked joint landmarks by the [PoseClassifier] in two independent
/// ways, both invariant to hand size, distance and in-plane rotation:
/// - extension: wrist → fingertip distance relative to wrist → knuckle;
/// - straightness: the joint angles at the finger's middle (PIP) and end (DIP) joints.
/// Their mean is the finger's "extended" score; 1 minus it is its "curled" score. The thumb is
/// ignored (Vision's thumb joints are unreliable), and the hand may be anywhere in view: the
/// shield blocks along the aim direction, not at the hand's screen position.
///
/// Separate, looser exit thresholds (hysteresis) and exponential smoothing keep landmark noise
/// from toggling the pose.
class ShieldGestureConfig {
  const ShieldGestureConfig({
    this.enterIndex = 0.75,
    this.exitIndex = 0.5,
    this.enterCurled = 0.7,
    this.exitCurled = 0.45,
    this.minConfidence = 0.45,
    this.confirmFrames = 3,
    this.recognizeMs = 80,
    this.releaseFrames = 2,
    this.dropoutReleaseMs = 300,
    this.smoothing = 0.5,
  });

  /// Index finger "extended" score (0..1) needed to enter / stay in the pose.
  final double enterIndex;
  final double exitIndex;

  /// "Curled" score (0..1) each of the middle, ring and little fingers needs to enter / stay.
  final double enterCurled;
  final double exitCurled;

  /// Below this classification confidence a frame is ignored: it never enters the pose, and
  /// never counts as a release either.
  final double minConfidence;

  /// The pose must be seen in at least this many new frames in a row ...
  final int confirmFrames;

  /// ... spanning at least this long (ms) before it is recognized (the recognition interval).
  final double recognizeMs;

  /// New confident frames in a row failing the exit thresholds before the pose counts as
  /// released.
  final int releaseFrames;

  /// A hand missing for longer than this counts as released.
  final double dropoutReleaseMs;

  /// Exponential smoothing weight of the newest finger scores (1 = no smoothing).
  final double smoothing;
}

/// One frame's (smoothed) finger measurements for the one-finger pose, for tests and debugging.
class OneFingerMetrics {
  const OneFingerMetrics({required this.index, required this.curled, required this.confidence});

  /// Index finger "extended" score, 0..1.
  final double index;

  /// "Curled" scores of the middle, ring and little fingers, 0..1.
  final List<double> curled;

  /// Classification (joint × hand) confidence of the frame.
  final double confidence;

  /// The least-curled of the other three fingers.
  double get minCurled => curled.reduce(math.min);

  /// Raw (unsmoothed) scores of one classification, or null when any of the four fingers could
  /// not be measured (missing or low-confidence joints): such a frame is ambiguous.
  static OneFingerMetrics? measure(PoseClassification c) {
    final ext = c.fingerExtension, straight = c.fingerStraightness;
    if (ext.length < 4 || straight.length < 4) return null;
    final extended = <double>[];
    for (var f = 0; f < 4; f++) {
      if (ext[f] < 0 || straight[f] < 0) return null;
      extended.add((ext[f] + straight[f]) / 2);
    }
    return OneFingerMetrics(index: extended[0], curled: [for (final e in extended.skip(1)) 1 - e], confidence: c.confidence);
  }
}

/// Where the one-finger recognizer is. Together with the shield's own state machine this gives
/// the full activation cycle:
///
///   idle ──pose seen──▶ recognizing ──stable for the recognition interval──▶ held
///     ▲                     │ pose lost / ambiguous / low confidence            │ (activation)
///     └─────────────────────┘                                                   ▼
///     └────────────── release recognized ◀── releasing ◀── confident non-pose frames
///
/// [ShieldGestureRecognizer.update] reports the activation once, on entering [held]. The shield
/// ([Shield]) then stays active for exactly its window and waits in `recharging` until this
/// recognizer has recognized the release ("awaiting release").
enum ShieldGesturePhase { idle, recognizing, held, releasing }

/// Recognizes the shield's one-finger pose with smoothing, hysteresis and a short recognition
/// interval. [held] is the debounced pose; [update] returns true only on the frame the pose
/// becomes held (the shield's activation request). The shield itself enforces the 0.5 s window
/// and the release/re-arm rule; this class only says whether the pose is held.
///
/// Fails safe: low-confidence or ambiguous frames and short dropouts never activate and never
/// count as a release; a dropout longer than [ShieldGestureConfig.dropoutReleaseMs] releases.
class ShieldGestureRecognizer {
  ShieldGestureRecognizer({this.config = const ShieldGestureConfig()});

  final ShieldGestureConfig config;

  ShieldGesturePhase _phase = ShieldGesturePhase.idle;
  int _enterCount = 0;
  double? _enterStartMs;
  int _exitCount = 0;
  int _lastFrameId = -1;
  int? _handId;
  double? _index;
  List<double>? _curled;
  double? _lostSinceMs;
  double _lastMs = 0;
  OneFingerMetrics? _metrics;

  ShieldGesturePhase get phase => _phase;

  /// The pose is recognized and not yet released (also while [ShieldGesturePhase.releasing]).
  bool get held => _phase == ShieldGesturePhase.held || _phase == ShieldGesturePhase.releasing;

  /// The latest smoothed measurements (null before the first measurable frame).
  OneFingerMetrics? get metrics => _metrics;

  /// 0..1 progress toward recognition (for the HUD's readiness pip).
  double get readiness {
    if (held) return 1;
    final m = _metrics;
    if (m == null) return 0;
    if (_phase == ShieldGesturePhase.recognizing) {
      final frames = _enterCount / config.confirmFrames;
      final time = config.recognizeMs <= 0 ? 1.0 : ((_lastMs - (_enterStartMs ?? _lastMs)) / config.recognizeMs);
      return 0.6 + 0.4 * math.min(frames, time).clamp(0.0, 1.0);
    }
    final closeness = math.min(m.index / config.enterIndex, m.minCurled / config.enterCurled);
    return 0.6 * closeness.clamp(0.0, 1.0);
  }

  void reset() {
    _phase = ShieldGesturePhase.idle;
    _exitCount = 0;
    _handId = null;
    _lostSinceMs = null;
    _resetMeasurement();
  }

  void _resetMeasurement() {
    _enterCount = 0;
    _enterStartMs = null;
    _index = null;
    _curled = null;
    _metrics = null;
  }

  bool update(HandInputFrame frame) {
    _lastMs = frame.timestampMs;
    if (frame.status != HandTrackingStatus.tracking) {
      _lostSinceMs ??= frame.timestampMs;
      final lostFor = frame.timestampMs - _lostSinceMs!;
      if (!held) {
        _phase = ShieldGesturePhase.idle; // never carry a half-recognized pose across a gap
        _enterCount = 0;
        _enterStartMs = null;
      }
      if (lostFor > config.dropoutReleaseMs) {
        if (held) _release();
        _resetMeasurement();
      }
      return false;
    }
    _lostSinceMs = null;
    if (frame.frameId == _lastFrameId) return false; // status-only re-delivery
    _lastFrameId = frame.frameId;
    if (frame.handId != _handId) {
      // A different hand: its scores start fresh (a held pose still needs a recognized release).
      _handId = frame.handId;
      _resetMeasurement();
    }

    final raw = frame.classification.confidence >= config.minConfidence ? OneFingerMetrics.measure(frame.classification) : null;
    if (raw == null) {
      // Ambiguous or low confidence: no evidence either way.
      if (!held) {
        _phase = ShieldGesturePhase.idle;
        _enterCount = 0;
        _enterStartMs = null;
      }
      return false;
    }

    final a = config.smoothing;
    final previousCurled = _curled;
    _index = _index == null ? raw.index : _index! + (raw.index - _index!) * a;
    _curled = [for (var i = 0; i < 3; i++) previousCurled == null ? raw.curled[i] : previousCurled[i] + (raw.curled[i] - previousCurled[i]) * a];
    final m = OneFingerMetrics(index: _index!, curled: _curled!, confidence: raw.confidence);
    _metrics = m;

    final entering = m.index >= config.enterIndex && m.minCurled >= config.enterCurled;
    final holding = m.index >= config.exitIndex && m.minCurled >= config.exitCurled;

    if (held) {
      _exitCount = holding ? 0 : _exitCount + 1;
      _phase = holding ? ShieldGesturePhase.held : ShieldGesturePhase.releasing;
      if (_exitCount >= config.releaseFrames) _release();
      return false;
    }
    if (!entering) {
      _phase = ShieldGesturePhase.idle;
      _enterCount = 0;
      _enterStartMs = null;
      return false;
    }
    _phase = ShieldGesturePhase.recognizing;
    _enterCount++;
    _enterStartMs ??= frame.timestampMs;
    if (_enterCount >= config.confirmFrames && frame.timestampMs - _enterStartMs! >= config.recognizeMs) {
      _phase = ShieldGesturePhase.held;
      _exitCount = 0;
      _enterCount = 0;
      _enterStartMs = null;
      return true;
    }
    return false;
  }

  void _release() {
    _phase = ShieldGesturePhase.idle;
    _enterCount = 0;
    _enterStartMs = null;
    _exitCount = 0;
  }
}
