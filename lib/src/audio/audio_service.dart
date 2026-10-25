import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import '../app/app_settings.dart';

/// Sound ids synthesized natively (SoundSynth.swift).
abstract final class Sounds {
  static const uiHover = 'ui_hover';
  static const uiSelect = 'ui_select';
  static const gameStart = 'game_start';
  static const fireballCast = 'fireball_cast';
  static const fireballImpact = 'fireball_impact';
  static const fizzle = 'fizzle';
  static const defeatTroll = 'defeat_troll';
  static const defeatGoblin = 'defeat_goblin';
  static const defeatFrog = 'defeat_frog';
  static const defeatSkeleton = 'defeat_skeleton';
  static const defeatSlime = 'defeat_slime';
  static const slimeSplit = 'slime_split';
  static const spawn = 'spawn';
  static const telegraph = 'telegraph';
  static const bowDraw = 'bow_draw';
  static const arrowRelease = 'arrow_release';
  static const playerHurt = 'player_hurt';
  static const lightningCast = 'lightning_cast';
  static const zap = 'zap';
  static const unlock = 'unlock';
  static const spellSwitch = 'spell_switch';
  static const gameOver = 'game_over';
}

/// Dart front end of the native spatial audio engine.
///
/// - Applies [AppSettings] (volumes, stereo/binaural, output choice) immediately on change.
/// - Suppresses duplicate triggers: the same sound id can't restart within its minimum interval
///   (e.g. 40 ms), so repeated gesture detections or state updates never stack copies.
/// - Exposes the active output route for the settings UI.
class AudioService extends ChangeNotifier {
  AudioService({required this._native, required this._settings, double Function()? nowMs}) : _nowMs = nowMs ?? _defaultClock {
    _sub = _native.events.listen((e) {
      if (e is AudioRouteEvent) {
        route = e.route;
        notifyListeners();
      }
    });
    _settings.addListener(_apply);
    _apply();
  }

  final MetarayzerNative _native;
  final AppSettings _settings;
  final double Function() _nowMs;
  StreamSubscription<NativeEvent>? _sub;

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static double _defaultClock() => _stopwatch.elapsedMicroseconds / 1000;

  /// Minimum gap between two triggers of the same sound id.
  static const Map<String, double> minIntervalMs = {
    Sounds.uiHover: 120,
    Sounds.spawn: 150,
    Sounds.zap: 30,
  };
  static const double defaultMinIntervalMs = 40;

  final Map<String, double> _lastPlayed = {};
  bool _ambientOn = false;

  /// Native route description: kind (mac/device/companion/fallback), name, note, devices.
  Map<String, Object?> route = const {'kind': 'starting'};

  List<Map<String, Object?>> get outputDevices =>
      (route['devices'] as List? ?? const []).whereType<Map>().map((m) => Map<String, Object?>.from(m)).toList();

  set ambientOn(bool on) {
    if (on == _ambientOn) return;
    _ambientOn = on;
    _apply();
  }

  Future<void> _apply() async {
    try {
      route = await _native.audioConfigure(
        sfx: _settings.sfxVolume,
        ambient: _settings.ambientVolume,
        mode: _settings.spatialMode.name,
        output: _settings.audioOutput,
        ambientOn: _ambientOn,
      );
      notifyListeners();
    } catch (e) {
      developer.log('audio configure failed: $e', name: 'metarayzer');
    }
  }

  /// Plays [sound] at game-world position (x right, z ahead, y up), or in front of the
  /// listener when [positional] is false. Returns false when suppressed as a duplicate.
  bool play(String sound, {double x = 0, double y = 1, double z = 1, double gain = 1, bool positional = true}) {
    final now = _nowMs();
    final last = _lastPlayed[sound];
    if (last != null && now - last < (minIntervalMs[sound] ?? defaultMinIntervalMs)) return false;
    _lastPlayed[sound] = now;
    _native.audioPlay(sound, x: x, y: y, z: z, gain: gain, positional: positional).catchError((Object e) {
      developer.log('audio play failed: $e', name: 'metarayzer');
    });
    return true;
  }

  /// UI sound helpers.
  void uiHover() => play(Sounds.uiHover, positional: false, gain: 0.6);
  void uiSelect() => play(Sounds.uiSelect, positional: false);

  double _lastYaw = double.nan;

  /// Turns the listener with the view (radians). Sent only when it changes noticeably.
  void setListenerYaw(double yaw) {
    if (!_lastYaw.isNaN && (yaw - _lastYaw).abs() < 0.005) return;
    _lastYaw = yaw;
    _native.audioListener(yaw).catchError((Object _) {});
  }

  @override
  void dispose() {
    _settings.removeListener(_apply);
    _sub?.cancel();
    super.dispose();
  }
}
