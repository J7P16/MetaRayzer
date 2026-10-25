import 'dart:math' as math;
import 'dart:ui';

/// Pseudo-3D projection of the game world (x lateral, z distance ahead, elevation up) onto the
/// screen. The player's eye is at the origin; the view can turn by [yaw]/[pitch] (head
/// movement × sensitivity). Perspective scale falls off as 1 / (1 + depth / zScale).
///
/// This is the only place world → screen math happens; gameplay never sees pixels. Enemy size,
/// screen position and every effect are derived from the same world coordinates the game uses,
/// so on-screen distance always matches gameplay distance.
class ArenaProjection {
  ArenaProjection(this.size, {this.yaw = 0, this.pitch = 0}) : _cos = math.cos(yaw), _sin = math.sin(yaw);

  final Size size;

  /// View rotation (radians): + yaw = looking right, + pitch = looking up.
  final double yaw;
  final double pitch;
  final double _cos;
  final double _sin;

  static const double zScale = 4.0;

  /// Screen pixels per radian for very distant objects (sky, mountains).
  double get focal => size.height * 0.22 * zScale;

  double get horizonY => size.height * 0.40 + pitch * focal;
  double get centerX => size.width / 2;

  /// Horizontal screen shift for infinitely distant layers when the view turns.
  double get farShiftX => -yaw * focal;

  /// World → camera space (rotated by the view yaw). Returns (lateral, depth).
  (double, double) toCamera(double x, double z) => (x * _cos - z * _sin, x * _sin + z * _cos);

  /// 1 at the eye, → 0 toward the horizon (by camera depth).
  double scaleAtDepth(double depth) => 1 / (1 + math.max(depth, -0.5) / zScale);

  /// Screen pixels per world unit at world position (x, z).
  double unitsAt(double x, double z) => size.height * 0.22 * scaleAtDepth(toCamera(x, z).$2);

  /// Screen pixels per world unit at camera depth (no rotation; for straight-ahead geometry).
  double pixelsPerUnit(double depth) => size.height * 0.22 * scaleAtDepth(depth);

  double _groundY(double depth) => horizonY + (size.height * 1.12 - size.height * 0.40) * scaleAtDepth(depth);

  Offset project(double x, double z, [double elevation = 0]) {
    final (cx, cz) = toCamera(x, z);
    final u = pixelsPerUnit(cz);
    return Offset(centerX + cx * u, _groundY(cz) - elevation * u);
  }

  /// Whether a world point is in front of the camera (not behind the player's view).
  bool inFront(double x, double z) => toCamera(x, z).$2 > -0.3;
}
