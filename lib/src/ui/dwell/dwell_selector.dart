import 'dart:ui';

/// Maps a hand position (display-normalized camera coordinates) to the app viewport.
///
/// Only a central "interaction box" of the camera view is used and stretched to the whole
/// window: small, comfortable hand movements reach every button, and the hand never has to go
/// near the frame edge, where it would leave the narrow glasses camera view.
class CursorMapper {
  const CursorMapper({this.box = const Rect.fromLTRB(0.2, 0.15, 0.8, 0.85)});

  /// Region of the camera view (normalized) mapped onto the full viewport.
  final Rect box;

  CursorMapper copyWithBox(Rect box) => CursorMapper(box: box);

  /// Camera position → 0..1 within the interaction box (clamped).
  Offset normalize(Offset handNormalized) => Offset(
        ((handNormalized.dx - box.left) / box.width).clamp(0.0, 1.0),
        ((handNormalized.dy - box.top) / box.height).clamp(0.0, 1.0),
      );

  Offset map(Offset handNormalized, Size viewport, {bool simulated = false}) {
    // The simulated hand already is a viewport position.
    final n = simulated ? handNormalized : normalize(handNormalized);
    return Offset(n.dx * viewport.width, n.dy * viewport.height);
  }
}

/// Dwell-to-select logic, independent of widgets so it can be unit-tested.
///
/// - Hovering a target accumulates progress; reaching [dwellSeconds] activates it once.
/// - Leaving the target (or losing the cursor) resets progress.
/// - After activating, the same target cannot activate again until the cursor has left it, so
///   one continuous hover never triggers twice.
class DwellSelector {
  DwellSelector({this.dwellSeconds = 1.0});

  double dwellSeconds;

  Object? _hovered;
  Object? _locked;
  double _progress = 0;
  Object? _lastActivated;
  double _sinceActivation = double.infinity;

  /// Target currently under the cursor.
  Object? get hovered => _hovered;

  /// 0..1 dwell progress on [hovered] (0 when it is locked after activation).
  double get progress => _progress;

  /// Whether [hovered] already fired during this hover.
  bool get hoveredIsLocked => _hovered != null && _hovered == _locked;

  Object? get lastActivated => _lastActivated;
  double get secondsSinceActivation => _sinceActivation;

  /// Records an activation that happened by another route (e.g. a mouse click) so the hand
  /// hovering the same target can't fire it again during this hover.
  void lockOn(Object target) {
    _locked = target;
    _progress = 0;
    _lastActivated = target;
    _sinceActivation = 0;
  }

  void reset() {
    _hovered = null;
    _locked = null;
    _progress = 0;
  }

  /// Advances by [dt] seconds with the cursor at [cursor] (null = no hand). [targets] maps target
  /// ids to their current global rects. Returns the id activated in this step, if any.
  Object? update(Offset? cursor, double dt, Map<Object, Rect> targets) {
    _sinceActivation += dt;
    Object? under;
    if (cursor != null) {
      for (final entry in targets.entries) {
        if (entry.value.contains(cursor)) under = entry.key;
      }
    }
    if (under != _hovered) {
      _hovered = under;
      _progress = 0;
    }
    if (_locked != null && _locked != under) _locked = null; // left the activated target
    if (under == null || under == _locked) return null;

    _progress += dt / dwellSeconds;
    if (_progress < 1) return null;
    _progress = 0;
    _locked = under;
    _lastActivated = under;
    _sinceActivation = 0;
    return under;
  }
}
