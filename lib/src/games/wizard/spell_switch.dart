import '../../input/hand_input.dart';
import '../../input/hand_pose.dart';

class SpellSwitchConfig {
  const SpellSwitchConfig({this.holdMs = 450, this.minConfidence = 0.45, this.releaseFrames = 3});

  /// The ✌ pose must be held continuously this long to switch spells.
  final double holdMs;
  final double minConfidence;

  /// After a switch, this many consecutive non-✌ frames (or losing the hand) are required
  /// before another switch can happen, so one held pose switches exactly once.
  final int releaseFrames;
}

/// Detects the deliberate "hold ✌" gesture that cycles spells. Independent of the cast
/// recognizer; the ✌ pose is neither fist nor open, so it can't arm or fire a cast.
class SpellSwitchRecognizer {
  SpellSwitchRecognizer({this.config = const SpellSwitchConfig()});

  final SpellSwitchConfig config;
  int _lastFrameId = -1;
  double? _holdStartMs;
  bool _latched = false;
  int _releaseCount = 0;

  /// 0..1 while the ✌ pose is being held (for a HUD progress ring).
  double progress = 0;

  void reset() {
    _holdStartMs = null;
    _latched = false;
    _releaseCount = 0;
    progress = 0;
  }

  /// Returns true exactly once per deliberate hold.
  bool update(HandInputFrame frame) {
    if (frame.status != HandTrackingStatus.tracking) {
      _holdStartMs = null;
      _latched = false;
      progress = 0;
      return false;
    }
    if (frame.frameId == _lastFrameId) return false;
    _lastFrameId = frame.frameId;
    final c = frame.classification;
    final victory = c.pose == HandPose.victory && c.confidence >= config.minConfidence;
    if (!victory) {
      _holdStartMs = null;
      progress = 0;
      if (_latched && ++_releaseCount >= config.releaseFrames) {
        _latched = false;
        _releaseCount = 0;
      }
      return false;
    }
    _releaseCount = 0;
    if (_latched) return false;
    _holdStartMs ??= frame.timestampMs;
    final held = frame.timestampMs - _holdStartMs!;
    progress = (held / config.holdMs).clamp(0.0, 1.0);
    if (held >= config.holdMs) {
      _latched = true;
      _holdStartMs = null;
      progress = 0;
      return true;
    }
    return false;
  }
}
