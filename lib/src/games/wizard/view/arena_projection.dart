import 'dart:math' as math;
import 'dart:ui';

/// Pseudo-3D projection of the game world (x lateral, z distance ahead, elevation up) onto the
/// screen. The player's eye is at z = 0; perspective scale falls off as 1 / (1 + z / zScale).
/// This is the only place world → screen math happens; gameplay never sees pixels.
class ArenaProjection {
  ArenaProjection(this.size);

  final Size size;
  static const double zScale = 4.0;

  double get horizonY => size.height * 0.40;
  double get centerX => size.width / 2;

  /// 1 at the player, → 0 toward the horizon.
  double scale(double z) => 1 / (1 + math.max(z, -0.5) / zScale);

  /// Screen y of the ground at distance z.
  double groundY(double z) => horizonY + (size.height * 1.12 - horizonY) * scale(z);

  /// Screen pixels per world unit at distance z.
  double pixelsPerUnit(double z) => size.height * 0.22 * scale(z);

  Offset project(double x, double z, [double elevation = 0]) {
    final u = pixelsPerUnit(z);
    return Offset(centerX + x * u, groundY(z) - elevation * u);
  }
}
