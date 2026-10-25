import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/app/tracking_controller.dart';
import 'package:metarayzer/src/ui/camera_stream_indicator.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import '../app/tracking_controller_test.dart' show FakeNative;

void main() {
  late FakeNative native;
  late TrackingController t;
  var now = 0.0;

  setUp(() async {
    native = FakeNative();
    now = 0;
    t = TrackingController(native: native, nowMs: () => now, scheduleAck: (ack) => ack());
    await t.start();
  });
  tearDown(() => t.dispose());

  Future<void> emit(NativeEvent e) async {
    native.controller.add(e);
    await Future<void>.delayed(Duration.zero);
  }

  FrameEvent frame() => FrameEvent(
        jpeg: Uint8List(0), width: 504, height: 896, seq: 0, source: 'glasses', captureTimeMs: 0, receivedAtMs: 0,
        processedAtMs: 0, decodeMs: 0, detectMs: 0, dropped: 0, hands: const [],
      );

  test('nothing without a device', () {
    expect(cameraStreamState(t), CameraStreamState.none);
  });

  test('connected vs actively streaming vs stopped vs stalled', () async {
    await emit(const CompanionEvent(connected: true));
    expect(cameraStreamState(t), CameraStreamState.connected);
    await emit(const CompanionStatusEvent({'stream': 'streaming'}));
    expect(cameraStreamState(t), CameraStreamState.stalled, reason: 'reported streaming but no frames yet');
    now += 40;
    await emit(frame());
    expect(cameraStreamState(t), CameraStreamState.live);
    now += 1500;
    expect(cameraStreamState(t), CameraStreamState.stalled);
    await emit(const CompanionStatusEvent({'stream': 'stopped'}));
    expect(cameraStreamState(t), CameraStreamState.connected, reason: 'no LIVE indicator once the stream is stopped');
    await emit(const CompanionEvent(connected: false));
    expect(cameraStreamState(t), CameraStreamState.none);
  });

  test('mock feeds are labeled as dev, never LIVE glasses', () async {
    await emit(const CompanionEvent(connected: true));
    await emit(const CompanionStatusEvent({'stream': 'streaming', 'mock': true}));
    now += 40;
    await emit(frame());
    expect(cameraStreamState(t), CameraStreamState.dev);
  });
}
