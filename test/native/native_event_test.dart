import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

void main() {
  test('parses a frame event as sent by MetarayzerNativePlugin.swift', () {
    final landmarks = Float64List(63)..[0] = 0.25..[1] = 0.75..[2] = 0.9;
    final e = NativeEvent.fromMap({
      'type': 'frame',
      'jpeg': Uint8List.fromList([0xff, 0xd8]),
      'width': 504,
      'height': 896,
      'seq': 7,
      'source': 'glasses',
      'captureTimeMs': 1,
      'receivedAtMs': 2,
      'processedAtMs': 3,
      'decodeMs': 1.5,
      'detectMs': 8,
      'dropped': 2,
      'hands': [
        {'landmarks': landmarks, 'confidence': 0.8, 'chirality': 'left'},
      ],
    });
    expect(e, isA<FrameEvent>());
    final f = e! as FrameEvent;
    expect((f.width, f.height, f.seq, f.dropped), (504, 896, 7, 2));
    expect(f.detectMs, 8.0);
    final h = f.hands!.single;
    expect((h.x(0), h.y(0), h.jointConfidence(0)), (0.25, 0.75, 0.9));
    expect(h.chirality, 'left');
  });

  test('frame without hands means detection was off', () {
    final f = NativeEvent.fromMap({'type': 'frame', 'jpeg': Uint8List(0), 'width': 1, 'height': 1, 'seq': 0})! as FrameEvent;
    expect(f.hands, isNull);
  });

  test('parses status events', () {
    final s = NativeEvent.fromMap({'type': 'server', 'state': 'listening', 'port': 47800, 'addresses': ['10.0.0.2']})! as ServerEvent;
    expect((s.state, s.port), ('listening', 47800));
    expect(s.addresses, ['10.0.0.2']);

    final c = NativeEvent.fromMap({'type': 'companion', 'connected': true, 'hello': {'name': 'Pat’s iPhone', 'protocol': 1}})! as CompanionEvent;
    expect((c.connected, c.deviceName), (true, 'Pat’s iPhone'));

    final st = NativeEvent.fromMap({'type': 'companionStatus', 'status': {'stream': 'streaming', 'mock': false}})! as CompanionStatusEvent;
    expect(st.status['stream'], 'streaming');
  });

  test('unknown events are ignored', () {
    expect(NativeEvent.fromMap({'type': 'nope'}), isNull);
  });
}
