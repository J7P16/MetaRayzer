import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/app/tracking_controller.dart';
import 'package:metarayzer/src/games/wizard/cast_gesture.dart';
import 'package:metarayzer/src/input/camera_hand_input.dart';
import 'package:metarayzer/src/input/hand_input.dart';
import 'package:metarayzer/src/input/hand_pose.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import '../app/tracking_controller_test.dart' show FakeNative;

/// Real Vision landmarks from the fixture: index 0/1 = open palms, 3 = fist (thumbs-up).
List<({NativeHand hand, int w, int h})> loadFixture() {
  final doc = jsonDecode(File('test/fixtures/real_hand_landmarks.json').readAsStringSync()) as Map;
  return (doc['hands'] as List).cast<Map>().map((h) {
    return (
      hand: NativeHand(
        landmarks: Float64List.fromList((h['landmarks'] as List).cast<num>().map((n) => n.toDouble()).toList()),
        confidence: (h['confidence'] as num).toDouble(),
        chirality: h['chirality'] as String? ?? 'unknown',
      ),
      w: h['width'] as int,
      h: h['height'] as int,
    );
  }).toList();
}

NativeHand withChirality(NativeHand h, String c) => NativeHand(landmarks: h.landmarks, confidence: h.confidence, chirality: c);

void main() {
  final fixture = loadFixture();
  final openPalm = fixture.firstWhere((f) => f.w == 638).hand; // male_full_height_hands, hand 0
  final fist = fixture.firstWhere((f) => f.w == 382).hand; // thumb_up

  late FakeNative native;
  late TrackingController controller;
  late CameraHandInput input;
  late double now;
  var seq = 0;

  setUp(() async {
    native = FakeNative();
    now = 0;
    controller = TrackingController(native: native, nowMs: () => now, scheduleAck: (ack) => ack());
    await controller.start();
    input = CameraHandInput(controller);
  });

  tearDown(() {
    input.dispose();
    controller.dispose();
  });

  Future<void> send(List<NativeHand> hands, {int w = 504, int h = 896}) async {
    now += 40;
    native.controller.add(FrameEvent(
      jpeg: Uint8List(0), width: w, height: h, seq: seq++, source: 'glasses', captureTimeMs: 0, receivedAtMs: 0,
      processedAtMs: 0, decodeMs: 0, detectMs: 0, dropped: 0, hands: hands,
    ));
    await Future<void>.delayed(Duration.zero);
  }

  test('unavailable with a reason until the glasses stream', () async {
    expect(input.value.status, HandTrackingStatus.unavailable);
    expect(input.value.message, 'Glasses not connected');
    native.controller.add(const CompanionEvent(connected: true));
    await Future<void>.delayed(Duration.zero);
    expect(input.value.message, 'Glasses camera not streaming');
  });

  test('searching when frames arrive without a hand, tracking once confirmed', () async {
    native.controller.add(const CompanionEvent(connected: true));
    await send([]);
    expect(input.value.status, HandTrackingStatus.searching);
    await send([fist]);
    await send([fist]);
    expect(input.value.status, HandTrackingStatus.tracking);
    expect(input.value.pose, HandPose.fist);
    expect(input.value.simulated, isFalse);
  });

  test('every new camera frame gets a new frameId', () async {
    native.controller.add(const CompanionEvent(connected: true));
    await send([fist]);
    final a = input.value.frameId;
    await send([fist]);
    expect(input.value.frameId, a + 1);
  });

  test('prefers the left hand and sticks with it', () async {
    native.controller.add(const CompanionEvent(connected: true));
    final left = withChirality(fist, 'left');
    final right = withChirality(openPalm, 'right');
    await send([right, left], w: 638, h: 1000);
    await send([right, left], w: 638, h: 1000);
    expect(input.value.pose, HandPose.fist, reason: 'the left (fist) hand is selected');
    final id = input.value.handId;
    await send([left, right], w: 638, h: 1000);
    expect(input.value.handId, id);
  });

  test('a lost hand reports its last position but no pose (never a stale gesture)', () async {
    native.controller.add(const CompanionEvent(connected: true));
    await send([openPalm]);
    await send([openPalm]);
    expect(input.value.pose, HandPose.open);
    await send([]);
    expect(input.value.status, HandTrackingStatus.lost);
    expect(input.value.position, isNotNull);
    expect(input.value.pose, HandPose.unknown);
  });

  test('stream stall makes input unavailable', () async {
    native.controller.add(const CompanionEvent(connected: true));
    await send([fist]);
    now += 1500;
    await Future<void>.delayed(const Duration(milliseconds: 150)); // controller housekeeping tick
    expect(input.value.status, HandTrackingStatus.unavailable);
    expect(input.value.message, 'Camera stream stalled');
  });

  test('end to end: real fist landmarks then real open-palm landmarks cast exactly one spell', () async {
    native.controller.add(const CompanionEvent(connected: true));
    final recognizer = CastGestureRecognizer(nowMs: () => now);
    var casts = 0;
    input.addListener(() {
      if (recognizer.update(input.value)) casts++;
    });
    for (var i = 0; i < 4; i++) {
      await send([fist]);
    }
    expect(recognizer.feedback.phase, CastPhase.ready);
    for (var i = 0; i < 20; i++) {
      await send([openPalm]);
    }
    expect(casts, 1);
    for (var i = 0; i < 4; i++) {
      await send([fist]);
    }
    for (var i = 0; i < 4; i++) {
      await send([openPalm]);
    }
    expect(casts, 2);
  });

  test('position follows the preview mirror setting', () async {
    native.controller.add(const CompanionEvent(connected: true));
    await send([fist], w: 382, h: 406);
    await send([fist], w: 382, h: 406);
    final x = input.value.position!.dx;
    controller.update(mirrored: true);
    await send([fist], w: 382, h: 406);
    expect(input.value.position!.dx, closeTo(1 - x, 0.02));
  });
}
