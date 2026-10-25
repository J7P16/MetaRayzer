import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/app/tracking_controller.dart';
import 'package:metarayzer/src/tracking/hand_tracker.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

class FakeNative implements MetarayzerNative {
  final controller = StreamController<NativeEvent>.broadcast();
  final commands = <String>[];
  int acks = 0;
  FrameSource? source;

  @override
  Stream<NativeEvent> get events => controller.stream;

  @override
  Future<ServerInfo> startServer() async =>
      const ServerInfo(port: 47800, bonjourType: '_metarayzer._tcp', addresses: ['192.168.1.20'], detector: 'fake', hostName: 'mac');

  @override
  Future<void> stopServer() async {}

  @override
  Future<void> sendCommand(String cmd) async => commands.add(cmd);

  @override
  Future<void> setSource(FrameSource source) async => this.source = source;

  @override
  Future<void> setDetectionEnabled(bool enabled) async {}

  @override
  Future<void> ackFrame() async => acks++;

  final plays = <({String sound, double x, double z, double gain, bool positional})>[];
  final configs = <Map<String, Object?>>[];
  final listenerYaws = <double>[];

  @override
  Future<Map<String, Object?>> audioConfigure({required double sfx, required double ambient, required String mode, required String output, required bool ambientOn}) async {
    configs.add({'sfx': sfx, 'ambient': ambient, 'mode': mode, 'output': output, 'ambientOn': ambientOn});
    return {'kind': 'mac', 'name': 'Test speakers'};
  }

  @override
  Future<void> audioPlay(String sound, {double x = 0, double y = 1, double z = 1, double gain = 1, bool positional = true}) async =>
      plays.add((sound: sound, x: x, z: z, gain: gain, positional: positional));

  @override
  Future<void> audioListener(double yaw) async => listenerYaws.add(yaw);
}

/// A hand whose 21 joints all sit at (x, y).
NativeHand hand(double x, double y, {double confidence = 0.9}) {
  final l = Float64List(63);
  for (var j = 0; j < 21; j++) {
    l[j * 3] = x;
    l[j * 3 + 1] = y;
    l[j * 3 + 2] = 0.9;
  }
  return NativeHand(landmarks: l, confidence: confidence, chirality: 'unknown');
}

FrameEvent frame(int seq, List<NativeHand>? hands, {String source = 'glasses'}) => FrameEvent(
      jpeg: Uint8List(0),
      width: 504,
      height: 896,
      seq: seq,
      source: source,
      captureTimeMs: 0,
      receivedAtMs: 1000,
      processedAtMs: 1012,
      decodeMs: 2,
      detectMs: 9,
      dropped: 0,
      hands: hands,
    );

void main() {
  late FakeNative native;
  late TrackingController c;
  late double now;

  setUp(() async {
    native = FakeNative();
    now = 0;
    c = TrackingController(native: native, nowMs: () => now, scheduleAck: (ack) => ack());
    await c.start();
  });

  tearDown(() => c.dispose());

  Future<void> emit(NativeEvent e) async {
    native.controller.add(e);
    await Future<void>.delayed(Duration.zero);
  }

  test('frames with hands produce tracked positions relative to the frame center', () async {
    await emit(const CompanionEvent(connected: true, deviceName: 'iPhone'));
    for (var i = 0; i < 3; i++) {
      now += 33;
      await emit(frame(i, [hand(0.75, 0.25)]));
    }
    expect(c.hands, hasLength(1));
    final p = c.positionOf(c.hands.single);
    expect(p.xr, closeTo(0.5, 1e-9));
    expect(p.yr, closeTo(-0.5, 1e-9));
    expect(p.offsetX, closeTo(126, 1e-9));
    expect(p.offsetY, closeTo(-224, 1e-9));
    expect(native.acks, 3, reason: 'every frame must be acknowledged');
  });

  test('hand indicators disappear after the hand leaves and the hold expires', () async {
    await emit(const CompanionEvent(connected: true));
    for (var i = 0; i < 3; i++) {
      now += 33;
      await emit(frame(i, [hand(0.5, 0.5)]));
    }
    now += 33;
    await emit(frame(3, []));
    expect(c.hands.single.status, TrackStatus.coasting);
    now += 400;
    await Future<void>.delayed(const Duration(milliseconds: 150)); // housekeeping tick
    expect(c.hands, isEmpty);
  });

  test('stall detection when frames stop', () async {
    await emit(const CompanionEvent(connected: true));
    now += 33;
    await emit(frame(0, []));
    expect(c.streamStalled, isFalse);
    now += 1500;
    expect(c.streamStalled, isTrue);
  });

  test('companion disconnect clears the preview and reports an error', () async {
    await emit(const CompanionEvent(connected: true));
    now += 33;
    await emit(frame(0, [hand(0.5, 0.5)]));
    await emit(const CompanionEvent(connected: false, reason: 'Companion closed the connection'));
    expect(c.frame, isNull);
    expect(c.hands, isEmpty);
    expect(c.lastError, contains('Companion disconnected'));
  });

  test('stream commands require a connected companion', () async {
    await c.startGlassesStream();
    expect(native.commands, isEmpty);
    expect(c.lastError, contains('No companion'));

    await emit(const CompanionEvent(connected: true));
    await c.startGlassesStream();
    await c.stopGlassesStream();
    expect(native.commands, ['startStream', 'stopStream']);
  });

  test('glasses-side errors from the companion are surfaced', () async {
    await emit(const CompanionEvent(connected: true));
    await emit(const CompanionStatusEvent({'stream': 'stopped', 'permission': 'denied', 'error': 'Camera permission denied'}));
    expect(c.companionStatus['permission'], 'denied');
    expect(c.lastError, 'Glasses: Camera permission denied');
  });

  test('frames from the inactive source are acknowledged but ignored', () async {
    await c.setSource(FrameSource.webcam);
    expect(native.source, FrameSource.webcam);
    now += 33;
    await emit(frame(0, [hand(0.5, 0.5)], source: 'glasses'));
    expect(c.frame, isNull);
    expect(native.acks, 1);
    await emit(frame(1, [hand(0.5, 0.5)], source: 'mac-webcam'));
    expect(c.frame?.seq, 1);
  });

  test('listener failure is shown to the user', () async {
    await emit(const ServerEvent(state: 'failed', message: 'Port 47800 is already in use.'));
    expect(c.lastError, 'Port 47800 is already in use.');
  });
}
