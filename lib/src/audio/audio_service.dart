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

  // Version 4.
  static const shieldUp = 'shield_up';
  static const shieldBlock = 'shield_block';
  static const shieldFade = 'shield_fade';

  /// The skeleton's distinct "arrow incoming" warning, at the start of each telegraph.
  static const archerWarn = 'archer_warn';
  static const projectileMiss = 'projectile_miss';
  static const bossCharge = 'boss_charge';
  static const bossBolt = 'boss_bolt';
  static const bossAppear = 'boss_appear';
  static const bossDefeat = 'boss_defeat';
  static const nightFall = 'night_fall';
  static const dawn = 'dawn';
  static const tutorialSuccess = 'tutorial_success';
}

/// Background music tracks synthesized natively (SoundSynth.swift, MusicSynth).
abstract final class MusicTracks {
  static const menu = 'menu';
  static const day = 'day';
  static const night = 'night';
}

/// Same heuristic as the native `AudioDevices.looksLikeGlasses`.
bool looksLikeGlasses(String name) {
  final n = name.toLowerCase();
  return n.contains('ray-ban') || n.contains('rayban') || n.contains('ray ban') || n.contains('meta') || n.contains('oakley');
}

enum RouteVerification {
  /// The operating system reports the glasses as the active output of the playing device.
  glassesConfirmed,

  /// The operating system reports a definite output that is not recognizably the glasses.
  otherConfirmed,

  /// The requested route is in use but its actual output can't be confirmed (yet).
  unconfirmed,

  /// The requested route is unavailable; playing on the Mac's default output instead.
  fallback,

  starting,
}

/// What the player asked for vs. what is verifiably happening. "Confirmed" means the OS that
/// plays the audio (macOS or iOS) reports that output as active; nobody can verify by software
/// that a person actually hears it.
@immutable
class AudioRouteStatus {
  const AudioRouteStatus({required this.verification, required this.active, this.hint, this.phonePlayed});

  final RouteVerification verification;

  /// Human-readable active output, e.g. "iPhone → Ray-Ban Meta (Bluetooth A2DP)".
  final String active;

  /// What to do next, when routing isn't confirmed on the glasses.
  final String? hint;

  /// Relayed sounds the iPhone reports it has played (null outside the iPhone route).
  final int? phonePlayed;

  bool get glassesConfirmed => verification == RouteVerification.glassesConfirmed;

  static const _bluetoothTypes = {'BluetoothA2DPOutput', 'BluetoothHFP', 'BluetoothLE'};

  static AudioRouteStatus from(Map<String, Object?> route) {
    final name = route['name'] as String? ?? 'System default';
    final note = route['note'] as String?;
    switch (route['kind']) {
      case 'companion':
        final phone = route['phone'];
        if (phone is! Map) {
          return const AudioRouteStatus(
            verification: RouteVerification.unconfirmed,
            active: 'iPhone companion (output not reported yet)',
            hint: 'Waiting for the iPhone to report its audio output. Update the companion app if this persists.',
          );
        }
        final played = (phone['played'] as num?)?.toInt();
        if (phone['engine'] != true) {
          return AudioRouteStatus(
            verification: RouteVerification.unconfirmed,
            active: 'iPhone companion (audio not running)',
            hint: 'The iPhone could not start audio${phone['error'] != null ? ': ${phone['error']}' : ''}. Bring the companion to the foreground.',
            phonePlayed: played,
          );
        }
        final outputs = (phone['outputs'] as List? ?? const []).whereType<Map>().toList();
        if (outputs.isEmpty) {
          return AudioRouteStatus(verification: RouteVerification.unconfirmed, active: 'iPhone (no output reported)', phonePlayed: played);
        }
        String describe(Map o) => '${o['name']} (${_portLabel(o['type'] as String? ?? '')})';
        final glasses = outputs.where((o) => looksLikeGlasses(o['name'] as String? ?? '') && _bluetoothTypes.contains(o['type'])).toList();
        if (glasses.isNotEmpty) {
          return AudioRouteStatus(verification: RouteVerification.glassesConfirmed, active: 'iPhone → ${describe(glasses.first)}', phonePlayed: played);
        }
        final bluetooth = outputs.where((o) => _bluetoothTypes.contains(o['type'])).toList();
        if (bluetooth.isNotEmpty) {
          return AudioRouteStatus(
            verification: RouteVerification.otherConfirmed,
            active: 'iPhone → ${describe(bluetooth.first)}',
            hint: 'The iPhone plays on a Bluetooth device that is not recognized as the glasses. If it is them, this is fine; otherwise pick the glasses in the companion\'s Audio output picker.',
            phonePlayed: played,
          );
        }
        return AudioRouteStatus(
          verification: RouteVerification.otherConfirmed,
          active: 'iPhone → ${outputs.map(describe).join(', ')}',
          hint: 'The glasses are not the iPhone\'s audio output. On the iPhone, open the companion\'s Audio output picker (or Control Center → AirPlay) and choose the glasses.',
          phonePlayed: played,
        );
      case 'device':
        final isGlasses = route['glasses'] == true;
        final bound = route['bound'] != false;
        if (!bound) return AudioRouteStatus(verification: RouteVerification.unconfirmed, active: name, hint: 'macOS did not accept $name as the output.');
        return AudioRouteStatus(verification: isGlasses ? RouteVerification.glassesConfirmed : RouteVerification.otherConfirmed, active: 'This Mac → $name');
      case 'mac':
        return AudioRouteStatus(verification: RouteVerification.otherConfirmed, active: 'This Mac → $name', hint: note);
      case 'fallback':
        return AudioRouteStatus(verification: RouteVerification.fallback, active: 'This Mac → $name', hint: note);
      default:
        return const AudioRouteStatus(verification: RouteVerification.starting, active: 'Starting audio…');
    }
  }

  static String _portLabel(String type) => switch (type) {
        'BluetoothA2DPOutput' => 'Bluetooth A2DP',
        'BluetoothHFP' => 'Bluetooth HFP',
        'BluetoothLE' => 'Bluetooth LE',
        'Speaker' => 'iPhone speaker',
        'Receiver' => 'iPhone earpiece',
        'Headphones' => 'wired headphones',
        _ => type,
      };
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
    Sounds.shieldBlock: 60,
  };
  static const double defaultMinIntervalMs = 40;

  final Map<String, double> _lastPlayed = {};
  bool _ambientOn = false;
  String? _music;

  /// The background music track requested last (null = silent).
  String? get music => _music;

  /// Crossfades to [track] (see [MusicTracks]) or fades out (null). Requesting the track that is
  /// already playing does nothing, so rapid state changes never start overlapping copies.
  void setMusic(String? track) {
    if (track == _music) return;
    _music = track;
    _native.audioMusic(track).catchError((Object e) {
      developer.log('audio music failed: $e', name: 'metarayzer');
    });
  }

  /// Native route description: kind (mac/device/companion/fallback), name, note, devices, and
  /// for the iPhone route the output the phone reports (`phone`).
  Map<String, Object?> route = const {'kind': 'starting'};

  /// Requested vs. verified output, for the settings UI.
  AudioRouteStatus get routeStatus => AudioRouteStatus.from(route);

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
        sfx: _settings.effectiveSfxVolume,
        ambient: _settings.effectiveAmbientVolume,
        music: _settings.effectiveMusicVolume,
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
    if (!_settings.sfxEnabled) return false;
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
