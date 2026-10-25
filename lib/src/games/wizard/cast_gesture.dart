import '../../input/hand_input.dart';
import '../../input/hand_pose.dart';

/// What the player's hand is doing, from the spell-casting point of view (drives the HUD).
enum CastPhase {
  /// No reliable hand right now.
  noHand,

  /// A hand is visible but not in a recognized pose, and no cast is armed.
  idle,

  /// A confirmed fist: armed, the next confirmed open palm casts.
  ready,

  /// Armed and the hand is starting to open.
  charging,

  /// A cast just fired; the hand must close into a fist again before the next one.
  spent,
}

class CastGestureConfig {
  const CastGestureConfig({
    this.confirmFrames = 2,
    this.minConfidence = 0.45,
    this.dropoutDisarmMs = 350,
    this.extendedDropoutMs = 2000,
  });

  /// A pose must be seen in this many consecutive new frames before it is accepted
  /// (2 frames ≈ 80 ms at 24 fps). Filters single-frame misclassifications.
  final int confirmFrames;

  /// Pose classifications below this confidence count as "unknown".
  final double minConfidence;

  /// If the hand is lost for longer than this, a pending (armed) cast is cancelled, so a hand
  /// that reappears already open never fires.
  final double dropoutDisarmMs;

  /// After this long without a hand, [CastGestureFeedback.extendedDropout] is raised so the UI
  /// can warn the player more visibly.
  final double extendedDropoutMs;
}

class CastGestureFeedback {
  const CastGestureFeedback({required this.phase, required this.charge, required this.extendedDropout, this.pose = HandPose.unknown});

  static const initial = CastGestureFeedback(phase: CastPhase.noHand, charge: 0, extendedDropout: false);

  final CastPhase phase;

  /// 0..1 while armed: how far the hand has opened (for a charging glow).
  final double charge;
  final bool extendedDropout;

  /// Last confirmed pose.
  final HandPose pose;
}

/// Turns the per-frame pose stream into discrete "cast" events.
///
/// Rules (see README > Controls):
/// 1. A pose counts only after [CastGestureConfig.confirmFrames] consecutive frames agree with
///    sufficient confidence.
/// 2. A confirmed **fist** arms the spell.
/// 3. A confirmed **open palm** while armed fires exactly once and disarms.
/// 4. Holding the palm open never fires again; only a new confirmed fist re-arms.
/// 5. Losing the hand never fires; losing it for longer than [CastGestureConfig.dropoutDisarmMs]
///    also cancels the armed state.
///
/// This is game-side logic. It deliberately knows nothing about menus (dwell selection is a
/// separate system) or about the camera (it only sees [HandInputFrame]s).
class CastGestureRecognizer {
  CastGestureRecognizer({this.config = const CastGestureConfig(), double Function()? nowMs}) : _nowMs = nowMs ?? _defaultClock;

  final CastGestureConfig config;
  final double Function() _nowMs;

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static double _defaultClock() => _stopwatch.elapsedMicroseconds / 1000;

  int _lastFrameId = -1;
  HandPose? _candidate;
  int _candidateFrames = 0;
  HandPose _confirmed = HandPose.unknown;
  bool _armed = false;
  bool _spent = false;
  double? _lostSinceMs;
  CastGestureFeedback _feedback = CastGestureFeedback.initial;

  CastGestureFeedback get feedback => _feedback;
  bool get armed => _armed;

  void reset() {
    _lastFrameId = -1;
    _candidate = null;
    _candidateFrames = 0;
    _confirmed = HandPose.unknown;
    _armed = false;
    _spent = false;
    _lostSinceMs = null;
    _feedback = CastGestureFeedback.initial;
  }

  /// Feeds one input update. Returns true exactly when a fireball should be cast.
  bool update(HandInputFrame frame) {
    if (frame.status != HandTrackingStatus.tracking) {
      _onNoHand();
      return false;
    }
    _lostSinceMs = null;
    // Re-delivered frame (status-only update): nothing new to count.
    if (frame.frameId == _lastFrameId) return false;
    _lastFrameId = frame.frameId;

    final c = frame.classification;
    final pose = c.confidence >= config.minConfidence ? c.pose : HandPose.unknown;
    if (pose == _candidate) {
      _candidateFrames++;
    } else {
      _candidate = pose;
      _candidateFrames = 1;
    }

    var cast = false;
    if (_candidateFrames >= config.confirmFrames && pose != HandPose.unknown) {
      _confirmed = pose;
      if (pose == HandPose.fist) {
        _armed = true;
        _spent = false;
      } else if (pose == HandPose.open && _armed) {
        _armed = false;
        _spent = true;
        cast = true;
      }
    }

    final CastPhase phase;
    if (_spent && !_armed) {
      phase = CastPhase.spent;
    } else if (_armed) {
      phase = (_confirmed == HandPose.fist && pose == HandPose.fist) ? CastPhase.ready : CastPhase.charging;
    } else {
      phase = CastPhase.idle;
    }
    _feedback = CastGestureFeedback(
      phase: phase,
      charge: _armed ? c.openness.clamp(0.0, 1.0) : 0,
      extendedDropout: false,
      pose: _confirmed,
    );
    return cast;
  }

  void _onNoHand() {
    final nowMs = _nowMs();
    _lostSinceMs ??= nowMs;
    final lostFor = nowMs - _lostSinceMs!;
    // Never carry a half-confirmed pose across a gap.
    _candidate = null;
    _candidateFrames = 0;
    if (lostFor > config.dropoutDisarmMs) {
      _armed = false;
      _spent = false;
      _confirmed = HandPose.unknown;
    }
    _feedback = CastGestureFeedback(
      phase: CastPhase.noHand,
      charge: 0,
      extendedDropout: lostFor > config.extendedDropoutMs,
      pose: _confirmed,
    );
  }

  /// Call periodically (e.g. each game tick). While the hand is missing, input updates may stop
  /// entirely (stream stalled), so this keeps the dropout timers advancing.
  void tick() {
    if (_lostSinceMs != null) _onNoHand();
  }
}
