import 'wizard_config.dart';

enum DayPhase {
  /// Ordinary enemies spawn under the difficulty controller.
  day,

  /// Light fades; no new ordinary enemies.
  dusk,

  /// The boss encounter. Lasts until the boss is defeated.
  night,

  /// Light returns after the boss falls; ordinary spawning resumes when day begins.
  dawn,
}

/// The day-night cycle as an explicit state machine (not just a timer on the background).
/// Pure logic; the game drives it through [update] and [bossDefeated] and reacts to the phase
/// it returns. One instance per run, so it pauses, resets and ends with the simulation.
class DayNightCycle {
  DayNightCycle(this.spec);

  final DayNightSpec spec;

  DayPhase _phase = DayPhase.day;
  double _phaseTime = 0;

  /// Number of nights that have started (1 during the first night).
  int nights = 0;

  DayPhase get phase => _phase;
  double get phaseTime => _phaseTime;
  bool get ordinarySpawning => !spec.enabled || _phase == DayPhase.day;

  /// Seconds of daylight left before dusk (0 outside the day).
  double get dayRemaining => _phase == DayPhase.day ? (spec.daySeconds - _phaseTime).clamp(0.0, spec.daySeconds) : 0;

  /// 1 = full daylight, 0 = night. Interpolated over dusk and dawn.
  double get daylight => switch (_phase) {
        DayPhase.day => 1,
        DayPhase.dusk => 1 - (_phaseTime / spec.duskSeconds).clamp(0.0, 1.0),
        DayPhase.night => 0,
        DayPhase.dawn => (_phaseTime / spec.dawnSeconds).clamp(0.0, 1.0),
      };

  /// Advances time. Returns the phase entered during this step, if any (at most one per call,
  /// so a long frame can never skip the night).
  DayPhase? update(double dt) {
    if (!spec.enabled) return null;
    _phaseTime += dt;
    switch (_phase) {
      case DayPhase.day when _phaseTime >= spec.daySeconds:
        return _enter(DayPhase.dusk);
      case DayPhase.dusk when _phaseTime >= spec.duskSeconds:
        nights++;
        return _enter(DayPhase.night);
      case DayPhase.dawn when _phaseTime >= spec.dawnSeconds:
        return _enter(DayPhase.day);
      default:
        return null;
    }
  }

  /// The night's boss fell. Returns true if this ended the night (only once per night).
  bool bossDefeated() {
    if (_phase != DayPhase.night) return false;
    _enter(DayPhase.dawn);
    return true;
  }

  DayPhase _enter(DayPhase p) {
    _phase = p;
    _phaseTime = 0;
    return p;
  }
}
