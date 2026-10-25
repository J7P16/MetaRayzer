import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'key_value_store.dart';

/// How positional game sounds are rendered.
enum SpatialMode {
  /// Stereo panning + distance attenuation. Works on any output (speakers, open-ear glasses).
  stereo,

  /// Binaural HRTF rendering (Apple's AVAudioEnvironmentNode HRTFHQ). Best on headphones.
  /// Not head-tracked by the OS: the listener turns only with the in-game view.
  binaural,
}

/// Where game audio plays.
abstract final class AudioOutputChoice {
  /// Prefer a Mac output that looks like the glasses (name contains Ray-Ban/Meta), else default.
  static const auto = 'auto';

  /// The Mac's current system default output.
  static const system = 'system';

  /// Relay sound events to the iPhone companion, which plays them on its current audio route
  /// (the glasses when they are the phone's Bluetooth audio device).
  static const companion = 'companion';
  // Any other value is a specific macOS output device UID.
}

/// User preferences, persisted locally. Ordinary preferences only: permanent progression (spell
/// unlocks) lives in [Progression] under a separate key, so resetting settings never erases it.
class AppSettings extends ChangeNotifier {
  AppSettings({required this._store});

  final KeyValueStore _store;
  static const _key = 'settings.v1';

  static const double minDwellSeconds = 0.4;
  static const double maxDwellSeconds = 3.0;
  static const double defaultDwellSeconds = 1.0;

  /// Head movement → view/aim multiplier. 0 disables head influence.
  static const double minHeadSensitivity = 0.0;
  static const double maxHeadSensitivity = 2.0;
  static const double defaultHeadSensitivity = 1.0;

  static const double defaultSfxVolume = 0.8;
  static const double defaultAmbientVolume = 0.45;

  double _dwellSeconds = defaultDwellSeconds;
  bool _simulatedInput = false;
  bool _showCameraInset = true;
  double _headSensitivity = defaultHeadSensitivity;
  bool _invertHeadYaw = false;
  double _sfxVolume = defaultSfxVolume;
  double _ambientVolume = defaultAmbientVolume;
  SpatialMode _spatialMode = SpatialMode.stereo;
  String _audioOutput = AudioOutputChoice.auto;

  double get dwellSeconds => _dwellSeconds;

  /// Development only: mouse/keyboard drive the hand (and arrow keys the head). Never restored.
  bool get simulatedInput => _simulatedInput;
  bool get showCameraInset => _showCameraInset;
  double get headSensitivity => _headSensitivity;

  /// Flips the measured head yaw, for glasses whose orientation axes turn out mirrored (the
  /// Motion API's axis convention is not documented).
  bool get invertHeadYaw => _invertHeadYaw;
  double get sfxVolume => _sfxVolume;
  double get ambientVolume => _ambientVolume;
  SpatialMode get spatialMode => _spatialMode;
  String get audioOutput => _audioOutput;

  set dwellSeconds(double v) => _set(() => _dwellSeconds = _round(v.clamp(minDwellSeconds, maxDwellSeconds)));
  set simulatedInput(bool v) => _set(() => _simulatedInput = v, persist: false);
  set showCameraInset(bool v) => _set(() => _showCameraInset = v);
  set headSensitivity(double v) => _set(() => _headSensitivity = _round(v.clamp(minHeadSensitivity, maxHeadSensitivity)));
  set invertHeadYaw(bool v) => _set(() => _invertHeadYaw = v);
  set sfxVolume(double v) => _set(() => _sfxVolume = _round(v.clamp(0.0, 1.0)));
  set ambientVolume(double v) => _set(() => _ambientVolume = _round(v.clamp(0.0, 1.0)));
  set spatialMode(SpatialMode v) => _set(() => _spatialMode = v);
  set audioOutput(String v) => _set(() => _audioOutput = v);

  static double _round(double v) => (v * 100).round() / 100;

  /// Restores ordinary preferences to defaults. Does not touch progression.
  void resetToDefaults() => _set(() {
        _dwellSeconds = defaultDwellSeconds;
        _showCameraInset = true;
        _headSensitivity = defaultHeadSensitivity;
        _invertHeadYaw = false;
        _sfxVolume = defaultSfxVolume;
        _ambientVolume = defaultAmbientVolume;
        _spatialMode = SpatialMode.stereo;
        _audioOutput = AudioOutputChoice.auto;
      });

  void _set(VoidCallback change, {bool persist = true}) {
    change();
    notifyListeners();
    if (persist) _save();
  }

  Future<void> load() async {
    try {
      final raw = await _store.getString(_key);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      double number(String k, double fallback, double lo, double hi) => ((m[k] as num?)?.toDouble() ?? fallback).clamp(lo, hi);
      _dwellSeconds = number('dwellSeconds', _dwellSeconds, minDwellSeconds, maxDwellSeconds);
      _showCameraInset = m['showCameraInset'] as bool? ?? _showCameraInset;
      _headSensitivity = number('headSensitivity', _headSensitivity, minHeadSensitivity, maxHeadSensitivity);
      _invertHeadYaw = m['invertHeadYaw'] as bool? ?? _invertHeadYaw;
      _sfxVolume = number('sfxVolume', _sfxVolume, 0, 1);
      _ambientVolume = number('ambientVolume', _ambientVolume, 0, 1);
      _spatialMode = SpatialMode.values.asNameMap()[m['spatialMode']] ?? _spatialMode;
      _audioOutput = m['audioOutput'] as String? ?? _audioOutput;
      // v2 keys (uiControlMode, handPreference) are ignored: both navigation methods are always
      // on, and the left hand is the only casting hand.
      notifyListeners();
    } catch (_) {
      // Ignore corrupt settings; defaults apply.
    }
  }

  Future<void> _save() => _store.setString(
        _key,
        jsonEncode({
          'dwellSeconds': _dwellSeconds,
          'showCameraInset': _showCameraInset,
          'headSensitivity': _headSensitivity,
          'invertHeadYaw': _invertHeadYaw,
          'sfxVolume': _sfxVolume,
          'ambientVolume': _ambientVolume,
          'spatialMode': _spatialMode.name,
          'audioOutput': _audioOutput,
        }),
      );
}
