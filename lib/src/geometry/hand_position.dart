/// Hand position expressed in every coordinate system the app uses.
///
/// Convention (image coordinates, used everywhere in the app):
///   +x = rightward, +y = downward, origin of pixel/normalized coords = top-left of the frame.
///
/// For a frame of width W and height H and a hand center at pixel (x, y):
///   offset            = (x - W/2, y - H/2)                    pixels from the frame center
///   normalized        = (x / W, y / H)                        in [0, 1]
///   center-relative   = ((x - W/2) / (W/2), (y - H/2) / (H/2)) in [-1, 1], (0, 0) = center
class HandPosition {
  const HandPosition({required this.xn, required this.yn, required this.frameWidth, required this.frameHeight})
      : assert(frameWidth > 0 && frameHeight > 0);

  factory HandPosition.fromPixels(double x, double y, {required double frameWidth, required double frameHeight}) {
    return HandPosition(xn: x / frameWidth, yn: y / frameHeight, frameWidth: frameWidth, frameHeight: frameHeight);
  }

  /// Normalized position, 0..1 (top-left origin).
  final double xn;
  final double yn;

  /// Frame size in pixels (W, H) the position refers to.
  final double frameWidth;
  final double frameHeight;

  double get xPixels => xn * frameWidth;
  double get yPixels => yn * frameHeight;

  /// Pixel offset from the frame center (x_hand - W/2, y_hand - H/2).
  double get offsetX => xPixels - frameWidth / 2;
  double get offsetY => yPixels - frameHeight / 2;

  /// Center-relative normalized coordinates, approximately -1..1, (0, 0) at the frame center.
  double get xr => offsetX / (frameWidth / 2);
  double get yr => offsetY / (frameHeight / 2);

  @override
  String toString() =>
      'HandPosition(px=(${xPixels.toStringAsFixed(1)}, ${yPixels.toStringAsFixed(1)}), '
      'offset=(${offsetX.toStringAsFixed(1)}, ${offsetY.toStringAsFixed(1)}), '
      'n=(${xn.toStringAsFixed(3)}, ${yn.toStringAsFixed(3)}), '
      'r=(${xr.toStringAsFixed(3)}, ${yr.toStringAsFixed(3)}))';
}
