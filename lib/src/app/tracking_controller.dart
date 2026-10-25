import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import '../geometry/hand_geometry.dart';
import '../geometry/hand_position.dart';
import '../geometry/view_mapping.dart';
import '../tracking/hand_tracker.dart';

void _log(String message) => developer.log(message, name: 'metarayzer');

/// Application state: link status, latest frame, tracked hands, stats and display settings.
/// UI widgets listen to this; all native interaction goes through [MetarayzerNative].
class TrackingController extends ChangeNotifier {
  TrackingController({
    MetarayzerNative? native,
    HandTracker? tracker,
    double Function()? nowMs,
    void Function(VoidCallback ack)? scheduleAck,
  })  : _native = native ?? MetarayzerNative(),
        _tracker = tracker ?? HandTracker(),
        _nowMs = nowMs ?? _monotonicMs,
        _scheduleAck = scheduleAck ?? _ackAfterNextFrame;

  final MetarayzerNative _native;
  final HandTracker _tracker;
  final double Function() _nowMs;
  final void Function(VoidCallback ack) _scheduleAck;
  StreamSubscription<NativeEvent>? _sub;
  Timer? _housekeeping;

  static final Stopwatch _clock = Stopwatch()..start();
  static double _monotonicMs() => _clock.elapsedMicroseconds / 1000;

  static void _ackAfterNextFrame(VoidCallback ack) {
    // Ack once the frame carrying this image has been built, so the native side never runs
    // more than a couple of frames ahead of what is on screen.
    SchedulerBinding.instance.addPostFrameCallback((_) => ack());
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// A frame older than this means the stream has stalled.
  static const double stallMs = 1000;

  // ---- Link state ----
  ServerEvent server = const ServerEvent(state: 'stopped');
  ServerInfo? serverInfo;
  CompanionEvent companion = const CompanionEvent(connected: false);
  Map<String, Object?> companionStatus = const {};
  FrameSource source = FrameSource.companion;
  bool webcamRunning = false;
  String? lastError;
  double? lastErrorAtMs;

  /// Latest glasses orientation sample (experimental DAT Motion via the companion), or null.
  final ValueNotifier<MotionEvent?> headMotion = ValueNotifier(null);

  /// The native bridge, shared with other services (audio).
  MetarayzerNative get native => _native;

  // ---- Frames and hands ----
  FrameEvent? frame;
  double? _lastFrameAtMs;
  List<TrackedHand> hands = const [];

  // ---- Stats (exponential moving averages) ----
  double displayFps = 0;
  double detectMs = 0;
  double pipelineMs = 0;
  double? glassesToMacMs;
  int droppedFrames = 0;
  int framesReceived = 0;

  // ---- Display settings ----
  bool mirrored = false;
  PreviewFit fit = PreviewFit.contain;
  int quarterTurns = 0;
  bool showLandmarks = false;
  bool showDebug = true;
  bool detectionEnabled = true;
  CenterMode centerMode = CenterMode.palmCentroid;

  bool get companionConnected => companion.connected;
  bool get streamStalled => _lastFrameAtMs != null && _nowMs() - _lastFrameAtMs! > stallMs;
  bool get hasFrame => frame != null;

  HandPosition positionOf(TrackedHand hand) {
    final f = frame!;
    return HandPosition(xn: hand.smoothed.x, yn: hand.smoothed.y, frameWidth: f.width.toDouble(), frameHeight: f.height.toDouble());
  }

  Future<void> start() async {
    _sub = _native.events.listen(_onEvent, onError: (Object e) => _setError('Native event stream error: $e'));
    _housekeeping = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    try {
      serverInfo = await _native.startServer();
      _log('listening for companion on ${serverInfo!.addresses.join(', ')}:${serverInfo!.port} using ${serverInfo!.detector}');
    } catch (e) {
      _setError('Could not start the companion listener: $e');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _housekeeping?.cancel();
    _sub?.cancel();
    _native.stopServer().catchError((_) {});
    super.dispose();
  }

  // ---- Actions ----

  Future<void> startGlassesStream() => _command('startStream');
  Future<void> stopGlassesStream() => _command('stopStream');

  Future<void> _command(String cmd) async {
    if (!companion.connected) {
      _setError('No companion iPhone connected. Open MetaRayzer Companion on the phone and connect to this Mac.');
      return;
    }
    try {
      await _native.sendCommand(cmd);
    } catch (e) {
      _setError('Could not send "$cmd" to the companion: $e');
    }
  }

  Future<void> setSource(FrameSource newSource) async {
    if (newSource == source) return;
    source = newSource;
    _resetFrames();
    notifyListeners();
    try {
      await _native.setSource(newSource);
    } on Exception catch (e) {
      _setError('Could not switch source: $e');
      if (newSource == FrameSource.webcam) {
        source = FrameSource.companion;
        await _native.setSource(FrameSource.companion).catchError((_) {});
        notifyListeners();
      }
    }
  }

  Future<void> setDetectionEnabled(bool enabled) async {
    detectionEnabled = enabled;
    if (!enabled) {
      _tracker.reset();
      hands = const [];
    }
    notifyListeners();
    await _native.setDetectionEnabled(enabled);
  }

  void update({bool? mirrored, PreviewFit? fit, int? quarterTurns, bool? showLandmarks, bool? showDebug, CenterMode? centerMode}) {
    this.mirrored = mirrored ?? this.mirrored;
    this.fit = fit ?? this.fit;
    this.quarterTurns = (quarterTurns ?? this.quarterTurns) % 4;
    this.showLandmarks = showLandmarks ?? this.showLandmarks;
    this.showDebug = showDebug ?? this.showDebug;
    if (centerMode != null && centerMode != this.centerMode) {
      this.centerMode = centerMode;
      _tracker.reset(); // centers jump when the definition changes; start clean
      hands = const [];
    }
    notifyListeners();
  }

  void clearError() {
    lastError = null;
    notifyListeners();
  }

  // ---- Event handling ----

  void _onEvent(NativeEvent event) {
    switch (event) {
      case FrameEvent():
        _onFrame(event);
        return; // _onFrame notifies
      case ServerEvent():
        server = event;
        if (event.state == 'failed') _setError(event.message ?? 'Companion listener failed', notify: false);
      case CompanionEvent():
        final wasConnected = companion.connected;
        companion = event;
        if (!event.connected) {
          companionStatus = const {};
          if (wasConnected && source == FrameSource.companion) {
            _setError('Companion disconnected${event.reason != null ? ': ${event.reason}' : ''}. '
                'Waiting for it to reconnect…', notify: false);
            _resetFrames();
          }
        }
        _log('companion ${event.connected ? 'connected (${event.deviceName ?? event.address})' : 'disconnected: ${event.reason}'}');
      case CompanionStatusEvent():
        companionStatus = event.status;
        final err = event.status['error'];
        if (err is String && err.isNotEmpty) _setError('Glasses: $err', notify: false);
      case WebcamEvent():
        webcamRunning = event.running;
        if (event.error != null) _setError(event.error!, notify: false);
      case ErrorEvent():
        _setError(event.message, notify: false);
      case MotionEvent():
        headMotion.value = event;
        return; // high-rate; consumers listen to [headMotion] directly
      case AudioRouteEvent():
        return; // handled by AudioService
    }
    notifyListeners();
  }

  void _onFrame(FrameEvent e) {
    final now = _nowMs();
    // Frames from a source we just switched away from can still be in flight.
    final expectedWebcam = source == FrameSource.webcam;
    if ((e.source == 'mac-webcam') != expectedWebcam) {
      _scheduleAck(_ack);
      return;
    }

    if (_lastFrameAtMs != null) {
      final dt = now - _lastFrameAtMs!;
      if (dt > 0) displayFps = _ema(displayFps, 1000 / dt, 0.1);
    }
    _lastFrameAtMs = now;
    framesReceived++;
    droppedFrames += e.dropped;
    frame = e;

    if (e.hands != null) {
      detectMs = _ema(detectMs, e.detectMs, 0.2);
      final observations = <HandObservation>[];
      for (final h in e.hands!) {
        final center = HandGeometry.center(h.landmarks, mode: centerMode);
        if (center == null) continue;
        observations.add(HandObservation(
          center: center,
          box: HandGeometry.boundingBox(h.landmarks),
          confidence: h.confidence,
          chirality: h.chirality,
          landmarks: h.landmarks,
        ));
      }
      hands = _tracker.update(observations, now, aspect: e.width / e.height);
    }

    pipelineMs = _ema(pipelineMs, (e.processedAtMs - e.receivedAtMs).toDouble(), 0.2);
    if (e.captureTimeMs > 0 && e.source != 'mac-webcam') {
      // Cross-device: only meaningful when phone and Mac clocks are NTP-synced.
      glassesToMacMs = _ema(glassesToMacMs ?? 0, (e.processedAtMs - e.captureTimeMs).toDouble(), 0.2);
    }
    notifyListeners();
    _scheduleAck(_ack);
  }

  void _ack() => _native.ackFrame().catchError((Object e) => _log('ackFrame failed: $e'));

  void _tick() {
    final before = hands.length;
    final wasStalled = _stalledReported;
    hands = _tracker.expire(_nowMs());
    _stalledReported = streamStalled;
    if (_stalledReported) displayFps = 0;
    if (hands.length != before || wasStalled != _stalledReported) notifyListeners();
  }

  bool _stalledReported = false;

  void _resetFrames() {
    frame = null;
    _lastFrameAtMs = null;
    displayFps = 0;
    _tracker.reset();
    hands = const [];
  }

  void _setError(String message, {bool notify = true}) {
    _log('error: $message');
    lastError = message;
    lastErrorAtMs = _nowMs();
    if (notify) notifyListeners();
  }

  static double _ema(double previous, double value, double alpha) => previous == 0 ? value : previous + alpha * (value - previous);
}
