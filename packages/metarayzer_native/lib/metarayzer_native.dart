/// Dart side of the MetaRayzer macOS native layer: the companion frame link (TCP + Bonjour),
/// the latest-frame pipeline and the on-device hand detector (Apple Vision).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Where frames come from.
enum FrameSource {
  /// The iPhone companion app relaying the glasses camera (the real path).
  companion,

  /// DEVELOPMENT FALLBACK: the Mac's built-in camera. Not the glasses.
  webcam,
}

/// Number of joints per hand, in MediaPipe Hand Landmarker order (0 = wrist).
const int kHandJointCount = 21;

/// One hand as returned by the native detector, before tracking.
class NativeHand {
  NativeHand({required this.landmarks, required this.confidence, required this.chirality})
      : assert(landmarks.length == kHandJointCount * 3);

  /// Flat `[x, y, confidence]` per joint. x/y are normalized to the frame with a top-left
  /// origin (x right, y down). Joints that were not located have confidence 0.
  final Float64List landmarks;
  final double confidence;

  /// `left`, `right` or `unknown`.
  final String chirality;

  double x(int joint) => landmarks[joint * 3];
  double y(int joint) => landmarks[joint * 3 + 1];
  double jointConfidence(int joint) => landmarks[joint * 3 + 2];
}

sealed class NativeEvent {
  const NativeEvent();

  /// Parses one event map from the native event channel. Unknown types return null.
  static NativeEvent? fromMap(Map<Object?, Object?> map) {
    switch (map['type']) {
      case 'server':
        return ServerEvent(
          state: map['state'] as String? ?? 'stopped',
          port: map['port'] as int?,
          addresses: (map['addresses'] as List?)?.cast<String>() ?? const [],
          message: map['message'] as String?,
        );
      case 'companion':
        return CompanionEvent(
          connected: map['connected'] as bool? ?? false,
          address: map['address'] as String?,
          reason: map['reason'] as String?,
          deviceName: (map['hello'] as Map?)?['name'] as String?,
        );
      case 'companionStatus':
        return CompanionStatusEvent(
          Map<String, Object?>.from(map['status'] as Map? ?? const {}),
        );
      case 'webcam':
        return WebcamEvent(running: map['running'] as bool? ?? false, error: map['error'] as String?);
      case 'error':
        return ErrorEvent(map['message'] as String? ?? 'Unknown native error');
      case 'motion':
        double d(String k) => (map[k] as num?)?.toDouble() ?? 0;
        return MotionEvent(x: d('x'), y: d('y'), z: d('z'), w: (map['w'] as num?)?.toDouble() ?? 1, deviceTimeNs: map['t'] as int? ?? 0);
      case 'audioRoute':
        return AudioRouteEvent(Map<String, Object?>.from(map['route'] as Map? ?? const {}));
      case 'frame':
        final hands = (map['hands'] as List?)?.map((h) {
          final hand = h as Map;
          return NativeHand(
            landmarks: hand['landmarks'] as Float64List,
            confidence: (hand['confidence'] as num).toDouble(),
            chirality: hand['chirality'] as String? ?? 'unknown',
          );
        }).toList();
        return FrameEvent(
          jpeg: map['jpeg'] as Uint8List,
          width: map['width'] as int,
          height: map['height'] as int,
          seq: map['seq'] as int,
          source: map['source'] as String? ?? 'unknown',
          captureTimeMs: map['captureTimeMs'] as int? ?? 0,
          receivedAtMs: map['receivedAtMs'] as int? ?? 0,
          processedAtMs: map['processedAtMs'] as int? ?? 0,
          decodeMs: (map['decodeMs'] as num?)?.toDouble() ?? 0,
          detectMs: (map['detectMs'] as num?)?.toDouble() ?? 0,
          dropped: map['dropped'] as int? ?? 0,
          hands: hands,
        );
    }
    return null;
  }
}

/// State of the Mac-side listener the companion connects to.
class ServerEvent extends NativeEvent {
  const ServerEvent({required this.state, this.port, this.addresses = const [], this.message});

  /// `stopped`, `starting`, `listening` or `failed`.
  final String state;
  final int? port;
  final List<String> addresses;
  final String? message;
}

class CompanionEvent extends NativeEvent {
  const CompanionEvent({required this.connected, this.address, this.reason, this.deviceName});
  final bool connected;
  final String? address;
  final String? reason;
  final String? deviceName;
}

/// Glasses-side state reported by the companion (registration, permission, stream state...).
class CompanionStatusEvent extends NativeEvent {
  const CompanionStatusEvent(this.status);
  final Map<String, Object?> status;
}

class WebcamEvent extends NativeEvent {
  const WebcamEvent({required this.running, this.error});
  final bool running;
  final String? error;
}

/// Glasses orientation (unit quaternion) from the experimental DAT Motion capability, relayed by
/// the companion.
class MotionEvent extends NativeEvent {
  const MotionEvent({required this.x, required this.y, required this.z, required this.w, required this.deviceTimeNs});
  final double x, y, z, w;
  final int deviceTimeNs;
}

/// The active audio output route chosen by the native AudioController.
class AudioRouteEvent extends NativeEvent {
  const AudioRouteEvent(this.route);

  /// kind: mac | device | companion | fallback; name; note; spatial; devices: [{uid, name, bluetooth, glasses}].
  final Map<String, Object?> route;
}

class ErrorEvent extends NativeEvent {
  const ErrorEvent(this.message);
  final String message;
}

/// A decoded, processed camera frame. [hands] is null when detection was disabled.
class FrameEvent extends NativeEvent {
  const FrameEvent({
    required this.jpeg,
    required this.width,
    required this.height,
    required this.seq,
    required this.source,
    required this.captureTimeMs,
    required this.receivedAtMs,
    required this.processedAtMs,
    required this.decodeMs,
    required this.detectMs,
    required this.dropped,
    required this.hands,
  });

  final Uint8List jpeg;
  final int width;
  final int height;
  final int seq;
  final String source;
  final int captureTimeMs;
  final int receivedAtMs;
  final int processedAtMs;
  final double decodeMs;
  final double detectMs;
  final int dropped;
  final List<NativeHand>? hands;
}

class ServerInfo {
  const ServerInfo({required this.port, required this.bonjourType, required this.addresses, required this.detector, required this.hostName});
  final int port;
  final String bonjourType;
  final List<String> addresses;
  final String detector;
  final String hostName;
}

/// Thin wrapper over the platform channels. One instance per app.
class MetarayzerNative {
  MetarayzerNative({MethodChannel? control, EventChannel? events})
      : _control = control ?? const MethodChannel('metarayzer_native/control'),
        _events = events ?? const EventChannel('metarayzer_native/events');

  final MethodChannel _control;
  final EventChannel _events;

  late final Stream<NativeEvent> events = _events
      .receiveBroadcastStream()
      .map((e) => NativeEvent.fromMap(e as Map<Object?, Object?>))
      .where((e) => e != null)
      .cast<NativeEvent>();

  Future<ServerInfo> startServer() async {
    final info = await _control.invokeMapMethod<String, Object?>('startServer') ?? const {};
    return ServerInfo(
      port: info['port'] as int? ?? 0,
      bonjourType: info['bonjourType'] as String? ?? '',
      addresses: (info['addresses'] as List?)?.cast<String>() ?? const [],
      detector: info['detector'] as String? ?? '',
      hostName: info['hostName'] as String? ?? '',
    );
  }

  Future<void> stopServer() => _control.invokeMethod('stopServer');

  /// Forwards a stream command (`startStream` / `stopStream`) to the connected companion.
  Future<void> sendCommand(String cmd) => _control.invokeMethod('sendCommand', {'cmd': cmd});

  Future<void> setSource(FrameSource source) => _control.invokeMethod('setSource', {'source': source.name});

  Future<void> setDetectionEnabled(bool enabled) =>
      _control.invokeMethod('setDetectionEnabled', {'enabled': enabled});

  /// Applies audio settings and output choice; returns the resulting route map.
  Future<Map<String, Object?>> audioConfigure({
    required double sfx,
    required double ambient,
    required String mode,
    required String output,
    required bool ambientOn,
  }) async =>
      await _control.invokeMapMethod<String, Object?>('audioConfigure', {
        'sfx': sfx,
        'ambient': ambient,
        'mode': mode,
        'output': output,
        'ambientOn': ambientOn,
      }) ??
      const {};

  /// Plays a synthesized sound at game-world position (x right, z ahead, y up).
  Future<void> audioPlay(String sound, {double x = 0, double y = 1, double z = 1, double gain = 1, bool positional = true}) =>
      _control.invokeMethod('audioPlay', {'s': sound, 'x': x, 'y': y, 'z': z, 'g': gain, 'p': positional});

  /// Turns the audio listener with the in-game view (radians, + = right).
  Future<void> audioListener(double yaw) => _control.invokeMethod('audioListener', {'yaw': yaw});

  /// Must be called once per received [FrameEvent]; the native side holds back new frames
  /// while too many are unacknowledged, so the UI never builds up a backlog.
  Future<void> ackFrame() => _control.invokeMethod('ackFrame');
}
