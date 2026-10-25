import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import '../app/tracking_controller.dart';
import '../geometry/view_mapping.dart';
import 'camera_stream_indicator.dart';
import 'dwell/dwell_selector.dart';
import 'hand_overlay_painter.dart';

/// What a game or menu camera view should show right now.
enum CameraFeedState {
  /// Nothing: no frame, the stream is stopped (a retained last frame is never shown), or the
  /// glasses/companion are gone.
  hidden,

  /// New frames are arriving.
  live,

  /// The stream should be running but no new frames arrive: the last frame is shown dimmed and
  /// labeled as paused, never as live.
  paused,
}

/// The one visibility rule for the in-game and menu camera feeds. Connecting the glasses or
/// starting the stream only makes a feed *available*; each screen still decides whether it
/// shows one. With [simulated] input the hand comes from the mouse, so a camera view (and its
/// hand overlay) would not correspond to the cursor: hidden.
CameraFeedState cameraFeedState(TrackingController t, {bool simulated = false}) {
  if (simulated || !t.hasFrame) return CameraFeedState.hidden;
  return switch (cameraStreamState(t)) {
    CameraStreamState.live || CameraStreamState.dev => t.streamStalled ? CameraFeedState.paused : CameraFeedState.live,
    CameraStreamState.stalled => CameraFeedState.paused,
    CameraStreamState.connected || CameraStreamState.none => CameraFeedState.hidden,
  };
}

/// The game's camera view, shared by the in-game inset and the menu backdrop so both show the
/// same frames through the same pipeline: one [CameraPreview] (same fit, mirroring, rotation,
/// [FrameViewMapping] and hand overlay as everywhere else), the hand-pointer area that the menu
/// cursor and the staff both map from ([CursorMapper.box]), and the paused treatment. Callers
/// only decide size, placement and readability styling.
class CameraFeedView extends StatelessWidget {
  const CameraFeedView({super.key, required this.controller, this.simulated = false});
  final TrackingController controller;
  final bool simulated;

  @override
  Widget build(BuildContext context) {
    final state = cameraFeedState(controller, simulated: simulated);
    if (state == CameraFeedState.hidden) return const SizedBox.shrink();
    final paused = state == CameraFeedState.paused;
    return Stack(fit: StackFit.expand, children: [
      Opacity(opacity: paused ? 0.35 : 1, child: CameraPreview(controller: controller, pointerBox: const CursorMapper().box, showBadges: false)),
      if (paused)
        const Center(
          child: Padding(
            padding: EdgeInsets.all(6),
            child: FittedBox(fit: BoxFit.scaleDown, child: _Badge('STREAM PAUSED · last frame, not live', Color(0xFFFFC857))),
          ),
        ),
    ]);
  }
}

/// Live camera frame with the hand overlay. The image is placed at exactly
/// [FrameViewMapping.imageRect] with the same rotation/mirroring the overlay uses, so dots and
/// picture always line up.
class CameraPreview extends StatelessWidget {
  const CameraPreview({super.key, required this.controller, this.pointerBox, this.showBadges = true});
  final TrackingController controller;

  /// Optional dashed outline of a normalized region of the displayed frame (the hand-pointer
  /// area), drawn with the same mapping as the picture.
  final Rect? pointerBox;

  /// The source/stall badges (off where the caller labels the feed itself).
  final bool showBadges;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final frame = c.frame;
    return LayoutBuilder(builder: (context, constraints) {
      if (frame == null) return _Placeholder(controller: c);
      final mapping = FrameViewMapping(
        frameSize: Size(frame.width.toDouble(), frame.height.toDouble()),
        viewSize: constraints.biggest,
        fit: c.fit,
        mirrored: c.mirrored,
        quarterTurns: c.quarterTurns,
      );
      return ClipRect(
        child: Stack(children: [
          const Positioned.fill(child: ColoredBox(color: Colors.black)),
          Positioned.fromRect(
            rect: mapping.imageRect,
            child: Transform.flip(
              flipX: c.mirrored,
              child: RotatedBox(quarterTurns: c.quarterTurns, child: LiveFrameImage(controller: c, jpeg: frame.jpeg)),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: HandOverlayPainter(
                mapping: mapping,
                hands: c.hands,
                showLandmarks: c.showLandmarks,
                showLabels: c.showDebug,
              ),
            ),
          ),
          if (pointerBox != null) Positioned.fill(child: CustomPaint(painter: _PointerAreaPainter(mapping, pointerBox!))),
          if (showBadges && c.source == FrameSource.webcam)
            const Positioned(left: 12, top: 12, child: _Badge('DEV FALLBACK · Mac webcam, not glasses', Colors.amber)),
          if (showBadges && c.companionStatus['mock'] == true && c.source == FrameSource.companion)
            const Positioned(left: 12, top: 12, child: _Badge('DEV · mock feed (MockDeviceKit or dev sender), not real glasses', Colors.amber)),
          if (showBadges && c.streamStalled)
            const Positioned(right: 12, top: 12, child: _Badge('Stream stalled: no new frames', Colors.redAccent)),
        ]),
      );
    });
  }
}

/// Decodes the controller's JPEG frames for every visible preview at once: one decoder per
/// [TrackingController] (so the menu backdrop, the in-game inset and the setup screen never
/// decode the same frame twice), latest-frame-wins, and the decoded image is handed over when a
/// screen change swaps one preview for another (no blank frame, nothing restarted). The image is
/// released as soon as no preview is showing it.
class SharedFrameDecoder extends ChangeNotifier {
  SharedFrameDecoder._();

  static final Expando<SharedFrameDecoder> _instances = Expando();

  static SharedFrameDecoder of(TrackingController controller) => _instances[controller] ??= SharedFrameDecoder._();

  ui.Image? _image;
  Uint8List? _shown;
  Uint8List? _latest;
  bool _decoding = false;
  int _users = 0;

  /// The latest decoded frame (null until the first decode, or while nothing shows it).
  ui.Image? get image => _image;

  /// Previews currently showing this decoder's image.
  int get users => _users;

  /// Decodes started (for tests: one per new frame, however many previews are visible).
  @visibleForTesting
  int decodes = 0;

  void attach() => _users++;

  void detach() {
    _users--;
    if (_users > 0) return;
    _latest = null;
    _shown = null;
    _image?.dispose();
    _image = null;
  }

  /// Asks for [jpeg] to be shown. Repeated requests for the same bytes are free.
  void request(Uint8List jpeg) {
    if (identical(jpeg, _shown) || identical(jpeg, _latest)) return;
    _latest = jpeg;
    if (!_decoding) _decodeLatest();
  }

  Future<void> _decodeLatest() async {
    _decoding = true;
    while (_users > 0 && _latest != null && !identical(_latest, _shown)) {
      final bytes = _latest!;
      decodes++;
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (_users == 0) {
          frame.image.dispose();
          break;
        }
        _image?.dispose(); // RawImage keeps its own clone until it rebuilds
        _image = frame.image;
        _shown = bytes;
        notifyListeners();
      } catch (e) {
        debugPrint('[metarayzer] frame decode failed: $e');
        _shown = bytes; // don't retry the same broken frame
      }
    }
    _decoding = false;
  }
}

/// Shows [jpeg] through the controller's [SharedFrameDecoder].
class LiveFrameImage extends StatefulWidget {
  const LiveFrameImage({super.key, required this.controller, required this.jpeg});
  final TrackingController controller;
  final Uint8List jpeg;

  @override
  State<LiveFrameImage> createState() => _LiveFrameImageState();
}

class _LiveFrameImageState extends State<LiveFrameImage> {
  late SharedFrameDecoder _decoder;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _decoder = SharedFrameDecoder.of(widget.controller)
      ..attach()
      ..addListener(_changed)
      ..request(widget.jpeg);
  }

  void _detach() {
    _decoder
      ..removeListener(_changed)
      ..detach();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(LiveFrameImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _detach();
      _attach();
    } else if (!identical(oldWidget.jpeg, widget.jpeg)) {
      _decoder.request(widget.jpeg);
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawImage(image: _decoder.image, fit: BoxFit.fill, filterQuality: FilterQuality.low);
}

/// Dashed outline of [box] (normalized displayed-frame coordinates) in the preview's mapping.
class _PointerAreaPainter extends CustomPainter {
  _PointerAreaPainter(this.mapping, this.box);
  final FrameViewMapping mapping;
  final Rect box;

  @override
  void paint(Canvas canvas, Size size) {
    final image = mapping.imageRect;
    final r = Rect.fromLTRB(image.left + box.left * image.width, image.top + box.top * image.height, image.left + box.right * image.width, image.top + box.bottom * image.height);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0x99FFD27A);
    for (final (a, b) in [(r.topLeft, r.topRight), (r.topRight, r.bottomRight), (r.bottomRight, r.bottomLeft), (r.bottomLeft, r.topLeft)]) {
      final d = (b - a).distance;
      if (d <= 0) continue;
      final dir = (b - a) / d;
      for (var x = 0.0; x < d; x += 16) {
        canvas.drawLine(a + dir * x, a + dir * (x + 8).clamp(0, d), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_PointerAreaPainter old) => old.box != box || old.mapping.imageRect != mapping.imageRect;
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: color.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(6)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(text, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600, fontSize: 12)),
        ),
      );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.controller});
  final TrackingController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final info = c.serverInfo;
    final theme = Theme.of(context);
    final String headline;
    final String detail;
    if (c.source == FrameSource.webcam) {
      headline = 'Starting Mac webcam…';
      detail = 'Development fallback. Allow camera access if macOS asks.';
    } else if (c.server.state == 'failed') {
      headline = 'Companion listener failed';
      detail = c.server.message ?? '';
    } else if (!c.companionConnected) {
      headline = 'Waiting for the iPhone companion';
      detail = 'Open MetaRayzer Companion on your iPhone (same Wi-Fi). It finds this Mac automatically.\n'
          'Manual connection: ${info == null || info.addresses.isEmpty ? '<this Mac\'s IP>' : info.addresses.join(' or ')}'
          ' port ${info?.port ?? 47800}';
    } else {
      headline = 'Companion connected · no video yet';
      final stream = c.companionStatus['stream'] ?? 'unknown';
      detail = 'Glasses stream state: $stream. Press "Start glasses stream" '
          '(the glasses must be registered and camera permission granted in the companion).';
    }
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.videocam_off_outlined, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(headline, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(detail, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }
}
