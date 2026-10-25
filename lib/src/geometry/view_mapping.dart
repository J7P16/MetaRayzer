import 'dart:math' as math;
import 'dart:ui';

/// How the camera frame is fitted into the preview widget.
enum PreviewFit {
  /// Whole frame visible, letterboxed/pillarboxed as needed.
  contain,

  /// Fills the widget, cropping the overflowing dimension. Points in the cropped area are not
  /// visible (see [FrameViewMapping.isVisible]).
  cover,
}

/// Maps normalized frame coordinates (0..1, top-left origin, +y down) to widget coordinates of
/// the preview, accounting for rotation, mirroring, aspect-ratio fitting and cropping.
///
/// The preview widget positions the image at exactly [imageRect] and applies the same
/// [quarterTurns] and [mirrored] transforms, so the overlay and the picture cannot disagree.
class FrameViewMapping {
  const FrameViewMapping({
    required this.frameSize,
    required this.viewSize,
    this.fit = PreviewFit.contain,
    this.mirrored = false,
    this.quarterTurns = 0,
  });

  /// Size of the decoded camera frame (W x H) as delivered by the source.
  final Size frameSize;

  /// Size of the preview widget.
  final Size viewSize;
  final PreviewFit fit;

  /// Horizontal flip of the displayed image (selfie-style). Applied after rotation.
  final bool mirrored;

  /// Clockwise quarter turns applied to the frame before display.
  final int quarterTurns;

  int get _turns => quarterTurns % 4;

  /// Frame size after rotation.
  Size get displayedFrameSize => _turns.isOdd ? Size(frameSize.height, frameSize.width) : frameSize;

  /// Screen pixels per (rotated) frame pixel.
  double get scale {
    final d = displayedFrameSize;
    if (d.isEmpty || viewSize.isEmpty) return 0;
    final sx = viewSize.width / d.width;
    final sy = viewSize.height / d.height;
    return fit == PreviewFit.contain ? math.min(sx, sy) : math.max(sx, sy);
  }

  /// Where the (rotated, scaled) image sits in the widget. With [PreviewFit.cover] this extends
  /// past the widget bounds; that part is cropped.
  Rect get imageRect {
    final d = displayedFrameSize;
    final w = d.width * scale;
    final h = d.height * scale;
    return Rect.fromLTWH((viewSize.width - w) / 2, (viewSize.height - h) / 2, w, h);
  }

  /// Normalized frame point -> normalized point in the displayed (rotated + mirrored) image.
  Offset displayNormalized(double xn, double yn) {
    var x = xn, y = yn;
    for (var i = 0; i < _turns; i++) {
      // One clockwise turn: pixel (x, y) in W x H lands at (H - y, x) in H x W.
      final nx = 1 - y;
      y = x;
      x = nx;
    }
    if (mirrored) x = 1 - x;
    return Offset(x, y);
  }

  /// Normalized frame point -> widget coordinates.
  Offset toView(double xn, double yn) {
    final d = displayNormalized(xn, yn);
    final r = imageRect;
    return Offset(r.left + d.dx * r.width, r.top + d.dy * r.height);
  }

  /// The frame center (W/2, H/2) in widget coordinates.
  Offset get frameCenterInView => toView(0.5, 0.5);

  /// Widget coordinates -> normalized frame point (inverse of [toView]).
  Offset toFrameNormalized(Offset view) {
    final r = imageRect;
    var x = (view.dx - r.left) / r.width;
    var y = (view.dy - r.top) / r.height;
    if (mirrored) x = 1 - x;
    for (var i = 0; i < _turns; i++) {
      // Inverse of one clockwise turn.
      final nx = y;
      y = 1 - x;
      x = nx;
    }
    return Offset(x, y);
  }

  /// Whether a widget point is inside the visible preview (false for points cropped by cover).
  bool isVisible(Offset view) => (Offset.zero & viewSize).contains(view);
}
