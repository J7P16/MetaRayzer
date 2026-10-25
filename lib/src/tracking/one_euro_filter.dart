import 'dart:math' as math;

/// One Euro filter (Casiez, Roussel & Vogel, CHI 2012): an adaptive low-pass filter that
/// smooths heavily when the signal is slow (kills jitter at rest) and lightly when it is fast
/// (keeps lag low during quick motion). https://gery.casiez.net/1euro/
class OneEuroFilter {
  OneEuroFilter({this.minCutoff = 1.2, this.beta = 2.0, this.derivativeCutoff = 1.0});

  /// Cutoff frequency (Hz) at zero speed. Lower = smoother at rest, more lag.
  final double minCutoff;

  /// How fast the cutoff rises with speed. Higher = less lag on fast motion, more jitter.
  final double beta;
  final double derivativeCutoff;

  double? _x;
  double _dx = 0;
  double? _lastTimeSeconds;

  void reset() {
    _x = null;
    _dx = 0;
    _lastTimeSeconds = null;
  }

  double filter(double value, double timeSeconds) {
    final prevX = _x;
    final prevT = _lastTimeSeconds;
    if (prevX == null || prevT == null || timeSeconds <= prevT) {
      _x = value;
      _lastTimeSeconds = timeSeconds;
      return value;
    }
    final dt = timeSeconds - prevT;
    final dx = (value - prevX) / dt;
    _dx = _lowPass(_dx, dx, _alpha(derivativeCutoff, dt));
    final cutoff = minCutoff + beta * _dx.abs();
    final x = _lowPass(prevX, value, _alpha(cutoff, dt));
    _x = x;
    _lastTimeSeconds = timeSeconds;
    return x;
  }

  static double _alpha(double cutoff, double dt) {
    final tau = 1 / (2 * math.pi * cutoff);
    return 1 / (1 + tau / dt);
  }

  static double _lowPass(double previous, double value, double alpha) => previous + alpha * (value - previous);
}
